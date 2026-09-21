// Offline check of the two claims the whole design rests on: that Opus at our
// exact frame size and bitrate carries speech, and that a packet is small
// enough that 25 a second is a sane thing to put on a gossipsub topic.
// No audio device is opened, so this runs anywhere.
#include <opus.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

constexpr int kSampleRate = 48000;
constexpr int kChannels   = 1;
constexpr int kFrameMs    = 40;
constexpr int kFrameSamples = kSampleRate / 1000 * kFrameMs;
constexpr int kBitrate    = 24000;
constexpr int kMaxPacket  = 400;
constexpr int kIdBytes    = 16;
constexpr int kAudioHeader = 1 + kIdBytes + 4;

static int g_fail = 0;
static void check(bool ok, const std::string& what)
{
    printf(ok ? "  ok    %s\n" : "  FAIL  %s\n", what.c_str());
    if (!ok) ++g_fail;
}

/** Something speech-shaped: a couple of voiced harmonics with an envelope. */
static void speechish(std::vector<int16_t>& pcm, int n, double t0)
{
    pcm.resize(n);
    for (int i = 0; i < n; ++i) {
        const double t = t0 + i / double(kSampleRate);
        const double env = 0.5 + 0.5 * std::sin(2 * M_PI * 3.0 * t);
        const double s = 0.45 * std::sin(2 * M_PI * 130 * t)
                       + 0.25 * std::sin(2 * M_PI * 260 * t)
                       + 0.12 * std::sin(2 * M_PI * 520 * t);
        pcm[i] = int16_t(std::max(-1.0, std::min(1.0, s * env)) * 26000);
    }
}

static double rms(const int16_t* p, int n)
{
    double s = 0;
    for (int i = 0; i < n; ++i) { const double v = p[i] / 32768.0; s += v * v; }
    return std::sqrt(s / n);
}

int main()
{
    printf("=== voice offline harness ===\n\n-- opus at the module's settings --\n");

    int e = 0;
    OpusEncoder* enc = opus_encoder_create(kSampleRate, kChannels, OPUS_APPLICATION_VOIP, &e);
    check(e == OPUS_OK && enc, "encoder created (48 kHz mono, VOIP)");
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(kBitrate));
    opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
    opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(10));

    OpusDecoder* dec = opus_decoder_create(kSampleRate, kChannels, &e);
    check(e == OPUS_OK && dec, "decoder created");

    std::vector<int16_t> in, out(kFrameSamples);
    std::vector<unsigned char> pkt(kMaxPacket);

    int    frames = 0, biggest = 0;
    long   total = 0;
    double inRms = 0, outRms = 0;
    bool   allDecoded = true;

    for (int k = 0; k < 50; ++k) {                 // two seconds of "speech"
        speechish(in, kFrameSamples, k * (kFrameMs / 1000.0));
        const int n = opus_encode(enc, in.data(), kFrameSamples, pkt.data(), kMaxPacket);
        if (n <= 0) { allDecoded = false; break; }
        total += n; ++frames; if (n > biggest) biggest = n;

        const int got = opus_decode(dec, pkt.data(), n, out.data(), kFrameSamples, 0);
        if (got != kFrameSamples) { allDecoded = false; break; }

        inRms  += rms(in.data(), kFrameSamples);
        outRms += rms(out.data(), kFrameSamples);
    }
    check(allDecoded && frames == 50, "50 frames encode and decode, full length each");

    const double avg = frames ? double(total) / frames : 0;
    inRms /= frames ? frames : 1;
    outRms /= frames ? frames : 1;

    // Opus is lossy, so this is an energy sanity check, not a bit comparison:
    // if the decoded frame carries roughly the energy that went in, the codec
    // is genuinely carrying the signal rather than emitting silence.
    const double ratio = inRms > 0 ? outRms / inRms : 0;
    check(ratio > 0.6 && ratio < 1.6, "decoded audio keeps the input's energy");

    printf("\n     frame              %d ms (%d samples)\n", kFrameMs, kFrameSamples);
    printf("     opus payload       %.0f bytes average, %d worst\n", avg, biggest);
    printf("     packet on the wire %.0f bytes (+%d header)\n", avg + kAudioHeader, kAudioHeader);
    printf("     per speaker        %.1f packets/s, %.1f kbit/s\n",
           1000.0 / kFrameMs, (avg + kAudioHeader) * (1000.0 / kFrameMs) * 8 / 1000.0);

    printf("\n-- does it fit the transport --\n");
    check(avg + kAudioHeader < 1024, "a packet is far below the 150 KiB delivery cap");
    check(1000.0 / kFrameMs <= 25, "at most 25 packets a second per speaker");
    // Six people all talking at once is the worst case a small room produces.
    const double busy = (avg + kAudioHeader) * (1000.0 / kFrameMs) * 6 * 8 / 1000.0;
    printf("     six talking at once %.0f kbit/s inbound\n", busy);
    check(busy < 500, "a six-way room stays under half a megabit");

    printf("\n-- packet framing --\n");
    std::vector<uint8_t> wire;
    wire.push_back('A');
    for (int i = 0; i < kIdBytes; ++i) wire.push_back(uint8_t(i));
    const uint32_t seq = 0xDEADBEEF;
    wire.push_back(seq & 0xff); wire.push_back((seq >> 8) & 0xff);
    wire.push_back((seq >> 16) & 0xff); wire.push_back((seq >> 24) & 0xff);
    wire.insert(wire.end(), pkt.begin(), pkt.begin() + int(avg));

    const uint32_t back = uint32_t(wire[17]) | (uint32_t(wire[18]) << 8)
                        | (uint32_t(wire[19]) << 16) | (uint32_t(wire[20]) << 24);
    check(wire[0] == 'A', "kind byte survives the round trip");
    check(back == seq, "sequence number survives the round trip");
    check(int(wire.size()) == kAudioHeader + int(avg), "packet length is header plus payload");

    opus_encoder_destroy(enc);
    opus_decoder_destroy(dec);
    printf("\n=== %s (%d failure%s) ===\n", g_fail ? "FAILURES" : "ALL PASS",
           g_fail, g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
