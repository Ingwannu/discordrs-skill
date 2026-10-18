# Interactions, commands, and modals (discord.rs 3.0.0)

Interactions arrive either over the gateway (`EventKind::InteractionCreate`, hook
`interaction_create(ctx, &Interaction)`) or as signed HTTP POSTs to your endpoint (`interactions`
feature: axum 0.8 router, `AppFramework`). Both decode with `decode_interaction(&str)` into the
same `Interaction` and answer with the same `request::InteractionResponse`. Source:
`src/model/interaction.rs`, `src/parsers/`, `src/response.rs`, `src/interactions.rs`,
`src/framework.rs`, `src/command.rs`. Docs: `discordrsdocs/docs/api/interactions-endpoint.md`,
`app-framework.md`, `commands.md`, `parsers.md`.

## The `Interaction` enum

`Ping`, `ChatInputCommand`, `UserContextMenu`, `MessageContextMenu`, `PrimaryEntryPoint`
(Activity entry-point command), `Autocomplete`, `Component`, `ModalSubmit`, and
`Unknown { kind: InteractionType, raw_data: Option<Box<RawValue>>, .. }`.

- Every variant has `context: InteractionContextData` (`id`, `application_id`, `token`,
  `guild_id`, `channel_id`, `user`, `member`, `app_permissions`, `locale`, `context`,
  `authorizing_integration_owners`, …). `Debug` redacts the token; never log the token yourself.
- Commands: `command.data.name: Option<String>`, `command.data.options: Vec<CommandInteractionOption>`
  (`name`, `value: Option<CommandOptionValue>`, nested `options` for subcommands, `focused`),
  `command.data.resolved`. `CommandOptionValue::{String, Integer, Number, Boolean}` with
  `as_str`, `as_i64`, `as_f64`, `as_bool`, `as_id`. In an autocomplete interaction the focused
  option's partial input is always `CommandOptionValue::String`, even for INTEGER/NUMBER options.
- Context menus: `target_id()`, `target_user()` / `target_message()`.
- Components: `component.data.custom_id`, `component_type`, `values`, `resolved()`, and the
  select helpers `component.data.get_users()`, `get_members()`, `get_roles()`, `get_channels()`.
- Modal submits: `submit.submission` (`V2ModalSubmission`): `get_text`, `get_select_values`,
  `get_file_values`, `get_radio_value` (`Option<&str>`, `None` when nothing picked),
  `get_checkbox` (`Option<bool>`); uploaded files via `submit.get_attachments(custom_id)`.
- Received `MessageComponent::value` is `Option<MessageComponentValue>` (`String`/`Bool`/`Other`,
  `value_str()` / `value_bool()`), plus `values` and `default`.

```rust
// features: default
use discordrs::{decode_interaction, DiscordError, Interaction};

fn amount_option(body: &str) -> Result<Option<i64>, DiscordError> {
    let Interaction::ChatInputCommand(command) = decode_interaction(body)? else {
        return Ok(None);
    };
    Ok(command
        .data
        .options
        .iter()
        .find(|option| option.name == "amount")
        .and_then(|option| option.value.as_ref()?.as_i64()))
}

fn ticket_form(body: &str) -> Result<Option<(String, bool)>, DiscordError> {
    let Interaction::ModalSubmit(submit) = decode_interaction(body)? else {
        return Ok(None);
    };
    let form = &submit.submission;
    let subject = form.get_text("subject").unwrap_or_default().to_owned();
    let urgent = form.get_checkbox("urgent").unwrap_or(false); // checkboxes are booleans
    Ok(Some((subject, urgent)))
}
```

## Responses: `InteractionResponse` and `EndpointReply`

`request::InteractionResponse` is one type for the REST callback, the HTTP endpoint, and the
responder: `reply(msg)` (type 4), `defer(ephemeral)` (5), `DeferredUpdateMessage` (6),
`update(UpdateMessage)` (7), `autocomplete(choices)` (8), `modal(modal)` (9), `LaunchActivity`
(12), `Raw(RawInteractionResponse)` for anything else. `PremiumRequired` (10) is deprecated: send
a `PremiumButtonBuilder` instead.

HTTP endpoint handlers, `AppFramework` routes, and guards return `request::EndpointReply`:

| `EndpointReply` | HTTP answer |
|---|---|
| `Inline(response)` (from `response.into()`) | `200` with the callback as the body |
| `Accepted` | `202` with no body: you already answered over REST |

Return `Accepted` only when the initial response goes over REST: after `command.reply(&rest, ..)`
/ `defer(&rest)` succeeded, or when a task you spawned will send it within Discord's 3 s window.
`Accepted` with no REST response leaves the interaction unanswered and Discord shows "This
interaction failed". `EndpointReply` has no `Serialize`, so it cannot be posted as a callback.
Inline responses are encoded **without** the REST client's default `allowed_mentions`: set
`allowed_mentions` on inline messages that echo user input.

## `InteractionResponder` (both transports)

Trait in the prelude, implemented by every respondable variant and by `AppContext`: `reply`,
`reply_ephemeral`, `reply_with_result`, `reply_with_files`, `defer`, `defer_ephemeral`,
`edit_reply`, `fetch_reply`, `delete_reply`, `follow_up`, `follow_up_ephemeral`,
`fetch_follow_up`, `edit_follow_up`, `delete_follow_up`, `show_modal`; plus `defer_update` /
`update_message` on component and modal interactions and `respond_autocomplete` on autocomplete.
`InteractionContextData::create_response(&rest, &InteractionResponse)` sends any other callback.
Futures are `Send`, so calls can move into `tokio::spawn`.

Every parsed interaction owns one shared `InteractionResponseState` (`response_phase()`,
`InteractionResponsePhase`):

| Phase | Initial response | follow-up / edit / delete |
|---|---|---|
| `Unacknowledged` | allowed | fail locally |
| `InFlight` | fails locally | wait for the outcome |
| `Deferred` / `Replied` / `Acknowledged` (Discord holds a response of unknown kind) | fails locally | allowed |
| `Uncertain` (timeout, 5xx, lost read, dropped future) | allowed: a retry is safe (Discord's 40060 settles it) | sent to Discord |

- A 4xx, 429, local validation error, or connect failure rolls back to `Unacknowledged`.
- `is_replied()` / `is_deferred()` / `is_acknowledged()` report only what Discord confirmed.
- The typed HTTP endpoint shares the slot: if the handler answered over REST, the endpoint answers
  202 even if the handler returned an inline response (logged and discarded).
- State is per process. The id/token-only helpers (`respond_with_container`, `respond_with_modal`,
  `followup_with_container`, …) are stateless; don't mix them with responder methods on one
  interaction. 11 old helpers (`defer_interaction`, `followup_message`, `edit_original_response`,
  …) are deprecated in favour of the responder.

```rust
// features: gateway
use discordrs::request::InteractionMessage;
use discordrs::{Context, EventHandler, Interaction, InteractionResponder};

struct Commands;

impl EventHandler for Commands {
    async fn interaction_create(&self, ctx: Context, interaction: &Interaction) {
        let rest = ctx.rest();
        let result = match interaction {
            Interaction::ChatInputCommand(command) if command.data.name.as_deref() == Some("report") => {
                // Defer within 3 s, then edit the original response when the work is done.
                match command.defer_ephemeral(&rest).await {
                    Ok(()) => command.edit_reply(&rest, "report ready").await.map(drop),
                    Err(error) => Err(error),
                }
            }
            Interaction::Component(component) if component.data.custom_id == "ticket:open" => {
                component.reply(&rest, InteractionMessage::new().content("Ticket opened").ephemeral(true)).await
            }
            _ => Ok(()),
        };
        if let Err(error) = result {
            eprintln!("interaction failed: {error}");
        }
    }
}
```

## HTTP interactions endpoint (`interactions` feature)

- `try_typed_interactions_endpoint(public_key_hex, handler)` → `Result<axum::Router>` serving
  `POST /interactions`; `try_interactions_endpoint` for the raw `InteractionHandler`
  (`RawInteraction`, no shared response state). The non-`try_` versions panic on a bad key and
  are deprecated.
- The route verifies the Ed25519 signature (`X-Signature-Ed25519`, `X-Signature-Timestamp`,
  stale/future timestamps rejected), answers PINGs itself, decodes, and calls the handler.
- Body limit 1 MiB per request (`DEFAULT_INTERACTION_BODY_LIMIT`);
  `InteractionsEndpointBuilder::new(key).body_limit(bytes).build_typed(handler)`. A proxy in front
  must allow the same size; bound concurrency there if needed.
- The handler type must be `Clone + Send + Sync + 'static`. Serve with axum 0.8.

```rust
// features: interactions
use discordrs::request::InteractionMessage;
use discordrs::{
    DiscordError, EndpointReply, Interaction, InteractionContextData, InteractionResponder,
    InteractionResponse, InteractionsEndpointBuilder, ModalBuilder, RestClient, TextInputBuilder,
    TextInputStyle, TypedInteractionHandler,
};

#[derive(Clone)]
struct Tickets {
    rest: RestClient,
}

fn ephemeral(text: &str) -> EndpointReply {
    InteractionResponse::reply(InteractionMessage::new().content(text).ephemeral(true)).into()
}

impl TypedInteractionHandler for Tickets {
    async fn handle_typed(&self, _ctx: InteractionContextData, interaction: Interaction) -> EndpointReply {
        match interaction {
            Interaction::ChatInputCommand(command) if command.data.name.as_deref() == Some("ticket") => {
                let modal = ModalBuilder::new("ticket:create", "New ticket")
                    .add_text_input(TextInputBuilder::new("subject", "Subject", TextInputStyle::SHORT));
                InteractionResponse::modal(modal).into()
            }
            Interaction::ChatInputCommand(command) if command.data.name.as_deref() == Some("status") => {
                match command.reply_ephemeral(&self.rest, "All systems go").await {
                    Ok(()) => EndpointReply::Accepted, // answered over REST: 202, no body
                    Err(_) => ephemeral("Status is unavailable right now"),
                }
            }
            Interaction::ModalSubmit(_) => ephemeral("Ticket created"),
            Interaction::Autocomplete(_) => InteractionResponse::autocomplete([]).into(),
            _ => ephemeral("Unknown command"),
        }
    }
}

async fn serve(public_key: &str, rest: RestClient) -> Result<(), DiscordError> {
    let router = InteractionsEndpointBuilder::new(public_key)
        .body_limit(2 * 1024 * 1024)
        .build_typed(Tickets { rest })?;
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    axum::serve(listener, router).await?;
    Ok(())
}
```

## `AppFramework`

`AppFramework::builder()` routes `command(name, ..)` (slash, user, message, entry point),
`autocomplete(name, ..)` (own route `RouteKey::Autocomplete`, no shared cooldown),
`component(custom_id, ..)`, `modal(custom_id, ..)`, `fallback(..)`; plus `guard(..)` returning
`Result<(), EndpointReply>` and `cooldown(RouteKey, Duration)` per user. Routes receive an owned
`AppContext` (`context`, `interaction`, route key, `user_id()`) and return anything
`Into<EndpointReply>`. `AppFramework` is a `TypedInteractionHandler` and cheaply `Clone`.
Autocomplete is always answered with choices: a rejected or unrouted autocomplete gets an empty
list. `component` / `modal` routes match the `custom_id` exactly (no prefixes); unmatched
interactions go to `fallback(..)`, or get an ephemeral "Unknown interaction." by default, so encode
variable data elsewhere or route through `fallback`. `AppContext` implements
`InteractionResponder`. An inline response is recorded only after the route returns, so an
`edit_reply`/`follow_up` that runs before that fails with "interaction has not been
acknowledged"; for background work, defer over REST first and return `EndpointReply::Accepted`
(as in `export` below).

```rust
// features: interactions
use std::time::Duration;

use discordrs::model::ApplicationCommandOptionChoice;
use discordrs::request::InteractionMessage;
use discordrs::{
    try_typed_interactions_endpoint, AppContext, AppFramework, DiscordError, EndpointReply,
    InteractionResponder, InteractionResponse, RestClient, RouteKey,
};

fn app(rest: RestClient) -> AppFramework {
    AppFramework::builder()
        .guard(|ctx: &AppContext| {
            if ctx.context.guild_id.is_some() {
                return Ok(());
            }
            let message = InteractionMessage::new().content("Use this in a server").ephemeral(true);
            Err(EndpointReply::from(InteractionResponse::reply(message)))
        })
        .command("hello", |_ctx: AppContext| async move { InteractionResponse::reply("Hello from discord.rs") })
        .command("export", move |ctx: AppContext| {
            let rest = rest.clone();
            async move {
                // Defer over REST first: the state is Deferred before the task starts.
                if let Err(error) = ctx.defer(&rest).await {
                    eprintln!("defer failed: {error}");
                    return InteractionResponse::reply("Export failed to start").into();
                }
                tokio::spawn(async move {
                    let report = "Export ready"; // the slow work goes here
                    if let Err(error) = ctx.edit_reply(&rest, report).await {
                        eprintln!("export edit failed: {error}");
                    }
                });
                EndpointReply::Accepted // answered over REST: 202, no body
            }
        })
        .autocomplete("search", |_ctx: AppContext| async move {
            InteractionResponse::autocomplete([ApplicationCommandOptionChoice::new("rust", "rust")])
        })
        .cooldown(RouteKey::Command("hello".to_string()), Duration::from_secs(5))
        .build()
}

fn router(public_key: &str, rest: RestClient) -> Result<axum::Router, DiscordError> {
    try_typed_interactions_endpoint(public_key, app(rest))
}
```

## Modals

`ModalBuilder::new(custom_id, title)` wraps every input in a Label (Discord's current layout):
`add_text_input(TextInputBuilder)`, `add_select_menu(label, description, select)`,
`add_file_upload(..)`, `add_radio_group(..)`, `add_checkbox_group(..)`, `add_checkbox(..)`,
`add_label(LabelBuilder)`, `add_text_display(text)`, `add_component(ModalComponent)`. 1–5
components. Modal inputs have no `disabled`; a single `CheckboxBuilder` cannot be required (use a
one-option `CheckboxGroupBuilder::required(true)`); `default_checked(bool)` sets its initial
state. `add_text_input_row` (action-row text input) is deprecated.

```rust
// features: default
use discordrs::request::Modal;
use discordrs::{
    CheckboxBuilder, DiscordError, FileUploadBuilder, ModalBuilder, RadioGroupBuilder,
    SelectOption, TextInputBuilder,
};

fn ticket_modal() -> Result<Modal, DiscordError> {
    ModalBuilder::new("ticket:create", "New ticket")
        .add_text_input(TextInputBuilder::short("subject", "Subject").max_length(100))
        .add_text_input(TextInputBuilder::paragraph("details", "Details").required(false))
        .add_radio_group(
            "Priority",
            None,
            RadioGroupBuilder::new("priority")
                .add_option(SelectOption::new("Low", "low"))
                .add_option(SelectOption::new("High", "high"))
                .required(true),
        )
        .add_checkbox("Urgent", Some("Page the on-call"), CheckboxBuilder::new("urgent").default_checked(false))
        .add_file_upload("Screenshot", None, FileUploadBuilder::new("shot").file_types(["image"]).required(false))
        .try_build()
}
```

## Commands

`SlashCommandBuilder`, `UserCommandBuilder`, `MessageCommandBuilder`,
`PrimaryEntryPointCommandBuilder` build `CommandDefinition`. Options: `CommandOptionBuilder::new(
CommandOptionType::X, ..)` or `::string/integer/number/boolean/user/channel/role/mentionable/
attachment/subcommand/subcommand_group`; `choice(name, impl Into<CommandOptionValue>)`
(`try_choice` for other values), `autocomplete(true)`, `min_value`/`max_value`, lengths,
`channel_types`, `file_types`, localizations. `try_build()` checks Discord's rules (lowercase
names, no punctuation or ASCII apostrophe, required-before-optional, unique names, choice types,
±2^53, 8,000-char total, locale keys); `build()` never validates. Limits: `command::limits`.
Register with `bulk_overwrite_global_commands(&defs)` or
`bulk_overwrite_guild_commands(guild_id, &defs)` (needs the application id).

```rust
// features: default
use discordrs::{
    ApplicationIntegrationType, CommandDefinition, CommandOptionBuilder, CommandOptionType,
    DiscordError, GuildId, InteractionContextType, Permissions, RestClient, SlashCommandBuilder,
    UserCommandBuilder,
};

fn commands() -> Result<Vec<CommandDefinition>, DiscordError> {
    let amount = CommandOptionBuilder::new(CommandOptionType::INTEGER, "amount", "How much")
        .required(true)
        .choice("ten", 10)
        .try_choice("most", 9_007_199_254_740_991_u64)?;
    let pay = SlashCommandBuilder::new("pay", "Send coins")
        .option(amount)
        .option(CommandOptionBuilder::user("to", "Recipient").required(true))
        .contexts([InteractionContextType::GUILD])
        .integration_types([ApplicationIntegrationType::GUILD_INSTALL])
        .default_member_permissions(Permissions::from_bits(0))
        .try_build()?;
    let config = SlashCommandBuilder::new("config", "Bot settings")
        .subcommand(
            CommandOptionBuilder::subcommand("show", "Show settings")
                .option(CommandOptionBuilder::string("key", "Setting").autocomplete(true)),
        )
        .try_build()?;
    let inspect = UserCommandBuilder::new("Inspect").try_build()?;
    Ok(vec![pay, config, inspect])
}

async fn register(rest: &RestClient, guild_id: GuildId) -> Result<(), DiscordError> {
    let registered = rest.bulk_overwrite_guild_commands(guild_id, &commands()?).await?;
    println!("registered {} commands", registered.len());
    Ok(())
}
```
