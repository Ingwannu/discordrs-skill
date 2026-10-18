# Voice and sharding (discord.rs 3.0.0)

## Voice

Features: `voice` (runtime, transport crypto, Opus decode, player API), `voice-encode` (PCM →
Opus; `AudioPlayer::play` returns `DiscordError::Voice` without it), `dave` (DAVE/MLS E2EE via
`davey`). Gateway bots also need `gateway` and the `GUILD_VOICE_STATES` intent. Source:
`src/voice.rs`, `src/voice/player.rs`, `src/voice_runtime.rs`. Docs:
`discordrsdocs/docs/api/voice.md`, `live-dave-validation.md`; full example
`examples/music_bot.rs` (`cargo run --example music_bot --features gateway,voice,voice-encode`).

Connection flow on the gateway:

1. `ctx.join_voice(guild_id, channel_id, self_mute, self_deaf)` sends the voice state update.
2. Wait for both VOICE_STATE_UPDATE (your user's `session_id`) and VOICE_SERVER_UPDATE (`token`,
   `endpoint`); they can arrive in either order.
3. `connect_voice_runtime(VoiceRuntimeConfig::new(guild_id, user_id, session_id, token, endpoint))`
   connects the voice websocket, does UDP discovery, selects the transport mode, and returns a
   `VoiceRuntimeHandle`. Filter VOICE_STATE_UPDATE by the bot's own user id, as below:
   `Context::connect_voice_runtime(guild_id, user_id)` builds the config from `ctx.voice()`,
   whose `VoiceManager` records any member's voice state for the guild, so another user's update
   can overwrite the session id.
4. Play through `AudioPlayer` (or send Opus frames yourself); receive with `recv_voice_packet*`.

**DAVE caveat.** `VoiceRuntimeConfig::new` advertises `max_dave_protocol_version = 1`. When Discord
negotiates DAVE for the call (the session description's `dave_protocol_version > 0`), plain
`send_opus_frame*` and plain `recv_voice_packet*` return errors, and an `AudioPlayer` subscribed
with `subscribe_runtime(handle)` plays nothing (its built-in sink uses the plain send; the player
only logs a warning). For DAVE calls, drive the MLS handshake yourself with `VoiceDaveySession`
(`dave` feature; see `tests/live_voice_dave.rs` and `examples/live_dave_capture_bot.rs`), send
through a custom `VoiceFrameSink` that calls `send_opus_frame_with_dave_after_gap`, and receive
with the `*_with_dave` methods. The example below works only for non-DAVE sessions.

```rust
// features: gateway, voice, voice-encode
use std::sync::{Arc, Mutex};

use discordrs::voice::player::{AudioInput, AudioPlayer, AudioPlayerEvent, AudioPlayerOptions, AudioResource};
use discordrs::{
    connect_voice_runtime, ChannelId, Context, DiscordError, EventHandler, GuildId, ReadyPayload,
    UserId, VoiceRuntimeConfig, VoiceServerUpdate, VoiceState,
};

#[derive(Default)]
struct Pending {
    user_id: Option<UserId>,
    session_id: Option<String>,
    server: Option<VoiceServerUpdate>,
    started: bool,
}

struct Music {
    guild_id: GuildId,
    channel_id: ChannelId,
    input: String,
    // Shared by the three hooks below; never held across .await.
    pending: Mutex<Pending>,
}

impl Music {
    fn try_start(&self) {
        let config = {
            let Ok(mut pending) = self.pending.lock() else { return };
            let (Some(user_id), Some(session_id), Some(server)) =
                (pending.user_id, pending.session_id.clone(), pending.server.clone())
            else {
                return;
            };
            let Some(endpoint) = server.endpoint.as_deref() else { return };
            if pending.started {
                return;
            }
            pending.started = true;
            VoiceRuntimeConfig::new(self.guild_id, user_id, session_id, server.token.as_str(), endpoint)
        };
        let input = self.input.clone();
        tokio::spawn(async move {
            if let Err(error) = play(config, &input).await {
                eprintln!("playback failed: {error}");
            }
        });
    }
}

async fn play(config: VoiceRuntimeConfig, input: &str) -> Result<(), DiscordError> {
    let handle = Arc::new(connect_voice_runtime(config).await?);
    let player = AudioPlayer::new(AudioPlayerOptions::default());
    let subscription = player.subscribe_runtime(Arc::clone(&handle))?;
    let mut events = player.events();
    player.play(AudioResource::new(AudioInput::ffmpeg(input)?).with_volume(0.8))?; // needs ffmpeg on PATH
    while let Ok(event) = events.recv().await {
        if let AudioPlayerEvent::TrackEnd { reason } = event {
            println!("track ended: {reason:?}");
            break;
        }
    }
    player.shutdown().await; // silence tail, speaking off, all player tasks joined
    drop(subscription);
    match Arc::try_unwrap(handle) {
        Ok(handle) => handle.close().await,
        Err(_) => Ok(()),
    }
}

impl EventHandler for Music {
    async fn ready(&self, ctx: Context, ready: &ReadyPayload) {
        if let Ok(mut pending) = self.pending.lock() {
            pending.user_id = Some(ready.user.id);
        }
        if let Err(error) = ctx.join_voice(self.guild_id, self.channel_id, false, true).await {
            eprintln!("join failed: {error}");
        }
    }

    async fn voice_state_update(&self, _ctx: Context, state: &VoiceState) {
        let Ok(mut pending) = self.pending.lock() else { return };
        if state.guild_id == Some(self.guild_id) && state.user_id == pending.user_id {
            pending.session_id = state.session_id.clone();
            drop(pending);
            self.try_start();
        }
    }

    async fn voice_server_update(&self, _ctx: Context, server: &VoiceServerUpdate) {
        if server.guild_id != self.guild_id {
            return;
        }
        if let Ok(mut pending) = self.pending.lock() {
            pending.server = Some(server.clone());
        }
        self.try_start();
    }
}
```

### Transport encryption

Both modes Discord offers are implemented: `aead_aes256_gcm_rtpsize` and
`aead_xchacha20_poly1305_rtpsize`. The runtime uses `VoiceRuntimeConfig::preferred_mode(..)` when
Discord offers it, otherwise the first mode Discord lists (`preferred_mode` is unset by default);
set `.preferred_mode(VoiceEncryptionMode::aead_aes256_gcm_rtpsize())` to prefer AES-GCM. 3.0 fixed the nonce layout (32-bit counter at the *start* of
the AEAD nonce, as in @discordjs/voice and Songbird; 2.x could not talk to real voice servers),
authenticates only the RTP header, CSRCs, and extension preamble as AAD, strips the decrypted
extension body and RTP padding (RFC 3550 §5.1). Known-answer vectors from
`ci/voice_transport_kat.py` (cross-checked with Node and libsodium) pin both directions.

### Sending and receiving

- `handle.send_opus_frame(frame, duration)`; `send_opus_frame_after_gap` moves the RTP timestamp
  across untransmitted media. Sequence/timestamp advance only after the datagram is sent; every
  attempt uses a fresh nonce. Plain sends reject an active DAVE session.
- `recv_voice_packet(max_len)`, `recv_decoded_voice_packet(&mut VoiceOpusDecoder, max_len)`
  (48 kHz stereo `i16` PCM).
- DAVE: `recv_voice_packet_with_dave(max_len, &mut decryptor)` /
  `recv_decoded_voice_packet_with_dave(..)` with a `VoiceDaveFrameDecryptor`
  (`VoiceDaveySession` behind `dave`), `send_opus_frame_with_dave(..)` with a
  `VoiceDaveFrameEncryptor`. A payload that is exactly the Opus silence frame `F8 FF FE` is passed
  through without decryption (Discord's SFU sends it unencrypted for muted users), so receive
  loops using `?` no longer die on muted speakers.

```rust
// features: voice
use discordrs::{DiscordError, VoiceDaveFrameDecryptor, VoiceOpusDecoder, VoiceRuntimeHandle};

async fn receive<D: VoiceDaveFrameDecryptor>(handle: &VoiceRuntimeHandle, dave: &mut D) -> Result<(), DiscordError> {
    let mut decoder = VoiceOpusDecoder::discord_default()?;
    loop {
        let decoded = handle.recv_decoded_voice_packet_with_dave(&mut decoder, 2048, dave).await?;
        println!("ssrc {} user {:?}: {} samples/channel", decoded.packet.rtp.ssrc, decoded.packet.user_id, decoded.samples_per_channel);
    }
}
```

### `AudioPlayer` (discord.js `@discordjs/voice` model)

`AudioInput` (`ffmpeg`, `ffmpeg_with_args`, `raw_pcm`, and `file`, which reads raw 48 kHz
stereo s16le PCM only; use `ffmpeg` for mp3/opus/etc.) → `AudioResource` (20 ms frames,
live `volume()`, cancel-safe `next_pcm_frame`) → `AudioPlayer` (`Idle`/`Buffering`/`Playing`/
`Paused`/`AutoPaused`; `play`, `pause`, `unpause`, `stop`, `state_watch`, `events`,
`shutdown().await`). Real-time rules: a frame must start sending within 60 ms, a send stalled
60 ms is cancelled, a full per-connection queue drops the oldest frame, skipped media becomes an
RTP timestamp gap, every stop gets five silence frames then speaking off. Re-subscribing a sink
replaces the earlier subscription.

Custom `VoiceFrameSink::send_opus_packet(frame, timing)` (`VoiceFrameTiming` is
`#[non_exhaustive]`: read `timing.duration` and `timing.gap`, don't construct it): transmit
only when the future completes, advance the RTP timestamp by `gap`, never block in a poll, and
stay usable when the future is dropped; `update_speaking` must not block or panic.

### Voice status

Live-tested in 3.0.0: nothing voice-related against real Discord (the read-only and owner-DM live
runs skipped joining voice). Evidence is the known-answer vectors, hermetic tests, and the ignored
live DAVE MLS-transition harness `tests/live_voice_dave.rs` (needs a prepared voice session via
`DISCORDRS_LIVE_VOICE_*` env vars). That harness passed against live Discord for 2.0.0
(2026-05-02, MLS transitions only, not media); rerun it before claiming DAVE interop for 3.x.

## Sharding

Feature `sharding` (implies `gateway`). Neither in-process nor multi-process sharding was
live-tested against Discord for 3.0.0 (hermetic harnesses only). Source: `src/sharding.rs`, `src/sharding/process.rs`,
`src/gateway/supervisor.rs`. Docs: `discordrsdocs/docs/api/sharding.md`.

### In-process

- `ClientBuilder::start_shards(n)` / `start_auto_shards()` run and wait;
  `spawn_shards(n)` / `spawn_auto_shards()` return a `ShardSupervisor` (`statuses()`,
  `drain_events()`, `reconnect`, `update_presence`, `join_voice`, `shutdown_and_wait()`, `wait()`).
- All shards share one IDENTIFY gate: one IDENTIFY per `shard_id % max_concurrency` bucket every
  5 s, re-IDENTIFYs included, each counted against the daily session-start budget from
  `/gateway/bot` (waits for the reset when exhausted). `spawn_shards(n)` returns the
  `/gateway/bot` error instead of starting unprotected unless `ClientBuilder::identify_gate(..)`
  supplies your own gate; `spawn_auto_shards` always needs `/gateway/bot`. A custom gate
  replaces the built-in pacing **and** budget accounting, so it owns both limits.
- The supervisor stops every shard on the first fatal error and returns it.
- Guild ↔ shard: `(guild_id >> 22) % shard_count`; guild-scoped commands from any `Context` go
  to the owning shard; DMs arrive on shard 0.
- Supervisor events are bounded (256 per shard); dropped ones surface as
  `ShardSupervisorEvent::Lagged { shard_id, missed }`. `statuses()` is always current.

```rust
// features: sharding
use discordrs::{gateway_intents, Client, DiscordError, EventHandler, ShardSupervisorEvent};

async fn run<H: EventHandler>(token: &str, handler: H) -> Result<(), DiscordError> {
    let supervisor = Client::builder(token, gateway_intents::GUILDS)
        .event_handler(handler)
        .spawn_auto_shards() // shard count, max_concurrency, budget from /gateway/bot
        .await?;
    for event in supervisor.drain_events()? {
        match event {
            ShardSupervisorEvent::StateChanged { shard_id, state } => println!("shard {shard_id}: {state:?}"),
            ShardSupervisorEvent::Lagged { shard_id, missed } => eprintln!("shard {shard_id}: {missed} events dropped"),
            other => println!("{other:?}"),
        }
    }
    supervisor.wait().await // first fatal shard error, after stopping the others
}
```

### Multi-process (`sharding::process`)

`ProcessShardManager::spawn_auto(token, ProcessShardManagerConfig::default())` re-executes the
current binary per shard group; `ShardChildProcess::from_env()` is `Some` only in a child. The
parent grants every IDENTIFY per bucket and enforces the session budget across children; IPC
lines carry the `@discordrs-ipc/1 ` prefix and a size cap (2.x parents/children cannot talk to
3.0: deploy both together). `broadcast(json)` is the `broadcastEval` equivalent;
`shutdown().await` returns once every child is confirmed gone.

```rust
// features: sharding
use discordrs::sharding::process::{ProcessShardManager, ProcessShardManagerConfig, ShardChildProcess};
use discordrs::{gateway_intents, Client, Context, DiscordError, EventHandler, GatewayConnectionConfig, ReadyPayload};
use serde_json::json;

struct Handler {
    child: ShardChildProcess,
}

impl EventHandler for Handler {
    async fn ready(&self, ctx: Context, _ready: &ReadyPayload) {
        let (shard_id, _) = ctx.shard_pair();
        if let Err(error) = self.child.notify_shard_ready(shard_id) {
            eprintln!("shard {shard_id}: {error}");
        }
    }
}

async fn run(token: String) -> Result<(), DiscordError> {
    if let Some(child) = ShardChildProcess::from_env() {
        child.serve(|_request| async { json!({ "ok": true }) })?; // before the shards connect
        // Every fresh IDENTIFY waits for the parent's grant for its bucket.
        let gateway = GatewayConnectionConfig::default().identify_gate(child.identify_gate());
        for &shard_id in child.shard_ids() {
            let client = Client::builder(&token, gateway_intents::GUILDS)
                .gateway_config(gateway.clone())
                .event_handler(Handler { child: child.clone() })
                .shard(shard_id, child.shard_count());
            tokio::spawn(async move {
                if let Err(error) = client.start().await {
                    eprintln!("shard {shard_id}: {error}");
                }
            });
        }
        child.shutdown_signal().await;
        return Ok(());
    }
    let manager = ProcessShardManager::spawn_auto(token, ProcessShardManagerConfig::default()).await?;
    for (shard_id, value) in manager.broadcast(json!({ "op": "stats" })).await? {
        println!("shard {shard_id}: {value}");
    }
    manager.shutdown().await
}
```

`ProcessShardManagerConfig` knobs: `total_shards`, `shard_list`, `shards_per_process`,
`respawn`/`respawn_delay`/`max_respawns`, `max_concurrency`, `session_start_budget`
(`FromGateway` / `Fixed` / `Unchecked`), `identify_interval` (5 s), `identify_permit_timeout`
(30 s), `spawn_stagger` (0), `broadcast_timeout`, `shutdown_timeout`, `max_ipc_frame_bytes`
(1 MiB). For a custom layout implement `IdentifyGate` (permits report
`IdentifyOutcome::Sent`; dropping a permit reports `Abandoned`) and pass it to
`ClientBuilder::identify_gate`.
