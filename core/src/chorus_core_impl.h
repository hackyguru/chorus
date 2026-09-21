#pragma once

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "logos_module_context.h"
#include "logos_result.h"
#include "voice_audio.h"

/**
 * @brief A conference call on a gossipsub topic.
 *
 * The whole idea of the module is one line: a room id is a content topic.
 * Joining a call is subscribing to `/logos-voice/1/<roomId>/json`, talking is
 * publishing 40 ms Opus frames on it, and everyone who typed the same id hears
 * everyone else. There is no server, no room registry and no host — the topic
 * is the room.
 *
 * This is a universal module, so these public methods *are* the API: the Qt
 * plugin glue is generated from this header. Module code stays Qt-free, which
 * is convenient here because @ref voice::AudioEngine is Qt-free too and the
 * pair can be exercised by an offline harness with no Basecamp running.
 *
 * Frames go on the wire as raw bytes rather than base64 inside JSON —
 * `delivery_module::send` takes a `std::vector<uint8_t>`, so a packet is a
 * 21-byte header plus the Opus payload, about 140 bytes for 40 ms of speech.
 */
class ChorusCoreImpl : public LogosModuleContext
{
public:
    ChorusCoreImpl();
    ~ChorusCoreImpl();

    /// Bring the delivery node up. Idempotent.
    StdLogosResult startNetwork();
    /// Leave any room and take the node down.
    StdLogosResult stopNetwork();

    /// Subscribe to a room and open the microphone. Any id is a valid room.
    StdLogosResult joinRoom(const std::string& roomId, const std::string& displayName);
    /// Unsubscribe, close the microphone, forget the peers.
    StdLogosResult leaveRoom();

    /// Stop sending without leaving. The stream keeps running so you still hear.
    StdLogosResult setMuted(bool muted);

    /// Everything the UI draws, as one JSON object.
    std::string roomState();

    /// This participant's stable id for the life of the process.
    std::string myId();

logos_events:
    /// Someone joined or left, or the connection state moved.
    void roomChanged(const std::string& stateJson);

protected:
    void onContextReady() override;

private:
    struct Peer {
        std::string name;
        int64_t     lastSeenMs = 0;
    };

    void wireDeliveryEvents();
    void onPacket(const std::string& topic, const std::vector<uint8_t>& payload);
    void pumpLoop();                       // own thread: send frames, beat, expire
    void send(const std::vector<uint8_t>& packet);
    void announce(uint8_t kind);
    static std::string topicFor(const std::string& roomId);

    std::unique_ptr<voice::AudioEngine> m_audio;

    mutable std::mutex m_mu;               // guards the fields below
    std::string m_myId;                    // 32 hex chars
    std::vector<uint8_t> m_myIdRaw;        // the same 16 bytes, for packet headers
    std::string m_myName;
    std::string m_roomId;
    std::string m_topic;                   // empty when not in a room
    std::map<std::string, Peer> m_peers;
    std::string m_netError;
    std::string m_audioError;
    int  m_status = 0;                     // 0 off, 1 connecting, 2 connected, 3 error
    bool m_nodeCreated = false;
    bool m_started     = false;
    bool m_eventsWired = false;

    std::thread       m_pump;
    std::atomic<bool> m_pumping{false};

    std::atomic<uint64_t> m_sent{0};
    std::atomic<uint64_t> m_recv{0};
};
