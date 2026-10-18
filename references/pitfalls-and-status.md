# Pitfalls, known limits, and what was live-tested (discord.rs 3.0.0)

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
  are encoded without it.
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
- DAVE-negotiated calls: the default config offers DAVE, and when Discord enables it, plain sends
  and receives fail and `AudioPlayer` via `subscribe_runtime` plays nothing (it only logs). See
  "DAVE caveat" in `voice-sharding.md`.
- `Context::connect_voice_runtime` can pick up another member's voice session id; build
  `VoiceRuntimeConfig` from your own user's VOICE_STATE_UPDATE.
- Starting the voice runtime before both VOICE_STATE_UPDATE (session id) and VOICE_SERVER_UPDATE
  (token, endpoint) arrived.
- Custom `VoiceFrameSink` that transmits before its future completes or blocks in `poll`.
- Process sharding: deploying a 3.0 parent with 2.x children (IPC frames differ), or not wiring
  `GatewayConnectionConfig::identify_gate(child.identify_gate())` in children.
- `spawn_shards` returns an error when `/gateway/bot` cannot be read (budget protection) unless
  you supply `ClientBuilder::identify_gate(..)`.

## Known limits and caveats

- Voice (send and receive, both transport modes) and DAVE were **not** exercised against live
  Discord for 3.0.0. The transport fix is backed by external known-answer vectors and parity with
  @discordjs/voice and Songbird. The ignored DAVE MLS-transition harness
  (`tests/live_voice_dave.rs`) passed live for 2.0.0 (2026-05-02, MLS only) and must be rerun
  before claiming DAVE interop for 3.x. `AudioPlayer` has no built-in DAVE path.
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
- Parts of the crate `README.md` feature list still use 2.x wording (for example "Event enum
  dispatch"); trust `CHANGELOG.md` "3.0.0", the API pages under `discordrsdocs/docs/api/`, the
  migration guide, and the code.
- API coverage at release: 234/234 REST method+path routes of discord-api-docs `3714862`
  (2026-10-09). Gateway receive events and REST routes are re-compared weekly by
  `ci/api_drift.py` (report-only); a dispatch newer than the crate arrives as `EventKind::Unknown`
  with its raw JSON.

## Live verification record (docs/design/perf-baseline.md §11, 2026-10-13, main `5a81f20`)

One production bot token (not recorded), release build of a scratch crate:

| Check | Result |
|---|---|
| 15 REST GETs (`/users/@me`, `/gateway/bot`, 30 guilds, 15 global commands, guilds/channels/recent messages/emojis of 3 guilds) | all succeeded, 0 decode errors |
| Gateway 60 s and 600 s, non-privileged intents (GUILDS, GUILD_MESSAGES, GUILD_MESSAGE_REACTIONS, GUILD_VOICE_STATES, GUILD_EXPRESSIONS) | READY, 30 GUILD_CREATE, 99 dispatches of 13 types, 0 decode failures, 0 unknown; RSS 4.4 → 13.6 MB |
| Privileged intents (GUILD_MEMBERS, GUILD_PRESENCES, MESSAGE_CONTENT), 120 s after the activity-buttons fix | GUILD_CREATE 30/30, 493 PRESENCE_UPDATE, 0 decode failures; RSS 22.6 MB (before the fix 11/30 GUILD_CREATEs failed) |
| Writes inside the app owner's DM only | open DM, create/edit message, add/remove reaction, Components V2 message with container and button, ephemeral button-interaction reply (327 ms), V2 edit without flags, delete cleanup: all passed |
| Not verified | voice connection, guild channel writes, modal and autocomplete responses, the HTTP interactions endpoint, sharding |
