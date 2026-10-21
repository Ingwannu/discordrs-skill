# Gateway, events, collectors, and cache (discord.rs 3.1.0)

Feature `gateway` (plus default `cache`; `collectors` for collectors). Source:
`src/gateway/bot.rs` (builder, `Context`, `EventHandler`), `src/gateway/bot/pipeline.rs`,
`src/event.rs`, `src/cache.rs`, `src/collector.rs`. Docs: `discordrsdocs/docs/api/gateway.md`,
`cache-and-collectors.md`.

## Minimal bot

```rust
// features: gateway
use std::sync::Arc;

use discordrs::{
    gateway_intents, Client, Context, DiscordError, Event, EventHandler, EventKind, Interaction,
    InteractionResponder,
};

struct Handler;

// No #[async_trait]: implement with plain `async fn`. Futures must be Send
// (no Rc, RefCell borrow, or std MutexGuard across .await).
impl EventHandler for Handler {
    async fn handle_event(&self, ctx: Context, event: Arc<Event>) {
        match event.kind() {
            EventKind::Ready(ready) => println!("ready as {}", ready.user.username),
            EventKind::MessageCreate(message) => println!("{}: {}", message.channel_id, message.content),
            EventKind::InteractionCreate(interaction) => {
                if let Interaction::ChatInputCommand(command) = &**interaction {
                    if command.data.name.as_deref() == Some("ping") {
                        if let Err(error) = command.reply_ephemeral(ctx.rest().as_ref(), "pong").await {
                            eprintln!("could not answer /ping: {error}");
                        }
                    }
                }
            }
            EventKind::DecodeFailed(error) => eprintln!("{}: {error}", event.name()),
            _ => {}
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), DiscordError> {
    let token = std::env::var("DISCORD_TOKEN")?; // never hard-code or print the token
    Client::builder(&token, gateway_intents::GUILDS | gateway_intents::GUILD_MESSAGES)
        .event_handler(Handler)
        .start() // returns on a terminal close code (4004, 4010-4014) or fatal error
        .await
}
```

Overriding `handle_event` replaces the default routing to the typed hooks. Either override it
or implement the hooks you need; the trait is not object safe (no `dyn EventHandler`).

## The `Event` envelope

- Handlers, collectors, and the cache share one `Arc<Event>` per dispatch (128 bytes).
- `event.kind()` → `&EventKind`: one variant per documented dispatch, plus `Unknown` (no type in
  this version) and `DecodeFailed(EventDecodeError)` (known dispatch, payload did not match).
- `event.name()` is the dispatch name (`"MESSAGE_CREATE"`); `event.metadata()` has `shard()`,
  `sequence()`, `received_at()`.
- `event.raw()` → `Option<&RawValue>`: kept for known events only with
  `ClientBuilder::keep_raw_events(true)`; always kept for `Unknown` and `DecodeFailed`.
- `decode_event("MESSAGE_CREATE", json_text)` builds an `Event` from fixture text for tests.
- Shared payloads: `MessageCreate(Arc<Message>)`, `MessageUpdate(Arc<MessageUpdate>)`,
  `MemberAdd(MemberEvent { guild_id, member: Arc<Member> })`, `MemberUpdate(Arc<MemberUpdate>)`,
  `ChannelCreate/Update(Arc<Channel>)`,
  `ThreadEvent::thread: Arc<Channel>`, `RoleEvent::role: Arc<Role>`. Clone the `Arc`, never the
  payload, to keep it.
- GUILD_CREATE is `GuildCreatePayload::{Available(Box<GuildCreate>), Unavailable(UnavailableGuild)}`.
  `GuildCreate` holds `guild: Arc<Guild>`, `roles`, `channels`, `threads`, `members`, and
  `presences` as `Vec<Arc<_>>`, and `voice_states`, `emojis`, `stickers`, `stage_instances`,
  `soundboard_sounds`, `guild_scheduled_events` as plain `Vec`s; `to_guild()` rebuilds a
  2.x-style `Guild`.
- Partial updates are typed patches: MESSAGE_UPDATE → `MessageUpdate`, GUILD_MEMBER_UPDATE →
  `MemberUpdate` (full `user`, other fields `Patch`), GUILD_UPDATE → `GuildUpdate` (never carries
  GUILD_CREATE-only fields like `member_count`). Each has `apply_to(&mut full)`.
- PRESENCE_UPDATE → `PresenceUpdateEvent { guild_id, user: Option<PartialUser>, presence: Arc<Presence> }`;
  read `user_id()`, `status()`, `activities()`, `client_status()`. Received `Activity::buttons`
  is `Option<Vec<String>>` (labels only; bots never see button URLs).

## Typed hooks

| Hook | Receives |
|---|---|
| `handle_event` | `Arc<Event>` |
| `ready` | `&ReadyPayload` |
| `message_create` | `Arc<Message>` |
| `message_update` | `Arc<MessageUpdate>` (partial) |
| `member_add` | `GuildId`, `Arc<Member>` |
| `member_update` | `Arc<MemberUpdate>` (partial) |
| `guild_create` | `&GuildCreatePayload` |
| `guild_update` | `&GuildUpdate` (partial) |
| `channel_create`, `channel_update` | `Arc<Channel>` (`channel_delete`: `&Channel`) |
| `presence_update` | `&PresenceUpdateEvent` |
| `guild_members_chunk` | `&GuildMembersChunkPayload` (`members: Vec<Arc<Member>>`) |
| `interaction_create` | `&Interaction` |
| `reaction_add`, … | `&ReactionEvent`, … (references into the event) |
| `raw_event` | `&str` name, `&RawValue` (unknown dispatches only) |
| `decode_failed` | `&str`, `&EventDecodeError`, `&RawValue` |

```rust
// features: gateway
use std::sync::Arc;

use discordrs::model::{GuildCreatePayload, MemberUpdate};
use discordrs::{
    Context, EventDecodeError, EventHandler, GuildId, Member, Nullable, Patch, PresenceUpdateEvent,
};
use serde_json::value::RawValue;

struct Hooks;

impl EventHandler for Hooks {
    async fn guild_create(&self, _ctx: Context, payload: &GuildCreatePayload) {
        match payload {
            GuildCreatePayload::Available(guild) => {
                println!("{}: {} members", guild.guild.name, guild.members.len())
            }
            // An outage: only the id is known; a full GUILD_CREATE follows later.
            GuildCreatePayload::Unavailable(unavailable) => println!("{} unavailable", unavailable.id),
        }
    }

    async fn member_add(&self, _ctx: Context, guild_id: GuildId, member: Arc<Member>) {
        if let Some(user) = &member.user {
            println!("{} joined {guild_id}", user.username); // user: Option<Arc<User>>
        }
    }

    async fn member_update(&self, _ctx: Context, update: Arc<MemberUpdate>) {
        match &update.nick {
            Patch::Value(Nullable::Value(nick)) => println!("{} is now {nick}", update.user_id()),
            Patch::Value(Nullable::Null) => println!("{} cleared their nick", update.user_id()),
            Patch::Missing => {} // this update did not touch the nick
        }
    }

    async fn presence_update(&self, _ctx: Context, event: &PresenceUpdateEvent) {
        println!("{:?} is {:?}", event.user_id(), event.status());
    }

    async fn decode_failed(&self, _ctx: Context, name: &str, error: &EventDecodeError, _data: &RawValue) {
        eprintln!("could not decode {name}: {error}");
    }
}
```

## Runtime pipeline and `ClientBuilder` knobs

Each shard runs an internal processor that applies every event in gateway order (cache, external
backend, voice state, `fetch_members` correlation, collector journal) without waiting for
handlers; handlers run afterwards from bounded lanes. Consequences:

- A handler can `await` `ctx.fetch_members(..)` or a collector in Serial mode without deadlock.
- The cache a handler reads may already contain later events.
- Handler panics are contained and logged.
- `EventDispatchMode::Serial` (default) runs one handler call at a time per shard;
  `Concurrent` runs up to `max_concurrent_handlers` (default 256). In Serial mode a handler that
  awaits a 30 s collector or a slow REST call holds up every other (non-interaction) handler on
  its shard: use `Concurrent`, or create the collector in the handler and `tokio::spawn` the wait.
- Queues are bounded by `event_queue_capacity` (default 10,000). If the gateway → processor queue
  overflows, the shard stops with `DiscordError::Gateway`, its cache is invalidated, and pending
  `fetch_members` fail; a full handler queue drops only the handler delivery.
- INTERACTION_CREATE has its own lane (`interaction_queue_capacity` 256,
  `max_concurrent_interactions` 32, `interaction_admission_timeout` 2 s). Interactions that miss
  admission go to `on_interaction_overload`; the runtime never acknowledges interactions itself.
  `Context::event_received_at()` shows how much of the 3 s window is left.
- `start()` returns after the gateway ends plus at most `handler_shutdown_timeout` (default 5 s);
  remaining handler tasks are aborted and joined.
- READY clears only that shard's guilds from the shared cache (`CacheHandle::clear_shard`).

```rust
// features: gateway
use std::time::Duration;

use discordrs::bitfield::gateway_capabilities;
use discordrs::model::{ActivityType, BotActivity};
use discordrs::{
    gateway_intents, AllowedMentions, CacheConfig, Client, ClientBuilder, EventDispatchMode,
    EventHandler, Interaction, InteractionResponder, UpdatePresence,
};

fn configure<H: EventHandler>(token: &str, handler: H) -> ClientBuilder {
    let mut presence = UpdatePresence::online_with_activity("Handling tickets");
    // Bots may set only name, type, state, url (BotActivity); no buttons.
    presence.activities = vec![BotActivity::new(ActivityType::WATCHING, "the queue")];
    Client::builder(token, gateway_intents::NON_PRIVILEGED | gateway_intents::MESSAGE_CONTENT)
        .event_handler(handler)
        .presence(presence)
        .event_dispatch(EventDispatchMode::Concurrent)
        .max_concurrent_handlers(64)
        .event_queue_capacity(20_000)
        .handler_shutdown_timeout(Duration::from_secs(10))
        .default_allowed_mentions(AllowedMentions::default())
        .cache_config(
            CacheConfig::default()
                .max_guilds(5_000) // default 1,000
                .max_messages_per_channel(100)
                .message_ttl(Duration::from_secs(60 * 60))
                .max_members_per_guild(25_000),
        )
        // Opt in early to channel obfuscation (mandatory for all bots from 2026-11-16).
        .gateway_capabilities(gateway_capabilities::CHANNEL_OBFUSCATION)
        .on_interaction_overload(|overloaded| {
            // Runs on its own thread with the Tokio runtime entered.
            if let Interaction::ChatInputCommand(command) = overloaded.interaction {
                let rest = overloaded.ctx.rest();
                tokio::spawn(async move {
                    if let Err(error) = command.reply_ephemeral(&rest, "Busy, try again.").await {
                        eprintln!("overload reply failed: {error}");
                    }
                });
            }
        })
}
```

## `Context`

- `ctx.rest()` → `Arc<RestClient>` (also the field `ctx.http`); `ctx.cache` → `CacheHandle`;
  managers `ctx.guilds()`, `channels()`, `users()` (`get(id)` = cache then REST, `cached(id)`,
  `contains`, `list_cached()`), `members()` (`get(guild_id, user_id)`, `cached_arc`,
  `list_cached(guild_id)`), `messages()` (`get(channel_id, message_id)`, …), `roles()`
  (`list(guild_id)` over REST, `cached(guild_id, role_id)`; no `get`).
- `ctx.data` (`Arc<RwLock<TypeMap>>`) for app state; `ctx.shard_pair()` → `(shard_id, shard_count)`.
- Gateway commands: `ctx.fetch_members(guild_id, query, limit)` (60 s overall timeout;
  `fetch_members_with_timeout` to change it), `request_guild_members`,
  `update_presence(status)` (status string only; `update_presence_typed(UpdatePresence)` for
  activities), `join_voice`/`leave_voice`, `request_channel_info(..)`. Guild-scoped commands are
  routed to the shard owning the guild when it runs in the same process.
- Voice (`voice` feature): `ctx.join_voice(..)` also tracks the guild's connection;
  `ctx.voice_runtime_config(guild_id, user_id)` is `Some` once the bot's VOICE_STATE_UPDATE and
  the VOICE_SERVER_UPDATE arrived (either order); then
  `ctx.connect_voice_runtime_with_dave(guild_id, user_id)`. Since 3.1.0 the context tracks only
  the bot's own voice state (user from READY); cache and hooks still see every member's. See
  `voice-sharding.md`.
- `ctx.voice()` (`voice` feature) → `Arc<RwLock<VoiceManager>>`; don't hold its write lock across
  `.await`, it stalls the shard's processor.

```rust
// features: gateway
use std::sync::Arc;

use discordrs::{Context, DiscordError, GuildId, Member};

// Needs the privileged GUILD_MEMBERS intent. Returns only when every chunk arrived.
async fn all_members(ctx: &Context, guild_id: GuildId) -> Result<Vec<Arc<Member>>, DiscordError> {
    match ctx.fetch_members(guild_id, None, None).await {
        Ok(members) => Ok(members),
        // Some members did not decode: the rest are here and cached.
        Err(DiscordError::IncompleteMemberFetch(partial)) => {
            eprintln!("{} members could not be decoded", partial.dropped);
            Ok(partial.members)
        }
        Err(error) => Err(error),
    }
}
```

## Collectors (`collectors` feature)

- `ctx.message_collector()`, `message_update_collector()`, `component_collector()`,
  `modal_collector()`, `interaction_collector()`, `reaction_collector(message_id)` start at the
  event being handled and replay what arrived while the handler was queued.
  `ctx.collectors().*` starts "from now".
- `MessageCollector` yields MESSAGE_CREATE only; edits come from `MessageUpdateCollector` as
  partial `MessageUpdate`s.
- `next()` copies the matching item out; `next_event()` returns the shared `Arc<Event>`.
- Controls: `filter`, `timeout`, `idle`, `max_items`, `stop`/`stop_with_reason`, `stop_handle()`,
  `reset_timer`, `end_reason`, `received_count`, `lagged_events`, `collect()`. The `timeout` and
  `idle` windows start at the first `next()`/`next_event()` poll, not at creation. Precedence
  when several are ready: stop, timeout, idle, then events.
- `CollectorEndReason` is `#[non_exhaustive]` (`Limit`, `Time`, `Idle`, `User`, `ChannelDropped`,
  `EmojiLimit`, `UserLimit`, `MessageDelete`, `ChannelDelete`, `ThreadDelete`, `GuildDelete`).
- The runtime's journal keeps the last 256 events (fixed; `CollectorHub::with_capacity` only
  applies to hubs you create yourself); a collector further behind skips ahead and counts the gap
  in `lagged_events()`.
- `ReactionCollector` (discord.js parity): `max_emojis`, `max_users`, `dispose(true)` for
  removals, results as `ReactionCollection` keyed by `EmojiKey::{Custom(id), Unicode(text)}`.

```rust
// features: gateway, collectors
use std::sync::Arc;
use std::time::Duration;

use discordrs::{Context, EventHandler, EventKind, Message};

struct Quiz;

impl EventHandler for Quiz {
    async fn message_create(&self, ctx: Context, message: Arc<Message>) {
        if message.content != "!quiz" {
            return;
        }
        let channel_id = message.channel_id;
        // Create collectors inside the handler: they replay from this event.
        let mut answers = ctx
            .message_collector()
            .filter(move |reply: &Message| reply.channel_id == channel_id)
            .timeout(Duration::from_secs(30));
        let mut edits = ctx.message_update_collector().timeout(Duration::from_secs(30));
        // Wait in a task so a Serial-mode shard keeps running other handlers.
        tokio::spawn(async move {
            if let Some(event) = answers.next_event().await {
                if let EventKind::MessageCreate(answer) = event.kind() {
                    println!("first answer: {}", answer.content);
                }
            }
            if let Some(update) = edits.next().await {
                println!("message {} was edited", update.id);
            }
        });
    }
}
```

```rust
// features: gateway, collectors
use std::time::Duration;

use discordrs::{Context, EmojiKey, Message, UserId};

// Tally ✅ / ❌ reactions on a poll message for 60 s, ignoring the bot's own.
async fn tally(ctx: &Context, poll: &Message, bot_user_id: UserId) -> (usize, usize) {
    let collection = ctx
        .collectors()
        .reaction_collector_for_message(poll)
        .filter(move |reaction| reaction.user_id != Some(bot_user_id))
        .dispose(true)
        .timeout(Duration::from_secs(60))
        .collect()
        .await;
    let count = |emoji: &str| collection.get(&EmojiKey::unicode(emoji)).map_or(0, |r| r.count());
    (count("✅"), count("❌"))
}
```

## Cache

- Default feature `cache`; bounded defaults (`CacheConfig::default()`): `max_guilds` 1,000,
  `max_users` 100,000, `max_members_per_guild` 25,000, `max_total_messages` 10,000,
  `max_messages_per_channel` 100, presences 50,000, member TTL 24 h, presence TTL 10 min, message
  TTL 1 h. A bot in more than 1,000 guilds must raise `max_guilds`, or whole guilds are evicted.
  `CacheConfig::unbounded()` only on purpose. `max_*` caps count the whole store (all guilds) and evict oldest first;
  `max_members_per_guild` / `max_messages_per_channel` are per guild/channel. GUILD_CREATE obeys
  the caps too (emojis, stickers, stage instances, soundboard sounds).
- Entries are `Arc`s shared with events: `upsert_*` take `impl Into<Arc<T>>`; `*_arc` getters
  (`message_arc`, `member_arc`, `user_arc`, `channel_arc`) return the shared `Arc`; owned getters
  clone. Cached objects are never mutated behind a shared `Arc` (copy-on-write).
- Partial updates never create entries: `apply_message_update`, `apply_member_update`,
  `apply_guild_update` return `None` for something not cached. Members and guilds enter through
  GUILD_CREATE, GUILD_MEMBER_ADD, GUILD_MEMBERS_CHUNK, `fetch_members`, or an upsert.
- `guild()`/`guilds()` fill `roles` from the role store (follows GUILD_ROLE_* events).
- A GUILD_CREATE/chunk element that fails to decode is skipped with a `warn!`; existing cached
  entries for it stay as they were.

```rust
// features: default
use std::sync::Arc;

use discordrs::model::{MemberUpdate, MessageUpdate};
use discordrs::{CacheHandle, Message};

async fn track_edit(cache: &CacheHandle, message: Arc<Message>, update: &MessageUpdate) {
    cache.upsert_message(Arc::clone(&message)).await; // stores the Arc, no copy
    if let Some(merged) = cache.apply_message_update(update).await {
        // copy-on-write: `message` still shows the old content
        println!("{:?} -> {:?}", message.content, merged.content);
    }
    let cached = cache.message_arc(message.channel_id, message.id).await; // typed keys by value
    assert!(cached.is_some());
}

async fn apply_member_change(cache: &CacheHandle, update: &MemberUpdate) {
    match cache.apply_member_update(update).await {
        Some(member) => println!("{} now has nick {:?}", update.user_id(), member.nick),
        None => println!("member {} is not cached; updates never create entries", update.user_id()),
    }
}
```

## External cache backends (`CacheBackend`)

- Plain `async fn` methods (RPITIT, futures `Send`); not object safe:
  `ClientBuilder::cache_backend(Arc<B>)` for a concrete `B`.
- One ordered worker per client mirrors member, message, and presence writes; `put_*` receive the
  event's `Arc<T>` snapshot.
- Epoch contract (normative): one epoch per store, starting at 0. `clear_cache(expected_epoch,
  clear_id)` / `clear_shard_cache(expected_epoch, clear_id, shard_id, shard_count)` are
  compare-and-set: on match delete, increment, record `clear_id`, return
  `CacheClear::Applied(new)`; a retry with the last applied `clear_id` returns that same
  `Applied`; otherwise `CacheClear::Rejected(current)`. Every `put_*`/`delete_*` carries its epoch
  and must be ignored (still `Ok(())`) when older than the store's. Make each step atomic
  (a Lua script or `MULTI`/`EXEC` in Redis).
- One writing client per store: not detected at startup, so enforce it in deployment.
- Failed or dropped writes quarantine the shard and resync it; `Context::cache_backend_health()`
  reports `healthy`, `superseded`, `dropped_writes`, `pending_resync_shards`, `last_error`, ….
- MESSAGE_UPDATE / GUILD_MEMBER_UPDATE are merged into the stored copy (`get_*` → merge →
  `put_*`), or skipped when nobody holds a full copy.

`CacheHandle` implements the contract, so delegating to it is a correct starting point:

```rust
// features: gateway
use std::sync::Arc;

use discordrs::cache::{CacheBackend, CacheClear, CacheClearId};
use discordrs::model::Presence;
use discordrs::{
    gateway_intents, CacheHandle, ChannelId, Client, ClientBuilder, DiscordError, GuildId, Member,
    Message, MessageId, UserId,
};

struct LoggingBackend {
    inner: CacheHandle,
}

impl CacheBackend for LoggingBackend {
    async fn clear_cache(&self, expected_epoch: u64, clear_id: CacheClearId) -> Result<CacheClear, DiscordError> {
        self.inner.clear_cache(expected_epoch, clear_id).await
    }
    async fn clear_shard_cache(
        &self,
        expected_epoch: u64,
        clear_id: CacheClearId,
        shard_id: u32,
        shard_count: u32,
    ) -> Result<CacheClear, DiscordError> {
        self.inner.clear_shard_cache(expected_epoch, clear_id, shard_id, shard_count).await
    }
    async fn purge_expired_entries(&self) -> Result<(), DiscordError> {
        self.inner.purge_expired_entries().await
    }
    async fn put_member(&self, epoch: u64, guild_id: GuildId, user_id: UserId, member: Arc<Member>) -> Result<(), DiscordError> {
        self.inner.put_member(epoch, guild_id, user_id, member).await
    }
    async fn get_member(&self, guild_id: GuildId, user_id: UserId) -> Result<Option<Arc<Member>>, DiscordError> {
        self.inner.get_member(guild_id, user_id).await
    }
    async fn list_members(&self, guild_id: GuildId) -> Result<Vec<Arc<Member>>, DiscordError> {
        self.inner.list_members(guild_id).await
    }
    async fn delete_member(&self, epoch: u64, guild_id: GuildId, user_id: UserId) -> Result<(), DiscordError> {
        self.inner.delete_member(epoch, guild_id, user_id).await
    }
    async fn put_message(&self, epoch: u64, message: Arc<Message>) -> Result<(), DiscordError> {
        println!("store message {} at epoch {epoch}", message.id);
        self.inner.put_message(epoch, message).await
    }
    async fn get_message(&self, channel_id: ChannelId, message_id: MessageId) -> Result<Option<Arc<Message>>, DiscordError> {
        self.inner.get_message(channel_id, message_id).await
    }
    async fn list_messages(&self, channel_id: ChannelId) -> Result<Vec<Arc<Message>>, DiscordError> {
        self.inner.list_messages(channel_id).await
    }
    async fn delete_message(&self, epoch: u64, channel_id: ChannelId, message_id: MessageId) -> Result<(), DiscordError> {
        self.inner.delete_message(epoch, channel_id, message_id).await
    }
    async fn put_presence(&self, epoch: u64, guild_id: GuildId, user_id: UserId, presence: Arc<Presence>) -> Result<(), DiscordError> {
        self.inner.put_presence(epoch, guild_id, user_id, presence).await
    }
    async fn get_presence(&self, guild_id: GuildId, user_id: UserId) -> Result<Option<Arc<Presence>>, DiscordError> {
        self.inner.get_presence(guild_id, user_id).await
    }
    async fn list_presences(&self, guild_id: GuildId) -> Result<Vec<Arc<Presence>>, DiscordError> {
        self.inner.list_presences(guild_id).await
    }
    async fn delete_presence(&self, epoch: u64, guild_id: GuildId, user_id: UserId) -> Result<(), DiscordError> {
        self.inner.delete_presence(epoch, guild_id, user_id).await
    }
}

fn with_backend(token: &str) -> ClientBuilder {
    let backend = Arc::new(LoggingBackend { inner: CacheHandle::new() });
    Client::builder(token, gateway_intents::GUILD_MESSAGES).cache_backend(backend)
}
```

## Channel obfuscation (from 2026-11-16)

Channels the bot cannot view arrive with `CHANNEL_OBFUSCATED` (`Channel::is_obfuscated()`); only
`id`, `type`, `position`, `parent_id` are reliable, and overwrites are a synthetic `@everyone`
deny. Detect by the flag, never by name. Permission computation returns
`ChannelPermissions::Obfuscated`. `GET /guilds/{id}/channels` omits such channels.
