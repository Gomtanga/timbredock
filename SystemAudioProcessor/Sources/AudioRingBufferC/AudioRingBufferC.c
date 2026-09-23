#include "AudioRingBufferC.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct LCCallbackGate {
    void *userdata;
    atomic_uint enabled;
    atomic_uint_fast64_t inFlight;
};

LCCallbackGate *lc_callback_gate_create(void *userdata) {
    if (userdata == NULL) return NULL;
    LCCallbackGate *gate = (LCCallbackGate *)calloc(1, sizeof(LCCallbackGate));
    if (gate == NULL) return NULL;
    gate->userdata = userdata;
    atomic_init(&gate->enabled, 1);
    atomic_init(&gate->inFlight, 0);
    if (!atomic_is_lock_free(&gate->enabled) || !atomic_is_lock_free(&gate->inFlight)) {
        free(gate);
        return NULL;
    }
    return gate;
}

void *lc_callback_gate_try_enter(LCCallbackGate *gate) {
    if (gate == NULL) return NULL;
    // One total order across entry, disable and the manager's count read means
    // an accepted callback is counted before disable can observe quiescence.
    atomic_fetch_add_explicit(&gate->inFlight, 1, memory_order_seq_cst);
    if (!atomic_load_explicit(&gate->enabled, memory_order_seq_cst)) {
        atomic_fetch_sub_explicit(&gate->inFlight, 1, memory_order_seq_cst);
        return NULL;
    }
    return gate->userdata;
}

void lc_callback_gate_leave(LCCallbackGate *gate) {
    if (gate != NULL) atomic_fetch_sub_explicit(&gate->inFlight, 1, memory_order_seq_cst);
}

void lc_callback_gate_disable(LCCallbackGate *gate) {
    if (gate != NULL) atomic_store_explicit(&gate->enabled, 0, memory_order_seq_cst);
}

uint64_t lc_callback_gate_in_flight(const LCCallbackGate *gate) {
    return gate == NULL ? 0 : atomic_load_explicit(&gate->inFlight, memory_order_seq_cst);
}

void lc_callback_gate_destroy(LCCallbackGate *gate) {
    // The caller must first remove the callback source; entry itself accesses
    // the gate even when it rejects userdata. See the public lifetime contract.
    free(gate);
}

struct LCLockFreeRingBuffer {
    float *storage;
    uint32_t capacity;
    uint32_t mask;
    atomic_uint_fast64_t readIndex;
    atomic_uint_fast64_t writeIndex;
    atomic_uint_fast64_t droppedWriteSamples;
    atomic_uint_fast64_t underrunSamples;
    atomic_uint_fast64_t totalWrittenSamples;
    atomic_uint_fast64_t totalReadSamples;
    atomic_uint discardRequested;
};

struct LCControlEventQueue {
    LCControlEvent *storage;
    uint32_t capacity;
    uint32_t mask;
    atomic_uint_fast64_t readIndex;
    atomic_uint_fast64_t writeIndex;
    atomic_uint_fast64_t appliedRevision;
    atomic_uint_fast64_t dspReceipt;
};

struct LCSpectrumSnapshot {
    atomic_uint_fast64_t sequence;
    atomic_uint_fast32_t active;
    atomic_uint_fast32_t values[LC_SPECTRUM_BIN_COUNT];
};

struct LCOutputGainRamp {
    // One atomic word publishes the whole command. Identical commands coalesce.
    atomic_uint_fast64_t requestedCommand;
    atomic_uint_fast32_t publishedCurrentBits;
    uint64_t appliedCommand;
    float currentGain;
    float targetGain;
    float step;
    uint32_t remainingFrames;
};

static uint32_t float_to_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float bits_to_float(uint32_t bits) {
    float value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static float clamp_gain(float gain) {
    if (!isfinite(gain)) {
        return 1.0f;
    }
    if (gain < 0.0f) {
        return 0.0f;
    }
    return gain > 1.0f ? 1.0f : gain;
}

static uint32_t next_power_of_two(uint32_t value) {
    if (value > UINT32_C(0x80000000)) return 0;
    if (value < 2) {
        return 2;
    }

    value--;
    value |= value >> 1;
    value |= value >> 2;
    value |= value >> 4;
    value |= value >> 8;
    value |= value >> 16;
    value++;
    return value;
}

LCLockFreeRingBuffer *lc_ring_buffer_create(uint32_t requestedCapacitySamples) {
    LCLockFreeRingBuffer *ringBuffer = (LCLockFreeRingBuffer *)calloc(1, sizeof(LCLockFreeRingBuffer));
    if (ringBuffer == NULL) {
        return NULL;
    }

    const uint32_t capacity = next_power_of_two(requestedCapacitySamples);
    if (capacity == 0) { free(ringBuffer); return NULL; }
    ringBuffer->storage = (float *)calloc(capacity, sizeof(float));
    if (ringBuffer->storage == NULL) {
        free(ringBuffer);
        return NULL;
    }

    ringBuffer->capacity = capacity;
    ringBuffer->mask = capacity - 1;
    atomic_init(&ringBuffer->readIndex, 0);
    atomic_init(&ringBuffer->writeIndex, 0);
    atomic_init(&ringBuffer->droppedWriteSamples, 0);
    atomic_init(&ringBuffer->underrunSamples, 0);
    atomic_init(&ringBuffer->totalWrittenSamples, 0);
    atomic_init(&ringBuffer->totalReadSamples, 0);
    atomic_init(&ringBuffer->discardRequested, 0);
    return ringBuffer;
}

// May be requested by management while producer/consumer are active.
void lc_ring_buffer_request_discard(LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer) atomic_store_explicit(&ringBuffer->discardRequested, 1, memory_order_release);
}

// Only the SPSC consumer may execute this. No storage is touched.
uint32_t lc_ring_buffer_consume_discard_request(LCLockFreeRingBuffer *ringBuffer) {
    if (!ringBuffer || !atomic_exchange_explicit(&ringBuffer->discardRequested, 0, memory_order_acq_rel)) return 0;
    const uint64_t write = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    atomic_store_explicit(&ringBuffer->readIndex, write, memory_order_release);
    return 1;
}

void lc_ring_buffer_destroy(LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return;
    }

    free(ringBuffer->storage);
    free(ringBuffer);
}

uint32_t lc_ring_buffer_capacity(const LCLockFreeRingBuffer *ringBuffer) {
    return ringBuffer == NULL ? 0 : ringBuffer->capacity;
}

uint32_t lc_ring_buffer_available(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_acquire);
    const uint64_t available = writeIndex - readIndex;
    return available > ringBuffer->capacity ? ringBuffer->capacity : (uint32_t)available;
}

uint32_t lc_ring_buffer_write_available(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }

    return ringBuffer->capacity - lc_ring_buffer_available(ringBuffer);
}

uint32_t lc_ring_buffer_push(LCLockFreeRingBuffer *ringBuffer, const float *samples, uint32_t sampleCount) {
    if (ringBuffer == NULL || samples == NULL || sampleCount == 0) {
        return 0;
    }

    const uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_acquire);
    uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_relaxed);
    const uint64_t available = writeIndex - readIndex;
    const uint32_t writable = available >= ringBuffer->capacity ? 0 : ringBuffer->capacity - (uint32_t)available;
    const uint32_t samplesToWrite = sampleCount < writable ? sampleCount : writable;
    if (samplesToWrite < sampleCount) {
        atomic_fetch_add_explicit(&ringBuffer->droppedWriteSamples,
                                  sampleCount - samplesToWrite,
                                  memory_order_relaxed);
    }

    if (samplesToWrite == 0) {
        return 0;
    }

    for (uint32_t index = 0; index < samplesToWrite; ++index) {
        ringBuffer->storage[(writeIndex + index) & ringBuffer->mask] = samples[index];
    }

    atomic_store_explicit(&ringBuffer->writeIndex, writeIndex + samplesToWrite, memory_order_release);
    atomic_fetch_add_explicit(
        &ringBuffer->totalWrittenSamples,
        samplesToWrite,
        memory_order_relaxed
    );
    return samplesToWrite;
}

uint32_t lc_ring_buffer_push_stereo_frame(LCLockFreeRingBuffer *ringBuffer, float left, float right) {
    if (ringBuffer == NULL) {
        return 0;
    }

    const uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_relaxed);
    const uint64_t available = writeIndex - readIndex;

    if (available + 2 > ringBuffer->capacity) {
        atomic_fetch_add_explicit(&ringBuffer->droppedWriteSamples, 2, memory_order_relaxed);
        return 0;
    }

    ringBuffer->storage[writeIndex & ringBuffer->mask] = left;
    ringBuffer->storage[(writeIndex + 1) & ringBuffer->mask] = right;
    atomic_store_explicit(&ringBuffer->writeIndex, writeIndex + 2, memory_order_release);
    atomic_fetch_add_explicit(&ringBuffer->totalWrittenSamples, 2, memory_order_relaxed);
    return 2;
}

uint32_t lc_ring_buffer_pop(LCLockFreeRingBuffer *ringBuffer, float *destination, uint32_t sampleCount) {
    if (ringBuffer == NULL || destination == NULL || sampleCount == 0) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_relaxed);
    const uint64_t available = writeIndex - readIndex;
    const uint32_t readable = available < sampleCount ? (uint32_t)available : sampleCount;

    for (uint32_t index = 0; index < readable; ++index) {
        destination[index] = ringBuffer->storage[(readIndex + index) & ringBuffer->mask];
    }

    if (readable < sampleCount) {
        atomic_fetch_add_explicit(&ringBuffer->underrunSamples,
                                  sampleCount - readable,
                                  memory_order_relaxed);
        memset(destination + readable, 0, (sampleCount - readable) * sizeof(float));
    }

    atomic_store_explicit(&ringBuffer->readIndex, readIndex + readable, memory_order_release);
    atomic_fetch_add_explicit(
        &ringBuffer->totalReadSamples,
        readable,
        memory_order_relaxed
    );
    return readable;
}

uint32_t lc_ring_buffer_pop_deinterleaved_stereo(LCLockFreeRingBuffer *ringBuffer,
                                                 float *left,
                                                 float *right,
                                                 uint32_t frameCount) {
    if (ringBuffer == NULL || left == NULL || right == NULL || frameCount == 0) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&ringBuffer->writeIndex, memory_order_acquire);
    uint64_t readIndex = atomic_load_explicit(&ringBuffer->readIndex, memory_order_relaxed);
    const uint64_t availableSamples = writeIndex - readIndex;
    const uint32_t availableFrames = (uint32_t)(availableSamples / 2);
    const uint32_t readableFrames = availableFrames < frameCount ? availableFrames : frameCount;

    for (uint32_t frame = 0; frame < readableFrames; ++frame) {
        left[frame] = ringBuffer->storage[(readIndex + frame * 2) & ringBuffer->mask];
        right[frame] = ringBuffer->storage[(readIndex + frame * 2 + 1) & ringBuffer->mask];
    }

    if (readableFrames < frameCount) {
        atomic_fetch_add_explicit(&ringBuffer->underrunSamples,
                                  (frameCount - readableFrames) * 2,
                                  memory_order_relaxed);
        memset(left + readableFrames, 0, (frameCount - readableFrames) * sizeof(float));
        memset(right + readableFrames, 0, (frameCount - readableFrames) * sizeof(float));
    }

    atomic_store_explicit(&ringBuffer->readIndex, readIndex + readableFrames * 2, memory_order_release);
    atomic_fetch_add_explicit(
        &ringBuffer->totalReadSamples,
        readableFrames * 2,
        memory_order_relaxed
    );
    return readableFrames;
}

uint64_t lc_ring_buffer_dropped_write_samples(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }
    return atomic_load_explicit(&ringBuffer->droppedWriteSamples, memory_order_relaxed);
}

uint64_t lc_ring_buffer_underrun_samples(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }
    return atomic_load_explicit(&ringBuffer->underrunSamples, memory_order_relaxed);
}

uint64_t lc_ring_buffer_total_written_samples(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }
    return atomic_load_explicit(&ringBuffer->totalWrittenSamples, memory_order_relaxed);
}

uint64_t lc_ring_buffer_total_read_samples(const LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return 0;
    }
    return atomic_load_explicit(&ringBuffer->totalReadSamples, memory_order_relaxed);
}

void lc_ring_buffer_reset_diagnostics(LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return;
    }
    atomic_store_explicit(&ringBuffer->droppedWriteSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&ringBuffer->underrunSamples, 0, memory_order_relaxed);
}

void lc_ring_buffer_clear(LCLockFreeRingBuffer *ringBuffer) {
    if (ringBuffer == NULL) {
        return;
    }

    memset(ringBuffer->storage, 0, ringBuffer->capacity * sizeof(float));
    atomic_store_explicit(&ringBuffer->readIndex, 0, memory_order_release);
    atomic_store_explicit(&ringBuffer->writeIndex, 0, memory_order_release);
}

LCOutputGainRamp *lc_output_gain_ramp_create(float initialGain) {
    LCOutputGainRamp *ramp = (LCOutputGainRamp *)calloc(1, sizeof(LCOutputGainRamp));
    if (ramp == NULL) {
        return NULL;
    }

    initialGain = clamp_gain(initialGain);
    const uint64_t initialCommand = (uint64_t)float_to_bits(initialGain) << 32;
    atomic_init(&ramp->requestedCommand, initialCommand);
    ramp->appliedCommand = initialCommand;
    atomic_init(&ramp->publishedCurrentBits, float_to_bits(initialGain));
    ramp->currentGain = initialGain;
    ramp->targetGain = initialGain;
    return ramp;
}

void lc_output_gain_ramp_destroy(LCOutputGainRamp *ramp) {
    free(ramp);
}

void lc_output_gain_ramp_set_target(LCOutputGainRamp *ramp, float targetGain, uint32_t frameCount) {
    if (ramp == NULL) {
        return;
    }

    targetGain = clamp_gain(targetGain);
    const uint64_t command = ((uint64_t)float_to_bits(targetGain) << 32) | frameCount;
    atomic_store_explicit(&ramp->requestedCommand, command, memory_order_release);
}

float lc_output_gain_ramp_current(const LCOutputGainRamp *ramp) {
    if (ramp == NULL) {
        return 1.0f;
    }
    return bits_to_float((uint32_t)atomic_load_explicit(
        &ramp->publishedCurrentBits,
        memory_order_acquire
    ));
}

static void output_gain_ramp_consume_command(LCOutputGainRamp *ramp) {
    const uint64_t command = atomic_load_explicit(&ramp->requestedCommand, memory_order_acquire);
    if (command == ramp->appliedCommand) return;
    ramp->appliedCommand = command;
    ramp->targetGain = bits_to_float((uint32_t)(command >> 32));
    ramp->remainingFrames = (uint32_t)command;
    if (ramp->remainingFrames == 0) {
        ramp->currentGain = ramp->targetGain;
        ramp->step = 0;
    } else {
        ramp->step = (ramp->targetGain - ramp->currentGain) / (float)ramp->remainingFrames;
    }
}

static float output_gain_ramp_next(LCOutputGainRamp *ramp) {
    if (ramp->remainingFrames > 0) {
        ramp->currentGain += ramp->step;
        ramp->remainingFrames--;
        if (ramp->remainingFrames == 0) {
            ramp->currentGain = ramp->targetGain;
        }
    }
    return ramp->currentGain;
}

void lc_output_gain_ramp_apply_stereo(LCOutputGainRamp *ramp,
                                      float *left,
                                      float *right,
                                      uint32_t frameCount) {
    if (ramp == NULL || left == NULL || right == NULL) {
        return;
    }

    output_gain_ramp_consume_command(ramp);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const float gain = output_gain_ramp_next(ramp);
        left[frame] *= gain;
        right[frame] *= gain;
    }
    atomic_store_explicit(
        &ramp->publishedCurrentBits,
        float_to_bits(ramp->currentGain),
        memory_order_release
    );
}

void lc_output_gain_ramp_apply_interleaved(LCOutputGainRamp *ramp,
                                           float *samples,
                                           uint32_t frameCount,
                                           uint32_t channelCount) {
    if (ramp == NULL || samples == NULL || channelCount == 0) {
        return;
    }

    output_gain_ramp_consume_command(ramp);
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const float gain = output_gain_ramp_next(ramp);
        const uint32_t base = frame * channelCount;
        for (uint32_t channel = 0; channel < channelCount; ++channel) {
            samples[base + channel] *= gain;
        }
    }
    atomic_store_explicit(
        &ramp->publishedCurrentBits,
        float_to_bits(ramp->currentGain),
        memory_order_release
    );
}

LCControlEventQueue *lc_control_event_queue_create(uint32_t requestedCapacityEvents) {
    LCControlEventQueue *queue = (LCControlEventQueue *)calloc(1, sizeof(LCControlEventQueue));
    if (queue == NULL) {
        return NULL;
    }

    const uint32_t capacity = next_power_of_two(requestedCapacityEvents);
    if (capacity == 0) { free(queue); return NULL; }
    queue->storage = (LCControlEvent *)calloc(capacity, sizeof(LCControlEvent));
    if (queue->storage == NULL) {
        free(queue);
        return NULL;
    }

    queue->capacity = capacity;
    queue->mask = capacity - 1;
    atomic_init(&queue->readIndex, 0);
    atomic_init(&queue->writeIndex, 0);
    atomic_init(&queue->appliedRevision, 0);
    atomic_init(&queue->dspReceipt, 0);
    if (!atomic_is_lock_free(&queue->dspReceipt)) {
        free(queue->storage); free(queue); return NULL;
    }
    return queue;
}

void lc_control_event_queue_destroy(LCControlEventQueue *queue) {
    if (queue == NULL) {
        return;
    }

    free(queue->storage);
    free(queue);
}

uint32_t lc_control_event_queue_push(LCControlEventQueue *queue, const LCControlEvent *event) {
    if (queue == NULL || event == NULL) {
        return 0;
    }

    const uint64_t readIndex = atomic_load_explicit(&queue->readIndex, memory_order_acquire);
    const uint64_t writeIndex = atomic_load_explicit(&queue->writeIndex, memory_order_relaxed);

    if (writeIndex - readIndex >= queue->capacity) {
        return 0;
    }

    queue->storage[writeIndex & queue->mask] = *event;
    atomic_store_explicit(&queue->writeIndex, writeIndex + 1, memory_order_release);
    return 1;
}

uint32_t lc_control_event_queue_pop(LCControlEventQueue *queue, LCControlEvent *event) {
    if (queue == NULL || event == NULL) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&queue->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&queue->readIndex, memory_order_relaxed);

    if (writeIndex == readIndex) {
        return 0;
    }

    *event = queue->storage[readIndex & queue->mask];
    atomic_store_explicit(&queue->readIndex, readIndex + 1, memory_order_release);
    return 1;
}

uint32_t lc_control_event_queue_available(const LCControlEventQueue *queue) {
    if (queue == NULL) {
        return 0;
    }

    const uint64_t writeIndex = atomic_load_explicit(&queue->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&queue->readIndex, memory_order_acquire);
    const uint64_t available = writeIndex - readIndex;
    return available > queue->capacity ? queue->capacity : (uint32_t)available;
}

void lc_control_event_queue_acknowledge(LCControlEventQueue *queue, uint64_t revision) {
    if (queue) atomic_store_explicit(&queue->appliedRevision, revision, memory_order_release);
}
uint64_t lc_control_event_queue_applied_revision(const LCControlEventQueue *queue) {
    return queue ? atomic_load_explicit(&queue->appliedRevision, memory_order_acquire) : 0;
}

void lc_control_event_queue_publish_dsp_receipt(LCControlEventQueue *queue, uint64_t receipt) {
    if (queue) atomic_store_explicit(&queue->dspReceipt, receipt, memory_order_release);
}
uint64_t lc_control_event_queue_dsp_receipt(const LCControlEventQueue *queue) {
    return queue ? atomic_load_explicit(&queue->dspReceipt, memory_order_acquire) : 0;
}

LCSpectrumSnapshot *lc_spectrum_snapshot_create(void) {
    LCSpectrumSnapshot *snapshot = (LCSpectrumSnapshot *)calloc(1, sizeof(LCSpectrumSnapshot));
    if (snapshot == NULL) {
        return NULL;
    }

    atomic_init(&snapshot->sequence, 0);
    atomic_init(&snapshot->active, 0);
    for (uint32_t index = 0; index < LC_SPECTRUM_BIN_COUNT; ++index) {
        atomic_init(&snapshot->values[index], 0);
    }
    return snapshot;
}

void lc_spectrum_snapshot_destroy(LCSpectrumSnapshot *snapshot) {
    free(snapshot);
}

void lc_spectrum_snapshot_publish(LCSpectrumSnapshot *snapshot, const float *values, uint32_t count) {
    if (snapshot == NULL || values == NULL) {
        return;
    }

    const uint32_t readable = count < LC_SPECTRUM_BIN_COUNT ? count : LC_SPECTRUM_BIN_COUNT;
    atomic_fetch_add_explicit(&snapshot->sequence, 1, memory_order_acq_rel);
    for (uint32_t index = 0; index < readable; ++index) {
        atomic_store_explicit(&snapshot->values[index], float_to_bits(values[index]), memory_order_relaxed);
    }
    for (uint32_t index = readable; index < LC_SPECTRUM_BIN_COUNT; ++index) {
        atomic_store_explicit(&snapshot->values[index], 0, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&snapshot->sequence, 1, memory_order_release);
}

uint32_t lc_spectrum_snapshot_copy(const LCSpectrumSnapshot *snapshot, float *destination, uint32_t count) {
    uint64_t ignoredSequence = 0;
    return lc_spectrum_snapshot_copy_if_new(snapshot, destination, count, UINT64_MAX, &ignoredSequence);
}

uint32_t lc_spectrum_snapshot_copy_if_new(const LCSpectrumSnapshot *snapshot,
                                          float *destination,
                                          uint32_t count,
                                          uint64_t previousSequence,
                                          uint64_t *newSequence) {
    if (snapshot == NULL || destination == NULL || count == 0) {
        return 0;
    }

    const uint32_t writable = count < LC_SPECTRUM_BIN_COUNT ? count : LC_SPECTRUM_BIN_COUNT;
    for (uint32_t attempt = 0; attempt < 3; ++attempt) {
        const uint64_t before = atomic_load_explicit(&snapshot->sequence, memory_order_acquire);
        if ((before & 1U) != 0) {
            continue;
        }
        if (before == previousSequence) {
            return 0;
        }

        for (uint32_t index = 0; index < writable; ++index) {
            const uint32_t bits = (uint32_t)atomic_load_explicit(&snapshot->values[index], memory_order_relaxed);
            destination[index] = bits_to_float(bits);
        }

        const uint64_t after = atomic_load_explicit(&snapshot->sequence, memory_order_acquire);
        if (before == after) {
            if (newSequence != NULL) {
                *newSequence = after;
            }
            return writable;
        }
    }
    return 0;
}

void lc_spectrum_snapshot_set_active(LCSpectrumSnapshot *snapshot, uint32_t active) {
    if (snapshot == NULL) {
        return;
    }
    atomic_store_explicit(&snapshot->active, active != 0, memory_order_release);
}

uint32_t lc_spectrum_snapshot_is_active(const LCSpectrumSnapshot *snapshot) {
    if (snapshot == NULL) {
        return 0;
    }
    return (uint32_t)atomic_load_explicit(&snapshot->active, memory_order_acquire);
}

void lc_spectrum_snapshot_clear(LCSpectrumSnapshot *snapshot) {
    if (snapshot == NULL) {
        return;
    }

    atomic_fetch_add_explicit(&snapshot->sequence, 1, memory_order_acq_rel);
    for (uint32_t index = 0; index < LC_SPECTRUM_BIN_COUNT; ++index) {
        atomic_store_explicit(&snapshot->values[index], 0, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&snapshot->sequence, 1, memory_order_release);
}
