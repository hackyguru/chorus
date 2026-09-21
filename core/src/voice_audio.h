#ifndef VOICE_AUDIO_H
#define VOICE_AUDIO_H

#include <cstdint>
#include <string>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────
// The audio half of a voice room: microphone in, speakers out, Opus in the
// middle, and one jitter buffer per person you can hear.
//
// No Qt and no networking in here, on purpose. The plugin owns the wire; this
// owns the sound. That split is what let the poker engine be tested without a
// running Basecamp, and the same trick works here — see the offline harness.
//
// Shape of a call:
//
//   mic ─► PortAudio callback ─► Opus encode ─► outgoing queue ─► (plugin sends)
//                                                                      │
//   speakers ◄─ mix ◄─ jitter buffers ◄─ Opus decode ◄─ (plugin receives)
//
// Encoding happens in the audio callback because it is microseconds of work.
// Decoding deliberately does not: it happens on the plugin's thread as packets
// arrive, so the callback only ever sums PCM that is already sitting in a
// buffer. An audio callback that misses its deadline produces an audible click,
// so the rule is that it does arithmetic and nothing else.
// ─────────────────────────────────────────────────────────────────────────

namespace voice {

constexpr int kSampleRate   = 48000;
constexpr int kChannels     = 1;
/** 40 ms: 25 packets a second per speaker. 20 ms halves the latency and
 *  doubles the packet rate, which is the wrong trade on a gossipsub mesh. */
constexpr int kFrameMs      = 40;
constexpr int kFrameSamples = kSampleRate / 1000 * kFrameMs;   // 1920
constexpr int kBitrate      = 24000;
/** Opus at this bitrate lands near 120 bytes; the cap is slack, not a target. */
constexpr int kMaxPacket    = 400;

/** How deep a peer's buffer must get before we start playing it, and how deep
 *  we let it get before dropping the oldest frame. Three frames is 120 ms of
 *  slack against reordering and late arrivals. */
constexpr int kJitterPrime  = 3;
constexpr int kJitterMax    = 8;

/** One encoded frame, ready for the wire. */
struct EncodedFrame {
    uint32_t                   seq = 0;
    std::vector<unsigned char> data;
};

class AudioEngine {
public:
    AudioEngine();
    ~AudioEngine();
    AudioEngine(const AudioEngine&) = delete;
    AudioEngine& operator=(const AudioEngine&) = delete;

    /** Open the duplex stream. False on failure, with `err` set. */
    bool start(std::string* err);
    void stop();
    bool running() const;

    /** Muted still runs the stream — it just stops producing frames. */
    void setMuted(bool muted);
    bool muted() const;

    /** Take everything the microphone has encoded since the last call. The
     *  plugin drains this on its own thread and publishes each frame. */
    std::vector<EncodedFrame> takeOutgoing();

    /** Hand a peer's frame to its jitter buffer. Decodes here, off the audio
     *  thread. Out-of-order and duplicate sequence numbers are dropped. */
    void pushIncoming(const std::string& peerId, uint32_t seq,
                      const unsigned char* data, int len);

    /** Forget a peer: its buffer and decoder go away. */
    void dropPeer(const std::string& peerId);

    /** 0..1, smoothed, for meters. `peerLevel` is 0 for an unknown peer. */
    float captureLevel() const;
    float peerLevel(const std::string& peerId) const;

    /** Frames the mixer wanted but did not have — the honest measure of
     *  whether the network is keeping up with the call. */
    uint64_t underruns() const;
    /** Frames thrown away for arriving late, out of order, or too fast. */
    uint64_t discards() const;

private:
    struct Impl;
    Impl* d;
};

} // namespace voice

#endif // VOICE_AUDIO_H
