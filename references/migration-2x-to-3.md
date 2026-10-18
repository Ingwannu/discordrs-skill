# Migrating discord.rs 2.x → 3.0

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
  so real voice servers rejected every packet). Fixed and pinned by known-answer vectors, not
  live-tested in 3.0.0.

Deprecated in 3.0 (removed in 4.0): `Snowflake`, `PermissionsBitField`,
`MessageSelectDefaultValue`, `ButtonBuilder`, `InteractionReplyData`,
`InteractionResponseBuilder`, `AutocompleteChoice`, `InteractionResponse::PremiumRequired`, 11
interaction helpers, the panicking endpoint constructors, `CheckboxBuilder::checked`,
`ModalBuilder::add_text_input_row`, `batch_edit_application_command_permissions`, `model::X` for
moved request bodies, 35 REST renames, and `create_guild` / `delete_guild` /
`create_guild_from_template` / `modify_guild_mfa_level` (Discord removed guild creation by apps).
