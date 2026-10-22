# discord.rs 3.1.0 API overview

Package and import name `discordrs`, brand "discord.rs". Version 3.1.0 (crates.io 2026-10-22, tag `v3.1.0`;
additive over 3.0.0 of 2026-10-18, tag `v3.0.0`). MSRV 1.88 (all features), edition 2021,
MIT OR Apache-2.0. Docs: <https://docs.rs/discordrs/3.1.0>; guide site in the repo under
`discordrsdocs/` (English) and `discordrsdocs/ko/` (Korean).

## Features

| Feature | Adds | Implies |
|---|---|---|
| `cache` (default) | in-memory `CacheHandle` storage; without it the cache API exists but stores nothing | |
| `gateway` | `Client`, `ClientBuilder`, `Context`, `EventHandler`, websocket runtime | |
| `collectors` | `CollectorHub`, message/update/component/modal/interaction/reaction collectors | `gateway` |
| `sharding` | `ShardingManager`, `ShardSupervisor`, multi-process `sharding::process` | `gateway` |
| `zstd-stream` | zstd transport compression for the gateway | `gateway` |
| `interactions` | axum 0.8 HTTP interactions endpoint, `AppFramework`, Ed25519 verification | |
| `voice` | voice gateway/UDP runtime, transport crypto, DAVE end-to-end encryption (`davey`/OpenMLS, since 3.1.0), Opus decode, `AudioPlayer` API | |
| `voice-encode` | PCM → Opus encoding (`AudioPlayer::play` needs it) | `voice` |
| `dave` | alias of `voice` since 3.1.0 (kept so `["voice", "dave"]` builds; was the opt-in DAVE feature in 3.0.0) | `voice` |

Always available without features: models, `request` bodies, builders, `RestClient`, command
builders, parsers (`decode_interaction`), permissions, formatters, webhook-event parsing, OAuth2.

```toml
[dependencies]
discordrs = { version = "3", features = ["gateway"] }        # gateway bot (+ default cache)
# discordrs = { version = "3.1", features = ["gateway", "voice", "voice-encode"] } # music bot
# discordrs = { version = "3", features = ["interactions"] } # HTTP interactions endpoint
# discordrs = "3"                                            # REST-only tool
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

## Module map

| Path | Holds |
|---|---|
| crate root | the common types (see `src/lib.rs` re-exports); prefer these paths |
| `prelude` | builders, command builders, `Client`/`Context`/`EventHandler`, `RestClient`, `InteractionResponder`, `MessageBuilder`, many models and request bodies, discriminants, `GuildId`/`ChannelId`/`UserId`/`RoleId`/`MessageId`/`ApplicationId`/`InvalidId`. Not in it: `Channel`, `Guild`, `Member`, `User`, `EventKind`, `Patch`, `Nullable`, `GenericId`; import those from the root |
| `model` | received Discord objects, typed IDs (`model::Id`), open discriminants (`model::discriminant`), `Patch`/`Nullable`, gateway-only payloads (`GuildCreate`, `GuildCreatePayload`, `GuildUpdate`, `MemberUpdate`, `MessageUpdate`, `PartialUser`, `Presence`) |
| `request` | everything you send (note: root `discordrs::Embed` is the *received* `model::Embed`; outgoing is `request::Embed`, which `EmbedBuilder` builds): REST bodies, `CreateMessage`, `EditMessage`, `ExecuteWebhook`, `InteractionMessage`, `InteractionResponse`, `EndpointReply`, components, `Modal`, `Embed`, `CreatePoll`, `ComponentEmbed` |
| `builders` | fluent builders that produce `request` types |
| `http` | `RestClient`, `RestClientBuilder`, `RawRequest`, `FileAttachment` |
| `event` | `Event`, `EventKind`, `EventMetadata`, `decode_event`, per-dispatch payloads |
| `gateway` | runtime (`Client`, `Context`, `ShardSupervisor`, `CacheBackendHealth`) |
| `cache` | `CacheHandle`, `CacheConfig`, `CacheBackend`, `CacheClear`, `CacheClearId`, managers |
| `collector` | collectors, `CollectorEndReason`, `EmojiKey` |
| `interactions`, `framework` | HTTP endpoint, `AppFramework` |
| `response` | `InteractionResponder`, `InteractionResponsePhase`, `MessageBuilder` |
| `parsers` | `decode_interaction`, `parse_interaction`, modal submission parsing |
| `permissions` | effective permission computation |
| `formatters` | mentions, timestamps, markdown, `escape_markdown`, `clean_content` |
| `command` | slash/user/message/entry-point builders, `command::limits` |
| `bitfield` | `Permissions`, `MessageFlags`, `ChannelFlags`, `Intents`, flag constant modules |
| `voice`, `voice::player`, `voice_runtime` | voice state, playback pipeline, UDP runtime and its DAVE session |
| `sharding`, `sharding::process` | in-process and multi-process sharding |
| `webhook_events` | Discord Webhook Events (Events URL) payloads |
| `oauth2` | `OAuth2Client`, authorization URLs, token exchange |
| `helpers` | stateless id/token helpers and Components V2 send helpers |
| `model_ext` | discord.js-style inherent methods (`message.reply(&rest, ..)`, `member.kick(..)`) |

## Typed IDs

`Id<M>` is 8 bytes, `Copy`, never zero, parsed strictly from Discord's decimal strings, and typed
per resource: `GuildId`, `ChannelId`, `UserId`, `RoleId`, `MessageId`, `ApplicationId`, `EmojiId`,
`WebhookId`, `CommandId`, `SkuId`, `AttachmentId`, `InteractionId`, … Passing a `ChannelId` where a
`GuildId` is expected does not compile. There is no `Default` and no infallible `From<u64>` /
`From<&str>`: use `FromStr` (`"…".parse()`), `TryFrom<&str>`, or `TryFrom<u64>`, which reject zero,
signs, whitespace, and overflow.

```rust
// features: default
use discordrs::{ChannelId, DiscordError, GuildId, RoleId, UserId};

// Parse untrusted text once, at the boundary: "0", " 1", "+1", "1.0" are rejected.
fn parse_ids(guild: &str, channel: u64) -> Result<(GuildId, ChannelId), DiscordError> {
    let guild_id: GuildId = guild.parse()?;
    let channel_id = ChannelId::try_from(channel)?; // InvalidId converts into DiscordError
    Ok((guild_id, channel_id))
}

// IDs are Copy: pass by value, no clone, no `&`.
fn describe(guild_id: GuildId, user_id: UserId) -> String {
    let everyone: RoleId = guild_id.everyone_role();
    // Display writes the decimal string; get() is the u64; timestamp() is the creation time in ms.
    format!("{user_id} (raw {}) in {guild_id}, @everyone = {everyone}", user_id.get())
}
```

- `GenericId` only where Discord leaves the kind open: audit-log `target_id`, scheduled-event
  `entity_id`, `CommandInteractionData::target_id`, `Unknown` variants. The prelude does not
  export it.
- Polymorphic fields are enums with the same JSON as before: `OverwriteTarget::{Role, Member,
  Unknown}` (permission overwrites), `CommandPermissionTarget` (with `Everyone` / `AllChannels`
  sentinels), `CommandPermissionsId::{Command, Application}`, `EntitlementOwner`,
  `SelectDefaultValue`, `MentionableId`.
- Wire values that look like IDs but are not snowflakes have their own types: `WidgetUserId`,
  `GuildInstallOwner` (`"0"` = `BotDm`), `UploadId` (attachment upload slots), `ComponentId`
  (component `id`, may be 0), `PollAnswerId`.
- Cache keys are typed tuples: members/presences/voice states `(GuildId, UserId)`, messages
  `(ChannelId, MessageId)`, roles `(GuildId, RoleId)`.
- `RestClient::new(token, Option<ApplicationId>)`; `DiscordModel::id()` returns
  `Id<Self::Marker>`.

```rust
// features: default
use discordrs::model::{OverwriteTarget, PermissionOverwrite};
use discordrs::DiscordError;

fn overwrite_owner(json: &str) -> Result<String, DiscordError> {
    let overwrite: PermissionOverwrite = serde_json::from_str(json)?;
    Ok(match overwrite.target {
        OverwriteTarget::Role(role_id) => format!("role {role_id}"),
        OverwriteTarget::Member(user_id) => format!("member {user_id}"),
        OverwriteTarget::Unknown { kind, id } => format!("type {kind:?} for {id}"),
    })
}
```

## Open discriminants

Every Discord integer enumeration is an open newtype with named constants (`ChannelType`,
`MessageType`, `ComponentType`, `ButtonStyle`, `InteractionType`, `InteractionResponseType`,
`CommandType`, `CommandOptionType`, `ActivityType`, `AuditLogActionType`, `TextInputStyle`,
`SeparatorSpacing`, …; canonical home `model::discriminant`, re-exported from `model` and the
root). Unknown values round-trip unchanged (`Debug` prints `Unknown(250)`), values wider than the
storage fail to decode, there is no `Default`, and no `.0` or tuple construction. Matching needs
a `_` arm.

```rust
// features: default
use discordrs::{Channel, ChannelType, MessageType};

fn describe(channel: &Channel) -> &'static str {
    match channel.kind {
        ChannelType::GUILD_TEXT | ChannelType::GUILD_ANNOUNCEMENT => "text",
        kind if kind.is_thread() => "thread",
        kind if kind.is_voice_based() => "voice",
        _ => "other", // the set is open: always keep a `_` arm
    }
}

fn raw_numbers() -> (u8, bool) {
    let kind = ChannelType::new(0); // raw number in
    let future = MessageType::new(250); // unknown values are kept, not rejected
    (kind.get(), future == MessageType::new(250)) // raw number out
}
```

- A missing required discriminant (component `type`, activity `type`, poll `layout_type`, …) is
  a decode error. Types with a required discriminant have constructors instead of `Default`:
  `Activity::new`, `MessageComponent::new`, `ApplicationCommandOption::new`,
  `EditChannelPermission::for_target`, `GuildMfaLevel::new`.
- `ApplicationCommand::kind` is `Option<CommandType>`; `command_type()` applies Discord's
  `CHAT_INPUT` default.
- Exception: `MessageComponent::style` stays `Option<u8>` because its meaning depends on the
  component type; read it with `button_style()` / `text_input_style()`.
- `PresenceStatus` is the string vocabulary (`ONLINE`, `DND`, `IDLE`, `INVISIBLE`, `OFFLINE`;
  unknown strings kept; compares with `&str`).

## Patch and Nullable

`Patch<T>` is `Missing | Value(T)`, `Nullable<T>` is `Null | Value(T)`, and
`NullablePatch<T> = Patch<Nullable<T>>`. The 3.0-era modify bodies use them with `new()` and
setters, where `clear_*` sends `null` (`ModifyChannel`, `EditMessage`, `EditWebhookMessage`,
`UpdateMessage`, `ModifyAutoModerationRule`, `ModifyGuildScheduledEvent`, `ModifyGuildEmoji`, …).
Create bodies use `Option` (`None` omits). Partial gateway updates (`MessageUpdate`,
`MemberUpdate`, `GuildUpdate`) use them too, with `apply_to(&mut full)`.

```rust
// features: default
use discordrs::model::MessageUpdate;
use discordrs::request::ModifyChannel;
use discordrs::{Message, Nullable, Patch};

fn rename_and_clear_topic() -> Result<String, serde_json::Error> {
    // Omitted fields are not sent; clear_* sends an explicit null.
    let body = ModifyChannel::new().name("announcements").clear_topic();
    serde_json::to_string(&body) // {"name":"announcements","topic":null}
}

fn apply_edit(message: &mut Message, update: &MessageUpdate) {
    if let Patch::Value(content) = &update.content {
        println!("new content: {content}");
    }
    if let Patch::Value(Nullable::Null) = &update.edited_timestamp {
        println!("edited_timestamp was cleared");
    }
    update.apply_to(message); // omitted fields keep their value
}
```

Declaring your own patch field needs `#[serde(default, skip_serializing_if = "Patch::is_missing")]`.
The 49 bodies that moved from `model` to `request` (`ModifyGuild`, `ModifyGuildMember`,
`ModifyGuildRole`, `CreateGuildRole`, `CreateGuildChannel`, `ModifyWebhook`, …) are different: plain
structs with public fields and `Default`, no `new()` or setters; nullable fields are
`Option<Option<T>>` (`Some(None)` sends `null`). Build them as struct literals with
`..Default::default()` (example in `rest-requests-builders.md`).

## Bitfields, permissions, intents

- One permission type: `Permissions` (`BitField<PermissionFlags>`), serialized as a decimal string.
  Message, channel, and user flags, intents, and capabilities serialize as numbers.
  `add`/`remove`/`merge`/`missing` return a new set and are `#[must_use]`; use `|`, `|=`, `-`.
  `contains`/`add`/`remove` take raw `u64` bits (`perms.contains(permissions::X.bits())`).
- Constants: `bitfield::permissions::*` (bits 41–52 follow Discord's table: `SEND_POLLS` = 49,
  `USE_EXTERNAL_APPS` = 50, `PIN_MESSAGES` = 51, `BYPASS_SLOWMODE` = 52),
  `bitfield::message_flags::*` (`SUPPRESS_NOTIFICATIONS` = 1<<12, `IS_VOICE_MESSAGE` = 1<<13,
  `HAS_SNAPSHOT` = 1<<14, `IS_COMPONENTS_V2` = 1<<15), `bitfield::channel_flags::CHANNEL_OBFUSCATED`,
  `bitfield::gateway_capabilities::CHANNEL_OBFUSCATION`.
- Intents: `gateway_intents::*` (`GUILDS`, `GUILD_MESSAGES`, `GUILD_MESSAGE_REACTIONS`,
  `GUILD_VOICE_STATES`, `DIRECT_MESSAGES`, `GUILD_EXPRESSIONS`, `GUILD_MESSAGE_POLLS`, …,
  `NON_PRIVILEGED`). Privileged ones must also be enabled in the Developer Portal:
  `GUILD_MEMBERS`, `GUILD_PRESENCES`, `MESSAGE_CONTENT` (`gateway_intents::PRIVILEGED`). Without
  `MESSAGE_CONTENT`, `message.content` is empty except in DMs, mentions, and the bot's own messages.

```rust
// features: default
use discordrs::bitfield::{message_flags, permissions};
use discordrs::{MessageFlags, Permissions};

fn permission_sets() -> Result<(), serde_json::Error> {
    let mut perms: Permissions = permissions::VIEW_CHANNEL | permissions::SEND_MESSAGES;
    perms |= permissions::EMBED_LINKS;
    perms = perms - permissions::SEND_MESSAGES; // `remove` returns the new set
    assert!(perms.contains(permissions::VIEW_CHANNEL.bits()));
    assert_eq!(serde_json::to_string(&perms)?, r#""17408""#); // permissions: string
    let flags: MessageFlags = message_flags::SUPPRESS_NOTIFICATIONS;
    assert_eq!(serde_json::to_string(&flags)?, "4096"); // other flags: number
    Ok(())
}
```

## Effective permissions

`discordrs::permissions` follows Discord's documented algorithm (owner, `ADMINISTRATOR` bypass,
`@everyone` → roles → member overwrites, timeouts keep only `VIEW_CHANNEL | READ_MESSAGE_HISTORY`,
threads use the parent's overwrites, implicit `VIEW_CHANNEL`/`SEND_MESSAGES`/`CONNECT` rules).
Entry points: `permissions_for(guild, member, channel, parent, now)`, `guild_permissions`,
`Channel::permissions_for`, `Member::guild_permissions`, and the cache versions
`cached_permissions_for` / `cached_guild_permissions`. Missing or contradictory data is a typed
`PermissionDataError` (converts into `DiscordError::Model`); an obfuscated channel gives
`ChannelPermissions::Obfuscated`, so `has()` returns `Option<bool>` (`None` = unknown).
`ComputedPermissions::raw` is the discord.js-equivalent overwrite-only value. Private-thread
membership and archived/locked state are not permission bits: check them separately.

```rust
// features: default
use std::time::SystemTime;

use discordrs::bitfield::permissions;
use discordrs::model::{Channel, Guild, Member};
use discordrs::permissions::{permissions_for, PermissionDataError};

/// Whether the member holds the send bit (not "can send": private threads need membership).
fn has_send_permission(
    guild: &Guild,
    member: &Member,
    channel: &Channel,
    parent: Option<&Channel>,
) -> Result<Option<bool>, PermissionDataError> {
    let result = permissions_for(guild, member, channel, parent, SystemTime::now())?;
    let needed = if channel.is_thread() {
        permissions::SEND_MESSAGES_IN_THREADS
    } else {
        permissions::SEND_MESSAGES
    };
    Ok(result.has(needed)) // None: the channel is obfuscated
}
```

## Formatters

`discordrs::formatters` matches `@discordjs/formatters`: `user_mention`, `role_mention`,
`channel_mention`, `slash_command_mention`, `custom_emoji`, `timestamp(secs).style(..)` with
`TimestampStyle`, `bold`/`italic`/`code_block_with_language`/`heading`/`subtext`/`hyperlink`,
lists, `escape_markdown(text, EscapeMarkdownOptions)`, `clean_code_block_content`, and
`clean_content(text, &resolver)` with a `MentionResolver` (typed IDs) or a
`Fn(MentionTarget) -> Option<String>` closure. Also `Member::mention()` and
`Message::clean_content(...)`.

```rust
// features: default
use discordrs::formatters::{bold, timestamp, user_mention};
use discordrs::{TimestampStyle, UserId};

fn welcome(user_id: UserId, joined_unix: i64) -> String {
    format!(
        "{} joined {}",
        bold(user_mention(user_id)),
        timestamp(joined_unix).style(TimestampStyle::RelativeTime)
    )
}
```

## Webhook Events (Events URL)

Discord's Webhook Events are signed HTTP POSTs to the app's Events URL (not gateway dispatches
and not incoming webhooks). Verify with `verify_discord_signature(public_key, signature,
timestamp, body)` (needs `interactions`), then parse; a payload whose `kind` is `PING` is
Discord's URL check and gets 204 No Content.

```rust
// features: default
use discordrs::{parse_webhook_event_payload, DiscordError, WebhookEvent, WebhookPayloadType};

fn handle_webhook_event(body: &str) -> Result<(), DiscordError> {
    let payload = parse_webhook_event_payload(serde_json::from_str(body)?)?;
    if payload.kind == WebhookPayloadType::PING {
        return Ok(()); // respond 204 No Content
    }
    if let Some(event) = payload.event {
        match event.event {
            WebhookEvent::ApplicationAuthorized(data) => println!("authorized by {}", data.user.username),
            WebhookEvent::EntitlementCreate(entitlement) => println!("entitlement {}", entitlement.id),
            WebhookEvent::Unknown { kind, .. } => println!("unhandled {kind}"),
            _ => {}
        }
    }
    Ok(())
}
```

## Errors

`DiscordError` variants: `Api` (Discord error JSON: status, code, message), `Http(HttpError)`
(`is_timeout`, `is_connect`, `is_body`, `is_retryable`), `RateLimit`, `Json`, `Io`, `Model`
(local validation and decode problems), `Gateway` (terminal close codes 4004/4010–4014, queue
overflow), `Voice`, `Cache`, `IncompleteMemberFetch`. Tokens are scrubbed from `Api`, `Http`,
`RateLimit`, and logs. `discordrs::Error`, `types::Error`, `error::BoxError` were removed.

## Finding the right function

1. Crate-root re-exports in `src/lib.rs` (or docs.rs) are the intended public names.
2. REST route → method: `src/http/routes.rs` lists every route as
   `Id: METHOD "/path/{x}" auth, query [...], body Req => Resp, api [methods]`. It covers all 234
   method+path routes documented in discord-api-docs `3714862`, plus crate-only rows (OAuth2
   token URLs). Search the Discord path there, then use the listed method.
3. Gateway dispatch → variant: `src/event/decode.rs` (`"EVENT_NAME" =>` arms) and `EventKind`.
4. 2.x name → 3.0 name: `references/migration-2x-to-3.md`; full REST rename table in
   `discordrsdocs/docs/api/http-and-helpers.md` ("Migrating REST Names from 2.x").
5. Search by concept: `rg -n "lobby|soundboard|voice_state" src/http src/request src/model`.
6. Local rustdoc: `cargo doc --all-features --no-deps --open`.
