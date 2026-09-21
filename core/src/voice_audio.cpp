#include "voice_audio.h"

#include <opus.h>
#include <portaudio.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>

namespace voice {

namespace {

/** Root-mean-square of a frame, mapped to something a meter can show. Speech
 *  sits far enough below full scale that a linear RMS barely moves the bar, so
 *  this leans on a square root to open up the quiet end. */
float levelOf(const int16_t* pcm, int n)
{
    if (n <= 0) return 0.0f;
    double sum = 0;
    for (int i = 0; i < n; ++i) {
        const double s = pcm[i] / 32768.0;
        sum += s * s;
    }
    return static_cast<float>(std::min(1.0, std::sqrt(std::sqrt(sum / n)) * 1.4));
}

/** One person you can hear: their decoder, their buffer, their meter. */
struct Peer {
    OpusDecoder*                    dec  = nullptr;
    std::deque<std::vector<int16_t>> buf;
    uint32_t                        lastSeq = 0;
    bool                            seenSeq = false;
    /** True until the buffer has primed; stays true after an underrun so a
     *  stutter refills rather than machine-gunning single frames. */
    bool                            priming = true;
    float                           level   = 0.0f;

    ~Peer() { if (dec) opus_decoder_destroy(dec); }
};

} // namespace

struct AudioEngine::Impl {
    PaStream*    stream = nullptr;
    OpusEncoder* enc    = nullptr;

    mutable std::mutex mu;                 // guards everything below
    std::vector<EncodedFrame> outgoing;
    std::map<std::string, Peer> peers;
    float    capLevel = 0.0f;
    uint32_t seq      = 0;
    bool     isMuted  = false;
    uint64_t nUnderrun = 0;
    uint64_t nDiscard  = 0;

    /** Scratch for the callback. Owned by the audio thread only. */
    std::vector<unsigned char> packet;
    std::vector<int32_t>       mix;

    static int paCallback(const void* in, void* out, unsigned long frames,
                          const PaStreamCallbackTimeInfo*, PaStreamCallbackFlags,
                          void* user)
    {
        return static_cast<Impl*>(user)->tick(static_cast<const int16_t*>(in),
                                              static_cast<int16_t*>(out),
                                              static_cast<int>(frames));
    }

    int tick(const int16_t* in, int16_t* out, int frames);
};

int AudioEngine::Impl::tick(const int16_t* in, int16_t* out, int frames)
{
    // PortAudio was asked for kFrameSamples and will hand us exactly that, but
    // a device can still surprise us; anything else is not a frame we can encode.
    const bool sized = (frames == kFrameSamples);

    std::lock_guard<std::mutex> lk(mu);

    // ── microphone ──
    if (in && sized) {
        capLevel = 0.75f * capLevel + 0.25f * levelOf(in, frames);
        if (!isMuted && enc) {
            packet.resize(kMaxPacket);
            const int n = opus_encode(enc, in, frames, packet.data(), kMaxPacket);
            if (n > 0) {
                EncodedFrame f;
                f.seq = ++seq;
                f.data.assign(packet.begin(), packet.begin() + n);
                // If the plugin stopped draining, the call is already broken;
                // keep the newest audio rather than a growing backlog of stale.
                if (outgoing.size() > 25) {
                    outgoing.erase(outgoing.begin());
                    ++nDiscard;
                }
                outgoing.push_back(std::move(f));
            }
        }
    } else if (in) {
        capLevel = 0.75f * capLevel + 0.25f * levelOf(in, frames);
    }

    // ── speakers: sum every peer that has audio ready ──
    mix.assign(frames, 0);
    for (auto& kv : peers) {
        Peer& p = kv.second;
        if (p.priming) {
            if (static_cast<int>(p.buf.size()) < kJitterPrime) { p.level *= 0.8f; continue; }
            p.priming = false;
        }
        if (p.buf.empty()) {
            // Wanted a frame, did not have one: the network fell behind.
            ++nUnderrun;
            p.priming = true;
            p.level *= 0.8f;
            continue;
        }
        const std::vector<int16_t>& f = p.buf.front();
        const int n = std::min<int>(frames, static_cast<int>(f.size()));
        for (int i = 0; i < n; ++i) mix[i] += f[i];
        p.level = 0.6f * p.level + 0.4f * levelOf(f.data(), n);
        p.buf.pop_front();
    }
    for (int i = 0; i < frames; ++i) {
        // Hard clip. Several people talking at once is exactly when this
        // matters, and a clip is far less unpleasant than a wrapped sample.
        out[i] = static_cast<int16_t>(std::max(-32768, std::min(32767, mix[i])));
    }
    return paContinue;
}

// ── lifecycle ────────────────────────────────────────────────────────────

AudioEngine::AudioEngine() : d(new Impl) {}

AudioEngine::~AudioEngine()
{
    stop();
    delete d;
}

bool AudioEngine::start(std::string* err)
{
    auto fail = [&](const std::string& m) { if (err) *err = m; return false; };
    if (d->stream) return true;

    int e = 0;
    d->enc = opus_encoder_create(kSampleRate, kChannels, OPUS_APPLICATION_VOIP, &e);
    if (e != OPUS_OK || !d->enc) return fail(std::string("opus encoder: ") + opus_strerror(e));
    opus_encoder_ctl(d->enc, OPUS_SET_BITRATE(kBitrate));
    // Voice on a lossy mesh: let Opus hide a dropped frame rather than leaving
    // a hole, and let it go quiet between words instead of paying for silence.
    opus_encoder_ctl(d->enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(d->enc, OPUS_SET_PACKET_LOSS_PERC(10));
    opus_encoder_ctl(d->enc, OPUS_SET_DTX(1));

    const PaError pe = Pa_Initialize();
    if (pe != paNoError) return fail(std::string("Pa_Initialize: ") + Pa_GetErrorText(pe));

    // One duplex stream on the default devices. Asking for kFrameSamples per
    // buffer means the callback fires once per Opus frame and no repacking is
    // needed anywhere.
    const PaError oe = Pa_OpenDefaultStream(&d->stream, kChannels, kChannels,
                                            paInt16, kSampleRate, kFrameSamples,
                                            &Impl::paCallback, d);
    if (oe != paNoError) {
        Pa_Terminate();
        return fail(std::string("Pa_OpenDefaultStream: ") + Pa_GetErrorText(oe));
    }
    const PaError se = Pa_StartStream(d->stream);
    if (se != paNoError) {
        Pa_CloseStream(d->stream);
        d->stream = nullptr;
        Pa_Terminate();
        return fail(std::string("Pa_StartStream: ") + Pa_GetErrorText(se));
    }
    return true;
}

void AudioEngine::stop()
{
    if (d->stream) {
        Pa_StopStream(d->stream);
        Pa_CloseStream(d->stream);
        d->stream = nullptr;
        Pa_Terminate();
    }
    std::lock_guard<std::mutex> lk(d->mu);
    if (d->enc) { opus_encoder_destroy(d->enc); d->enc = nullptr; }
    d->peers.clear();
    d->outgoing.clear();
    d->capLevel = 0.0f;
}

bool AudioEngine::running() const { return d->stream != nullptr; }

void AudioEngine::setMuted(bool m)
{
    std::lock_guard<std::mutex> lk(d->mu);
    d->isMuted = m;
    if (m) d->outgoing.clear();
}

bool AudioEngine::muted() const
{
    std::lock_guard<std::mutex> lk(d->mu);
    return d->isMuted;
}

// ── wire side ────────────────────────────────────────────────────────────

std::vector<EncodedFrame> AudioEngine::takeOutgoing()
{
    std::lock_guard<std::mutex> lk(d->mu);
    std::vector<EncodedFrame> out;
    out.swap(d->outgoing);
    return out;
}

void AudioEngine::pushIncoming(const std::string& peerId, uint32_t seq,
                               const unsigned char* data, int len)
{
    if (!data || len <= 0) return;

    std::vector<int16_t> pcm(kFrameSamples);
    int decoded = 0;
    {
        std::lock_guard<std::mutex> lk(d->mu);
        Peer& p = d->peers[peerId];
        if (!p.dec) {
            int e = 0;
            p.dec = opus_decoder_create(kSampleRate, kChannels, &e);
            if (e != OPUS_OK || !p.dec) { d->peers.erase(peerId); return; }
        }
        // Gossipsub gives no ordering promise. Reordering the stream would cost
        // more latency than it saves at 40 ms a frame, so anything that is not
        // newer than what we already took is dropped and counted.
        if (p.seenSeq && seq <= p.lastSeq) { ++d->nDiscard; return; }
        p.seenSeq = true;
        p.lastSeq = seq;

        decoded = opus_decode(p.dec, data, len, pcm.data(), kFrameSamples, 0);
        if (decoded <= 0) { ++d->nDiscard; return; }
        pcm.resize(decoded);

        if (static_cast<int>(p.buf.size()) >= kJitterMax) {
            // Further behind than the buffer is deep: the far end is ahead of
            // us and catching up matters more than keeping every frame.
            p.buf.pop_front();
            ++d->nDiscard;
        }
        p.buf.push_back(std::move(pcm));
    }
}

void AudioEngine::dropPeer(const std::string& peerId)
{
    std::lock_guard<std::mutex> lk(d->mu);
    d->peers.erase(peerId);
}

// ── meters ───────────────────────────────────────────────────────────────

float AudioEngine::captureLevel() const
{
    std::lock_guard<std::mutex> lk(d->mu);
    return d->isMuted ? 0.0f : d->capLevel;
}

float AudioEngine::peerLevel(const std::string& peerId) const
{
    std::lock_guard<std::mutex> lk(d->mu);
    auto it = d->peers.find(peerId);
    return it == d->peers.end() ? 0.0f : it->second.level;
}

uint64_t AudioEngine::underruns() const
{
    std::lock_guard<std::mutex> lk(d->mu);
    return d->nUnderrun;
}

uint64_t AudioEngine::discards() const
{
    std::lock_guard<std::mutex> lk(d->mu);
    return d->nDiscard;
}

} // namespace voice
