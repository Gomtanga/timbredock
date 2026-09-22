#ifndef AUDIO_RING_BUFFER_C_H
#define AUDIO_RING_BUFFER_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LCLockFreeRingBuffer LCLockFreeRingBuffer;
typedef struct LCControlEventQueue LCControlEventQueue;
typedef struct LCSpectrumSnapshot LCSpectrumSnapshot;
typedef struct LCOutputGainRamp LCOutputGainRamp;
typedef struct LCCallbackGate LCCallbackGate;

// The callback registration owns this gate until its callback source has been
// successfully removed. userdata must be non-NULL and remain alive until the
// gate is disabled and in_flight reaches zero. Creation fails if the counters
// cannot be implemented with lock-free atomics on this platform.
LCCallbackGate *lc_callback_gate_create(void *userdata);
// Each non-NULL result requires exactly one leave after the last userdata use.
// A rejected entry returns NULL and balances its own temporary entry count.
void *lc_callback_gate_try_enter(LCCallbackGate *gate);
void lc_callback_gate_leave(LCCallbackGate *gate);
// Permanent: a disabled registration must never be enabled or reused.
void lc_callback_gate_disable(LCCallbackGate *gate);
uint64_t lc_callback_gate_in_flight(const LCCallbackGate *gate);
// Preconditions: disabled, in_flight == 0, and successful removal of the
// callback source guarantees that no new try_enter call can start. A zero
// count alone does NOT permit destroying the gate while still registered.
void lc_callback_gate_destroy(LCCallbackGate *gate);

enum {
    LC_SPECTRUM_BIN_COUNT = 128
};

enum {
    LC_CONTROL_EVENT_DSP = 1,
    LC_CONTROL_EVENT_SPATIAL = 2,
    // Output conditioning parameter snapshot (headroom / oversampling / dither / DSD-DoP).
    // Purely additive variant; the control event queue stores events by sizeof(LCControlEvent),
    // so extending the struct is safe and does not touch the DSP/spatial paths.
    LC_CONTROL_EVENT_OUTPUT_CONDITIONING = 4
};

typedef struct {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
} LCBiquadCoefficients;

// Additive precision path for low-frequency filters at high sample rates.
// The existing Float coefficient contract remains available to old call sites.
typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} LCBiquadCoefficients64;

typedef struct {
    float intensity;
    float body;
    float outputGain;
    float headroomGain;
    uint32_t dspModel;
    LCBiquadCoefficients shelf;
    float warmthAmount;
    float virtualFeedbackGain;
    float bodyInjectionGain;
    float circuitHeadroomGain;
    float circuitMakeupGain;
    float wetMix;
    float bassAlpha;
    float subAlpha;
    LCBiquadCoefficients transformerPreEmphasis;
    LCBiquadCoefficients transformerDeEmphasis;
    float transformerDrive;
    float transformerAsymmetry;
    float transformerBiasOffset;
    float transformerMakeupGain;
    LCBiquadCoefficients exciterHighPass;
    float exciterDrive;
    float exciterWetMix;
    uint32_t exciterOversampleFactor;
    LCBiquadCoefficients exciterStage1LowPass1;
    LCBiquadCoefficients exciterStage1LowPass2;
    LCBiquadCoefficients exciterStage2LowPass1;
    LCBiquadCoefficients exciterStage2LowPass2;
    float exciterDCBlockPole;
    uint32_t preciseCircuitCoefficientsEnabled;
    LCBiquadCoefficients64 preciseShelf;
    LCBiquadCoefficients64 preciseTransformerPreEmphasis;
    LCBiquadCoefficients64 preciseTransformerDeEmphasis;
} LCDSPSettings;

typedef struct {
    uint32_t delaySamples;
    float gain;
} LCSpatialPathSettings;

typedef struct {
    uint32_t enabled;
    float amount;
    LCSpatialPathSettings ll;
    LCSpatialPathSettings lr;
    LCSpatialPathSettings rl;
    LCSpatialPathSettings rr;
} LCSpatialSettings;

// Flat snapshot of the output-conditioning parameters. Carried through the same
// lock-free SPSC control event queue as the DSP/spatial settings, so the audio
// thread reads it without locks or allocation.
typedef struct {
    uint32_t enabled;
    uint32_t outputMode;
    uint32_t oversamplingFactor;
    uint32_t filterMode;
    float headroomGain;
    uint32_t ditherEnabled;
    uint32_t noiseShapingEnabled;
    uint32_t dsdMode;
} LCOutputConditioningSettings;

typedef struct {
    uint32_t type;
    uint64_t revision;
    LCDSPSettings dsp;
    LCSpatialSettings spatial;
    LCOutputConditioningSettings conditioning;
} LCControlEvent;

// Ring ownership: exactly one producer calls push/push_stereo_frame and exactly
// one consumer calls pop/pop_deinterleaved/consume_discard_request. Calls on the
// same side must not overlap. Storage is owned by the ring; input/output arrays
// remain caller-owned and valid for the full call. Counts are float samples,
// except APIs explicitly named frame/frameCount (stereo means two samples).
// Capacity is rounded up to a power of two, minimum 2; requests > 2^31 or
// allocation failure return NULL. The full capacity is usable. Push/pop may
// transfer fewer samples than requested; always use the returned count.
// Create/destroy/clear are control-thread operations. Destroy requires all
// producers, consumers and diagnostic readers to be quiescent, including any
// callback registration that can still obtain the pointer. Never free a ring
// merely because available()==0. Availability/diagnostics are atomic snapshots,
// not reservations; a separate observer cannot authorize a producer/consumer.
LCLockFreeRingBuffer *lc_ring_buffer_create(uint32_t requestedCapacitySamples);
void lc_ring_buffer_destroy(LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_capacity(const LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_available(const LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_write_available(const LCLockFreeRingBuffer *ringBuffer);
uint32_t lc_ring_buffer_push(LCLockFreeRingBuffer *ringBuffer, const float *samples, uint32_t sampleCount);
uint32_t lc_ring_buffer_push_stereo_frame(LCLockFreeRingBuffer *ringBuffer, float left, float right);
uint32_t lc_ring_buffer_pop(LCLockFreeRingBuffer *ringBuffer, float *destination, uint32_t sampleCount);
uint32_t lc_ring_buffer_pop_deinterleaved_stereo(LCLockFreeRingBuffer *ringBuffer,
                                                 float *left,
                                                 float *right,
                                                 uint32_t frameCount);
uint64_t lc_ring_buffer_dropped_write_samples(const LCLockFreeRingBuffer *ringBuffer);
uint64_t lc_ring_buffer_underrun_samples(const LCLockFreeRingBuffer *ringBuffer);
uint64_t lc_ring_buffer_total_written_samples(const LCLockFreeRingBuffer *ringBuffer);
uint64_t lc_ring_buffer_total_read_samples(const LCLockFreeRingBuffer *ringBuffer);
void lc_ring_buffer_reset_diagnostics(LCLockFreeRingBuffer *ringBuffer);
// Reset storage/indices only after both producer and consumer are quiescent.
void lc_ring_buffer_clear(LCLockFreeRingBuffer *ringBuffer);
// A control-thread request is handled by the consumer at its next boundary.
void lc_ring_buffer_request_discard(LCLockFreeRingBuffer *ringBuffer);
// Consumer-thread only. Returns 1 when a pending discard was consumed.
uint32_t lc_ring_buffer_consume_discard_request(LCLockFreeRingBuffer *ringBuffer);

// One audio owner calls apply_*; those calls must not overlap. Control threads
// may set_target concurrently: each gain/frameCount pair is one atomic command,
// with latest-wins semantics (not a queue). current() is a published snapshot.
// Creation/destruction require quiescence; arrays are caller-owned for the call.
LCOutputGainRamp *lc_output_gain_ramp_create(float initialGain);
void lc_output_gain_ramp_destroy(LCOutputGainRamp *ramp);
void lc_output_gain_ramp_set_target(LCOutputGainRamp *ramp, float targetGain, uint32_t frameCount);
float lc_output_gain_ramp_current(const LCOutputGainRamp *ramp);
void lc_output_gain_ramp_apply_stereo(LCOutputGainRamp *ramp,
                                      float *left,
                                      float *right,
                                      uint32_t frameCount);
void lc_output_gain_ramp_apply_interleaved(LCOutputGainRamp *ramp,
                                           float *samples,
                                           uint32_t frameCount,
                                           uint32_t channelCount);

// SPSC: one producer pushes value copies; one consumer pops and acknowledges
// revisions only AFTER applying their settings. Failed push/pop returns 0 and
// transfers nothing; a full queue does not retain a failed event for retry.
// Capacity rounds up to a power of two (minimum 2); >2^31/allocation failure
// returns NULL. available/applied_revision are observations, not reservations.
// Destroy requires both sides and all observers to be quiescent. Event structs
// are same-build ABI values, not a stable serialized or cross-version format.
LCControlEventQueue *lc_control_event_queue_create(uint32_t requestedCapacityEvents);
void lc_control_event_queue_destroy(LCControlEventQueue *queue);
uint32_t lc_control_event_queue_push(LCControlEventQueue *queue, const LCControlEvent *event);
uint32_t lc_control_event_queue_pop(LCControlEventQueue *queue, LCControlEvent *event);
uint32_t lc_control_event_queue_available(const LCControlEventQueue *queue);
void lc_control_event_queue_acknowledge(LCControlEventQueue *queue, uint64_t revision);
uint64_t lc_control_event_queue_applied_revision(const LCControlEventQueue *queue);
// Packed DSP receipt: one lock-free word, published only after the callback
// consumes a DSP event. Zero clears it while callbacks are quiescent.
void lc_control_event_queue_publish_dsp_receipt(LCControlEventQueue *queue, uint64_t receipt);
uint64_t lc_control_event_queue_dsp_receipt(const LCControlEventQueue *queue);

// Single publisher: publish and clear must be serialized with each other.
// Readers may copy concurrently. A 0 copy result means no coherent new snapshot
// was obtained; destination may have been partially overwritten and must not be
// consumed on failure. At most LC_SPECTRUM_BIN_COUNT values are copied.
// set_active/is_active are independent atomic state. Destroy requires publisher,
// readers and active-state callers to be quiescent. Arrays are caller-owned.
LCSpectrumSnapshot *lc_spectrum_snapshot_create(void);
void lc_spectrum_snapshot_destroy(LCSpectrumSnapshot *snapshot);
void lc_spectrum_snapshot_publish(LCSpectrumSnapshot *snapshot, const float *values, uint32_t count);
uint32_t lc_spectrum_snapshot_copy(const LCSpectrumSnapshot *snapshot, float *destination, uint32_t count);
uint32_t lc_spectrum_snapshot_copy_if_new(const LCSpectrumSnapshot *snapshot,
                                          float *destination,
                                          uint32_t count,
                                          uint64_t previousSequence,
                                          uint64_t *newSequence);
void lc_spectrum_snapshot_set_active(LCSpectrumSnapshot *snapshot, uint32_t active);
uint32_t lc_spectrum_snapshot_is_active(const LCSpectrumSnapshot *snapshot);
void lc_spectrum_snapshot_clear(LCSpectrumSnapshot *snapshot);

#ifdef __cplusplus
}
#endif

#endif
