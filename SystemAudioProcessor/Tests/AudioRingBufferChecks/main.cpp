#include "AudioRingBufferC.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <thread>

namespace {
std::atomic<unsigned> failures { 0 };

void check(bool value, const char* message) {
    if (!value) {
        if (failures.fetch_add(1, std::memory_order_relaxed) < 12) {
            std::fprintf(stderr, "FAIL: %s\n", message);
        }
    }
}

using Clock = std::chrono::steady_clock;

void testCallbackGateLifetime() {
    check(lc_callback_gate_create(nullptr) == nullptr, "callback gate rejects ambiguous null userdata");
    check(lc_callback_gate_try_enter(nullptr) == nullptr && lc_callback_gate_in_flight(nullptr) == 0,
          "null callback gate rejects entry");
    uint64_t payload = 17;
    auto* gate = lc_callback_gate_create(&payload);
    check(gate != nullptr, "callback gate uses lock-free counters on the test platform");
    if (!gate) return;
    std::atomic<bool> entered { false }, release { false };
    std::thread callback([&] {
        auto* context = static_cast<uint64_t*>(lc_callback_gate_try_enter(gate));
        check(context == &payload, "enabled callback receives its registration userdata");
        entered.store(true, std::memory_order_release);
        while (!release.load(std::memory_order_acquire)) std::this_thread::yield();
        if (context) {
            *context = 23;
            lc_callback_gate_leave(gate);
        }
    });
    while (!entered.load(std::memory_order_acquire)) std::this_thread::yield();
    lc_callback_gate_disable(gate);
    lc_callback_gate_disable(gate);
    check(lc_callback_gate_in_flight(gate) == 1, "disable preserves a callback already using userdata");
    for (unsigned index = 0; index < 1000; ++index) {
        check(lc_callback_gate_try_enter(gate) == nullptr, "disabled callback never exposes userdata");
    }
    check(lc_callback_gate_in_flight(gate) == 1, "rejected callbacks balance their own entry counts");
    release.store(true, std::memory_order_release);
    callback.join();
    check(lc_callback_gate_in_flight(gate) == 0 && payload == 23,
          "quiescence waits for the last userdata write and callback exit");
    lc_callback_gate_destroy(gate); // callback source is joined; no later entry is possible.

    // Remove userdata while a disabled registration continues to be invoked.
    // Gate lifetime outlasts all threads; only the pointed-to payload is freed.
    // ASan/TSan can detect a late accepted entry accessing that retired payload.
    for (unsigned round = 0; round < 32; ++round) {
        auto* sharedPayload = new std::atomic<uint64_t>(0);
        auto* racingGate = lc_callback_gate_create(sharedPayload);
        check(racingGate != nullptr, "concurrent callback gate allocation");
        if (!racingGate) { delete sharedPayload; return; }
        std::atomic<bool> start { false }, retired { false };
        std::atomic<uint64_t> attempts { 0 }, accepted { 0 }, rejectedAfterRetirement { 0 };
        std::thread callbacks[4];
        for (auto& thread : callbacks) {
            thread = std::thread([&] {
                while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
                unsigned retiredAttempts = 0;
                while (retiredAttempts < 1000) {
                    const bool payloadWasRetired = retired.load(std::memory_order_acquire);
                    auto* context = static_cast<std::atomic<uint64_t>*>(lc_callback_gate_try_enter(racingGate));
                    if (context) {
                        check(!payloadWasRetired, "no accepted entry after disabled userdata retirement");
                        context->fetch_add(1, std::memory_order_relaxed);
                        accepted.fetch_add(1, std::memory_order_relaxed);
                        lc_callback_gate_leave(racingGate);
                    } else if (payloadWasRetired) {
                        rejectedAfterRetirement.fetch_add(1, std::memory_order_relaxed);
                    }
                    attempts.fetch_add(1, std::memory_order_relaxed);
                    if (payloadWasRetired) ++retiredAttempts;
                    std::this_thread::yield();
                }
            });
        }
        start.store(true, std::memory_order_release);
        while (attempts.load(std::memory_order_acquire) < 1000) std::this_thread::yield();
        lc_callback_gate_disable(racingGate);
        const auto deadline = Clock::now() + std::chrono::seconds(5);
        bool quiescent = false;
        while (Clock::now() < deadline) {
            if (lc_callback_gate_in_flight(racingGate) == 0) {
                quiescent = true;
                break;
            }
            std::this_thread::yield();
        }
        check(quiescent, "disable reaches userdata quiescence under concurrent entry");
        if (quiescent) delete sharedPayload;
        retired.store(true, std::memory_order_release);
        for (auto& thread : callbacks) thread.join();
        if (!quiescent) delete sharedPayload;
        check(accepted.load() > 0 && rejectedAfterRetirement.load() == 4000,
              "stress exercises accepted entries and calls after userdata retirement");
        check(lc_callback_gate_in_flight(racingGate) == 0, "all concurrent callbacks balanced entry/exit");
        lc_callback_gate_destroy(racingGate);
    }
}

void testConsumerOwnedDiscard() {
    auto* ring = lc_ring_buffer_create(1024);
    check(ring != nullptr, "ring allocation");
    if (!ring) return;
    constexpr uint32_t inputFrames = 200000;
    std::atomic<bool> start { false }, producerDone { false }, consumerDone { false };
    std::atomic<uint32_t> progress { 0 }, discarded { 0 }, received { 0 };
    const auto deadline = Clock::now() + std::chrono::seconds(15);

    std::thread producer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (uint32_t frame = 1; frame <= inputFrames; ++frame) {
            // One producer owns writeIndex. Dropped frames are permitted;
            // consumer output must remain a strictly ordered stereo sequence.
            lc_ring_buffer_push_stereo_frame(ring, float(frame), -float(frame));
            progress.store(frame, std::memory_order_release);
            if ((frame & 31u) == 0) std::this_thread::yield();
        }
        producerDone.store(true, std::memory_order_release);
    });

    std::thread consumer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        float previous = 0;
        while (!producerDone.load(std::memory_order_acquire) || lc_ring_buffer_available(ring) != 0) {
            discarded.fetch_add(lc_ring_buffer_consume_discard_request(ring), std::memory_order_relaxed);
            float left[17] {}, right[17] {};
            const uint32_t count = lc_ring_buffer_pop_deinterleaved_stereo(ring, left, right, 17);
            check(count <= 17, "bounded stereo read count");
            for (uint32_t frame = 0; frame < count && frame < 17; ++frame) {
                check(left[frame] > previous && left[frame] <= inputFrames,
                      "discard preserves increasing producer sequence");
                check(right[frame] == -left[frame], "discard preserves stereo frame pairing");
                previous = left[frame];
            }
            received.fetch_add(count, std::memory_order_relaxed);
            if (Clock::now() > deadline) {
                check(false, "ring progress must recover rather than stall after discard");
                break;
            }
            if (count == 0) std::this_thread::yield();
        }
        // Keep ownership on the same consumer thread through the final request.
        discarded.fetch_add(lc_ring_buffer_consume_discard_request(ring), std::memory_order_relaxed);
        consumerDone.store(true, std::memory_order_release);
    });

    std::thread manager([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (uint32_t trigger = 100; trigger < inputFrames; trigger += 100) {
            while (progress.load(std::memory_order_acquire) < trigger
                   && !consumerDone.load(std::memory_order_acquire)) std::this_thread::yield();
            if (consumerDone.load(std::memory_order_acquire)) break;
            lc_ring_buffer_request_discard(ring);
        }
    });
    start.store(true, std::memory_order_release);
    producer.join(); manager.join(); consumer.join();
    check(discarded.load() > 0, "manager discard actually overlaps consumption");
    check(received.load() > 0, "consumer made progress during discard stress");
    check(lc_ring_buffer_total_read_samples(ring) <= lc_ring_buffer_total_written_samples(ring),
          "discard does not fabricate read progress");

    // Both endpoints are now quiescent; ownership can move to this thread.
    lc_ring_buffer_consume_discard_request(ring);
    check(lc_ring_buffer_available(ring) == 0, "ring is empty after final consumer discard");
    check(lc_ring_buffer_push_stereo_frame(ring, 12345, -12345) == 2,
          "ring accepts a post-discard canary");
    float left = 0, right = 0;
    check(lc_ring_buffer_pop_deinterleaved_stereo(ring, &left, &right, 1) == 1
        && left == 12345 && right == -12345, "post-discard canary is delivered intact");
    lc_ring_buffer_clear(ring);
    check(lc_ring_buffer_available(ring) == 0, "quiescent clear remains supported");
    lc_ring_buffer_destroy(ring);
    check(lc_ring_buffer_create(UINT32_MAX) == nullptr, "overflowing ring capacity rejected");
}

void testCoherentGainCommands() {
    auto* ramp = lc_output_gain_ramp_create(0);
    check(ramp != nullptr, "gain ramp allocation");
    if (!ramp) return;
    constexpr uint32_t longRamp = 1000000;
    std::atomic<bool> start { false }, writerDone { false };
    std::thread writer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (uint32_t index = 0; index < 400000; ++index) {
            // Only these pairs are valid. A torn {target=1, frames=0} causes
            // an immediate rise, while {target=0, frames=long} causes a decline.
            lc_output_gain_ramp_set_target(ramp, index & 1u ? 1 : 0, index & 1u ? longRamp : 0);
            if ((index & 255u) == 0) std::this_thread::yield();
        }
        lc_output_gain_ramp_set_target(ramp, 0, 0);
        writerDone.store(true, std::memory_order_release);
    });
    start.store(true, std::memory_order_release);
    float previous = 0;
    uint32_t frames = 0;
    do {
        float left = 1, right = 1;
        lc_output_gain_ramp_apply_stereo(ramp, &left, &right, 1);
        check(std::isfinite(left) && left >= 0 && left <= 1 && left == right,
              "gain is finite, bounded and equal across channels");
        check(left <= previous + 1.0f / longRamp + 0.0000002f,
              "target and duration stay coherent: no immediate rise");
        check(left == 0 || left + 0.0000002f >= previous,
              "target and duration stay coherent: no unrequested slow decline");
        previous = left;
        ++frames;
    } while (!writerDone.load(std::memory_order_acquire) || frames < 200000);
    writer.join();
    float sample = 1;
    lc_output_gain_ramp_apply_interleaved(ramp, &sample, 1, 1);
    check(sample == 0 && lc_output_gain_ramp_current(ramp) == 0, "final immediate mute is consumed");
    lc_output_gain_ramp_set_target(ramp, 1, 4);
    float interleaved[8] { 1,1,1,1,1,1,1,1 };
    lc_output_gain_ramp_apply_interleaved(ramp, interleaved, 4, 2);
    check(interleaved[0] == 0.25f && interleaved[2] == 0.5f
        && interleaved[4] == 0.75f && interleaved[6] == 1,
        "coherent snapshot still produces the requested ramp duration");
    lc_output_gain_ramp_destroy(ramp);
}

LCControlEvent eventFor(uint64_t revision) {
    LCControlEvent event {};
    event.type = LC_CONTROL_EVENT_SPATIAL;
    event.revision = revision;
    event.spatial.ll.delaySamples = uint32_t(revision * 3);
    event.spatial.rr.gain = float(revision);
    return event;
}

void testQueueOverflowFinalAndAcknowledgment() {
    auto* queue = lc_control_event_queue_create(8);
    check(queue != nullptr, "control queue allocation");
    if (!queue) return;
    check(lc_control_event_queue_applied_revision(queue) == 0, "ack starts at zero");
    check(lc_control_event_queue_dsp_receipt(queue) == 0, "DSP receipt starts unconfirmed");
    for (uint64_t revision = 1; revision <= 8; ++revision) {
        const auto event = eventFor(revision);
        check(lc_control_event_queue_push(queue, &event) == 1, "queue fills to capacity");
    }
    const auto final = eventFor(9);
    check(lc_control_event_queue_push(queue, &final) == 0, "overflow is reported to producer");
    for (uint64_t revision = 1; revision <= 8; ++revision) {
        LCControlEvent event {};
        check(lc_control_event_queue_pop(queue, &event) == 1 && event.revision == revision,
              "full queue preserves FIFO order");
        lc_control_event_queue_acknowledge(queue, event.revision);
    }
    check(lc_control_event_queue_push(queue, &final) == 1, "producer can retry rejected final");
    LCControlEvent received {};
    check(lc_control_event_queue_pop(queue, &received) == 1 && received.revision == 9,
          "retried final is preserved");
    lc_control_event_queue_acknowledge(queue, received.revision);
    check(lc_control_event_queue_applied_revision(queue) == 9, "final revision is acknowledged");
    lc_control_event_queue_destroy(queue);

    queue = lc_control_event_queue_create(64);
    if (!queue) { check(false, "concurrent queue allocation"); return; }
    constexpr uint64_t count = 50000;
    std::atomic<bool> start { false }, consumerDone { false }, timedOut { false };
    const auto deadline = Clock::now() + std::chrono::seconds(15);
    std::thread producer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (uint64_t revision = 1; revision <= count; ++revision) {
            const auto event = eventFor(revision);
            while (!lc_control_event_queue_push(queue, &event)) {
                if (timedOut.load(std::memory_order_acquire)) return;
                std::this_thread::yield();
            }
        }
    });
    std::thread consumer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        uint64_t expected = 1;
        while (expected <= count) {
            LCControlEvent event {};
            if (lc_control_event_queue_pop(queue, &event)) {
                check(event.revision == expected && event.spatial.ll.delaySamples == expected * 3
                    && event.spatial.rr.gain == float(expected), "SPSC event payload and revision stay coherent");
                lc_control_event_queue_acknowledge(queue, event.revision);
                const uint64_t value = event.revision % 10001;
                lc_control_event_queue_publish_dsp_receipt(queue, (UINT64_C(1) << 63) | (value << 16) | (value ^ 0xffff));
                ++expected;
            } else {
                std::this_thread::yield();
            }
            if (Clock::now() > deadline) {
                check(false, "queue producer/consumer make bounded progress");
                timedOut.store(true, std::memory_order_release);
                break;
            }
        }
        consumerDone.store(true, std::memory_order_release);
    });
    start.store(true, std::memory_order_release);
    uint64_t previous = 0;
    while (!consumerDone.load(std::memory_order_acquire)) {
        const auto revision = lc_control_event_queue_applied_revision(queue);
        check(revision >= previous && revision <= count, "manager observes monotonic applied revision");
        previous = revision;
        const auto receipt = lc_control_event_queue_dsp_receipt(queue);
        if (receipt != 0) check((((receipt >> 16) & 0xffff) ^ (receipt & 0xffff)) == 0xffff,
                               "DSP receipt is one coherent atomic word across threads");
        std::this_thread::yield();
    }
    producer.join(); consumer.join();
    check(lc_control_event_queue_applied_revision(queue) == count, "last concurrent revision acknowledged");
    check(lc_control_event_queue_available(queue) == 0, "queue drained after final revision");
    lc_control_event_queue_destroy(queue);
    check(lc_control_event_queue_create(UINT32_MAX) == nullptr, "overflowing queue capacity rejected");
}
}

int main() {
    testCallbackGateLifetime();
    testConsumerOwnedDiscard();
    testCoherentGainCommands();
    testQueueOverflowFinalAndAcknowledgment();
    const unsigned count = failures.load();
    std::printf("AudioRingBufferChecks: %u failure(s)\n", count);
    return count ? 1 : 0;
}
