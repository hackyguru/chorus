#include "voice_impl.h"

#include "logos_sdk.h"          // generated: modules().delivery_module

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <random>
#include <sstream>

using nlohmann::json;

namespace {

constexpr uint8_t kPktAudio = 'A';
constexpr uint8_t kPktHello = 'H';
constexpr uint8_t kPktBye   = 'B';

constexpr int kIdBytes     = 16;
constexpr int kHeaderBytes = 1 + kIdBytes;          // kind + sender
constexpr int kAudioHeader = kHeaderBytes + 4;      // + seq

/** A heartbeat every 2 s, gone after 6 s. Booth uses 15 s and 45 s, which is
 *  right for a radio directory and far too slow for a call — you want a name
 *  to disappear at about the moment the voice does. */
constexpr int64_t kHeartbeatMs = 2000;
constexpr int64_t kPeerTtlMs   = 6000;

int64_t nowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::string toHex(const std::vector<uint8_t>& b)
{
    static const char* d = "0123456789abcdef";
    std::string s;
    s.reserve(b.size() * 2);
    for (uint8_t c : b) { s.push_back(d[c >> 4]); s.push_back(d[c & 15]); }
    return s;
}

void putU32(std::vector<uint8_t>& v, uint32_t x)
{
    v.push_back(static_cast<uint8_t>(x & 0xff));
    v.push_back(static_cast<uint8_t>((x >> 8) & 0xff));
    v.push_back(static_cast<uint8_t>((x >> 16) & 0xff));
    v.push_back(static_cast<uint8_t>((x >> 24) & 0xff));
}

uint32_t getU32(const uint8_t* p)
{
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
         | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

} // namespace

// ── lifecycle ────────────────────────────────────────────────────────────

VoiceImpl::VoiceImpl()
    : m_audio(new voice::AudioEngine)
{
    std::random_device rd;
    m_myIdRaw.resize(kIdBytes);
    for (int i = 0; i < kIdBytes; ++i) m_myIdRaw[i] = static_cast<uint8_t>(rd() & 0xff);
    m_myId = toHex(m_myIdRaw);
}

VoiceImpl::~VoiceImpl()
{
    m_pumping = false;
    if (m_pump.joinable()) m_pump.join();
    if (m_audio) m_audio->stop();
}

void VoiceImpl::onContextReady()
{
    // Nothing to load from disk yet. The node is brought up on demand, so
    // opening the module does not put you on the network.
    //
    // VOICE_AUTOJOIN is a testing hook: two Basecamps on one machine share a
    // process name, and the macOS accessibility layer cannot reliably tell
    // them apart, so driving both UIs from a script does not work. With this
    // set, the second instance joins on its own and only the first needs a
    // human (or a click) at all.
    const char* room = std::getenv("VOICE_AUTOJOIN");
    if (!room || !*room) return;
    const std::string roomId = room;
    const char* nm = std::getenv("VOICE_NAME");
    const std::string name = nm ? nm : "";

    // Off the init path and after a beat: the dependency is not necessarily
    // ready to answer at the moment the context lands.
    std::thread([this, roomId, name] {
        std::this_thread::sleep_for(std::chrono::seconds(3));
        joinRoom(roomId, name);
    }).detach();
}

std::string VoiceImpl::myId()
{
    std::lock_guard<std::mutex> lk(m_mu);
    return m_myId;
}

// ── network ──────────────────────────────────────────────────────────────

void VoiceImpl::wireDeliveryEvents()
{
    if (m_eventsWired) return;
    m_eventsWired = true;

    // Registered before start(), so the first connection event is not missed.
    modules().delivery_module.onMessageReceived(
        [this](const std::string&, const std::string& contentTopic,
               const std::vector<uint8_t>& payload, int64_t) {
            onPacket(contentTopic, payload);
        });

    modules().delivery_module.onConnectionStateChanged(
        [this](const std::string& status, int64_t) {
            bool changed = false;
            {
                std::lock_guard<std::mutex> lk(m_mu);
                // "PartiallyConnected" is the per-shard variant and counts.
                const int next = status.find("Connected") != std::string::npos ? 2 : 1;
                changed = (m_status != next);
                m_status = next;
            }
            if (changed) roomChanged(roomState());
        });
}

StdLogosResult VoiceImpl::startNetwork()
{
    {
        std::lock_guard<std::mutex> lk(m_mu);
        if (m_started) return {true, "already running"};
        m_status = 1;
        m_netError.clear();
    }

    if (!m_nodeCreated) {
        // Two Basecamps on one machine collide on the delivery port, and the
        // logos.dev bootstrap peers are not dependable enough to find a sibling
        // through. Deterministic node keys give each instance a known PeerID so
        // the pair dials directly over loopback.
        //
        // The B identity below is what this delivery_module actually derives
        // from KEY_B, read off a live run. The value part6 still carries is
        // stale, which silently cost it one of its two dial directions.
        const char* portEnv = std::getenv("VOICE_TCPPORT");
        const int customPort = portEnv ? std::atoi(portEnv) : 0;
        const bool isB    = customPort > 0;
        const int tcpPort = isB ? customPort : 60000;
        const int udpPort = isB ? 9000 + (tcpPort - 60000) : 9000;

        static const char* KEY_A = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
        static const char* KEY_B = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f21";
        static const char* PEERID_A = "16Uiu2HAm4Ms862Gnqafssgvik4JJ1LuqWMcKNipq4nm2UaoLRbeP";
        static const char* PEERID_B = "16Uiu2HAmKCaJ7sfcm1aHY8TAShdsKttUHvDwTPbgTkJhLQu8AMiG";

        std::ostringstream peer;
        peer << "/ip4/127.0.0.1/tcp/" << (isB ? 60000 : 60001) << "/p2p/"
             << (isB ? PEERID_A : PEERID_B);

        json cfg;
        cfg["logLevel"]      = "INFO";
        cfg["mode"]          = "Core";
        cfg["preset"]        = "logos.dev";
        // The logos.dev fleet moved to cluster 3 (logos-delivery #4113), but the
        // preset baked into delivery_module 0.2.0 still says 2 — every fleet
        // peer then drops us with "different clusterId reported: 2 vs 3".
        // An explicit clusterId wins over the preset.
        cfg["clusterId"]     = 3;
        cfg["relay"]         = true;       // gossipsub — the only path voice uses
        cfg["tcpPort"]       = tcpPort;
        cfg["discv5UdpPort"] = udpPort;
        cfg["nodeKey"]       = isB ? KEY_B : KEY_A;
        cfg["staticNodes"]   = json::array({ peer.str() });

        const StdLogosResult r = modules().delivery_module.createNode(cfg.dump());
        if (!r.success) {
            std::lock_guard<std::mutex> lk(m_mu);
            m_status = 3;
            m_netError = r.error.empty() ? "createNode failed" : r.error;
            return {false, {}, m_netError};
        }
        m_nodeCreated = true;
    }

    wireDeliveryEvents();

    const StdLogosResult s = modules().delivery_module.start();
    if (!s.success) {
        std::lock_guard<std::mutex> lk(m_mu);
        m_status = 3;
        m_netError = s.error.empty() ? "start failed" : s.error;
        return {false, {}, m_netError};
    }

    {
        std::lock_guard<std::mutex> lk(m_mu);
        m_started = true;
        // Optimistic: the real confirmation arrives on connectionStateChanged,
        // and running solo there is no peer to become connected to.
        if (m_status < 2) m_status = 2;
    }
    roomChanged(roomState());
    return {true, "started"};
}

StdLogosResult VoiceImpl::stopNetwork()
{
    leaveRoom();
    {
        std::lock_guard<std::mutex> lk(m_mu);
        if (!m_started) return {true, "already stopped"};
    }
    modules().delivery_module.stop();
    {
        std::lock_guard<std::mutex> lk(m_mu);
        m_started = false;
        m_status  = 0;
    }
    roomChanged(roomState());
    return {true, "stopped"};
}

// ── rooms ────────────────────────────────────────────────────────────────

std::string VoiceImpl::topicFor(const std::string& roomId)
{
    // A topic segment, not a free string. Without this, "Team Standup" and
    // "team-standup" would be different rooms that look like the same one.
    std::string clean;
    for (char c : roomId) {
        if (c >= 'A' && c <= 'Z')                              clean.push_back(c - 'A' + 'a');
        else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                 || c == '-' || c == '_')                      clean.push_back(c);
        else if (!clean.empty() && clean.back() != '-')        clean.push_back('-');
    }
    while (!clean.empty() && clean.back() == '-') clean.pop_back();
    if (clean.empty()) clean = "lobby";
    return "/logos-voice/1/" + clean + "/json";
}

StdLogosResult VoiceImpl::joinRoom(const std::string& roomId, const std::string& displayName)
{
    if (roomId.empty()) return {false, {}, "room id is empty"};

    {
        std::lock_guard<std::mutex> lk(m_mu);
        if (!m_topic.empty()) { /* switch rooms */ }
    }
    if (!m_topic.empty()) leaveRoom();

    const StdLogosResult net = startNetwork();
    if (!net.success) return net;

    const std::string topic = topicFor(roomId);
    const StdLogosResult sub = modules().delivery_module.subscribe(topic);
    if (!sub.success) {
        std::lock_guard<std::mutex> lk(m_mu);
        m_netError = sub.error.empty() ? "subscribe failed" : sub.error;
        return {false, {}, m_netError};
    }

    {
        std::lock_guard<std::mutex> lk(m_mu);
        m_roomId = roomId;
        m_topic  = topic;
        m_myName = displayName.empty() ? ("Guest-" + m_myId.substr(0, 4)) : displayName;
        m_peers.clear();
    }

    // The microphone opens only on join. Holding the input device open in the
    // lobby lights the system recording indicator for a call you have not
    // joined, which is a promise this module should not break.
    std::string err;
    if (!m_audio->start(&err)) {
        std::lock_guard<std::mutex> lk(m_mu);
        m_audioError = err;
    } else {
        std::lock_guard<std::mutex> lk(m_mu);
        m_audioError.clear();
    }

    if (!m_pumping.exchange(true)) m_pump = std::thread(&VoiceImpl::pumpLoop, this);

    announce(kPktHello);
    roomChanged(roomState());
    return {true, topic};
}

StdLogosResult VoiceImpl::leaveRoom()
{
    std::string topic;
    {
        std::lock_guard<std::mutex> lk(m_mu);
        topic = m_topic;
    }
    if (topic.empty()) return {true, "not in a room"};

    announce(kPktBye);

    m_pumping = false;
    if (m_pump.joinable()) m_pump.join();
    m_audio->stop();

    modules().delivery_module.unsubscribe(topic);

    {
        std::lock_guard<std::mutex> lk(m_mu);
        m_topic.clear();
        m_roomId.clear();
        m_peers.clear();
    }
    m_sent = 0;
    m_recv = 0;

    roomChanged(roomState());
    return {true, "left"};
}

StdLogosResult VoiceImpl::setMuted(bool muted)
{
    m_audio->setMuted(muted);
    roomChanged(roomState());
    return {true, muted};
}

// ── the wire ─────────────────────────────────────────────────────────────

void VoiceImpl::send(const std::vector<uint8_t>& packet)
{
    std::string topic;
    {
        std::lock_guard<std::mutex> lk(m_mu);
        topic = m_topic;
    }
    if (topic.empty()) return;
    modules().delivery_module.send(topic, packet);
}

void VoiceImpl::announce(uint8_t kind)
{
    std::vector<uint8_t> pkt;
    std::string name;
    {
        std::lock_guard<std::mutex> lk(m_mu);
        pkt.reserve(kHeaderBytes + m_myName.size());
        pkt.push_back(kind);
        pkt.insert(pkt.end(), m_myIdRaw.begin(), m_myIdRaw.end());
        name = m_myName;
    }
    if (kind == kPktHello) pkt.insert(pkt.end(), name.begin(), name.end());
    send(pkt);
}

void VoiceImpl::pumpLoop()
{
    int64_t lastBeat = 0;
    while (m_pumping) {
        // Drain whatever the encoder produced and put each frame on the topic.
        const std::vector<voice::EncodedFrame> frames = m_audio->takeOutgoing();
        for (const voice::EncodedFrame& f : frames) {
            std::vector<uint8_t> pkt;
            pkt.reserve(kAudioHeader + f.data.size());
            pkt.push_back(kPktAudio);
            {
                std::lock_guard<std::mutex> lk(m_mu);
                pkt.insert(pkt.end(), m_myIdRaw.begin(), m_myIdRaw.end());
            }
            putU32(pkt, f.seq);
            pkt.insert(pkt.end(), f.data.begin(), f.data.end());
            send(pkt);
            ++m_sent;
        }

        const int64_t now = nowMs();
        if (now - lastBeat >= kHeartbeatMs) {
            lastBeat = now;
            announce(kPktHello);

            bool dropped = false;
            std::vector<std::string> gone;
            {
                std::lock_guard<std::mutex> lk(m_mu);
                for (auto it = m_peers.begin(); it != m_peers.end();) {
                    if (now - it->second.lastSeenMs > kPeerTtlMs) {
                        gone.push_back(it->first);
                        it = m_peers.erase(it);
                        dropped = true;
                    } else {
                        ++it;
                    }
                }
            }
            for (const std::string& id : gone) m_audio->dropPeer(id);
            if (dropped) roomChanged(roomState());
        }

        // Half a frame. The encoder runs on the audio device's clock, so
        // polling faster than the frame rate keeps send latency off the books.
        std::this_thread::sleep_for(std::chrono::milliseconds(voice::kFrameMs / 2));
    }
}

void VoiceImpl::onPacket(const std::string& topic, const std::vector<uint8_t>& payload)
{
    if (static_cast<int>(payload.size()) < kHeaderBytes) return;
    {
        std::lock_guard<std::mutex> lk(m_mu);
        if (m_topic.empty() || topic != m_topic) return;
    }

    const uint8_t kind = payload[0];
    const std::vector<uint8_t> idRaw(payload.begin() + 1, payload.begin() + kHeaderBytes);
    const std::string id = toHex(idRaw);

    {
        std::lock_guard<std::mutex> lk(m_mu);
        if (id == m_myId) return;              // our own message, back off the mesh
    }

    if (kind == kPktBye) {
        bool had = false;
        {
            std::lock_guard<std::mutex> lk(m_mu);
            had = m_peers.erase(id) > 0;
        }
        if (had) { m_audio->dropPeer(id); roomChanged(roomState()); }
        return;
    }

    // Any packet is proof the sender is still here, audio included — so a
    // steady talker never expires just because one heartbeat went missing.
    bool isNew = false;
    {
        std::lock_guard<std::mutex> lk(m_mu);
        auto it = m_peers.find(id);
        isNew = (it == m_peers.end());
        Peer& p = m_peers[id];
        p.lastSeenMs = nowMs();
        if (kind == kPktHello && static_cast<int>(payload.size()) > kHeaderBytes) {
            p.name.assign(payload.begin() + kHeaderBytes, payload.end());
        }
        if (p.name.empty()) p.name = "Guest-" + id.substr(0, 4);
    }
    if (isNew) roomChanged(roomState());

    if (kind == kPktAudio && static_cast<int>(payload.size()) > kAudioHeader) {
        const uint32_t seq = getU32(payload.data() + kHeaderBytes);
        m_audio->pushIncoming(id, seq, payload.data() + kAudioHeader,
                              static_cast<int>(payload.size()) - kAudioHeader);
        ++m_recv;
    }
}

// ── state for the UI ─────────────────────────────────────────────────────

std::string VoiceImpl::roomState()
{
    json st;
    std::vector<std::pair<std::string, std::string>> peers;
    {
        std::lock_guard<std::mutex> lk(m_mu);
        st["status"]   = m_status;
        st["myId"]     = m_myId;
        st["myName"]   = m_myName;
        st["roomId"]   = m_roomId;
        st["topic"]    = m_topic;
        st["inRoom"]   = !m_topic.empty();
        st["netError"] = m_netError;
        st["micError"] = m_audioError;
        for (const auto& kv : m_peers) peers.emplace_back(kv.first, kv.second.name);
    }

    st["muted"]   = m_audio->muted();
    st["micOk"]   = m_audio->running();
    st["myLevel"] = m_audio->captureLevel();

    json arr = json::array();
    for (const auto& p : peers) {
        json e;
        e["id"]    = p.first;
        e["name"]  = p.second;
        e["level"] = m_audio->peerLevel(p.first);
        arr.push_back(e);
    }
    st["peers"] = arr;

    // Underruns are the honest measure of whether the network is keeping up:
    // frames the mixer wanted and did not have.
    json stats;
    stats["sent"]      = m_sent.load();
    stats["recv"]      = m_recv.load();
    stats["underruns"] = m_audio->underruns();
    stats["discards"]  = m_audio->discards();
    st["stats"] = stats;

    return st.dump();
}
