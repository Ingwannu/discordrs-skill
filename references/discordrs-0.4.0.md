# discordrs 2.0.0 Reference

Legacy filename note: this file remains `discordrs-0.4.0.md` for compatibility with installed skills and older prompts, but the guidance below targets `discordrs 2.0.0`.

The Cargo package and import path are `discordrs`. The public-facing project name is `discord.rs`.

## Version And Evidence

- Verified release version: `2.0.0`.
- Source of truth for a workspace: `Cargo.toml`.
- Official REST route-shape coverage recorded for 2.0.0: `223 / 223`.
- Official Gateway send-event coverage recorded for 2.0.0: `7 / 7`.
- Official Gateway receive-event coverage recorded for 2.0.0: `82 / 82`.
- Official object-heading coverage recorded for 2.0.0: `90 / 90` mapped or intentionally dynamic.
- Release coverage recorded for 2.0.0: `92.32%` all-features line coverage.
- Live DAVE/MLS validation: ignored harness passed against a real Discord voice session for the 2.0.0 release. Do not reuse that as proof for future behavior without rerunning the live gate.

If the target workspace uses a different version, prefer the workspace and adjust examples to match it.

## Current Public Surface Notes

- Prefer `Client` over `BotClient`.
- Prefer `RestClient` over `DiscordHttpClient`.
- Prefer `EventHandler::handle_event(...)` plus typed `Event` matching over raw event routing.
- Prefer `AppFramework` for beginner HTTP interaction routing when the task is commands/components/modals with guards or cooldowns.
- Prefer typed `Interaction` variants and `try_typed_interactions_endpoint(...)` over raw JSON interaction routing.
- Prefer `parse_webhook_event_payload(...)` for Discord Webhook Events after signature verification.
- Typed `RestClient` methods are the public REST API.
- Builder implementation submodules are private; use `discordrs::builders::{...}` or crate-root re-exports.
- `ApplicationCommand` IDs are optional until Discord assigns them. Use `id_opt()` and `created_at()` on the command.
- Tokenized callback/webhook paths validate path segments and reject empty or unsafe values.
- Bot `Authorization` headers are intentionally omitted for token-authenticated `/webhooks/...` and `/interactions/...` routes.
- Gateway Identify/Resume payloads send the raw Discord token.
- Default Gateway startup must not ask for payload compression unless the runtime decodes it; explicit `zlib-stream` decodes compressed `HELLO` and dispatch frames.
- Typed slash/autocomplete input uses `CommandInteractionOption` so nested option `value` and `focused` survive parsing.
- Default cache storage is bounded; use `ClientBuilder::cache_config(...)` to tune and `CacheConfig::unbounded()` only by explicit operator choice.
- OAuth2 client secrets, authorization codes, access tokens, and refresh tokens are redacted from `Debug`.
- Interaction signatures are timestamp freshness checked.
- Voice provides raw UDP receive, Opus-frame send, RTP parsing, AES-GCM/XChaCha RTP-size transport encrypt/decrypt, Opus PCM decode, optional PCM-to-Opus encode through `voice-encode`, and experimental DAVE hooks through `dave`.

## Beginner Mental Model

`discordrs` has five main surfaces. Pick one first.

1. Core/default surface
   Builders, typed models, parsers, helpers, Components V2, `RestClient`, and response builders.
2. Gateway runtime
   A long-lived bot websocket connection that receives typed Gateway events.
3. HTTP interactions endpoint
   Discord POSTs slash commands, components, autocomplete, and modals to your web server.
4. Webhook Events endpoint
   Discord POSTs application event notifications to an Events URL.
5. Voice runtime
   Gateway voice state plus voice websocket/UDP transport, Opus send/receive, decode/encode, and DAVE hooks.

Cause and effect:

- If you need live events such as `MESSAGE_CREATE`, choose `gateway`.
- If Discord should call your web app for slash commands or buttons, choose `interactions`.
- If you want a simple interaction router, choose `AppFramework`.
- If Discord should send application event notifications, choose Webhook Events parsing.
- If you only need setup/admin HTTP calls, choose core/default plus `RestClient`.
- If you need cache-backed reads while handling Gateway events, add `cache`.
- If you need wait-for-next-message / wait-for-next-click flows, add `collectors`.
- If one Gateway connection is not enough, add `sharding`.
- If you need voice state, voice handshake, decrypted Opus frames, or PCM decode, add `voice`.
- If you need PCM-to-Opus playback, add `voice-encode`.
- If you need DAVE/MLS receive or outbound media hooks, add `voice` plus `dave`, then run the live gate before making interoperability claims.

## Feature Flags With Cause/Effect

- default/core:
  - Adds typed models, builders, parsers, helpers, `RestClient`, response builders, OAuth2 helpers, Webhook Event parsing, and Components V2 builders.
  - Choose this for REST-only tools, command registration, typed model work, message builders, OAuth2 flows, and parsing helpers.
- `gateway`:
  - Adds `Client`, `Context`, typed `Event`, Gateway websocket handling, `EventHandler`, Gateway URL/config helpers, and Gateway command helpers.
  - Choose this when your bot reacts to Discord in real time.
- `interactions`:
  - Adds Ed25519 request verification, raw and typed interactions endpoints, `TypedInteractionHandler`, and `AppFramework`.
  - Choose this when Discord calls your HTTP server.
- `cache`:
  - Enables in-memory cache storage and cache policy tuning.
  - Choose this when manager reads should use gateway-populated state.
- `collectors`:
  - Adds collectors for message, component, modal, and interaction flows.
  - Choose this when the bot waits for the next matching user action.
- `sharding`:
  - Adds shard config, supervisor, status, control messages, and shard lifecycle helpers.
  - Choose this for large bots or tests around multi-shard control.
- `voice`:
  - Adds voice state management, voice Gateway commands, voice runtime, raw UDP receive, RTP parsing, transport decrypt/encrypt, Opus-frame send, Opus PCM decode, and DAVE frame types.
  - Choose this for voice state, joining channels, receiving/playing Opus, or audio diagnostics.
- `voice-encode`:
  - Adds `PcmFrame`, `AudioSource`, `AudioMixer`, and `VoiceOpusEncoder` for 48 kHz stereo 20 ms PCM-to-Opus playback.
  - Choose this when feeding PCM into voice playback.
- `dave`:
  - Adds experimental DAVE/MLS receive and outbound media hooks, `VoiceDaveySession`, and `VoiceDaveFrameEncryptor`.
  - Choose this only when the task explicitly needs DAVE frame parsing, decryptor/encryptor integration, MLS gateway command payloads, or live validation.

## Runtime Relationship Map

### Gateway Path

`Client::builder(token, intents)`
-> `.event_handler(handler)`
-> `.start()`
-> `EventHandler::handle_event(ctx, event)`
-> match on typed `Event`
-> use `ctx.rest()`, helpers, cache managers, shard helpers, or voice helpers

Meaning:

- `Client` starts and owns the Gateway runtime.
- `Event` is typed incoming data from Discord.
- `Context` bridges Gateway events to outgoing REST, cache, shard, and voice actions.
- `raw_event` is for unknown/untyped Gateway events, not the default path.

### HTTP Interactions Path

Beginner router:

`AppFramework::builder()`
-> `.command(...)`, `.component(...)`, `.modal(...)`
-> optional `.guard(...)`, `.cooldown(...)`, `.fallback(...)`
-> `.build()`
-> pass to `try_typed_interactions_endpoint(public_key, app)`

Lower-level handler:

`try_typed_interactions_endpoint(public_key, handler)`
-> typed `Interaction`
-> return `InteractionResponse`

Meaning:

- `AppFramework` is best for simple named routes, guards, cooldowns, and fallback behavior.
- `TypedInteractionHandler` is best for custom routing, middleware, dynamic dispatch, or nonstandard behavior.
- `try_interactions_endpoint()` is raw and should be used only when the task needs raw payload preservation.
- `InteractionContextData` carries ids, token, application id, user/member context, and reply metadata.

### Webhook Events Path

HTTP request
-> verify Discord Ed25519 signature
-> `parse_webhook_event_payload(body_json)`
-> inspect `WebhookPayloadType`
-> match `WebhookEvent`

Meaning:

- Webhook Events are Discord application Events URL payloads.
- They are not Gateway events.
- They are not the same as executing an incoming webhook.
- Unknown event types are preserved as `WebhookEvent::Unknown`.

### REST-Only Path

`RestClient::new(token, application_id)` or `Client::builder(...).rest_only()`
-> call typed HTTP methods such as `create_global_command(...)`, `get_guild_with_query(...)`, `create_message(...)`, `create_lobby(...)`

Meaning:

- This is the smallest surface when no live runtime is needed.
- It is the safest choice for setup scripts, migration jobs, admin tools, and HTTP-only integrations.
- Prefer typed methods. Old raw convenience methods such as `send_message(...)` as `RestClient` methods are not the public path.
- HTTP failures should surface as `DiscordError::Api` or `DiscordError::RateLimit`.

### Voice Path

Gateway bot
-> `ctx.join_voice(guild_id, channel_id, self_mute, self_deaf)`
-> capture `VOICE_STATE_UPDATE` and `VOICE_SERVER_UPDATE`
-> `connect_voice_runtime(...)`
-> send/receive Opus frames or decode PCM
-> optionally apply `VoiceDaveFrameDecryptor` / `VoiceDaveySession` for DAVE

Meaning:

- Voice setup depends on both Gateway voice state and voice server update data.
- Voice credentials are short-lived.
- DAVE claims need the ignored live test, not just default unit tests.

## Major API Families In 2.0.0

Use this list to pick public entry points before searching source.

If an exact method or type name is missing from memory, do not guess. Use this discovery order:

1. `src/lib.rs` for public re-exports and feature gates.
2. `USAGE.md`, `README.md`, and `discordrsdocs/docs/api/*.md` for intended examples.
3. `src/http.rs`, `src/http/paths.rs`, and `src/http/tests.rs` for REST methods, route builders, auth mode, and request/response expectations.
4. `src/model.rs` for public data shapes and Discord object fields.
5. `src/event.rs` for Gateway receive events and decoding behavior.
6. `src/framework.rs`, `src/interactions.rs`, and `src/parsers/interaction.rs` for AppFramework, typed interactions, and parsing behavior.
7. `src/webhook_events.rs` for Webhook Events payloads.
8. `src/voice.rs`, `src/voice_runtime.rs`, and `tests/live_voice_dave.rs` for voice, Opus, DAVE, and live-gate behavior.
9. `cargo doc --all-features --no-deps --locked` when you need a generated public API index.

### Builders And Components V2

- `MessageBuilder`, `InteractionResponseBuilder`
- `ActionRowBuilder`, `ButtonBuilder`, `SelectMenuBuilder`, `TextInputBuilder`, `ModalBuilder`
- Components V2: `ComponentsV2Message`, `ContainerBuilder`, `SectionBuilder`, `TextDisplayBuilder`, `MediaGalleryBuilder`, `FileBuilder`, `ThumbnailBuilder`, `SeparatorBuilder`
- Newer controls: `CheckboxBuilder`, `CheckboxGroupBuilder`, `RadioGroupBuilder`, `FileUploadBuilder`, `LabelBuilder`
- Select defaults: `SelectDefaultValue`
- Modal parsing: `V2ModalSubmission`, `V2ModalComponent`, `get_file_values()`

### Commands And Interactions

- Command builders: `SlashCommandBuilder`, `UserCommandBuilder`, `MessageCommandBuilder`, `PrimaryEntryPointCommandBuilder`, `CommandOptionBuilder`
- Typed interactions: `Interaction`, `ChatInputCommandInteraction`, `AutocompleteInteraction`, `ComponentInteraction`, `ModalSubmitInteraction`, context menu variants
- Typed input: `CommandInteractionData`, `CommandInteractionOption`
- Interaction server: `InteractionHandler`, `TypedInteractionHandler`, `try_typed_interactions_endpoint(...)`, `typed_interactions_endpoint(...)`
- Beginner router: `AppFramework`, `AppFrameworkBuilder`, `AppContext`, `RouteKey`
- Helpers: `respond_with_message`, `respond_with_container`, `respond_with_components_v2`, `respond_with_modal`, `respond_with_autocomplete_choices`, `defer_interaction`, `followup_message`, `edit_original_response`, `delete_original_response`

### Webhook Events

- Parser: `parse_webhook_event_payload(...)`
- Types: `WebhookEventPayload`, `WebhookPayloadType`, `WebhookEvent`, `WebhookEventBody`
- Event families: application authorized/deauthorized, entitlement create/update/delete, quest enrollment, lobby message create/update/delete, game direct message create/update/delete
- Unknown future events: `WebhookEvent::Unknown`

### REST And HTTP

- Client: `RestClient`
- Compatibility alias: `DiscordHttpClient`
- Uploads: `FileUpload`, `FileAttachment`
- Typed message helpers: create/update/delete/get/list pins, message search, channel pin routes
- Webhook execution/message helpers, including Slack/GitHub-compatible execution helpers
- Interaction callback/follow-up/original-response helpers
- Route safety: tokenized paths validate path segments; query strings are percent-encoded
- Rate limits: route/global rate-limit tracking and bounded 429 retry behavior

### Guild, Channel, Member, Role, Admin

- Guild fetch/query: `GetGuildQuery`, `get_guild_with_query(...)`
- Member list/search: `GuildMembersQuery`, `SearchGuildMembersQuery`
- Bans/prune: `GuildBansQuery`, `CreateGuildBan`, `BulkGuildBanRequest`, `BeginGuildPruneRequest`
- Guild edits: `ModifyGuild`, `CreateGuildChannel`, `ModifyGuildMember`, `ModifyCurrentMember`
- Roles: `CreateGuildRole`, `ModifyGuildRole`, `ModifyGuildRolePosition`, member-count reads
- Incidents: `GuildIncidentsData`, `ModifyGuildIncidentActions`
- Widgets/welcome/onboarding/templates: `GuildWidget*`, `WelcomeScreen*`, `GuildOnboarding`, `GuildTemplate`
- Stage/stickers: `CreateStageInstance`, `ModifyStageInstance`, `CreateGuildSticker`, `ModifyGuildSticker`, `StickerPackList`

### Applications, OAuth2, Commands Permissions

- Current app: `ModifyCurrentApplication`
- Activity lookup: `ActivityInstance`
- Install params/config: `ApplicationInstallParams`, `ApplicationIntegrationTypeConfig`
- OAuth2 client: `OAuth2Client`, `OAuth2AuthorizationRequest`, `OAuth2CodeExchange`, `OAuth2RefreshToken`, `OAuth2TokenResponse`
- Current user: `CurrentUserGuildsQuery`, `UserConnection`, `UserApplicationRoleConnection`
- Command permissions: `ApplicationCommandPermission`, `GuildApplicationCommandPermissions`, `EditApplicationCommandPermissions`
- Some command-permission and current-user routes require OAuth2 Bearer authorization, not bot authorization.

### Lobby And Social SDK

- Models: `Lobby`, `LobbyMember`, `CreateLobby`, `ModifyLobby`, `AddLobbyMember`, `LobbyMemberUpdate`, `LinkLobbyChannel`
- Bot-authorized helpers: create/get/modify/delete lobby, member add/remove/bulk update, moderation metadata
- Bearer-authorized helpers: current user leave lobby and link/unlink lobby channel
- Use Lobby for matchmaking/Social SDK style integrations, not for ordinary Discord text channels.

### Monetization, Polls, Soundboard, Invites

- Monetization: `Sku`, `Entitlement`, `Subscription`, query helpers, entitlement/SKU/subscription routes
- Polls: `CreatePoll`, `Poll`, `PollAnswer`, answer voters, end poll, vote events
- Soundboard: `SoundboardSound`, `SoundboardSoundList`, default/guild soundboard helpers, Gateway soundboard events
- Invites: invite get/delete/options, create channel invite, target-user CSV helpers, job status models, multipart `target_users_file` flow

### Gateway Events And Commands

- Event decoder: `decode_event(...)`
- Primary enum: `Event`
- Gateway send helpers cover identify, resume, heartbeat, request-guild-members, request-soundboard-sounds, request-channel-info, voice-state, and presence command payloads.
- Newer receive coverage includes `CHANNEL_INFO`, `RATE_LIMITED`, richer reaction payload fields, and richer `PRESENCE_UPDATE` metadata.
- Keep unknown events and flexible metadata safe rather than panicking.

### Cache, Collectors, Sharding

- Cache: `CacheConfig`, `CacheHandle`, `GuildManager`, `ChannelManager`, `MemberManager`, `MessageManager`, `RoleManager`, `UserManager`
- Cache buckets include users, guild metadata, channels, members, roles, messages, emoji, stickers, voice states, presences, threads, webhooks, scheduled events, AutoMod rules, invites, integrations, soundboard sounds, and monetization entities where enabled by policy.
- Collectors: `CollectorHub`, `MessageCollector`, `ComponentCollector`, `ModalCollector`, `InteractionCollector`
- Sharding: `ShardConfig`, `ShardInfo`, `ShardRuntimeState`, `ShardRuntimeStatus`, `ShardIpcMessage`, `ShardMessenger`, `ShardSupervisor`, `ShardSupervisorEvent`

### Voice, Opus, DAVE

- Voice state/commands: `VoiceManager`, `VoiceConnectionState`, `VoiceGatewayCommand`, `VoiceSpeakingCommand`, `VoiceSelectProtocolCommand`
- Runtime: `connect_voice_runtime(...)`, `VoiceRuntimeConfig`, `VoiceRuntimeHandle`, `VoiceRuntimeState`
- Receive: `recv_raw_udp_packet(...)`, `recv_voice_packet(...)`, `VoiceReceivedPacket`, `VoiceRawUdpPacket`
- RTP/crypto: `VoiceRtpHeader`, `VoiceEncryptionMode`, AES-GCM and XChaCha RTP-size support
- Decode: `VoiceOpusDecoder::discord_default()`
- Encode/playback with `voice-encode`: `PcmFrame`, `AudioSource`, `AudioMixer`, `VoiceOpusEncoder`, `AudioPlayer`, `AudioTrack`
- DAVE with `dave`: `VoiceDaveFrame`, `VoiceDaveState`, `VoiceDaveFrameDecryptor`, `VoiceDaveFrameEncryptor`, `VoiceDaveySession`, `VoiceDaveyDecryptor`

## Common Workflows

### 1. Minimal Typed Gateway Bot

```rust
use async_trait::async_trait;
use discordrs::{gateway_intents, Client, Context, DiscordError, Event, EventHandler};

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

Use this when the bot needs a persistent Gateway connection.

### 2. Register Slash Commands Without Gateway

```rust
use discordrs::{DiscordError, RestClient, SlashCommandBuilder};

async fn register(http: &RestClient) -> Result<(), DiscordError> {
    let command = SlashCommandBuilder::new("ping", "Reply with pong").build();
    http.create_global_command(&command).await?;
    Ok(())
}
```

Use this for setup, migration, and admin tools.

### 3. AppFramework HTTP Interactions App

```rust
use discordrs::{AppFramework, InteractionResponse, RouteKey};

let app = AppFramework::builder()
    .guard(|ctx| ctx.user_id().is_some())
    .command("ping", |_ctx| async move {
        InteractionResponse::ChannelMessage(serde_json::json!({
            "content": "pong"
        }))
    })
    .component("refresh", |_ctx| async move {
        InteractionResponse::DeferredUpdateMessage
    })
    .cooldown(RouteKey::Command("ping".to_string()), std::time::Duration::from_secs(3))
    .build();
```

Pass `app` to `try_typed_interactions_endpoint(public_key, app)` when wiring your HTTP server.

### 4. Lower-Level Typed Interactions Endpoint

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

Use this when custom routing is more important than beginner convenience.

### 5. Parse Webhook Events

```rust
use discordrs::{parse_webhook_event_payload, WebhookEvent, WebhookPayloadType};

let payload = parse_webhook_event_payload(body_json)?;

if payload.kind == WebhookPayloadType::PING {
    // Acknowledge Discord's URL verification probe with HTTP 204.
}

if let Some(body) = payload.event {
    match body.event {
        WebhookEvent::ApplicationAuthorized(data) => {
            println!("authorized scopes: {:?}", data.scopes);
        }
        WebhookEvent::EntitlementCreate(entitlement) => {
            println!("entitlement {}", entitlement.id);
        }
        WebhookEvent::LobbyMessageCreate(message) => {
            println!("lobby message {}", message.id);
        }
        WebhookEvent::Unknown { kind, data } => {
            println!("new event {kind}: {data:?}");
        }
        _ => {}
    }
}
```

Always verify the Discord signature before trusting the body.

### 6. Use Lobby Helpers

```rust
use discordrs::{CreateLobby, LobbyMember, Snowflake};

let lobby = rest
    .create_lobby(&CreateLobby {
        members: Some(vec![LobbyMember {
            id: Snowflake::from("123456789012345678"),
            ..LobbyMember::default()
        }]),
        idle_timeout_seconds: Some(300),
        ..CreateLobby::default()
    })
    .await?;
```

Use bot-token helpers for normal lobby CRUD. Use Bearer-token helpers for current-user lobby routes.

### 7. Read Cache-Aware Managers

```rust
async fn inspect_cache(ctx: &discordrs::Context) {
    let guilds = ctx.guilds().list_cached().await;
    println!("cached guilds: {}", guilds.len());
}
```

Manager shortcuts can exist without useful cached data. `list_cached()` and `cached(...)` become meaningful after `gateway + cache` sees relevant events.

### 8. Reply To Gateway Interactions

- Match `Event::InteractionCreate(interaction)` in `handle_event(...)`.
- Use `respond_with_message(...)`, `followup_message(...)`, `defer_interaction(...)`, or `update_interaction_message(...)`.
- If the client has no application id, use explicit application-id follow-up helpers where required.
- Do not attach bot auth to token-authenticated interaction callback/follow-up routes.

### 9. Voice Receive And Decode

- Join voice from a Gateway bot with `Context::join_voice(...)`.
- Use the resulting voice state/server update data with `connect_voice_runtime(...)`.
- Use `recv_voice_packet(...)` for transport-decrypted Opus frames.
- Use `VoiceOpusDecoder::discord_default()` to decode Opus to 48 kHz stereo interleaved `i16` PCM.
- Use `voice-encode` only when feeding PCM into playback.

### 10. Live DAVE Validation

The release gate is ignored by default and requires live voice credentials:

```powershell
$env:DISCORD_TOKEN="bot-token"
$env:DISCORDRS_CAPTURE_GUILD_ID="123456789012345678"
$env:DISCORDRS_CAPTURE_CHANNEL_ID="345678901234567890"
cargo run --all-features --example live_dave_capture_bot
```

Keep the capture bot running and use the printed env block:

```powershell
cargo test --all-features --test live_voice_dave -- --ignored --nocapture
```

Required variables:

- `DISCORDRS_LIVE_VOICE_SERVER_ID`
- `DISCORDRS_LIVE_VOICE_USER_ID`
- `DISCORDRS_LIVE_VOICE_SESSION_ID`
- `DISCORDRS_LIVE_VOICE_TOKEN`
- `DISCORDRS_LIVE_VOICE_ENDPOINT`
- `DISCORDRS_LIVE_VOICE_CHANNEL_ID`

Treat `DISCORDRS_LIVE_VOICE_TOKEN` as secret and short-lived.

## Compatibility Aliases And Migration Notes

- `BotClient` is still available, but use `Client` in new examples.
- `DiscordHttpClient` is still available, but use `RestClient` in new examples.
- Legacy `EventHandler` convenience callbacks still exist, but `handle_event(...)` is canonical.
- `ready`, `message_create`, `interaction_create`, and other convenience hooks receive typed payloads.
- Builder implementation submodules are private. Use crate-root re-exports or `discordrs::builders::{...}`.
- `ApplicationCommand` no longer implements `DiscordModel`; use `id_opt()` and `created_at()`.
- `CommandInteractionData.options` uses `CommandInteractionOption`, not command-definition options.
- Common replacements:
  - old `RestClient::send_message(...)` -> helper `send_message(...)` or `RestClient::create_message(...)`
  - old `RestClient::edit_message(...)` -> `RestClient::update_message(...)`
  - old `RestClient::create_dm_channel(...)` -> `RestClient::create_dm_channel_typed(...)`
  - old `RestClient::create_interaction_response(...)` -> `RestClient::create_interaction_response_typed(...)`
  - old `RestClient::bulk_overwrite_global_commands(...)` -> `RestClient::bulk_overwrite_global_commands_typed(...)`
  - raw interaction routing -> typed `Interaction` or `AppFramework`

## 2.0.0 Release Notes For Agents

- Added `AppFramework` for typed HTTP interaction routing across commands, components, and modals.
- Added typed Webhook Events parsing for application authorization, entitlement, lobby message, and game DM event families.
- Added typed Activity Instance models and REST helper.
- Added application command permission models and helpers, including OAuth2 Bearer-token writes for Discord's permission edit route.
- Added current-user OAuth2 connection and application role connection models and helpers.
- Added current-user guild pagination/count support through `CurrentUserGuildsQuery`.
- Added Lobby resource models and REST helpers for lobby CRUD, members, channel linking, and moderation metadata.
- Added guild incident-action models and the `PUT /guilds/{guild.id}/incident-actions` helper.
- Added typed audit log resource models and `after` cursor query support.
- Added optional guild count fetch, ban pagination, member pagination, member search, role member counts, widget reads/images, and current member nick edits.
- Added typed guild channel-position, OAuth2 guild-member join, role reorder, guild/channel/member/role/stage/sticker/welcome/onboarding request bodies.
- Added typed voice REST helpers for current-user and user voice-state reads/writes.
- Added current-application edit models and helper.
- Added typed Webhook Resource request bodies, query-aware webhook execution/message helpers, Slack/GitHub-compatible execution helpers, and validation.
- Expanded monetization, message, member, channel, reaction, presence, Activity, invite, command-permission, allowed-mentions, and reaction-count models.
- Added legacy route aliases and final missing wrappers to close the official route-shape audit at 223/223.
- Added Gateway opcode 43 channel-info requests, typed `CHANNEL_INFO`, typed `RATE_LIMITED`, richer reaction dispatches, and richer `PRESENCE_UPDATE`.
- Kept release coverage above the 90% gate with regression coverage for new REST, Gateway, event, AppFramework, webhook-event, lobby, and model surfaces.

## Current API Coverage Boundary

`223 / 223` means every official REST route shape in the audited Discord docs snapshot mapped to a `RestClient` wrapper, helper path, or tokenized interaction/webhook helper.

It does not mean:

- every undocumented Discord rollout is modeled,
- every object field has live integration coverage,
- every route permutation has been manually hit against Discord,
- every Social SDK behavior is semantically verified,
- future Discord docs cannot drift.

Use the broad claim carefully:

- REST route shapes are represented.
- Gateway send and receive event names are represented.
- Official non-example object headings are represented or intentionally dynamic.
- Major interactions, webhook, voice, DAVE, cache, collectors, components, OAuth2, lobbies, monetization, soundboard, stickers, stage, invites, polls, subscriptions, entitlements, templates, and admin surfaces have typed wrappers or models where Discord documents them.

## Pitfalls

- Do not start with cache/collectors/sharding/voice. Start with the primary runtime.
- Do not document cache managers as if `cache` creates the access pattern; it enables storage.
- Do not use `raw_event` as the happy path.
- Do not use raw interaction routing unless unknown payload preservation is required.
- Do not treat Webhook Events as Gateway dispatches.
- Do not treat incoming webhook execution helpers as Webhook Events parsing.
- Do not handwrite button/select/modal JSON if builders model the payload.
- Do not recommend removed raw REST convenience methods in new code or docs.
- Do not import from private builder paths such as `discordrs::builders::modal::*`.
- Do not prefix Gateway Identify/Resume tokens with `Bot `.
- Do not parse typed slash/autocomplete input into command-definition models when `value` or `focused` matters.
- Do not assume follow-up helpers work without an application id unless using explicit application-id variants.
- Do not attach bot `Authorization` headers to token-authenticated webhook or interaction routes.
- Do not bypass tokenized webhook/callback path validation.
- Do not make cache defaults unbounded without an explicit operator decision.
- Do not derive `Debug` on OAuth2 secret-bearing types.
- Do not describe default `voice` as full DAVE support.
- Do not claim live DAVE/MLS support without running the ignored live test.
- Treat `MESSAGE_UPDATE` as partial.
- Do not use `ready.data.application.id` as a guild cache key.
- Treat Gateway event handling as ordered work.
- Treat voice disconnects and endpoint loss as state reset events.
- Treat OAuth2 Bearer and bot-token routes as different authorization modes.
- Treat route coverage numbers as snapshot evidence, not future-proof guarantees.

## Verification Commands

Standard public-surface verification:

```powershell
cargo fmt --all -- --check
cargo check --all-features --all-targets --locked
cargo test --all-features --locked --no-fail-fast
cargo clippy --all-features --all-targets --locked -- -D warnings
```

Docs and release verification:

```powershell
$env:RUSTDOCFLAGS='-D warnings'; cargo doc --all-features --no-deps --locked
cargo package --locked
cargo llvm-cov --all-features --locked --summary-only
```

Focused checks:

- Gateway/cache: `cargo test --features "gateway cache" --lib gateway::bot::tests`
- HTTP: `cargo test --lib http::tests`
- HTTP hardening: check auth-header behavior and tokenized callback/webhook path validation tests.
- Interactions parsing: prove option `value` and `focused` survive the typed parser.
- AppFramework: prove command/component/modal/fallback routing, guard denial, and cooldown behavior.
- Webhook Events: prove known event parsing and unknown event preservation.
- Voice: prove RTP, encryption/decryption, Opus decode/encode, DAVE state, and outbound command payloads.
- Live DAVE: `cargo test --all-features --test live_voice_dave -- --ignored --nocapture` with live env vars.

## Coverage Patterns

- Builders, bitfields, models, parsers, and event decode helpers: direct unit tests.
- REST wrappers: local TCP HTTP harness recording method, path, headers, query, and body.
- Tokenized routes: validation-before-network tests.
- Gateway client: local websocket harnesses with scripted `HELLO`, `READY`, `INVALID_SESSION`, `RECONNECT`, heartbeat, compressed frames, and close frames.
- AppFramework: pure handler tests that assert route key, context extraction, guard, cooldown, and fallback behavior.
- Webhook Events: tiny valid JSON payloads plus unknown event preservation.
- Cache/collectors/sharding: prefill state, apply one event or command, assert exact mutation and nearby no-op behavior.
- Voice runtime: hermetic RTP/crypto/Opus/DAVE tests before live tests.
- Coverage-driven work: use `cargo llvm-cov --all-features --summary-only` and target real uncovered source, not generated or artificial tests.

## Documentation Sync Checklist

When public behavior changes, check all of these:

- `Cargo.toml` version and feature flags
- `README.md`
- `USAGE.md`
- `CHANGELOG.md`
- `discordrsdocs/README.md`
- `discordrsdocs/_sidebar.md`
- `discordrsdocs/docs/api/*.md`
- `discordrsdocs/docs/guide/*.md`
- `discordrsdocs/ko/*.md` when the changed guidance is user-facing
- examples under `examples/`
- installed skill at `C:\Users\B360M-PC\.codex\skills\discordrs-dev`
- skill repository at `C:\Users\B360M-PC\Documents\guthab\discordrs-skill`

Skill repository and installed skill must stay byte-identical for `SKILL.md`, `agents/openai.yaml`, and this reference file.
