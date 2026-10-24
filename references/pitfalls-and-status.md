# Pitfalls, known limits, and what was live-tested (discord.rs 3.2.0)

## Common mistakes

Interactions

- Returning `EndpointReply::Accepted` without having sent a REST response. The endpoint answers
  202 and Discord shows "This interaction failed". Return `Accepted` only after `reply`/`defer`/…
  over REST succeeded (or when a task you spawned will send it within 3 s); otherwise return an
  inline `InteractionResponse::…into()`.
- Answering twice: an inline response plus a REST `reply` (the endpoint answers 202 and discards
  the inline one), or two `reply` calls (the second fails locally). Use `edit_reply` /
  `follow_up` after the first response.
- Slow work before the first response. Discord allows 3 s: `defer()` / `defer_ephemeral()` first,
  then `edit_reply`. Check `Context::event_received_at()` on a busy gateway.
- Answering autocomplete with a message. Only choices are accepted:
  `InteractionResponse::autocomplete(..)` / `respond_autocomplete(..)`; in `AppFramework` add
  `.autocomplete(name, ..)` (without it the framework answers with no choices).
- Mixing stateless id/token helpers (`respond_with_container`, …) with responder methods on the
  same interaction: the shared response state cannot see the helper's response.
- Editing or following up from a task spawned inside an `AppFramework` route that answers inline:
  the inline response is recorded only after the route returns, so an early edit fails with
  "interaction has not been acknowledged". Defer over REST and return `EndpointReply::Accepted`.
- Relying on the REST client's default `allowed_mentions` for inline HTTP-endpoint replies: they
  never use it. Set `InteractionsEndpointBuilder::default_allowed_mentions` (3.1.0) or
  `allowed_mentions` per message.
- Expecting `AppFramework` `component`/`modal` routes to match a `custom_id` prefix: matching is
  exact; use `fallback(..)` for dynamic ids.
- Requiring a single checkbox, or `disabled` modal inputs: Discord rejects both; use a one-option
  `CheckboxGroupBuilder::required(true)`.
- A reverse proxy with a body limit below 1 MiB in front of the interactions endpoint (413s on
  large resolved payloads).

Gateway, cache, collectors

- Leftover `#[async_trait]` (E0195) or a non-`Send` future (holding `Rc`, `RefCell` borrow, or a
  `std::sync::MutexGuard` across `.await`).
- Holding the `ctx.voice()` write lock across `.await`: it stalls the shard's event processor and
  can overflow the queue, which stops the shard.
- Expecting MESSAGE_UPDATE / GUILD_MEMBER_UPDATE / GUILD_UPDATE to populate the cache; partial
  updates only patch what is already cached.
- Assuming the cache shows the state at the handled event: it may already include later events.
- Awaiting long collectors or slow calls inside a handler in Serial mode (the default): other
  handlers on that shard wait. Spawn the wait or use `EventDispatchMode::Concurrent`.
- Running in more than 1,000 guilds with the default `CacheConfig` (`max_guilds` 1,000).
- Using `ctx.collectors().message_collector()` in a handler when you need messages sent right
  after the trigger; `ctx.message_collector()` replays from the handled event.
- Exhaustive matches on `CollectorEndReason`, `ShardSupervisorEvent`, or open discriminants
  without a `_` arm.
- Missing privileged intents (also enable them in the Developer Portal): `MESSAGE_CONTENT` (else
  `content` is empty outside DMs/mentions), `GUILD_MEMBERS` (`fetch_members`, member events),
  `GUILD_PRESENCES`. Disallowed intents end `start()` with close code 4014.
- Treating `fetch_members` errors as fatal: `DiscordError::IncompleteMemberFetch` carries the
  members that decoded.
- Two running clients mirroring into one `CacheBackend` store (not detected; the older one is
  silently superseded).
- Initialising in `ready` (registering commands, loading state) on a client started with
  `ClientBuilder::resume_sessions` (3.2.0): a resumed process gets RESUMED and no READY, and its
  cache starts empty (no GUILD_CREATE burst). Initialise at startup, or also in `resumed`.
- Dropping the start future after `GatewayHandoff::request()` (the usual `select!` shutdown): the
  shards then close without recording sessions. Pin the future and await it again.
- Resuming one session snapshot twice, or keeping it readable by other users: delete it once
  read, and write it with mode 0600 (with the token it continues the session).
- Changing intents or the shard count in an update and expecting the old session to resume: such
  a session is dropped (with a warning) and the shard identifies; a resumed session keeps its
  intents and presence.

REST and builders

- Hand-writing JSON (`json!`) when a `request::X` type, builder, or method exists. `RawRequest` is
  only for routes the crate does not wrap.
- Using 2.x REST names: most `*_typed` pairs were folded into the canonical name and the untyped
  variants removed; 35 one-to-one renames remain as deprecated forwards. Other deprecated items
  (`ButtonBuilder`, `defer_interaction`, `interactions_endpoint`, `create_guild`) name their
  replacement in the warning. (`update_presence_typed` is current, not deprecated.)
- Relying on POST/PATCH retries: they are not replayed after 5xx/timeouts. For an idempotent
  message create use `CreateMessage::enforce_nonce(..)`.
- Content, embeds, poll, or stickers in an `IS_COMPONENTS_V2` message (validation error): use
  `TextDisplayBuilder` inside the layout.
- `u64` or `&str` where an ID is expected: parse once with `parse()?` / `try_from(..)?`; never
  `GuildId` from a `ChannelId`'s number.
- Ignoring the result of `Permissions::add/remove/merge` (`#[must_use]`; they return new sets).
- Thinking bots can set activity buttons or rich fields: `BotActivity` has only `name`, `type`,
  `state`, `url`. Received `Activity::buttons` are label strings; bots never see button URLs.
- `AllowedMentions::default()` means "parse no mentions" (`{}`); with no `allowed_mentions` at
  all Discord pings everything mentioned in `content`.
- Hard-coding or printing tokens. Read them from the environment; `Debug` of interaction contexts
  redacts the token, but your own `println!` does not.

Voice and sharding

- `AudioPlayer::play` without the `voice-encode` feature returns `DiscordError::Voice`.
- Connecting with `connect_voice_runtime` / `Context::connect_voice_runtime` in a normal
  (non-Stage) channel: they keep 3.0.0's behaviour (advertise DAVE, run no MLS session), so in a
  DAVE call plain sends and receives fail. Use `Context::connect_voice_runtime_with_dave` or
  `connect_voice_runtime_with_options(config, VoiceConnectOptions::new(channel_id))`. A 4017
  close means Discord required DAVE. (On 3.0.0 there is no runtime DAVE: `AudioPlayer` plays
  nothing in DAVE channels; upgrade to 3.1.)
- Driving MLS by hand (`VoiceDaveySession`, `send_dave_*`) on a `with_options` runtime: it already
  sends its own key package; the gateway would see two.
- Treating `AutoPaused` as a hang: on a DAVE runtime the player waits until the MLS group has a
  media key; a bot alone in the channel waits until someone joins. With
  `NoSubscriberBehavior::Stop`, `wait_until_playable().await` before `play`.
- Expecting receive errors for key problems: since 3.1.0 RTCP, forged, malformed, and
  undecryptable packets are skipped; watch `receive_stats()` (`non_voice_packets`,
  `rejected_packets`) and `dave_status().undecryptable_packets`, and pass a `max_len` that fits.
- Enabling trace logging for `davey` (`RUST_LOG=trace` without `davey=info`): it writes call media
  keys; install the tracing subscriber before connecting voice so the runtime's filter applies.
- Starting the voice runtime before both the bot's VOICE_STATE_UPDATE and the VOICE_SERVER_UPDATE
  arrived: wait until `ctx.voice_runtime_config(guild_id, user_id)` is `Some`. (On 3.0.0 the
  context also applied other members' voice states, so build the config yourself there.)
- Expecting a voice reconnect to resume: there is no RESUME; reconnecting is a fresh IDENTIFY and
  MLS join.
- Custom `VoiceFrameSink` that transmits before its future completes or blocks in `poll`.
- Process sharding: deploying a 3.0 parent with 2.x children (IPC frames differ), or not wiring
  `GatewayConnectionConfig::identify_gate(child.identify_gate())` in children.
- `spawn_shards` returns an error when `/gateway/bot` cannot be read (budget protection) unless
  you supply `ClientBuilder::identify_gate(..)`.

## Known limits and caveats

- **3.2.0 bounds every connection's setup** (connect, WebSocket upgrade, HELLO) to 15 s by default
  (`GatewayConnectionConfig::setup_timeout`). Up to 3.1.x only setups holding an IDENTIFY permit
  were bounded, so a RESUME or an ungated IDENTIFY waited as long as it took. Now an attempt that
  runs over fails and retries with the 1–300 s backoff: on a link where setup is always slower the
  shard never connects. Raise the bound there; `Duration::MAX` means no bound (3.1.x behaviour).

- **Never open a "passive" live gateway session with a production bot token.** On 2026-10-23 a
  handoff check opened a second, GUILDS-only session on the production bot's token while the bot
  ran; within 60 s a real user's INTERACTION_CREATE (s=5) arrived on the test session, which never
  answers, so Discord appears to have routed it there instead of to the production bot. Test
  gateway behaviour against a local mock gateway, or with a separate test application's token.

- **3.1.0 gateway bug, fixed in 3.1.1 (crates.io 2026-10-23):**
  after Discord's Reconnect (opcode 7) the client built the RESUME URL from READY's path-less
  `resume_gateway_url` as `wss://host?v=10…`, Discord answered HTTP 400, and the client retried the
  same URL forever, so the bot stayed offline until restarted (seen live for four hours). Require
  `discordrs = "3.1.1"`; repeated `Gateway connection error: … 400 Bad Request` logs mean 3.1.0.

- Voice: 3.1.0's DAVE runtime was live-checked once in a regular channel (send heard in an
  official client, receive decrypted; see the record below). Not yet run: the ignored full harness
  `tests/live_voice_dave.rs`. davey 0.1.x does not check a welcome's members against the call; there is no voice
  RESUME. The crate's voice guide (`discordrsdocs/docs/api/voice.md`, "Verification status") and
  the CHANGELOG still say only receiving was run live; `docs/design/perf-baseline.md` records the
  later send check.
- davey 0.1.5 logs media keys at trace level; the runtime's scoped filter is a mitigation only.
- Sharding (in-process and multi-process) was not live-tested; hermetic harnesses only.
- Modal and autocomplete responses, guild-channel writes, and the HTTP interactions endpoint were
  not live-tested (hermetic tests only).
- `display_name_styles` (`DisplayNameStyles`, `DisplayNameFont`, `DisplayNameEffect`) follows the
  unreleased discord-api-docs PR #8178 and may change.
- Interaction response state and the in-memory cache are per process (process sharding gives
  each child its own).
- OAuth2 error-body cleanup in `Debug` output is still listed as open in `ROADMAP.md`; don't log
  OAuth2 error bodies verbatim.
- Guild creation by applications was removed by Discord (2025-07-15); the related methods are
  deprecated and will be removed.
- Deadlines from Discord: channel obfuscation is mandatory from 2026-11-16 (`is_obfuscated()`,
  `ChannelPermissions::Obfuscated`); `CurrentUserGuildsQuery::shard` is required for
  `GET /users/@me/guilds` with large bot sharding since 2026-09-15.
- API coverage at release: 234/234 REST method+path routes of discord-api-docs `3714862`
  (2026-10-09). Gateway receive events and REST routes are re-compared weekly by
  `ci/api_drift.py` (report-only); a dispatch newer than the crate arrives as `EventKind::Unknown`
  with its raw JSON.

## Live verification records (docs/design/perf-baseline.md §11)

2026-10-23, `feat/session-handoff` (3.2.0 before release), production bot token, GUILDS only, no
REST writes (do not repeat: see "Never open a passive live gateway session" above):

| Check | Result |
|---|---|
| Process 1 → handoff → process 2 | process 1: IDENTIFY, READY, handoff, `start()` returned 1 ms after the request, snapshot sequence 3; process 2: RESUME on the resume URL, RESUMED (s=4) about 0.47 s after the handoff, no READY, then heartbeat ACKs and an INTERACTION_CREATE (s=5, a real user's, unanswered) |
| Made-up snapshot | RESUME → INVALID_SESSION → warning → IDENTIFY → READY |

2026-10-13, main `5a81f20`, one production bot token (not recorded), release build of a scratch
crate:

| Check | Result |
|---|---|
| 15 REST GETs (`/users/@me`, `/gateway/bot`, 30 guilds, 15 global commands, guilds/channels/recent messages/emojis of 3 guilds) | all succeeded, 0 decode errors |
| Gateway 60 s and 600 s, non-privileged intents (GUILDS, GUILD_MESSAGES, GUILD_MESSAGE_REACTIONS, GUILD_VOICE_STATES, GUILD_EXPRESSIONS) | READY, 30 GUILD_CREATE, 99 dispatches of 13 types, 0 decode failures, 0 unknown; RSS 4.4 → 13.6 MB |
| Privileged intents (GUILD_MEMBERS, GUILD_PRESENCES, MESSAGE_CONTENT), 120 s after the activity-buttons fix | GUILD_CREATE 30/30, 493 PRESENCE_UPDATE, 0 decode failures; RSS 22.6 MB (before the fix 11/30 GUILD_CREATEs failed) |
| Writes inside the app owner's DM only | open DM, create/edit message, add/remove reaction, Components V2 message with container and button, ephemeral button-interaction reply (327 ms), V2 edit without flags, delete cleanup: all passed |
| Not verified then | voice connection, guild channel writes, modal and autocomplete responses, the HTTP interactions endpoint, sharding |

2026-10-21, main `cea24e7` (receive fix rerun on `a37dbb0`), approved server, regular non-Stage
voice channel: `Context::join_voice` → `Context::connect_voice_runtime_with_dave` → `AudioPlayer`
(3 s 440 Hz tone, raw PCM) → receive loop.

| Check | Result |
|---|---|
| DAVE negotiation | protocol v1, epoch 1, 0 transitions, no `last_error`, voice privacy code issued |
| Playback timing | bot alone: no group, waited in `AutoPaused` ~80 s until a person joined, then played; person already present: playing within 20 ms |
| Send | tone heard in an official Discord client (real interop of the runtime's DAVE frame encryption) |
| Receive (before fix) | 63 packets of one speaker decrypted (DAVE + transport, 14 with speech); 35 `failed to decrypt AES-GCM voice packet` errors (~1/s, RTCP opened as voice); a `?` loop ended at the first |
| Receive (after `a37dbb0`, 2 runs) | 0 errors; 33 and 110 non-voice (RTCP) packets skipped, 0 rejected, 0 DAVE failures, epoch 1 → 3 with 2 transitions handled; no speech captured in these runs |
| Still not verified | guild channel writes, modal and autocomplete responses, the HTTP interactions endpoint, sharding, `tests/live_voice_dave.rs` |
