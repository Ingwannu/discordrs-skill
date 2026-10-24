# Migrating discord.rs 2.x → 3.0, 3.0.0 → 3.1.0, and 3.1.x → 3.2.0

The authoritative guide is `discordrsdocs/docs/guide/migration-3.0.md` in the crate repo (Korean:
`discordrsdocs/ko/guide/migration-3.0.md`); every 3.0 snippet in it is compiled by
`tests/migration_guide.rs`. 2.0.2 was the last 2.x on crates.io; 2.1.0/2.2.0 were never published
but lived on `main`. This file is the condensed map; the 3.0-side code is in the other references.

## Order of work

1. `discordrs = "3"`, Rust ≥ 1.88, axum 0.8 if you serve the interactions endpoint; drop
   `async-trait` if nothing else uses it.
2. Delete every `#[async_trait]` on `EventHandler`, `CacheBackend`, `InteractionHandler`,
   `TypedInteractionHandler`, `CachedManager` impls first; a leftover fails with E0195 and hides
   other errors.
3. Fix compile errors by area (table below), then every deprecation warning (each names its
   replacement; all are removed in 4.0), then review the behaviour changes.

## Map

| Area | 2.x | 3.0 |
|---|---|---|
| IDs | `Snowflake` (String + u64), `From<u64>`, `From<&str>`, `&Snowflake` params | `GuildId`/`ChannelId`/`UserId`/… by value; `"…".parse()?`, `X::try_from(u64)?`; `get()`, `Display`; `GenericId` only for open kinds; `Snowflake` = deprecated alias of `GenericId` |
| | `RestClient::new(token, 0)` | `RestClient::new(token, None)` / `Some(app_id)` |
| | `PermissionOverwrite { id, kind }` | `target: OverwriteTarget` |
| | `Default` on `Message`, `User`, `Guild`, … | removed; build from JSON or constructors |
| Discriminants | `u8` fields, constant modules (`button_style::PRIMARY`, `option_type::INTEGER`, `INTERACTION_RESPONSE_*`), closed `ChannelType::Text` | open newtypes: `ButtonStyle::PRIMARY`, `CommandOptionType::INTEGER`, `InteractionResponseType::…`, `ChannelType::GUILD_TEXT`; `new(n)`/`get()`; keep `_` arms |
| | `Activity::default()`, `ActivityType(0)`, `.0` | `Activity::new(kind, name)`, `ActivityType::PLAYING`, `.get()` |
| | `UpdatePresence { activities: vec![Activity { .. }] }`, `ActivityButton` | `vec![BotActivity::new(kind, name)]`; received `Activity::buttons: Option<Vec<String>>` |
| Patches | `Option<Option<T>>`, `json!({"topic": null})` | `request::ModifyChannel::new().clear_topic()`; `Patch`/`Nullable`/`NullablePatch` |
| Events | `handle_event(ctx, Event)`, `match event { Event::Ready(r) => r.data… }` | `handle_event(ctx, Arc<Event>)`, `match event.kind() { EventKind::Ready(r) => r… }` |
| | `event.kind()` (name string) | `event.name()`; `event.metadata()` |
| | raw `Value` on every event | `event.raw()` with `keep_raw_events(true)` |
| | `message_create(ctx, Message)` | `message_create(ctx, Arc<Message>)` |
| | `message_update(ctx, Message)` | `message_update(ctx, Arc<MessageUpdate>)` (partial) |
| | `member_add(ctx, Snowflake, Member)` / `member_update(ctx, Snowflake, Member)` | `member_add(ctx, GuildId, Arc<Member>)` / `member_update(ctx, Arc<MemberUpdate>)` |
| | `guild_create(ctx, Guild)` / `guild_update(ctx, Guild)` | `guild_create(ctx, &GuildCreatePayload)` / `guild_update(ctx, &GuildUpdate)` |
| | `channel_create(ctx, Channel)` | `channel_create(ctx, Arc<Channel>)` |
| | `presence_update(ctx, PresenceUpdateEvent { user_id, status, .. })` | `&PresenceUpdateEvent` with `user_id()`, `status()`, `activities()` |
| | other hooks by value (`ready(ctx, ReadyPayload)`) | by reference (`&ReadyPayload`, `&Interaction`, …) |
| | `raw_event(ctx, String, Value)` for unknown and undecodable | `raw_event(ctx, &str, &RawValue)` (unknown) + `decode_failed(..)` |
| | `decode_event(name, Value)` | `decode_event(name, &str)` |
| Collectors | `MessageCollector` yielded edits too | edits via `MessageUpdateCollector`; `next_event()`; `ctx.*_collector()` replays from the handled event; `CollectorEndReason` non-exhaustive |
| Cache | `upsert_message(Message)`, owned getters, `&Snowflake` keys | `impl Into<Arc<T>>`, `*_arc` getters, typed keys by value; `apply_*_update` never create entries; `Member::user` / `Message::author` are `Option<Arc<User>>` |
| | every READY cleared the whole cache | only the shard's guilds |
| Backends | `Arc<dyn CacheBackend>`, `clear_cache(&self)`, `put_*(T)` | `Arc<B>`, epoch + `CacheClearId` compare-and-set, `clear_shard_cache`, `put_*(epoch, .., Arc<T>)` |
| REST | `update_channel(id, &Value)`, `*_typed` pairs, `B: Serialize` bodies | one method per route with its `request::X` body; 35 old names are deprecated forwards, untyped variants removed |
| | `model::CreateMessage` (JSON components) | `request::CreateMessage::new().content(..)` |
| | `update_message` | `edit_message(.., &request::EditMessage)` |
| | `update_guild` / `create_role` / `update_role` | `modify_guild` / `create_guild_role` / `modify_guild_role` |
| | `execute_webhook(&Value) -> Value` | `execute_webhook(id, token, &request::ExecuteWebhook) -> Message` |
| | `request(Method, &str, Option<&Value>)` | `request::<T>(RawRequest::get(..))`, `request_discard(..)` |
| | `available_tags: Vec<ForumTag>` | `Vec<request::AvailableForumTag>` |
| | `create_interaction_response_typed`, `InteractionCallbackResponse` | `create_interaction_response(id, token, &InteractionResponse)`; `InteractionResponse::Raw` |
| Builders | `ButtonBuilder::new().custom_id(..)` / `.url(..)` | `CustomButtonBuilder::new(id)` / `LinkButtonBuilder::new(url)` / `PremiumButtonBuilder::new(sku)` |
| | `ActionRowBuilder::add_select_menu(menu)` | `add_action_row(menu)` (a select is its own row) |
| | one `SelectMenuBuilder`, `default_value(SelectDefaultValue::role(..))` | per-kind builders, `default_role(role_id)` |
| | `X::build() -> Value`, `add_component(json!(..))` | typed models; `RawComponent::from_value(&json)?` |
| | `SectionBuilder` without accessory compiled | accessory required by the type |
| Interactions | `parse_interaction(&Value)`; option `value: Option<Value>` | `decode_interaction(&str)`; `Option<CommandOptionValue>` |
| | handlers return `interactions::InteractionResponse::{ChannelMessage(json!), DeferredMessage, ..}` | return `EndpointReply`: `InteractionResponse::reply(..)/defer(..)/update(..)/modal(..)/autocomplete(..).into()` or `EndpointReply::Accepted` (only after a REST reply) |
| | `defer_interaction`, `followup_message`, `edit_original_response`, … | `InteractionResponder` methods (`defer`, `follow_up`, `edit_reply`, …) |
| | `interactions_endpoint` (panics) | `try_interactions_endpoint` / `try_typed_interactions_endpoint` |
| | `AppFramework` `command(..)` also got autocomplete | `autocomplete(name, ..)`, `RouteKey::Autocomplete` |
| | text inputs in action rows, `CheckboxBuilder::checked`, `disabled`/`required` on modal choice builders | Label-wrapped `add_text_input`, `default_checked`, removed |
| | `InteractionReplyData`, `From<CreateMessage>` | `request::InteractionMessage`, `TryFrom<CreateMessage>` |
| | entry-point command was `Interaction::Unknown` | `Interaction::PrimaryEntryPoint` |
| Permissions | `PermissionsBitField(bits)`, in-place `remove` | `Permissions`; `set - flag`, `#[must_use]` add/remove |
| Voice | `VoiceFrameSink::send_opus_packet(frame, Duration)` | `(frame, VoiceFrameTiming { duration, gap })`, cancellation contract |
| Sharding | exhaustive `ShardSupervisorEvent` match; `event_tx` fields | add `Lagged`; use `publish` |
| | process IPC bare JSON lines; `serve` returns `()` | `@discordrs-ipc/1 ` frames (deploy parent + children together); `serve` returns `Result`; wire `child.identify_gate()` |
| Errors | `discordrs::Error`, `types::Error`, `error::BoxError` | `DiscordError`; `Box<dyn Error + Send + Sync>` |

## Behaviour changes that still compile

- REST: POST/PATCH are no longer replayed after 5xx/timeouts (except nonce-enforced Create
  Message within 60 s; `RestClientBuilder::retry_non_idempotent_requests(true)` opts back in);
  no redirects; per-channel bucket scoping; tokens redacted.
- Gateway: terminal close codes stop the shard with an error; event-queue overflow stops the
  shard; unavailable GUILD_CREATE is its own variant.
- Interactions: follow-ups and `edit_reply` wait for the initial response; a second initial
  response fails locally; `InteractionResponse::defer(false)` sends
  `{"type":5,"data":{"flags":0}}`; the HTTP endpoint answers 202 when the response went over REST.
- Decoding is stricter (invalid IDs, missing discriminants, duplicate keys are errors).
- Wire values fixed: message flags (`SUPPRESS_NOTIFICATIONS` = 4096), permission bits 41–52,
  checkbox `default`, non-permission bitfields as numbers.
- Default `allowed_mentions` also apply to `edit_webhook_message` and the V2 channel helpers.
- Cache: partial updates never create entries; guild roles follow GUILD_ROLE_* events.
- Voice transport encryption uses Discord's nonce layout (2.x put the counter at the wrong end,
  so real voice servers rejected every packet). Fixed and pinned by known-answer vectors; first
  heard live with 3.1.0's DAVE runtime.

Deprecated in 3.0 (removed in 4.0): `Snowflake`, `PermissionsBitField`,
`MessageSelectDefaultValue`, `ButtonBuilder`, `InteractionReplyData`,
`InteractionResponseBuilder`, `AutocompleteChoice`, `InteractionResponse::PremiumRequired`, 11
interaction helpers, the panicking endpoint constructors, `CheckboxBuilder::checked`,
`ModalBuilder::add_text_input_row`, `batch_edit_application_command_permissions`, `model::X` for
moved request bodies, 35 REST renames, and `create_guild` / `delete_guild` /
`create_guild_from_template` / `modify_guild_mfa_level` (Discord removed guild creation by apps).

## 3.0.0 → 3.1.0

A minor release: nothing breaks (new items, a defaulted trait method, `#[non_exhaustive]` types).
Bump to `discordrs = "3.1"`; `features = ["voice", "dave"]` still builds (`dave` is now an alias,
`voice` includes davey). What to change to benefit:

| Area | 3.0.0 | 3.1.0 |
|---|---|---|
| Voice in DAVE (non-Stage) channels | `connect_voice_runtime` advertised DAVE but ran no MLS: `AudioPlayer` played nothing, plain send/recv errored | `ctx.connect_voice_runtime_with_dave(guild, user)` or `connect_voice_runtime_with_options(config, VoiceConnectOptions::new(channel_id))` run DAVE; `connect_voice_runtime` keeps the old behaviour |
| Playback before keys | sends errored per frame (one warning each) | sends refuse until a media key is in use; `AudioPlayer` waits in `AutoPaused`, then plays from the first frame; `connection_events()` reports `SendFailed`/`Recovered` once per stretch; `VoiceFrameSink::is_playable` |
| `NoSubscriberBehavior::Stop` on a DAVE runtime | n/a | call `handle.wait_until_playable().await` before `play` |
| Receive errors | RTCP and undecryptable packets returned errors (ended `?` loops) | skipped; watch `receive_stats()` and `dave_status().undecryptable_packets` |
| Gateway voice state | the context applied every member's VOICE_STATE_UPDATE; a server update before the state was lost; call `connect_voice` before `join_voice` | only the bot's own state; server update kept in either order; `join_voice` tracks the guild; `ctx.voice_runtime_config(..)` is `Some` when ready |
| 4017 close | "voice websocket closed unexpectedly" | error naming DAVE and the entry point to use |
| DAVE status | — | `dave_status()`, `subscribe_dave_status()`, `is_playable()`, `wait_until_playable()`, `dave_verification_code()` |
| Logging | — | keep `davey` at `info` or coarser (trace logs media keys); install the subscriber before connecting |
| Endpoint mentions | inline replies had no default `allowed_mentions` | `InteractionsEndpointBuilder::default_allowed_mentions(..)` |
| Respond later from `AppFramework` | docs showed spawn + inline `defer` (racy) | defer over REST, spawn, return `EndpointReply::Accepted` |

Do not mix: on a `with_options` runtime, don't drive MLS yourself (`VoiceDaveySession`,
`send_dave_*`); custom frame encryption via `send_opus_frame_with_dave` /
`recv_voice_packet_with_dave` still works.

## 3.1.x → 3.2.0

A minor release: nothing breaks (new types and builder methods; a client without a handoff runs as
in 3.1.1, and a normal shutdown still closes with 1000). Bump to `discordrs = "3.2"`.

| Area | 3.1.x | 3.2.0 |
|---|---|---|
| Restart or update the bot | every new process IDENTIFYs (READY, GUILD_CREATE burst, a session-start each); `select!` drop of `start()` closed without a session | `GatewayHandoff` + `ClientBuilder::handoff` record `GatewaySession`s (close 4000); `ClientBuilder::resume_sessions` RESUMEs them, Discord replays missed events |
| Init on READY | always ran in a new process | a resumed process gets RESUMED only: move command registration and state loading to startup (or `resumed`) |
| Connection setup bound | 15 s only while an IDENTIFY permit was held; a RESUME could wait forever, and a shutdown sent during setup was not read | every connection, default 15 s (`GatewayConnectionConfig::setup_timeout`; `Duration::MAX` = none); shutdown and handoff are served during setup; a setup that runs over retries with 1–300 s backoff |
| Supervisor state after RESUMED | stayed `Reconnecting` | `Running` (and `SessionEstablished` for a handed-off session) |
| READY log line | full session id | first 6 characters |

To adopt handoff, follow the example in [gateway-events-cache.md](gateway-events-cache.md),
"Process handoff (3.2.0)".
