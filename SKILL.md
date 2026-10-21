---
name: discordrs-dev
description: Build, debug, review, migrate, and document Rust Discord bots and apps that use the discordrs crate (discord.rs) 3.x (written for 3.1.0), and contribute to the crate itself. Use when code or a request involves discordrs or discord.rs - gateway Client/EventHandler with shared Arc events and EventKind, typed IDs (GuildId, ChannelId), RestClient with discordrs::request bodies, MessageBuilder and Components V2 builders, slash commands, InteractionResponder, the HTTP interactions endpoint or AppFramework (EndpointReply), modals, collectors, cache and CacheBackend, permissions, formatters, webhook events, voice in DAVE (E2EE) channels and AudioPlayer, sharding, or upgrading 2.x or 3.0 code.
---

# discordrs-dev (discord.rs 3.1.0)

Crate `discordrs` (brand "discord.rs"), version 3.1.0 (released 2026-10-21; 3.0.0 was
2026-10-18), MSRV 1.88, async on Tokio. 3.1.0 is additive over 3.0.0 (working voice in DAVE
channels, receive-loop fixes, an endpoint `allowed_mentions` default). Source: <https://github.com/Ingwannu/discord.rs>; API docs on docs.rs;
guide site in the repo (`discordrsdocs/`, Korean copy in `discordrsdocs/ko/`).

## First steps

1. Read the project's `Cargo.toml` / `Cargo.lock` for the discordrs version and features. This
   skill is exact for 3.1.0; on 3.0.0 everything holds except the 3.1 additions listed in
   [migration-2x-to-3.md](references/migration-2x-to-3.md) ("3.0.0 → 3.1.0"), which also maps 2.x code.
   For a newer version, check its `CHANGELOG.md` before trusting details here.
2. Pick the runtime lane (below), then open only the reference you need.
3. Prefer typed APIs: never hand-write JSON when a `discordrs::request` type, builder, or method
   exists; never invent a method; look it up ([api-overview.md](references/api-overview.md),
   "Finding the right function").

## Quick start: choose the lane

| Lane | Cargo features | Entry point | Reference |
|---|---|---|---|
| Gateway bot (events, cache, slash replies over the websocket) | `gateway` (+ `collectors`) | `Client::builder(token, intents).event_handler(h).start()` | [gateway-events-cache.md](references/gateway-events-cache.md) |
| HTTP interactions endpoint (serverless-style slash app) | `interactions` | `try_typed_interactions_endpoint(public_key, AppFramework::builder()...build())` → axum 0.8 `Router` | [interactions.md](references/interactions.md) |
| REST-only tool (register commands, send messages, admin) | none (default) | `RestClient::new(token, Some(app_id))` | [rest-requests-builders.md](references/rest-requests-builders.md) |
| Webhook Events (Events URL) | none (`interactions` for `verify_discord_signature`) | verify signature, then `parse_webhook_event_payload` | [api-overview.md](references/api-overview.md) |
| Voice / music | `gateway`, `voice` (includes DAVE), `voice-encode` | `ctx.join_voice` → both voice updates arrived → `ctx.connect_voice_runtime_with_dave(guild, bot_user)` → `AudioPlayer` | [voice-sharding.md](references/voice-sharding.md) |
| Large bots | `sharding` | `spawn_auto_shards()`, `sharding::process` | [voice-sharding.md](references/voice-sharding.md) |

```rust
// features: gateway
use std::sync::Arc;

use discordrs::{
    gateway_intents, Client, Context, DiscordError, Event, EventHandler, EventKind, Interaction,
    InteractionResponder,
};

struct Bot;

impl EventHandler for Bot {
    // Plain `async fn` (no #[async_trait]); the future must be Send.
    async fn handle_event(&self, ctx: Context, event: Arc<Event>) {
        match event.kind() {
            EventKind::Ready(ready) => println!("ready as {}", ready.user.username),
            EventKind::InteractionCreate(interaction) => {
                if let Interaction::ChatInputCommand(command) = &**interaction {
                    if let Err(error) = command.reply_ephemeral(ctx.rest().as_ref(), "pong").await {
                        eprintln!("reply failed: {error}");
                    }
                }
            }
            _ => {} // EventKind is large and open: keep a catch-all arm
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), DiscordError> {
    let token = std::env::var("DISCORD_TOKEN")?;
    Client::builder(&token, gateway_intents::GUILDS)
        .event_handler(Bot)
        .start()
        .await
}
```

Register the `/ping` command once with `RestClient::bulk_overwrite_global_commands` (see
[interactions.md](references/interactions.md), "Commands").

## Mental model

- **Typed IDs.** `GuildId`, `ChannelId`, `UserId`, `RoleId`, `MessageId`, `ApplicationId`, … are
  8-byte `Copy` newtypes, never zero, parsed strictly (`"…".parse()?`, `X::try_from(u64)?`), passed
  by value. Mixing kinds does not compile. `GenericId` only where Discord leaves the kind open;
  polymorphic fields are enums (`OverwriteTarget`, `CommandPermissionTarget`, …).
- **Open discriminants.** `ChannelType`, `MessageType`, `ButtonStyle`, `InteractionType`, … are
  newtypes with constants (`ChannelType::GUILD_TEXT`), `new(n)` / `get()`, unknown values kept,
  no `Default`. Always keep a `_` arm.
- **Patch vs Nullable.** `Patch::{Missing, Value}`, `Nullable::{Null, Value}`,
  `NullablePatch<T>`; modify bodies use `clear_*()` to send `null`; partial events
  (`MessageUpdate`, `MemberUpdate`, `GuildUpdate`) have `apply_to`.
- **One shared event.** Every dispatch is decoded once into an `Arc<Event>` shared by cache,
  collectors, and handlers. Match `event.kind()`; `event.name()`; `event.raw()` for known events
  only with `keep_raw_events(true)` (always kept for `Unknown` / `DecodeFailed`); decode failures
  go to `EventKind::DecodeFailed` / the `decode_failed` hook.
- **Pipeline.** A per-shard processor updates cache and collectors in order without waiting for
  handlers; handlers run in bounded lanes (interactions have their own lane and 2 s admission;
  Serial mode runs one regular handler at a time per shard, so spawn long waits). The cache may
  be ahead of the event you are handling; partial updates never create entries.
- **Received vs sent types.** `discordrs::model` = what Discord sends; `discordrs::request` =
  what you send (`CreateMessage`, `EditMessage`, `ExecuteWebhook`, `ModifyChannel`,
  `InteractionMessage`, `Modal`, …). Builders produce `request` types; nothing is
  `serde_json::Value`.
- **One response type.** `request::InteractionResponse` serves the REST callback, the HTTP
  endpoint, and `InteractionResponder`. HTTP handlers return `EndpointReply::{Inline, Accepted}`.
  Each interaction has one shared response state (`Unacknowledged → InFlight →
  Deferred/Replied/Acknowledged`, or `Uncertain` after an ambiguous failure, where a retry is
  safe and Discord's 40060 settles it). Inline endpoint replies get a default
  `allowed_mentions` only from `InteractionsEndpointBuilder::default_allowed_mentions` (3.1.0),
  not from the `RestClient`.
- **Voice runs DAVE.** Discord requires DAVE (MLS end-to-end encryption) outside Stage channels;
  `connect_voice_runtime_with_options` / `Context::connect_voice_runtime_with_dave` run it for
  you, while `connect_voice_runtime` keeps 3.0.0's leave-it-to-you behaviour.
- **Async traits without async-trait.** `EventHandler`, `CacheBackend`, `InteractionHandler`,
  `TypedInteractionHandler`, `CachedManager` use `async fn`; not object safe (`Arc<B>`, not
  `Arc<dyn ..>`).
- **Safe transport.** One REST method per route; ambiguous POST/PATCH failures are not replayed;
  interaction callbacks are exempt from the bot-global rate limit; tokens are scrubbed from errors.

## Rules

1. Read tokens, public keys, and IDs from the environment or config; never print, log, commit,
   or paste them (also not in examples, tests, or reports).
2. Use the canonical 3.0 names; treat every deprecation warning as a bug to fix.
3. Use `request::*` bodies and builders; `RawRequest` (+ `request_discard`) only for routes the
   crate does not wrap.
4. Respond to every interaction exactly once within 3 s (`defer` first for slow work); return
   `EndpointReply::Accepted` only when the initial response goes over REST (sent already, or by
   a task you spawned within the 3 s).
5. Parse IDs at the boundary; never convert between ID kinds through `u64`.
6. Keep `_` arms for open enums, `CollectorEndReason`, `ShardSupervisorEvent`, `EventKind`.
7. Request privileged intents (`GUILD_MEMBERS`, `GUILD_PRESENCES`, `MESSAGE_CONTENT`) only when
   needed, and enable them in the Developer Portal too.
8. No std `Mutex` guard or `ctx.voice()` lock across `.await`.
9. Voice: connect with the `*_with_dave` / `*_with_options` entry points, and keep the `davey`
   log target at `info` or coarser (`RUST_LOG=info,davey=info`): its trace output contains call
   media keys.
10. Bots set presence with `BotActivity` (name, type, state, url only); no activity buttons.
11. Validate locally with `try_build()` / `validate()` before sending user-built content.
12. When changing the crate itself, follow [contributing.md](references/contributing.md): lint
    rules, Why-comments + Decision Log, en+ko docs, snippet harness, route manifest, gates.

## Pitfalls (details in [pitfalls-and-status.md](references/pitfalls-and-status.md))

- `EndpointReply::Accepted` without a REST reply → "This interaction failed".
- Autocomplete must be answered with choices; `AppFramework` needs `.autocomplete(name, ..)`.
- `MessageCollector` no longer yields edits: use `MessageUpdateCollector`. Inside handlers use
  `ctx.message_collector()` (replays from the handled event).
- Received activity `buttons` are label strings; bots cannot send buttons.
- `IS_COMPONENTS_V2` forbids `content`/embeds/poll: put text in `TextDisplayBuilder`.
- `AllowedMentions::default()` suppresses all mentions; no `allowed_mentions` pings everything.
- `AudioPlayer::play` needs `voice-encode`. On a DAVE runtime it waits in `AutoPaused` until the
  MLS group has keys; a bot alone in a channel waits until someone joins (that is not a hang).
  Watch `player.connection_events()` for `SendFailed`/`Recovered`.
- `connect_voice_runtime` / `Context::connect_voice_runtime` in a DAVE channel: plain sends and
  receives fail (3.0.0 behaviour). A 4017 close means DAVE was required.
- Receive loops no longer error on RTCP or undecryptable packets; check `receive_stats()`.
- Live-tested for 3.1.0: DAVE send (heard in an official client) and receive. Not live-tested:
  sharding, the HTTP interactions endpoint, modal/autocomplete replies.
- Serial dispatch (default) runs one handler at a time per shard: spawn long collector waits.
- Default cache keeps at most 1,000 guilds (`CacheConfig::max_guilds`).

## Verify your work

For a bot project: `cargo check` / `cargo clippy --all-targets -- -D warnings` with the features
you use, and `cargo test`. Never run a bot against Discord with a real token unless the user
asked for it. For this skill's own examples: `scripts/check-examples.sh` compiles every Rust block
against the published crate (see `README.md`).

## References

- [api-overview.md](references/api-overview.md): features, module map, typed IDs, discriminants,
  `Patch`, bitfields/intents, permissions, formatters, webhook events, errors, API discovery.
- [gateway-events-cache.md](references/gateway-events-cache.md): `Client`, hooks, pipeline knobs,
  `Context`, `fetch_members`, collectors, cache, `CacheBackend` epoch contract.
- [rest-requests-builders.md](references/rest-requests-builders.md): `RestClient`, request bodies,
  `RawRequest`, retries and rate limits, `allowed_mentions`, Components V2, buttons, selects,
  embeds, Component Embed.
- [interactions.md](references/interactions.md): `Interaction`, `InteractionResponse`,
  `EndpointReply`, responder state, HTTP endpoint, `AppFramework`, modals, commands.
- [voice-sharding.md](references/voice-sharding.md): voice flow, DAVE runtime, davey logging,
  transport crypto, receive skipping, `AudioPlayer`, `VoiceFrameSink`, live voice record,
  in-process and multi-process sharding, `IdentifyGate`.
- [migration-2x-to-3.md](references/migration-2x-to-3.md): 2.x → 3.0 map, behaviour changes,
  and 3.0.0 → 3.1.0.
- [contributing.md](references/contributing.md): working on the crate (code rules, docs, CI gates).
- [pitfalls-and-status.md](references/pitfalls-and-status.md): mistakes, known limits, live tests.
