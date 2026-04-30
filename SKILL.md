---
name: discordrs-dev
description: Build, update, debug, explain, review, and document Rust Discord bots or libraries that use discordrs 1.2.1. Use when Codex needs to work on discordrs gateway runtimes, typed EventHandler/Event flows, interactions endpoints, RestClient or DiscordHttpClient helpers, cache managers, collectors, sharding, voice playback/receive, DAVE/MLS hooks, Opus encode/decode, Components V2 builders, modal parsing, examples, docs, or the upstream discordrs project.
---

# Discordrs Dev

## Quick Start

- Confirm the workspace version first. Prefer the repository's `Cargo.toml` over memory.
- Read [references/discordrs-0.4.0.md](references/discordrs-0.4.0.md) before changing public examples, runtime selection, event flow, helper choice, or docs. The filename is retained for compatibility, but the content targets discordrs `1.2.1`.
- Preserve the existing typed/builder-style API unless a breaking change is explicitly requested.
- Assume the public REST surface is typed-first: the old raw `RestClient` convenience methods are gone from the public API.
- Assume builder implementation submodules are private; import through `discordrs::builders::{...}` or crate-root re-exports.
- Assume tokenized callback/webhook paths are validated and must reject empty or unsafe path segments.
- Assume bot `Authorization` headers are intentionally omitted for token-authenticated `/webhooks/...` and `/interactions/...` requests.
- Assume gateway Identify/Resume payloads send the raw Discord token, not an HTTP `Bot ` prefix.
- Assume typed slash/autocomplete input uses `CommandInteractionOption`, preserving nested option `value` and `focused`.
- Assume voice includes raw UDP receive, Opus-frame send, RTP-size transport decrypt, pure-Rust Opus PCM decode, optional `voice-encode` PCM-to-Opus playback, and experimental `dave` receive/outbound hooks; do not claim live DAVE/MLS interoperability without real voice gateway transition testing.
- Assume REST/event coverage includes polls, subscriptions, entitlements, soundboard, thread details, forum fields, invites, integrations, stickers, stage, onboarding, templates, and welcome screen helpers unless the current workspace proves otherwise.
- Assume default cache storage is bounded; use `ClientBuilder::cache_config(...)` to tune gateway cache limits and `CacheConfig::unbounded()` only for intentional unbounded retention.
- Assume OAuth2 secret-bearing types redact credentials in `Debug` output; do not add derived `Debug` back to client secrets, authorization codes, access tokens, or refresh tokens.
- When expanding tests, prefer hermetic local harnesses over real Discord traffic.
- Assume `src/http.rs` may expose a test-only local base URL seam for request-wrapper tests.
- Assume gateway and voice runtime coverage can be driven with local `TcpListener` + websocket harnesses.

## Mental Model First

- Start with the runtime choice, not the helper choice.
- `Client` is the long-lived gateway bot runtime.
- `try_typed_interactions_endpoint()` is the signed HTTP interactions runtime.
- `RestClient` / `DiscordHttpClient` is the outgoing HTTP layer used by both.
- `Context` belongs to gateway handling. `InteractionContextData` belongs to interaction payloads.
- `ApplicationCommand` IDs are optional until Discord assigns them. Use `id_opt()` / `created_at()` on the command itself instead of treating it as a generic `DiscordModel`.
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
   Use typed `RestClient` methods such as `create_message`, `update_message`, `create_dm_channel_typed`, `create_interaction_response_typed`, and `bulk_overwrite_*_typed`.
   Preserve the hardened HTTP rules: validate tokenized callback/webhook path segments, and do not attach bot `Authorization` headers to token-authenticated `/webhooks/...` or `/interactions/...` requests.
   For follow-up helpers, prefer typed follow-up APIs when you want a typed `Message` result; the raw JSON follow-up container helper remains backed by crate-private JSON webhook helpers.
   When the task depends on slash/autocomplete user input, use `CommandInteractionOption` data instead of command-definition models so `value` and `focused` survive parsing.
3. Keep the object graph straight.
   `Client` starts the runtime.
   `EventHandler` receives `Event`.
   `Context` is the bridge to outgoing actions (`rest`, cache managers, shard helpers, voice helpers).
   `RestClient` / `DiscordHttpClient` performs HTTP work.
   Cache managers only provide meaningful cached reads when gateway events are populating storage and the `cache` feature is enabled.
4. Respect compatibility aliases.
   `BotClient` and `DiscordHttpClient` still exist, but prefer `Client` and `RestClient` in new docs/examples.
   Legacy convenience callbacks still exist, but `handle_event(...)` is the canonical gateway entry point.
   Do not recommend removed raw REST convenience methods or private builder submodule paths in new examples.
5. Sync docs and examples with public surface changes.
   Update `README.md`, `USAGE.md`, Docsify pages under `discordrsdocs/`, and docs pages when helper recommendations or public examples change.
   When documenting upgrades, include explicit old -> new replacement paths for removed public APIs.
   Keep `C:\Users\B360M-PC\.codex\skills\discordrs-dev` and `C:\Users\B360M-PC\Documents\guthab\discordrs-skill` byte-identical, including `references/discordrs-0.4.0.md`.
6. Verify before finishing.
   Run `cargo test --all-features`.
   Run `cargo check --all-features --all-targets`.
   Run a focused test subset for the edited surface when one exists.
   Run `cargo clippy --all-features --tests -- -D warnings` when public API or docs-facing code paths changed.
   When editing HTTP surfaces, explicitly check auth-header behavior and tokenized path validation tests.
   When editing typed interaction parsing, add a regression test that proves option `value` / `focused` data survives the typed parser.
   When the task is coverage-driven, also run `cargo llvm-cov --all-features --summary-only` and choose the next target from the biggest uncovered files.

## Coverage Patterns

- Prefer direct unit tests first for builders, bitfields, types, parsers, and event decode helpers.
- For `http.rs`, prefer a local TCP HTTP harness that records method, path, headers, and body so wrapper methods can be tested without touching Discord.
- For `gateway/client.rs` and `voice_runtime.rs`, prefer local websocket harnesses with scripted `HELLO`, `READY`, `INVALID_SESSION`, `RECONNECT`, heartbeat, and close-frame flows.
- For voice work, cover RTP header parsing, AES-GCM/XChaCha RTP-size encrypt/decrypt, Opus encode/decode, DAVE frame parsing, DAVE outbound command payloads, and DAVE state transitions with hermetic tests before claiming behavior.
- For `gateway/bot.rs`, `cache.rs`, `collector.rs`, `sharding.rs`, and `voice.rs`, prefill runtime state, apply one event or command, and assert the exact mutation plus nearby no-op state.
- Prefer tiny valid payloads over large shared fixtures when covering `decode_event`, `parse_interaction`, or modal parsers.
- Prefer validation-before-network tests for helper wrappers when the target mostly delegates to `DiscordHttpClient`.
- Do not add coverage-only production refactors unless there is a clear reuse or maintainability win.

## Reference

- Load [references/discordrs-0.4.0.md](references/discordrs-0.4.0.md) for the beginner mental model, feature cause/effect map, runtime relationships, voice/DAVE boundaries, current typed coverage, common workflows, and pitfalls. Treat it as the `1.2.1` reference despite the legacy filename.

