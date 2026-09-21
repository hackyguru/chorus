# Chorus

A conference call with no server. Type a room id, and everyone else who typed
the same one can hear you.

```
chorus/
├── core/                       # C++ core module "voice"
│   └── src/
│       ├── voice_impl.{h,cpp}  # rooms, presence, the wire
│       └── voice_audio.{h,cpp} # PortAudio + Opus + jitter buffers + mixing
└── ui/                         # QML frontend "voice_ui" (depends on voice)
    └── Main.qml
```

## The whole idea

A room id is a content topic. Joining a call is subscribing to
`/logos-voice/1/<roomId>/json`, talking is publishing 40 ms Opus frames on it,
and leaving is unsubscribing. There is no room registry, no host and no
signalling step — the topic *is* the room, so two people who type `standup`
are on the same call without anything having introduced them.

## Why the audio is not done the way the radio modules do it

`booth-basecamp` and `receiver-basecamp` are the two existing Logos audio
modules, and neither one captures or plays a sample itself: booth hands capture
to OBS and pushes HLS through Tor, receiver spawns `ffplay` to play it, and
Waku carries only a small JSON station announcement. That is a sound design for
radio and the wrong shape for a call — one origin, many listeners, one
direction, and about ten seconds of latency by design.

Qt Multimedia is not bundled in Basecamp (not in the Linux AppImage, and no
`QtMultimedia.framework` on macOS either), which is what pushed both of those
projects to external processes. This module links PortAudio and Opus into the
core instead. That means no bundled `ffplay`, no nixpkgs pin for a specific
SDL2, no `patchelf` rpath rewriting, no privoxy bridge, no PATH discovery for
GUI apps, and no orphaned player processes — the `.lgx` carries
`libportaudio.2.dylib` and `libopus.0.dylib` and that is the whole dependency
story.

## Does voice fit on a gossipsub topic

Measured, not estimated — `core` ships the harness (`core/tests/run.sh`) that produces these:

```
frame              40 ms (1920 samples)
opus payload       125 bytes average, 188 worst
packet on the wire 146 bytes (+21 header)
per speaker        25 packets/s, 29 kbit/s
six talking at once 175 kbit/s inbound
```

Against the transport, from the installed `delivery_module`: the message cap is
150 KiB, roughly a thousand times a packet. The configurable rate limits name
`store, storev3, lightpush, px, filter` — relay is not among them, and relay is
the only path this module uses. RLN spam protection defaults to off.

So throughput and quota are not the constraint. Jitter is. Gossipsub is a relay
mesh with no ordering guarantee and no loss recovery, so each peer gets a
jitter buffer that primes at three frames (120 ms) and drops anything that
arrives late or out of order. The `gaps` counter in the UI is the honest
measure: frames the mixer wanted and did not have.

## Build

```bash
cd core
nix build '.#lgx-portable' --out-link result-portable

cd ../ui
# the UI pins core from GitHub; to build against your local core/ instead:
nix build --override-input voice path:../core '.#lgx-portable' --out-link result-portable
```

Then `./install.sh`, which quits Basecamp, copies both modules into the user
directory, and re-signs the core dylibs — without that last step macOS kills
Basecamp on the next launch with `Code Signature Invalid`.

## Run two peers on one machine

Only the P2P ports collide, so the core reads `VOICE_TCPPORT` and uses
deterministic node keys plus static nodes so the two instances dial each other
over loopback rather than depending on the logos.dev bootstrap fleet.

```bash
open -n "/Applications/LogosBasecamp.app"
VOICE_TCPPORT=60001 open -n "/Applications/LogosBasecamp.app"
```

Open **Chorus** (`voice_ui`) in both, type the same room id in each, and talk. Wear
headphones: two instances on one machine with open microphones will feed back
through the speakers otherwise.

## Notes and limits

- **Open mic or push to talk.** Push to talk (hold the button or Space) is a UI
  mode over `setMuted`. Opus DTX is on, so silence costs almost nothing on the
  wire either way.
- **No echo cancellation.** On one machine, use headphones. This is the single
  biggest gap between this and a product.
- **No encryption.** Anyone subscribed to the topic hears the room. A room id
  is obscurity, not confidentiality — the same caveat booth documents for its
  legacy private streams. Deriving a key from the room id plus a passphrase,
  the way `StationCrypto` does, is the natural next step.
- **Late frames are dropped, not reordered.** At 40 ms a frame, reordering
  would cost more latency than it saves.
- **The public fleet is unmeasured.** The loopback path is verified; what
  gossipsub does to one-way delay across the real network is the open question,
  and the `gaps` counter is there to answer it.

## Licence

MIT and Apache-2.0 — pick whichever works for you.
