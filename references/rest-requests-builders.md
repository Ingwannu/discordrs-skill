# REST, request bodies, and builders (discord.rs 3.1.0)

No feature needed. Source: `src/http.rs` (transport), `src/http/<domain>.rs` (endpoints),
`src/http/routes.rs` (route manifest), `src/request/` (bodies), `src/builders/`. Docs:
`discordrsdocs/docs/api/http-and-helpers.md`, `builders.md`.

## `RestClient`

- `RestClient::new(token, Option<ApplicationId>)`; `RestClient::builder(token, app_id)` for
  `api_version`, `connect_timeout`, `request_timeout`, `user_agent`, `proxy`, `use_client`,
  `rate_limit_callback`, `default_allowed_mentions`, `retry_non_idempotent_requests`.
  Application-scoped routes fail until the app id is known (`set_application_id`; the gateway
  sets it from READY). `Client::builder(..).rest_only()` also gives an `Arc<RestClient>`.
- `Clone` is cheap; clones share rate-limit state, the connection pool, and the app id.
- `rest.with_reason("spam")` returns a scoped clone that sends `X-Audit-Log-Reason`.
- One canonical method per Discord route: it takes the route's concrete request type and returns
  the typed model. No public domain method takes `serde_json::Value` except Slack/GitHub-compatible
  webhooks and lobby moderation metadata. 35 old names (`*_typed`, `*_from_request`, `*_config`, …)
  are `#[deprecated]` forwards: use the canonical name the warning gives.
- Find a route's method in `src/http/routes.rs`:
  `GetGuild: GET "/guilds/{guild.id}" bot, query [with_counts], body () => Guild, api [get_guild, get_guild_with_query];`
- `discordrs::model_ext` adds discord.js-style methods: `message.reply(&rest, ..)`, `react`,
  `forward_to`, `start_thread`; `member.kick`, `ban`, `timeout`, `add_role`; `channel.send`;
  `user.dm`; CDN URL helpers.

```rust
// features: default
use discordrs::request::{AvailableForumTag, CreateMessage, ModifyChannel};
use discordrs::{
    AllowedMentions, ApplicationId, ChannelId, DiscordError, FileAttachment, GuildId, RestClient,
    UserId,
};

fn client(token: String, app: Option<ApplicationId>) -> Result<RestClient, DiscordError> {
    RestClient::builder(token, app)
        .user_agent("my-bot/1.0")
        // Injected into every message body that leaves allowed_mentions unset.
        // `AllowedMentions::default()` serializes as `{}`: Discord parses no mentions.
        .default_allowed_mentions(AllowedMentions::default())
        .build()
}

async fn rest_calls(rest: &RestClient, guild_id: GuildId, channel_id: ChannelId, user_id: UserId) -> Result<(), DiscordError> {
    let channel = rest
        .update_channel(channel_id, &ModifyChannel::new().name("general").clear_topic())
        .await?;
    // Forum tags: keep existing ones by id, create new ones by name; omitted tags are deleted.
    let mut tags: Vec<AvailableForumTag> = channel
        .available_tags
        .iter()
        .flatten()
        .map(AvailableForumTag::from)
        .collect();
    tags.push(AvailableForumTag::new("bug"));
    rest.update_channel(channel_id, &ModifyChannel::new().available_tags(tags)).await?;

    // `enforce_nonce` makes the create safe to replay after a lost response (60 s window).
    let message = rest
        .create_message(channel_id, &CreateMessage::new().content("hello").enforce_nonce("order-42"))
        .await?;
    rest.create_message_with_files(
        channel_id,
        &CreateMessage::new().content("report attached").reply_to(message.id),
        &[FileAttachment::new("report.txt", b"all good".to_vec())],
    )
    .await?;
    rest.with_reason("spam").remove_guild_member(guild_id, user_id).await?;
    let emojis = rest.get_guild_emojis(guild_id).await?; // Vec<Emoji>
    println!("{} emojis", emojis.len());
    Ok(())
}
```

## Request bodies (`discordrs::request`)

| Type | Endpoint | Notes |
|---|---|---|
| `CreateMessage` | `create_message(_with_files)` | create; reply (`reply_to`), stickers, `nonce` / `enforce_nonce`, poll |
| `EditMessage` | `edit_message(_with_files)` | patch; `clear_*`; `clear_stickers()` / `clear_poll()` for the V2 switch |
| `ExecuteWebhook` | `execute_webhook(webhook_id, token, &body)` → `Message` (sends `wait=true`) | username, avatar, thread name, tags |
| `EditWebhookMessage` (= `EditInteractionResponse`) | webhook / `@original` edits | patch; list every kept attachment |
| `InteractionMessage`, `UpdateMessage`, `CreateFollowup` | interaction callbacks and follow-ups | see `interactions.md` |
| `ModifyChannel`, `StartThreadFromMessage`, `StartThreadWithoutMessage`, `StartForumThread` + `ForumThreadMessage` | channels and threads | `available_tags: Vec<AvailableForumTag>` |
| `CreateGuildChannel`, `ModifyGuild`, `ModifyGuildMember` (→ returns `Member`), `CreateGuildRole`, `ModifyGuildRole`, `CreateWebhook`, `ModifyWebhook`, … | guild admin | the 49 bodies moved from `model` (old `model::X` paths are deprecated aliases): struct literals with public fields, `Option<Option<T>>` for nullable fields, no setters |
| `CreateAutoModerationRule`, `CreateGuildScheduledEvent`, `CreateGuildEmoji`, `EditApplicationCommand`, … | other domains | |
| `InteractionResponse`, `EndpointReply`, `Modal` | interactions | |
| `Component` tree, `Embed`, `CreatePoll`, `MessageAttachment::{Existing, Upload}`, `RawComponent` | message parts | |
| `ComponentEmbed` | website link previews | not sent by a bot |

- Create bodies use `Option` (`None` omits). The 3.0-era modify bodies (`ModifyChannel`,
  `EditMessage`, `EditWebhookMessage`, `ModifyAutoModerationRule`, …) use `Patch`/`NullablePatch`
  with `new()` and setters, where `clear_*` sends `null`. The moved admin bodies are struct
  literals (see below).
- `validate()` exists on the message, component, modal, embed, poll, and interaction-response
  types (and a few others such as `UpdateApplicationIdentityProfile`); builders have
  `try_build()`. REST methods do not validate message content for you: call `validate()` /
  `try_build()` before sending user-built content.
- Interaction-shaped bodies convert from `CreateMessage` with `TryFrom`, which fails on channel-only
  fields (`message_reference`, `sticker_ids`, `nonce`, `shared_client_theme`) instead of dropping them.
- Never hand-write JSON for a route that has a request type.

```rust
// features: default
use discordrs::request::{CreateGuildRole, ModifyGuildMember};
use discordrs::{DiscordError, GuildId, Permissions, RestClient, RoleId, UserId};

async fn moderate(rest: &RestClient, guild_id: GuildId, user_id: UserId, muted: RoleId) -> Result<(), DiscordError> {
    // Moved admin bodies: struct literals; Some(None) sends null, None omits the key.
    let member = rest
        .with_reason("cleanup")
        .modify_guild_member(
            guild_id,
            user_id,
            &ModifyGuildMember { nick: Some(None), roles: Some(Some(vec![muted])), ..Default::default() },
        )
        .await?; // returns the updated Member
    let role = rest
        .create_guild_role(
            guild_id,
            &CreateGuildRole { name: Some("helpers".into()), permissions: Some(Permissions::from_bits(0)), ..Default::default() },
        )
        .await?;
    println!("{:?} now has {} roles; new role {}", member.nick, member.roles.len(), role.id);
    Ok(())
}
```

## Raw requests

For a route the crate does not wrap (or an experiment), use the same transport:

```rust
// features: default
use discordrs::{ChannelId, DiscordError, GuildId, RawRequest, RestClient};
use serde_json::{json, Value};

async fn raw_calls(rest: &RestClient, guild_id: GuildId, channel_id: ChannelId) -> Result<(), DiscordError> {
    let preview: Value = rest.request(RawRequest::get(format!("/guilds/{guild_id}/preview"))).await?;
    let created: Value = rest
        .request(RawRequest::post(format!("/channels/{channel_id}/messages")).json(&json!({ "content": "hi" })))
        .await?;
    // request_discard never decodes the body: a mutation Discord applied is not reported as failed.
    rest.request_discard(RawRequest::delete(format!("/channels/{channel_id}/messages/{}", created["id"].as_str().unwrap_or_default())))
        .await?;
    println!("{preview}");
    Ok(())
}
```

Raw POST/PATCH are never replayed after an ambiguous failure (even with a nonce) unless
`retry_non_idempotent_requests(true)`. The `Authorization` header follows the path (bot token,
none on `/webhooks/{id}/{token}…` and `/interactions/…`) unless `bearer(..)` /
`without_authorization()` choose. `Debug` prints only the method and the token-redacted path.

## Retries, rate limits, tokens

- 5xx, timeouts, and failed response reads are ambiguous, so they are retried only for GET, HEAD,
  OPTIONS, PUT, DELETE, and Create Message with `nonce` + `enforce_nonce: true` within 60 s of the
  first attempt. Other POST/PATCH surface the error instead of risking a duplicate.
  `RestClientBuilder::retry_non_idempotent_requests(true)` opts back in.
- 429s are always retried (up to 5 times, then `DiscordError::RateLimit`); retryable 5xx and
  transport failures up to 3 times with 0.5 s / 1 s / 2 s backoff. Malformed `Retry-After`
  values are clamped. Default timeouts: connect 10 s, request 30 s.
- The managed transport (`new`, `builder().build()`) follows no redirects, so a connect failure
  proves nothing was sent and is retried for every method. With `use_client(..)` it is not.
- Buckets: the learned `x-ratelimit-bucket` hash is scoped by the route's major parameter
  (channel, guild, webhook, interaction token); requests are serialized per bucket.
- Global limits: interaction-token routes (callback, `@original` get/edit/delete, follow-up
  create/get/edit/delete) are not held by the bot's global 429, so a bot-token request's global
  429 no longer delays `defer()`. They still wait for their own bucket and for the separate
  per-IP global deadline shared by all requests without an `Authorization` header (interaction
  and webhook token routes, public routes). Webhook-token routes and raw requests also honour the
  bot global.
- `rate_limit_callback` gets `RateLimitInfo { route, retry_after, global }`; `route` never holds a token.
- Webhook and interaction tokens are scrubbed from errors, rate-limit info, logs, and `Debug`.

## Default `allowed_mentions`

`RestClientBuilder::default_allowed_mentions` / `ClientBuilder::default_allowed_mentions` fill
`allowed_mentions` only where a body leaves it unset: `create_message*`, `edit_message*`,
`execute_webhook*`, `edit_webhook_message*`, the first message of `create_forum_thread`, the
Components V2 channel helpers (`send_container_message`, `send_to_channel`, `send_components_v2`,
`edit_message_with_container`), interaction message callbacks (types 4 and 7, not `Raw`),
follow-ups, and `@original`/follow-up edits. An explicit value (or explicit `null` on an edit)
wins. With no default configured, Discord's own default applies (mentions in content ping).
**Inline HTTP-endpoint replies** (`EndpointReply::Inline`) never use the `RestClient` default:
set it on the endpoint too with `InteractionsEndpointBuilder::default_allowed_mentions` (3.1.0;
same rule: types 4 and 7 only, an explicit value wins, `Raw` is sent as written), or set
`allowed_mentions` on each inline message. On 3.0.0 only the per-message route exists.

## Message builders and Components V2

`MessageBuilder::build()` returns `request::CreateMessage` (no `serde_json::Value` anywhere);
`try_build()` validates, `build()` never does. It converts into `InteractionMessage` and
`CreateFollowup`, and fallibly into `UpdateMessage` / `EditInteractionResponse`.

- Buttons: `CustomButtonBuilder::new(custom_id)` (primary/secondary/success/danger),
  `LinkButtonBuilder::new(url)` (no `custom_id` setter), `PremiumButtonBuilder::new(sku_id)` (no
  label/emoji/url). `ButtonBuilder` is deprecated.
- Rows: `ActionRowBuilder` holds 1–5 buttons. A select builder is itself a row:
  `add_action_row(SelectMenuBuilder::role("id"))`. Mixing buttons and a select does not compile.
- Selects: `SelectMenuBuilder::{string, user, role, mentionable, channel}` return per-kind builders
  with only that kind's setters (`add_option`, `default_user`, `default_role`,
  `default_mentionable`, `default_channel`, `channel_types`, `default_values(ids)`).
- Components V2: `ContainerBuilder` (`accent_color`, `spoiler`, `add_text_display`,
  `add_separator`, `add_section`, `add_media_gallery`, `add_file`, `add_action_row`,
  `add_component`), `TextDisplayBuilder`, `SeparatorBuilder` (`divider`, `spacing`),
  `MediaGalleryBuilder` + `MediaGalleryItem`, `FileBuilder` (`attachment://name`),
  `ThumbnailBuilder`. `ComponentsV2Message` collects top-level components;
  `MessageBuilder::components_v2(..)` sets `IS_COMPONENTS_V2`, which forbids content, embeds,
  poll, and stickers in the same message. Turning an existing message into V2 with
  `EditMessage::components_v2(..)` requires clearing what it has in the same edit
  (`clear_content()`, `clear_embeds()`, `clear_stickers()`, `clear_poll()`); the flag cannot be
  removed again.
- Webhooks: `execute_webhook` always sends `wait=true`. To send components through a webhook use
  `execute_webhook_with_query` with `WebhookExecuteQuery { with_components: Some(true), .. }`
  (application-owned webhooks may use interactive components; others only non-interactive ones).
- `SectionBuilder` tracks its required accessory in its type: only
  `SectionBuilder<SectionAccessory>` (after `set_thumbnail_accessory` / `set_button_accessory`)
  can be added.
- Escape hatch: `request::RawComponent::from_json(..)` / `from_value(&json)`, accepted by every
  `add_component`, written verbatim.
- Validation (`validate()` / `try_build()`): content 2,000 chars, 10 embeds / 6,000 chars, ≤ 40
  V2 components, unique `custom_id`/`id`, ≤ 5 legacy rows, select min/max, voice-message rules.
  Limits are named constants citing Discord's docs.

```rust
// features: default
use discordrs::request::CreateMessage;
use discordrs::{
    ActionRowBuilder, ButtonStyle, ComponentsV2Message, ContainerBuilder, CustomButtonBuilder,
    DiscordError, LinkButtonBuilder, MediaGalleryBuilder, MediaGalleryItem, MessageBuilder,
    RoleId, SectionBuilder, SelectMenuBuilder, SelectOption, SeparatorBuilder, TextDisplayBuilder,
    ThumbnailBuilder,
};

fn support_panel(moderators: RoleId) -> Result<CreateMessage, DiscordError> {
    let buttons = ActionRowBuilder::new()
        .add_button(CustomButtonBuilder::new("ticket:open").label("Open").style(ButtonStyle::PRIMARY))
        .add_button(LinkButtonBuilder::new("https://example.com/help").label("Help"));
    // Without set_*_accessory, add_section does not compile.
    let header = SectionBuilder::new()
        .add_text_display(TextDisplayBuilder::new("## Support"))
        .set_thumbnail_accessory(ThumbnailBuilder::new("https://example.com/logo.png"));
    let container = ContainerBuilder::new()
        .accent_color(0x5865F2)
        .add_section(header)
        .add_separator(SeparatorBuilder::new().divider(true))
        .add_media_gallery(MediaGalleryBuilder::new().add_item(MediaGalleryItem::new("https://example.com/status.png")))
        .add_action_row(buttons)
        .add_action_row(SelectMenuBuilder::string("ticket:topic").add_option(SelectOption::new("Billing", "billing")))
        .add_action_row(SelectMenuBuilder::role("ticket:notify").default_role(moderators));
    MessageBuilder::new()
        .components_v2(ComponentsV2Message::new().add_container(container))
        .try_build() // validated request::CreateMessage, ready for rest.create_message
}
```

```rust
// features: default
use discordrs::request::CreatePoll;
use discordrs::{ChannelId, DiscordError, EmbedBuilder, MessageBuilder, RestClient};

async fn status_embed(rest: &RestClient, channel_id: ChannelId) -> Result<(), DiscordError> {
    let embed = EmbedBuilder::new()
        .title("Status")
        .description("All systems nominal")
        .color(0x2ECC71)
        .field("API", "ok", true)
        .timestamp_now()
        .try_build()?;
    let message = MessageBuilder::new().content("Daily report").add_embed(embed).try_build()?;
    rest.create_message(channel_id, &message).await?;
    let poll = CreatePoll::new("Lunch?").add_answer("Pizza").add_answer("Sushi").duration(24);
    rest.create_message(channel_id, &MessageBuilder::new().poll(poll).try_build()?).await?;
    Ok(())
}
```

## Component Embed (website link previews)

`request::ComponentEmbed` builds the `discord:component-embed` document a website serves for its
own Discord link preview (no bot involved). Its restricted model (`PreviewSection`,
`PreviewMediaGallery`, `PreviewActionRow` of `PreviewLinkButton`, …) cannot express custom-ID
buttons, nested containers, or raw JSON. `to_json()` / `to_script_tag()` / `link_tag(href)` emit
HTML/XHTML-safe output; `try_build()`/`validate()` enforce the 3,000-byte, 40-component,
10-gallery-item, and URL rules with a `ComponentEmbedError` naming the path.
`ComponentEmbed::try_from(container_builder)` converts a message container losslessly or fails.

```rust
// features: default
use discordrs::request::{
    ComponentEmbed, PreviewActionRow, PreviewLinkButton, PreviewSection, PreviewThumbnail,
};
use discordrs::DiscordError;

fn preview_tag() -> Result<String, DiscordError> {
    let embed = ComponentEmbed::builder()
        .accent_color(0x1ABC9C)
        .add_component(
            PreviewSection::new(PreviewThumbnail::new("https://example.com/boss.png"))
                .add_text("# New version out!"),
        )
        .add_component(
            PreviewActionRow::new().add_button(PreviewLinkButton::new("https://example.com/store").label("Store")),
        )
        .try_build()?;
    // Server-render into <head>; Discord does not run scripts. Keep the Open Graph tags as fallback.
    Ok(embed.to_script_tag()?)
}
```
