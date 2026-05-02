---
name: discordrs-dev
description: Build, update, debug, explain, review, and document Rust Discord bots or libraries that use discordrs 2.0.0. Use when Codex needs to work on discord.rs gateway runtimes, typed EventHandler/Event flows, AppFramework HTTP interactions, Webhook Events, Lobby/Social SDK helpers, typed RestClient or DiscordHttpClient helpers, cache managers, collectors, sharding, voice playback/receive, live DAVE/MLS validation, Opus encode/decode, Components V2 builders, modal parsing, examples, docs, coverage, release checks, or the upstream discordrs project.
---

# Discordrs Dev

Use this skill for `discordrs` crate work and for apps built with `discordrs`.
The Cargo package and Rust import name are `discordrs`; the public-facing brand is `discord.rs`.

## Quick Start

- Confirm the workspace version first. Prefer the repository's `Cargo.toml` over memory or this skill.
- Read [references/discordrs-0.4.0.md](references/discordrs-0.4.0.md) before changing examples, runtime selection, helper choice, docs, release claims, or public API guidance. The filename is retained for compatibility; the content targets `discordrs 2.0.0`.
- Start by choosing the runtime lane:
  - Gateway bot: `Client::builder(...).event_handler(...).start()`.
  - HTTP interactions app: `AppFramework` or `try_typed_interactions_endpoint(...)`.
  - REST-only tool: `RestClient::new(...)` or `Client::builder(...).rest_only()`.
  - Webhook Events URL: verify the Ed25519 signature, then `parse_webhook_event_payload(...)`.
  - Voice bot: `gateway + voice`, then join voice and use `connect_voice_runtime(...)`.
- Prefer typed/builder APIs. Do not handwrite JSON, route strings, or component payloads when the crate has a public type, builder, or helper.
- Treat `RestClient` as the canonical HTTP surface. `DiscordHttpClient` remains a compatibility alias.
- Treat `Client` as the canonical Gateway surface. `BotClient` remains a compatibility alias.
- Treat `EventHandler::handle_event(ctx, event)` plus `Event` matching as the canonical Gateway flow. Legacy per-event callbacks still exist for compatibility and focused handlers.
- Treat `AppFramework` as the beginner-friendly HTTP interactions router for commands, components, modals, guards, cooldowns, and fallback behavior.
- Treat Webhook Events as HTTP event payloads from Discord's Events URL, not Gateway dispatches and not incoming webhook executions.
- Treat Lobby helpers as Discord application/Social SDK REST helpers. Some routes use bot authorization and some current-user routes require OAuth2 Bearer tokens.

## 2.0.0 Ground Truth

- Version: `discordrs 2.0.0`.
- Official REST route-shape audit: `223 / 223` mapped.
- Official Gateway send-event audit: `7 / 7` mapped.
- Official Gateway receive-event audit: `82 / 82` mapped.
- Official object-heading audit: `90 / 90` mapped or intentionally dynamic.
- Release coverage evidence: all-features line coverage stayed above the 90% gate; recorded release result was `92.32%`.
- DAVE/MLS: an ignored live validation harness exists and passed for the 2.0.0 release. Do not claim future live DAVE compatibility from default tests alone.

## Safety Rules

- Tokenized callback/webhook paths must validate path segments and reject empty or unsafe values.
- Bot `Authorization` headers are intentionally omitted for token-authenticated `/webhooks/...` and `/interactions/...` requests.
- Gateway Identify/Resume payloads send the raw Discord token, not an HTTP `Bot ` prefix.
- Default Gateway startup must not request payload compression without a matching decoder. Explicit `zlib-stream` transport compression must decode compressed `HELLO` and dispatch frames with a stream decoder.
- Typed slash/autocomplete input uses `CommandInteractionOption`; preserve nested option `value` and `focused`.
- Cache defaults are bounded. Use `ClientBuilder::cache_config(...)` for tuning and `CacheConfig::unbounded()` only for intentional unbounded retention.
- OAuth2 secret-bearing types must redact credentials in `Debug`; do not derive or print secrets.
- Interaction signatures are freshness-checked. Stale and future timestamps are rejected.
- `MESSAGE_UPDATE` is partial by nature; custom cache logic must merge carefully instead of wiping known fields.
- Voice disconnects and endpoint loss reset stale runtime/session state.
- DAVE is live-gated. The `dave` feature exposes parser/state/decryptor/encryptor/MLS hooks, but interoperability claims require the ignored live test.

## Beginner Mental Model

Pick one primary surface first, then add optional layers.

1. Core/default
   Builders, models, parsers, helpers, Components V2, `RestClient`, and response builders.
2. Gateway
   Long-lived websocket bot runtime with typed `Event` dispatch.
3. Interactions
   Signed HTTP endpoint for Discord interaction POSTs; use `AppFramework` for simple apps.
4. Webhook Events
   Signed HTTP endpoint for Discord application events; parse into `WebhookEvent`.
5. Voice
   Voice state, voice gateway/UDP runtime, Opus send/receive/decode, optional encode, experimental DAVE hooks.

Layer only when needed:

- Add `cache` for cache-backed manager reads.
- Add `collectors` for wait-for-next-message/component/modal flows.
- Add `sharding` for multi-shard lifecycle control.
- Add `voice` for voice state/runtime/receive/playback.
- Add `voice-encode` for PCM-to-Opus playback.
- Add `dave` for DAVE/MLS frame and command integration.

## Choose the Right Entry Point

- Send/edit messages: `RestClient::create_message(...)`, `RestClient::update_message(...)`, or helpers such as `send_message(...)`.
- Register commands: `SlashCommandBuilder`, `UserCommandBuilder`, `MessageCommandBuilder`, then `create_*_command(...)` or `bulk_overwrite_*_typed(...)`.
- Handle Gateway events: implement `EventHandler`, then match `Event`.
- Reply to Gateway interactions: match `Event::InteractionCreate(...)`, then use `respond_with_message(...)`, `followup_message(...)`, `defer_interaction(...)`, or `update_interaction_message(...)`.
- Build an HTTP slash-command app: use `AppFramework::builder().command(...).component(...).modal(...).build()`.
- Build a lower-level interactions endpoint: implement `TypedInteractionHandler` and pass it to `try_typed_interactions_endpoint(...)`.
- Parse Webhook Events: verify the signature, then `parse_webhook_event_payload(...)`, then match `WebhookEvent`.
- Use Lobby/Social SDK routes: use `Lobby`, `CreateLobby`, `ModifyLobby`, `AddLobbyMember`, `LobbyMemberUpdate`, and `LinkLobbyChannel` helpers.
- Use OAuth2: use `OAuth2Client`, `OAuth2AuthorizationRequest`, token exchange/refresh helpers, current-user connection helpers, and Bearer-token routes where Discord requires user authorization.
- Use cache: use `ctx.guilds()`, `ctx.channels()`, `ctx.members()`, `ctx.messages()`, `ctx.roles()` and `CacheConfig`.
- Use collectors: use `CollectorHub`, `MessageCollector`, `ComponentCollector`, `ModalCollector`, or `InteractionCollector`.
- Use sharding: use `ShardConfig`, `ShardSupervisor`, `ShardMessenger`, and shard lifecycle/status types.
- Use voice: use `Context::join_voice(...)`, `connect_voice_runtime(...)`, `VoiceRuntimeHandle`, `recv_voice_packet(...)`, `VoiceOpusDecoder`, and playback helpers.
- Use DAVE: use `recv_voice_packet_with_dave(...)`, `VoiceDaveySession`, `VoiceDaveFrameEncryptor`, and the live validation harness before making release claims.

## Follow This Workflow

1. Inspect the target workspace.
   Check `Cargo.toml`, features, examples, docs, and the current public API before making claims.
2. Pick a lane.
   Gateway, interactions/AppFramework, Webhook Events, REST-only, cache, collectors, sharding, voice, DAVE, or docs/release.
3. Prefer typed public entry points.
   Use crate-root re-exports or `discordrs::builders::{...}`. Do not import private builder submodules.
4. Keep authorization mode explicit.
   Bot-token HTTP, token-authenticated webhook/interaction callback, and OAuth2 Bearer routes have different header rules.
5. Add or update examples using small, runnable snippets.
   A beginner AI should be able to copy the pattern without knowing Discord internals.
6. Add or update tests when behavior changes.
   Prefer hermetic local harnesses over live Discord traffic, except for the explicitly ignored live DAVE gate.
7. Sync docs and skills together.
   When the public surface changes, update `README.md`, `USAGE.md`, Docsify pages under `discordrsdocs/`, root `CHANGELOG.md`, and both skill copies when applicable.
8. Keep skill copies byte-identical.
   `C:\Users\B360M-PC\Documents\guthab\discordrs-skill` and `C:\Users\B360M-PC\.codex\skills\discordrs-dev` must match for `SKILL.md`, `agents/openai.yaml`, and `references/discordrs-0.4.0.md`.

## Verification Commands

Use the smallest command set that proves the change, then broaden for public API or release work.

```powershell
cargo fmt --all -- --check
cargo check --all-features --all-targets --locked
cargo test --all-features --locked --no-fail-fast
cargo clippy --all-features --all-targets --locked -- -D warnings
```

Docs/release checks:

```powershell
$env:RUSTDOCFLAGS='-D warnings'; cargo doc --all-features --no-deps --locked
cargo package --locked
cargo llvm-cov --all-features --locked --summary-only
```

Focused checks:

- HTTP wrappers and route validation: `cargo test --lib http::tests`
- Gateway/cache behavior: `cargo test --features "gateway cache" --lib gateway::bot::tests`
- Interaction parsing: run parser tests and add regressions for option `value` / `focused`.
- Voice runtime: run voice runtime tests for RTP, Opus, encryption, and DAVE state when changed.
- Live DAVE claim: run `cargo test --all-features --test live_voice_dave -- --ignored --nocapture` with the documented voice env vars.

## Coverage Patterns

- Builders/bitfields/types/parsers/events: direct unit tests with tiny valid payloads.
- `http.rs`: local TCP harness that records method, path, headers, and body.
- Gateway client: local websocket harnesses for `HELLO`, `READY`, `INVALID_SESSION`, `RECONNECT`, heartbeat, compressed frames, and close handling.
- Voice runtime: local or hermetic tests for RTP header parsing, AES-GCM/XChaCha RTP-size encrypt/decrypt, Opus encode/decode, DAVE frame parsing, DAVE outbound command payloads, and DAVE state transitions.
- Cache/collectors/sharding: prefill runtime state, apply one event/command, assert exact mutation plus nearby no-op behavior.
- Coverage-driven work: use `cargo llvm-cov --all-features --summary-only`, then target the largest uncovered real source files. Do not add coverage-only production refactors without a maintainability reason.

## Reference

- Load [references/discordrs-0.4.0.md](references/discordrs-0.4.0.md) for the 2.0.0 beginner map, feature flag decisions, API families, workflow snippets, release boundaries, and pitfalls.
