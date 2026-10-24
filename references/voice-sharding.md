# Voice and sharding (discord.rs 3.2.0)

## Voice

Features: `voice` (runtime, transport crypto, DAVE end-to-end encryption via `davey`/OpenMLS,
Opus decode, player API) and `voice-encode` (PCM → Opus; `AudioPlayer::play` returns
`DiscordError::Voice` without it). Since 3.1.0 `voice` includes DAVE; `dave` is only an alias kept
so `features = ["voice", "dave"]` still builds. Gateway bots also need `gateway` and the
`GUILD_VOICE_STATES` intent. Source: `src/voice.rs`, `src/voice/player.rs`, `src/voice_runtime.rs`,
`src/voice_runtime/dave.rs`. Docs: `discordrsdocs/docs/api/voice.md`, `live-dave-validation.md`,
design record `docs/design/dave-voice.md`; full example `examples/music_bot.rs`
(`cargo run --example music_bot --features gateway,voice,voice-encode`).

Discord requires DAVE in every voice channel except Stage channels since 2026-03-01 and closes
connections without it with code 4017. Pick the entry point accordingly:

| Entry point | DAVE | Use |
|---|---|---|
| `Context::connect_voice_runtime_with_dave(guild_id, user_id)` | the runtime runs the MLS session itself | gateway bots (default choice) |
| `connect_voice_runtime_with_options(config, VoiceConnectOptions::new(channel_id))` (`voice_runtime::connect_with_options`) | same | your own voice state handling; `VoiceManager::runtime_options(guild_id)` builds the options |
| `connect_voice_runtime(config)` / `Context::connect_voice_runtime` | 3.0.0 behaviour: advertises DAVE, runs nothing; plain sends/receives refuse a DAVE call | Stage channels, or hand-driven MLS with `VoiceDaveySession` + `send_dave_*` |

Connection flow on the gateway:

1. `ctx.join_voice(guild_id, channel_id, self_mute, self_deaf)` sends the voice state update and
   tracks the guild's connection right away.
2. Discord answers with the bot's VOICE_STATE_UPDATE (session id) and a VOICE_SERVER_UPDATE (token,
   endpoint) in either order. The context applies only the bot's own voice state (user from
   READY), and keeps a server update that arrives first until the connection exists.
3. When `ctx.voice_runtime_config(guild_id, user_id)` is `Some`, call
   `ctx.connect_voice_runtime_with_dave(guild_id, user_id)` → `VoiceRuntimeHandle`.
4. Play through `AudioPlayer` (or `send_opus_frame`); receive with `recv_voice_packet*`.

```rust
// features: gateway, voice, voice-encode
use std::sync::{Arc, Mutex};

use discordrs::voice::player::{
    AudioInput, AudioPlayer, AudioPlayerEvent, AudioPlayerOptions, AudioResource,
    PlayerConnectionEvent,
};
use discordrs::{
    ChannelId, Context, DiscordError, EventHandler, GuildId, ReadyPayload, UserId,
    VoiceServerUpdate, VoiceState,
};

struct Music {
    guild_id: GuildId,
    channel_id: ChannelId,
    input: String,
    // (bot user, started): written by the hooks below, never held across .await.
    state: Mutex<(Option<UserId>, bool)>,
}

impl Music {
    // Both voice updates must have arrived; they come in either order.
    async fn try_start(&self, ctx: &Context) {
        let Some(user_id) = self.state.lock().ok().and_then(|state| state.0) else { return };
        if ctx.voice_runtime_config(self.guild_id, user_id).await.is_none() {
            return;
        }
        match self.state.lock() {
            Ok(mut state) if !state.1 => state.1 = true,
            _ => return,
        }
        let (ctx, guild_id, input) = (ctx.clone(), self.guild_id, self.input.clone());
        tokio::spawn(async move {
            if let Err(error) = play(&ctx, guild_id, user_id, &input).await {
                eprintln!("playback failed: {error}");
            }
        });
    }
}

async fn play(ctx: &Context, guild_id: GuildId, user_id: UserId, input: &str) -> Result<(), DiscordError> {
    // Runs DAVE itself; `ctx.connect_voice_runtime` would leave MLS to you (3.0.0 behaviour).
    let handle = Arc::new(ctx.connect_voice_runtime_with_dave(guild_id, user_id).await?);
    let player = AudioPlayer::new(AudioPlayerOptions::default());
    let mut connection_events = player.connection_events();
    let subscription = player.subscribe_runtime(Arc::clone(&handle))?;
    let mut events = player.events();
    // Waits in AutoPaused until the DAVE group has keys (alone in a channel: until someone joins).
    player.play(AudioResource::new(AudioInput::ffmpeg(input)?).with_volume(0.8))?; // ffmpeg on PATH
    loop {
        tokio::select! {
            event = events.recv() => match event {
                Ok(AudioPlayerEvent::TrackEnd { reason }) => {
                    println!("track ended: {reason:?}");
                    break;
                }
                Ok(other) => println!("{other:?}"),
                Err(_) => break,
            },
            event = connection_events.recv() => match event {
                // Reported once per stretch of failed sends, not per frame.
                Ok(PlayerConnectionEvent::SendFailed { error, .. }) => eprintln!("audio not sent: {error}"),
                Ok(PlayerConnectionEvent::Recovered { failed, .. }) => println!("recovered after {failed} frames"),
                Ok(_) => {}
                Err(_) => break,
            },
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
        if let Ok(mut state) = self.state.lock() {
            state.0 = Some(ready.user.id);
        }
        if let Err(error) = ctx.join_voice(self.guild_id, self.channel_id, false, true).await {
            eprintln!("join failed: {error}");
        }
    }

    async fn voice_state_update(&self, ctx: Context, _state: &VoiceState) {
        // Fires for every member; voice_runtime_config reads only the bot's own tracked state.
        self.try_start(&ctx).await;
    }

    async fn voice_server_update(&self, ctx: Context, _server: &VoiceServerUpdate) {
        self.try_start(&ctx).await;
    }
}
```

### DAVE on a `connect_voice_runtime_with_options` runtime

- **Joining.** IDENTIFY advertises `max_dave_protocol_version` (capped at 1). After
  SESSION_DESCRIPTION negotiates DAVE, the runtime sends its MLS key package, applies the external
  sender, commits proposals for joining members (checked against CLIENTS_CONNECT), processes
  commits and welcomes, answers `prepare_transition`/`execute_transition`/`prepare_epoch`, follows
  downgrades and upgrades, and on an invalid commit/welcome (or > 36 undecryptable frames outside
  a transition) reports `dave_mls_invalid_commit_welcome` and rejoins with a new key package.
  Don't drive MLS by hand on this runtime (the voice gateway would see two key packages).
- **Sending.** `send_opus_frame*`, `play_opus_frames`, and an `AudioPlayer` subscribed with
  `subscribe_runtime` DAVE-encrypt each frame before transport encryption (the Opus silence frame
  stays unencrypted). Until the runtime has a media key in use, sends return `DiscordError::Voice`
  and transmit nothing (no sequence, timestamp, or nonce used up), `is_playable()` is `false`, and
  the player waits in `AutoPaused` (default `NoSubscriberBehavior::Pause`), then plays the track
  from its first frame. A bot alone in a DAVE channel has no group: it waits until someone joins.
  With `NoSubscriberBehavior::Stop`, call `handle.wait_until_playable().await?` before `play`.
- **Receiving.** `recv_voice_packet` / `recv_decoded_voice_packet` decrypt each speaker with that
  user's key (SSRC → user from SPEAKING); frames that fail around MLS transitions are skipped and
  counted in `dave_status().undecryptable_packets`.
- **Status.** `dave_status()` → `VoiceDaveStatus` (`protocol_version`, readiness, `epoch`,
  `voice_privacy_code`, last transition, `last_error`, `undecryptable_packets`, recoveries,
  `can_send_audio()`); `subscribe_dave_status()`; `is_playable()`; `wait_until_playable()`;
  `dave_verification_code(user_id)`.
- **4017.** A close during the handshake returns an error naming the code and Discord's meaning;
  for 4017 it says DAVE is required and, on `connect_voice_runtime`, to use
  `connect_voice_runtime_with_options`.
- **Limits.** No RESUME loop: when the voice websocket closes the handle stops being playable;
  reconnecting is a fresh IDENTIFY and a fresh MLS join. davey 0.1.x does not check a welcome's
  member list against the call (commits and proposals are checked). 2^32 − 1 frames per epoch,
  then sends fail until the next epoch.

```rust
// features: voice
use discordrs::{
    connect_voice_runtime_with_options, DiscordError, VoiceConnectOptions, VoiceDaveStatus,
    VoiceRuntimeConfig, VoiceRuntimeHandle,
};

// Without the gateway helpers: you supply session id, token, endpoint, and the channel.
async fn connect(config: VoiceRuntimeConfig, channel: &str) -> Result<VoiceRuntimeHandle, DiscordError> {
    let handle = connect_voice_runtime_with_options(config, VoiceConnectOptions::new(channel.parse()?)).await?;
    handle.wait_until_playable().await?; // a media key is in use (or the call is not DAVE)
    Ok(handle)
}

fn describe(handle: &VoiceRuntimeHandle) {
    let dave: VoiceDaveStatus = handle.dave_status();
    if dave.protocol_version == 0 {
        println!("transport encryption only (Stage channel or downgraded call)");
    } else if dave.can_send_audio() {
        println!("end-to-end encrypted, epoch {:?}, privacy code {:?}", dave.epoch, dave.voice_privacy_code);
    } else {
        println!("waiting for the MLS group; last error: {:?}", dave.last_error);
    }
}
```

### Security: keep `davey` trace logging off

davey 0.1.5 writes media key secrets (every member's MLS-exported sender secret, ratchet keys) to
`tracing` at **trace** level in `davey::session`, `davey::cryptor::hash_ratchet`, and
`davey::cryptor::mlspp_crypto`. A trace log can decrypt captured call audio. Keep the `davey`
target at `info` or coarser (`RUST_LOG=info,davey=info`; add `davey=info` to any trace-level
filter). The runtime runs its own davey calls under a scoped filter that drops davey's trace events
and warns when a DAVE session starts with those modules at trace level. That is a mitigation, not
a fix: it does not cover `VoiceDaveySession` or direct davey calls, tracing's `log` fallback when
no subscriber is installed, or a session started before the subscriber was installed (install the
subscriber before connecting voice). The runtime's own key material is zeroized and kept out of
`Debug`.

### Transport encryption

Both modes Discord offers are implemented: `aead_aes256_gcm_rtpsize` and
`aead_xchacha20_poly1305_rtpsize`. The runtime uses `VoiceRuntimeConfig::preferred_mode(..)` when
Discord offers it, otherwise the first mode Discord lists (`preferred_mode` is unset by default);
set `.preferred_mode(VoiceEncryptionMode::aead_aes256_gcm_rtpsize())` to prefer AES-GCM. 3.0 fixed
the nonce layout (32-bit counter at the *start* of the AEAD nonce, as in @discordjs/voice and
Songbird), authenticates only the RTP header, CSRCs, and extension preamble as AAD, and strips the
decrypted extension body and RTP padding. Known-answer vectors (`ci/voice_transport_kat.py`) pin
both directions.

### Receiving

- `recv_voice_packet(max_len)`, `recv_decoded_voice_packet(&mut VoiceOpusDecoder, max_len)`
  (48 kHz stereo `i16` PCM) return only Opus voice. Since 3.1.0 they skip, instead of returning
  errors: datagrams that are not RTP v2 with payload type 120 (RTCP reports, about one per second;
  other payload types; runts) → `receive_stats().non_voice_packets`; voice packets that fail
  transport authentication, are malformed, or exceed `max_len` → `receive_stats().rejected_packets`
  (debug log without payload). A receive loop with `?` keeps running; when it gets no audio, look
  at `receive_stats()`, not at errors. Still returned as errors: socket errors, a session without a
  usable mode or key, a DAVE call on a `connect_voice_runtime` handle.
- `recv_raw_udp_packet` returns every datagram, RTCP included.
- Custom DAVE: `recv_voice_packet_with_dave(max_len, &mut decryptor)` /
  `send_opus_frame_with_dave*` with your `VoiceDaveFrameDecryptor` / `VoiceDaveFrameEncryptor`
  (they also work on a `with_options` runtime for custom frame encryption).

```rust
// features: voice
use discordrs::{DiscordError, VoiceOpusDecoder, VoiceRuntimeHandle};

async fn receive(handle: &VoiceRuntimeHandle) -> Result<(), DiscordError> {
    let mut decoder = VoiceOpusDecoder::discord_default()?;
    loop {
        // RTCP, forged, and undecryptable packets are skipped, not returned as errors.
        let decoded = handle.recv_decoded_voice_packet(&mut decoder, 2048).await?;
        let stats = handle.receive_stats();
        println!(
            "user {:?}: {} samples/channel (skipped {} non-voice, {} rejected)",
            decoded.packet.user_id, decoded.samples_per_channel, stats.non_voice_packets, stats.rejected_packets
        );
    }
}
```

### `AudioPlayer` (discord.js `@discordjs/voice` model)

`AudioInput` (`ffmpeg`, `ffmpeg_with_args`, `raw_pcm`, and `file`, which reads raw 48 kHz
stereo s16le PCM only; use `ffmpeg` for mp3/opus/etc.) → `AudioResource` (20 ms frames,
live `volume()`, cancel-safe `next_pcm_frame`) → `AudioPlayer` (`Idle`/`Buffering`/`Playing`/
`Paused`/`AutoPaused`; `play`, `pause`, `unpause`, `stop`, `state_watch`, `events`,
`connection_events`, `shutdown().await`). Only playable sinks count as subscribed
(`VoiceFrameSink::is_playable`, default `true`), as in @discordjs/voice. Real-time rules: a frame
must start sending within 60 ms, a send stalled 60 ms is cancelled, a full per-connection queue
drops the oldest frame, skipped media becomes an RTP timestamp gap, every stop gets five silence
frames then speaking off. Re-subscribing a sink replaces the earlier subscription.
`PlayerConnectionEvent::{SendFailed, Recovered}` (`#[non_exhaustive]`) report failing sends once
per stretch; `PlayerSubscription::id()` matches them to a subscription.

Custom `VoiceFrameSink::send_opus_packet(frame, timing)` (`VoiceFrameTiming` is
`#[non_exhaustive]`: read `timing.duration` and `timing.gap`, don't construct it): transmit
only when the future completes, advance the RTP timestamp by `gap`, never block in a poll, and
stay usable when the future is dropped; `update_speaking` must not block or panic; override
`is_playable` when the sink cannot deliver audio yet.

### Voice status

- Live, 2026-10-21 (main `cea24e7`, approved server, regular non-Stage channel, recorded in
  `docs/design/perf-baseline.md`): `join_voice` → `connect_voice_runtime_with_dave` →
  `AudioPlayer` (3 s 440 Hz tone) → receive loop. DAVE v1 negotiated (epoch 1, no `last_error`,
  privacy code issued). **Send:** the tone was heard in an official Discord client; alone, the
  player waited in `AutoPaused` (~80 s) until a person joined, then played; with a person already
  present it started within 20 ms. **Receive:** 63 packets of one speaker decrypted (DAVE +
  transport); the RTCP-as-voice bug found there (35 errors) was fixed in `a37dbb0`, and two reruns
  skipped 33 and 110 RTCP packets with 0 errors, 0 rejected, 0 DAVE failures, across an epoch
  1 → 3 change (speech was not captured in the reruns).
- Not run yet: the ignored full live harness `tests/live_voice_dave.rs` (`DISCORDRS_LIVE_VOICE_*`
  env vars). Hermetic tests run two independent davey sessions and a test voice gateway through
  join, audio both ways, downgrade/upgrade, recovery, and 4017.

## Sharding

Feature `sharding` (implies `gateway`). Neither in-process nor multi-process sharding was
live-tested against Discord for 3.0.0 or 3.1.0 (hermetic harnesses only). Source: `src/sharding.rs`, `src/sharding/process.rs`,
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

Handoff (3.2.0): `ClientBuilder::handoff`/`resume_sessions` work with `spawn_shards` and
`spawn_auto_shards` too: call `handoff.request()`, then `supervisor.wait().await`, then
`take_sessions()`. Resuming shards skip the identify waves; if `/gateway/bot` recommends a new
shard count, every session is dropped and the fleet identifies.

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
