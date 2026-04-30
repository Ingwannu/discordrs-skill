# discordrs 1.2.1 Reference

Legacy filename note: this file remains `discordrs-0.4.0.md` for compatibility, but the guidance below targets `discordrs 1.2.1`.

## Version

- Verified workspace version: `1.2.1`
- Preferred names in new code/docs:
  - `Client` over `BotClient`
  - `RestClient` over `DiscordHttpClient`
  - `EventHandler::handle_event(...)` over per-event legacy callbacks
  - typed `Interaction` variants over raw JSON routing when possible
- Current public surface notes:
  - typed `RestClient` methods are the public REST API
  - builder implementation submodules are private; use `discordrs::builders::{...}` or crate-root re-exports
  - `ApplicationCommand` uses `id_opt()` / `created_at()` instead of a `DiscordModel` impl
  - tokenized callback/webhook paths are validated and reject empty or unsafe path segments
  - bot `Authorization` headers are intentionally omitted for token-authenticated `/webhooks/...` and `/interactions/...` requests
  - gateway Identify/Resume payloads send the raw Discord token
  - default cache storage is bounded; tune gateway cache with `ClientBuilder::cache_config(...)`
  - `CacheConfig::unbounded()` is explicit opt-in for retaining all cached gateway data
  - OAuth2 client secrets, authorization codes, access tokens, and refresh tokens are redacted from `Debug` output
  - typed slash/autocomplete input uses `CommandInteractionOption` so nested `value` / `focused` data survives parsing
  - voice provides raw UDP receive, Opus-frame send, RTP header parsing, AES-GCM/XChaCha RTP-size transport encrypt/decrypt, pure-Rust Opus PCM decode, and optional PCM-to-Opus encode through `voice-encode`
  - `dave` is an experimental feature that exposes DAVE opcode state plus `davey`/OpenMLS-backed receive and outbound media hooks; do not claim full live DAVE support without real Discord voice gateway transition tests
  - typed REST/event coverage includes polls, subscriptions, entitlements, soundboard, thread details, forum fields, invites, and integrations in addition to the earlier command/message/core surfaces

If the target workspace uses a different version, prefer the workspace and adjust examples to match it.

## Beginner Mental Model

`discordrs` has three main surfaces. Pick one first, then add optional runtime layers.

1. Core/default surface
   Use for builders, typed models, parsers, helper functions, and direct HTTP calls.
2. Gateway runtime
   Use when the bot stays connected to Discord and reacts to websocket events.
3. Signed HTTP interactions endpoint
   Use when Discord POSTs interactions to your web server.

Cause and effect:

- If you need live events such as `MESSAGE_CREATE`, choose `gateway`.
- If you need Discord to call your web app, choose `interactions`.
- If you only need to register commands or send/edit messages, core/default plus `RestClient` is enough.
- If you need cache-backed reads during gateway event handling, add `cache` on top of `gateway`.
- If you need wait-for-next-message / wait-for-next-click style flows, add `collectors` on top of `gateway`.
- If you need multi-shard lifecycle control, add `sharding` on top of `gateway`.
- If you need voice state, voice handshake, transport-decrypted Opus frames, or PCM decode, add `voice`.
- If you need DAVE/MLS receive or outbound media hooks, add `voice` plus `dave` and keep interoperability claims tied to live gateway tests.

## Runtime Relationship Map

### Gateway path

`Client::builder(token, intents)`  
-> `.event_handler(handler)`  
-> `.start()`  
-> `EventHandler::handle_event(ctx, event)`  
-> match on typed `Event`  
-> use `ctx.rest()`, helpers, cache managers, shard helpers, or voice helpers

Meaning:

- `Client` starts and owns the runtime.
- `Event` is typed incoming data from Discord.
- `Context` is the bridge from incoming gateway events to outgoing actions.
- `raw_event` is for unknown/untyped gateway events, not the default happy path.

### HTTP interactions endpoint path

`try_typed_interactions_endpoint(public_key, handler)`  
-> typed `Interaction`  
-> return `InteractionResponse`

Meaning:

- Use `TypedInteractionHandler` when you want typed HTTP interaction handling.
- Use `try_interactions_endpoint()` only when you intentionally want the raw interaction surface.
- `InteractionContextData` lives inside interactions and carries ids/token/application id for replies.

### REST-only path

`RestClient::new(token, application_id)` or `Client::builder(...).rest_only()`  
-> call typed HTTP methods such as `create_global_command()`, `get_guild()`, `create_message()`

Meaning:

- This is the smallest surface when you do not need a live runtime.
- It is the safest choice for command registration, setup scripts, and HTTP-only tools.
- Prefer typed public methods. The old raw convenience methods such as `send_message(...)` or `create_interaction_response(...)` are no longer public.
- Follow-up and interaction webhook helpers intentionally omit bot `Authorization` headers on token-authenticated `/webhooks/...` and `/interactions/...` routes.
- Tokenized callback/webhook path assembly is hardened: empty or unsafe path segments are rejected instead of being interpolated into request paths.
- HTTP failures should surface as `DiscordError::Api` or `DiscordError::RateLimit`, not generic model errors.

## Feature Flags With Cause/Effect

- default/core:
  - Adds typed models, builders, parsers, helpers, `RestClient`, and response builders.
  - Choose this when you want the crate's data model and HTTP helpers without a live runtime.
- `gateway`:
  - Adds `Client`, `Context`, typed `Event`, gateway websocket handling, and `EventHandler`.
  - Choose this when your bot reacts to messages, interactions, or lifecycle events in real time.
- `interactions`:
  - Adds request signature verification plus `interactions_endpoint()` / `try_typed_interactions_endpoint()`.
  - Choose this when your app receives Discord interactions over HTTP.
- `cache`:
  - Enables in-memory cache storage used by gateway cache managers.
  - Manager shortcuts exist from `Context`, but meaningful cached reads depend on this feature plus a running gateway runtime.
- `collectors`:
  - Adds collectors for follow-up UI/message flows.
  - Choose this when the bot needs to wait for the next matching message/component/modal event.
- `sharding`:
  - Adds shard supervisor/status/control primitives.
  - Choose this when one gateway connection is not enough or the task is about shard lifecycle.
- `voice`:
  - Adds voice state management, voice runtime handshake plumbing, Opus-frame send, raw UDP receive, RTP-size transport decrypt, and pure-Rust Opus PCM decode.
  - Choose this when the task needs voice state/session setup, Opus-frame playback, decrypted Opus frames, or interleaved `i16` PCM.
- `voice-encode`:
  - Adds `PcmFrame`, `AudioSource`, `AudioMixer`, and `VoiceOpusEncoder` for 48 kHz stereo 20 ms PCM-to-Opus playback.
  - Choose this when the task needs to feed PCM sources into the existing voice playback path.
- `dave`:
  - Adds experimental DAVE/MLS receive and outbound media hooks, `VoiceDaveySession`, and `VoiceDaveFrameEncryptor`.
  - Choose this only when the task explicitly needs DAVE frame parsing, decryptor/encryptor integration, or MLS gateway command payloads. Full live interoperability still needs real voice gateway transition verification.

## Common Workflows

### 1. Build a minimal typed gateway bot

```rust
use async_trait::async_trait;
use discordrs::{gateway_intents, Client, Context, Event, EventHandler, DiscordError};

struct Handler;

#[async_trait]
impl EventHandler for Handler {
    async fn handle_event(&self, _ctx: Context, event: Event) {
        match event {
            Event::Ready(ready) => println!("READY: {}", ready.data.user.username),
            Event::MessageCreate(message) => println!("MESSAGE: {}", message.message.content),
            _ => {}
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), DiscordError> {
    let token = std::env::var("DISCORD_TOKEN")?;
    Client::builder(
        &token,
        gateway_intents::GUILDS | gateway_intents::GUILD_MESSAGES,
    )
    .event_handler(Handler)
    .start()
    .await
}
```

Use this when the bot needs a persistent connection and typed event dispatch.

### 2. Register commands without starting a gateway runtime

```rust
use discordrs::{DiscordError, RestClient, SlashCommandBuilder};

async fn register(http: &RestClient) -> Result<(), DiscordError> {
    let command = SlashCommandBuilder::new("ping", "Reply with pong").build();
    http.create_global_command(&command).await?;
    Ok(())
}
```

Use this when the job is setup/migration/admin tooling, not a live bot.

### 3. Build a typed HTTP interactions endpoint

```rust
use async_trait::async_trait;
use axum::Router;
use discordrs::{
    Interaction, InteractionContextData, InteractionResponse, TypedInteractionHandler,
    try_typed_interactions_endpoint,
};

#[derive(Clone)]
struct Handler;

#[async_trait]
impl TypedInteractionHandler for Handler {
    async fn handle_typed(
        &self,
        _ctx: InteractionContextData,
        interaction: Interaction,
    ) -> InteractionResponse {
        match interaction {
            Interaction::ChatInputCommand(cmd) if cmd.data.name.as_deref() == Some("hello") => {
                InteractionResponse::ChannelMessage(serde_json::json!({ "content": "hello" }))
            }
            _ => InteractionResponse::DeferredMessage,
        }
    }
}

fn router(public_key: &str) -> Router {
    try_typed_interactions_endpoint(public_key, Handler).expect("invalid public key")
}
```

Use this when Discord calls your server instead of your bot consuming a websocket stream.

### 4. Read from cache-aware managers

```rust
async fn inspect_cache(ctx: &discordrs::Context) {
    let guilds = ctx.guilds().list_cached().await;
    println!("cached guilds: {}", guilds.len());
}
```

Important relationship:

- `ctx.guilds()`, `ctx.channels()`, `ctx.members()`, `ctx.messages()`, and `ctx.roles()` are manager shortcuts.
- These managers can fall back to HTTP, but `list_cached()` and `cached(...)` only become useful when `gateway + cache` is active and the runtime has seen relevant events.

### 5. Reply to gateway interactions

- For new gateway code, match `Event::InteractionCreate(interaction)` inside `handle_event(...)`.
- Prefer typed helpers like `respond_with_message(...)`, `followup_message(...)`, `defer_interaction(...)`, or `update_interaction_message(...)`.
- If the client was created without an application id, use the explicit `*_with_application_id` follow-up helpers when needed.

## Compatibility Aliases and Migration Notes

- `BotClient` is still available, but treat it as a compatibility alias for `Client`.
- `DiscordHttpClient` is still available, but treat it as a compatibility alias for `RestClient`.
- Legacy convenience callbacks still exist on `EventHandler`, but `handle_event(...)` is the canonical typed entry point.
- `ready`, `message_create`, and `interaction_create` now receive typed payloads too.
- The modern public surface is `1.2.0`; examples/docs should prefer that version and naming.
- Builder implementation submodules are private. Use `discordrs::builders::{...}` or crate-root re-exports.
- `ApplicationCommand` no longer implements `DiscordModel`. Use `id_opt()` and `created_at()` on the command directly.
- `CommandInteractionData.options` uses `CommandInteractionOption`, not `ApplicationCommandOption`, so user-entered `value` / `focused` data remains available in typed slash/autocomplete flows.
- Common replacements:
  - `RestClient::send_message(...)` -> `send_message(...)` helper or `RestClient::create_message(...)`
  - `RestClient::edit_message(...)` -> `RestClient::update_message(...)`
  - `RestClient::create_dm_channel(...)` -> `RestClient::create_dm_channel_typed(...)`
  - `RestClient::create_interaction_response(...)` -> `RestClient::create_interaction_response_typed(...)`
  - `RestClient::bulk_overwrite_global_commands(...)` -> `RestClient::bulk_overwrite_global_commands_typed(...)`
  - typed follow-up helpers may now return a typed `Message`; the raw JSON follow-up container helper still routes through crate-private JSON webhook helpers

## 1.2.0 Release Notes For Agents

- Version source of truth: `Cargo.toml` is `1.2.0`; crates.io package/import remains `discordrs`, while public branding is `discord.rs`.
- Gateway: `zlib-stream` payloads are buffered as a stream instead of decoded as independent binary frames.
- HTTP: multipart upload helpers exist for message, webhook, and interaction attachment paths, and webhook message CRUD is typed.
- Models/events: polls, AutoMod, scheduled events, audit logs, stickers, stage instances, onboarding, templates, invites, integrations, forum fields, soundboard, subscriptions, SKUs, and entitlements have stronger typed coverage.
- Cache: additional optional cache buckets cover emoji, stickers, voice states, presences, threads, webhooks, scheduled events, AutoMod rules, invites, integrations, soundboard sounds, and monetization entities.
- Voice: playback/receive now includes raw UDP, RTP parsing, AES-GCM/XChaCha RTP-size transport encrypt/decrypt, Opus-frame send, Opus PCM decode, and optional PCM-to-Opus encode through `voice-encode`.
- DAVE: `dave` remains experimental and exposes parser/state/decryptor/encryptor hooks plus MLS outbound command payloads; do not present it as verified end-to-end Discord voice interoperability without live gateway evidence.
- Release docs: update root `CHANGELOG.md`, Docsify changelog, README, USAGE, and both skill copies together when the release surface changes.

## Current API Coverage Notes

- Voice playback/receive:
  - `connect_voice_runtime(...)` returns a runtime handle after voice websocket and UDP setup.
  - `recv_raw_udp_packet(...)` returns the raw RTP-like UDP packet metadata.
  - `recv_voice_packet(...)` returns a transport-decrypted Opus frame for non-DAVE sessions.
  - `VoiceOpusDecoder::discord_default()` decodes received Opus frames to 48 kHz stereo interleaved `i16` PCM.
  - `VoiceOpusEncoder` encodes 48 kHz stereo 20 ms `PcmFrame` values when `voice-encode` is enabled.
  - `recv_voice_packet_with_dave(...)` and `recv_decoded_voice_packet_with_dave(...)` accept a `VoiceDaveFrameDecryptor`.
  - With `voice,dave`, `VoiceDaveySession` wraps `davey::DaveSession` for experimental OpenMLS-backed frame decrypt/encrypt integration.
- REST/event coverage to prefer in examples:
  - Polls: `CreatePoll`, `Poll`, `get_poll_answer_voters(...)`, `end_poll(...)`, `MESSAGE_POLL_VOTE_ADD`, `MESSAGE_POLL_VOTE_REMOVE`.
  - Monetization: `Sku`, `Entitlement`, `Subscription`, entitlement REST helpers, SKU subscription REST helpers, `ENTITLEMENT_*`, `SUBSCRIPTION_*`.
  - Soundboard: default/guild soundboard REST helpers plus `GUILD_SOUNDBOARD_*` and `SOUNDBOARD_SOUNDS`.
  - Threads: thread member get/list/add/remove, public/private/joined archived thread lists, and active guild threads.
  - Forum/media channels: `available_tags`, `applied_tags`, `default_reaction_emoji`, and `default_thread_rate_limit_per_user`.
  - Integrations/invites: integration list/delete plus `INTEGRATION_*`, invite options, `INVITE_CREATE`, and `INVITE_DELETE`.

## Pitfalls

- Do not start with cache/collectors/sharding/voice. Start with the runtime choice, then layer them on.
- Do not document cache managers as if `cache` creates the types. The feature enables storage; the manager access pattern already exists from `Context`.
- Do not use `raw_event` as the default gateway path. Use typed `Event` matching first.
- Do not use raw interaction routing unless the task specifically needs unknown payload preservation.
- Do not handwrite button/select JSON if the builder already models the payload.
- Do not recommend removed raw REST convenience methods in new code or docs.
- Do not import from deeper builder implementation paths such as `discordrs::builders::modal::*`.
- Do not prefix gateway Identify/Resume tokens with `Bot `; that prefix is only for HTTP authorization headers.
- Do not parse typed slash/autocomplete input into command-definition models when the task depends on user-entered `value` or `focused` data.
- Do not assume follow-up webhook helpers can work with `application_id == 0`.
- Do not attach bot `Authorization` headers to token-authenticated `/webhooks/...` or `/interactions/...` requests.
- Do not bypass tokenized webhook/callback path validation with empty or unsafe path segments.
- Do not switch gateway cache defaults back to unbounded retention; require an explicit `CacheConfig::unbounded()` choice for that behavior.
- Do not derive `Debug` on OAuth2 types that store client secrets, authorization codes, access tokens, or refresh tokens.
- Do not describe default `voice` as full DAVE support. It provides state, handshake/runtime, transport encrypt/decrypt, Opus-frame send, and PCM decode; `voice-encode` adds PCM encode/playback; DAVE/MLS remains experimental and must be validated against live voice gateway transitions.
- Treat `MESSAGE_UPDATE` as partial by nature when writing custom cache logic or examples.
- Do not use `ready.data.application.id` as a guild cache key in examples; it is not a guild id.
- Treat gateway event handling as ordered work. The runtime now serializes dispatches through a dedicated event processor rather than unbounded per-event task spawning.
- Treat interaction request signatures as freshness-checked; stale and future timestamps are rejected.
- Treat voice disconnects and endpoint loss as state-reset events that clear stale runtime/session data.

## Verification Commands

```powershell
cargo test --all-features
```

```powershell
cargo check --all-features --all-targets
```

```powershell
cargo clippy --all-features --tests -- -D warnings
```

Focused checks are useful when editing one surface:

- gateway/cache work: `cargo test --features "gateway cache" --lib gateway::bot::tests`
- HTTP work: `cargo test --lib http::tests`
- HTTP hardening work: check auth-header behavior and tokenized callback/webhook path tests in the focused HTTP suite
- embed builder work: `cargo test --lib embed::tests`
