<p align="center">
	<img width="150" height="150" src="ui/icons/voice.png" alt="Chorus logo">
</p>

<h1 align="center">Chorus</h1>

<p align="center">
	Voice rooms with no server in between. Pick a room name, share it, and everyone who joins the same name is on the same call.
</p>

<p align="center">
	<a href="#why-chorus">Why Chorus</a>
	·
	<a href="#how-a-room-works">How a room works</a>
	·
	<a href="#get-started">Get started</a>
	·
	<a href="#local-development">Develop</a>
	·
	<a href="#status">Status</a>
</p>

<p align="center">
	<img src="https://img.shields.io/badge/runs%20in-Logos%20Basecamp-ED7B58" alt="Runs in Logos Basecamp">
	<img src="https://img.shields.io/badge/transport-Logos%20Delivery-lightgrey" alt="Logos Delivery">
	<img src="https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey" alt="macOS on Apple Silicon">
	<img src="https://img.shields.io/badge/codec-Opus%2029%20kbit%2Fs-brightgreen" alt="Opus at 29 kbit/s">
</p>

> [!WARNING]
> **Chorus is alpha software, provided as is and without warranty of any kind.**
> Rooms are open: anyone who knows a room name can join it and hear everything
> said there, and audio is **not encrypted**. A room name is obscurity, not
> confidentiality. Do not say anything on a call that you would not say in a
> public place.

## Why Chorus

- **There is no call server.** Not ours, not anyone's. Audio is relayed peer to peer over the Logos Delivery network.
- **The name is the room.** No registry, no host, no invite flow. Two people who type `standup` are on the same call without anything having introduced them.
- **No account.** Open it, type a room name, talk. Your display name is optional and stays on your machine until you send it to the room.
- **It lives in Basecamp.** A core module and a QML frontend, installed like any other Basecamp app, on the same design system as the rest of it.
- **Nothing extra to install.** PortAudio and Opus are linked into the module. No external player, no helper process, no browser.

## How a room works

A room name is a content topic. Joining a call subscribes to `/logos-voice/1/<room>/json`, talking publishes 40 ms Opus frames on it, and leaving unsubscribes. That is the whole protocol.

| | |
| --- | --- |
| **Presence** | A hello with your display name when you join, a heartbeat every two seconds while you stay, a bye when you leave. A peer that goes quiet for six seconds drops off on its own |
| **Audio** | Opus, 40 ms frames at about 29 kbit/s per speaker, with DTX so silence costs almost nothing on the wire |
| **Jitter** | Each peer gets its own buffer that primes at three frames (120 ms) and drops anything late or out of order. At 40 ms a frame, reordering would cost more latency than it saves |
| **Mixing** | Every peer's stream is decoded and mixed locally, so a six-person call is six small streams rather than one server-mixed one |
| **Network** | Relay (gossipsub) only, on the logos.dev network. No store, no filter, no lightpush |

## What's in a call

- **Tiles for everyone,** with a ring that grows while they speak. It is the only thing on screen that proves audio is actually moving.
- **Open mic or push to talk.** Hold the button, or hold Space, to talk. Press M to mute in open-mic mode. Your choice is remembered.
- **Connection quality** from the fraction of frames the mixer wanted and did not have. Hover it for the raw counts.
- **Random private room names** like `amber-otter-4821`, and your recent rooms one click away.
- **A call timer, an invite button** and a waiting tile while you are the only one there.

## Does voice fit on a gossip topic

Measured, not estimated. [`core/tests/run.sh`](core/tests/run.sh) builds the harness that produces these without opening an audio device:

| | |
| --- | --- |
| **Frame** | 40 ms (1,920 samples) |
| **Opus payload** | 125 bytes on average, 188 at worst |
| **Packet on the wire** | 146 bytes (21 bytes of header) |
| **Per speaker** | 25 packets a second, 29 kbit/s |
| **Six people talking at once** | 175 kbit/s inbound |

Against the transport: the delivery module caps a message at 150 KiB, about a thousand times a packet. Its configurable rate limits cover store, lightpush, peer exchange and filter. Relay is not among them, and relay is the only path Chorus uses. RLN spam protection is off by default.

So throughput and quota are not the constraint. Jitter is. Gossipsub is a relay mesh with no ordering guarantee and no loss recovery, which is what the per-peer jitter buffer and the quality meter are there for.

## Get started

**You need**

- [Logos Basecamp](https://github.com/logos-co/logos-basecamp) 0.2 or later on an Apple Silicon Mac.
- `delivery_module` installed in Basecamp. Basecamp 0.2 does not bundle it, so build [`logos-delivery-module`](https://github.com/logos-co/logos-delivery-module) and install it first if a clean install left you without it.
- [Nix](https://nixos.org) with flakes enabled, to build the modules.
- Headphones, if two people will be calling from the same room.

**Then**

1. **Build the core.** `cd core && nix build '.#lgx-portable' --out-link result-portable`
2. **Build the UI.** `cd ../ui && nix build '.#lgx-portable' --out-link result-portable`
3. **Install both.** `./install.sh` quits Basecamp, copies the modules into your Basecamp user directory and re-signs the core's libraries.
4. **Open Basecamp,** pick Chorus from the sidebar, type a room name and join.

Step 3's re-signing matters: Apple Silicon checks every executable page when it is mapped, and without it macOS kills Basecamp on the next launch with `Code Signature Invalid`.

## Local development

**Commands**

| Command | What it does |
| --- | --- |
| `nix build '.#lgx-portable'` in `core/` | Build the core module package |
| `nix build '.#lgx-portable'` in `ui/` | Build the UI against the core pinned on GitHub |
| `nix build --override-input chorus_core path:../core '.#lgx-portable'` in `ui/` | Build the UI against your local `core/` |
| `nix flake update chorus_core` in `ui/` | Move the UI's pin to the latest pushed core |
| `./install.sh` | Install both packages into Basecamp |
| `core/tests/run.sh` | Build and run the Opus and packet-size harness |

**Two peers on one machine.** Two Basecamps would fight over the same P2P ports, so the core reads `CHORUS_TCPPORT` and gives each instance a deterministic node key and the other's address as a static peer. They dial each other over loopback instead of depending on the public fleet.

```sh
open -n /Applications/LogosBasecamp.app
CHORUS_TCPPORT=60001 open -n /Applications/LogosBasecamp.app
```

Wear headphones. Two open microphones on one machine feed back through the speakers otherwise.

**Environment**

| Variable | What it does |
| --- | --- |
| `CHORUS_TCPPORT` | Run as the second instance on this port (and UDP `9000 + port − 60000`) |
| `CHORUS_AUTOJOIN` | Join this room on its own a few seconds after loading. Two Basecamps share a process name, so scripting both UIs does not work; this lets only one of them need a human |
| `CHORUS_NAME` | The display name to use with `CHORUS_AUTOJOIN` |

**The network.** The logos.dev fleet moved to cluster 3, and the `logos.dev` preset inside `delivery_module` 0.2.0 still says cluster 2, so every fleet peer would drop the node with `different clusterId reported: 2 vs 3`. The core sets `clusterId` explicitly, which wins over the preset. Drop that line once the module ships the new preset.

## Repository map

| Path | What it is |
| --- | --- |
| [`core/`](core/) | The `chorus_core` module, C++ |
| [`core/src/chorus_core_impl.cpp`](core/src/chorus_core_impl.cpp) | Rooms, presence and the wire format |
| [`core/src/voice_audio.cpp`](core/src/voice_audio.cpp) | PortAudio capture and playback, Opus, jitter buffers, mixing |
| [`core/tests/`](core/tests/) | The offline Opus and packet-size harness |
| [`ui/`](ui/) | The `chorus` frontend, a single `Main.qml` on Logos.Theme and Logos.Controls |
| [`install.sh`](install.sh) | Local installer for Basecamp on macOS |

Two modules: `chorus_core` does the audio and the networking, `chorus` is the interface you open in Basecamp.

## Status

Version 0.1.0.

| | |
| --- | --- |
| **Two peers over loopback** | Verified: audio both ways between two Basecamps on one machine |
| **The public logos.dev fleet** | Connects and publishes to relay peers on cluster 3. A call between two machines across the fleet has not been measured yet |
| **Push to talk** | Built on the existing mute call. Expect up to one refresh (about 100 ms) between press and live |
| **Linux** | Not built or tested. The module builder supports it; `install.sh` does not yet |

The honest gaps:

- **No encryption.** Deriving a key from the room name plus a passphrase is the natural next step.
- **No echo cancellation.** On one machine, use headphones. This is the biggest gap between Chorus and a phone call.
- **One microphone.** Chorus uses the system default input. There is no device picker yet.
- **Unmeasured delay.** What gossipsub does to one-way latency across the real network is the open question, and the quality meter is there to answer it.

## Why not the radio approach

`booth-basecamp` and `receiver-basecamp`, the two existing Logos audio modules, never touch a sample themselves: booth hands capture to OBS and pushes HLS, receiver spawns `ffplay`, and the network carries only a small station announcement. That is right for radio, which is one origin, many listeners and ten seconds of latency by design, and wrong for a call.

Basecamp does not bundle Qt Multimedia, which is what pushed those projects to external processes. Chorus links PortAudio and Opus into the core instead, so the package carries `libportaudio` and `libopus` and that is the whole dependency story.

## Contributing

Issues and pull requests are welcome. The core is two source files and the UI is one, so start there.

## Licence

MIT and Apache-2.0. Pick whichever works for you.
