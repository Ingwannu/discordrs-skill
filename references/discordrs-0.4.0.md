# Moved: discord.rs reference

This file is kept only so that older prompts, installed copies, and links that point at
`references/discordrs-0.4.0.md` still resolve. Its 2.0.2-era content was wrong for 3.0 (string
`Snowflake`s, the `Event` enum, `Value` builders, `async-trait`) and has been removed.

The skill now targets **discordrs 3.0.0**. Start at [`SKILL.md`](../SKILL.md), then read:

- [api-overview.md](api-overview.md): features, module map, typed IDs, discriminants, `Patch`, permissions, formatters
- [gateway-events-cache.md](gateway-events-cache.md): `Client`, `Arc<Event>`, hooks, collectors, cache, backends
- [rest-requests-builders.md](rest-requests-builders.md): `RestClient`, `request` bodies, builders, Components V2
- [interactions.md](interactions.md): interactions, responder, HTTP endpoint, `AppFramework`, modals, commands
- [voice-sharding.md](voice-sharding.md): voice runtime, DAVE, `AudioPlayer`, sharding
- [migration-2x-to-3.md](migration-2x-to-3.md): upgrading 2.x code
- [contributing.md](contributing.md): working on the crate itself
- [pitfalls-and-status.md](pitfalls-and-status.md): common mistakes, what was live-tested
