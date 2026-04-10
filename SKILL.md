---
name: discordrs-dev
description: Build, update, debug, explain, review, and document Rust Discord bots or libraries that use discordrs 0.4.0. Use when Codex needs to work on discordrs gateway runtimes, typed EventHandler/Event flows, interactions endpoints, RestClient or DiscordHttpClient helpers, cache managers, collectors, sharding, voice, Components V2 builders, modal parsing, examples, docs, or the upstream discordrs project.
---

# Discordrs Dev

## Quick Start

- Confirm the workspace version first. Prefer the repository's `Cargo.toml` over memory.
- Read [references/discordrs-0.4.0.md](references/discordrs-0.4.0.md) before changing public examples, runtime selection, event flow, helper choice, or docs.
- Preserve the existing typed/builder-style API unless a breaking change is explicitly requested.

## Mental Model First

- Start with the runtime choice, not the helper choice.
- `Client` is the long-lived gateway bot runtime.
- `try_typed_interactions_endpoint()` is the signed HTTP interactions runtime.
- `RestClient` / `DiscordHttpClient` is the outgoing HTTP layer used by both.
- `Context` belongs to gateway handling. `InteractionContextData` belongs to interaction payloads.
- `cache`, `collectors`, `sharding`, and `voice` extend a runtime; they do not replace choosing one.

## Follow This Workflow

1. Pick the lane first.
   Use core/default APIs for builders, parsers, helper functions, and REST-only work.
   Use `gateway` when the bot keeps a websocket connection and reacts to events.
   Use `interactions` when Discord posts interactions to your HTTP server.
   Add `cache`, `collectors`, `sharding`, or `voice` only when the task needs those runtime layers.
2. Prefer the typed entry points.
   Use `Client::builder(...).event_handler(...).start()` for gateway bots.
   Match on `Event` inside `EventHandler::handle_event(...)` for new gateway logic.
   Use typed `Interaction` variants or `try_typed_interactions_endpoint()` before falling back to raw JSON.
   Use crate builders/helpers before handwriting JSON payloads.
3. Keep the object graph straight.
   `Client` starts the runtime.
   `EventHandler` receives `Event`.
   `Context` is the bridge to outgoing actions (`rest`, cache managers, shard helpers, voice helpers).
   `RestClient` / `DiscordHttpClient` performs HTTP work.
   Cache managers only provide meaningful cached reads when gateway events are populating storage and the `cache` feature is enabled.
4. Respect compatibility aliases.
   `BotClient` and `DiscordHttpClient` still exist, but prefer `Client` and `RestClient` in new docs/examples.
   Legacy convenience callbacks still exist, but `handle_event(...)` is the canonical gateway entry point.
5. Sync docs and examples with public surface changes.
   Update `README.md`, `USAGE.md`, and docs pages when helper recommendations or public examples change.
6. Verify before finishing.
   Run `cargo test --all-features`.
   Run `cargo check --all-features --all-targets`.
   Run a focused test subset for the edited surface when one exists.

## Reference

- Load [references/discordrs-0.4.0.md](references/discordrs-0.4.0.md) for the beginner mental model, feature cause/effect map, runtime relationships, common workflows, and pitfalls.

