# Contributing to discord.rs itself

Use this when changing the crate (`github.com/Ingwannu/discord.rs`), not when building a bot with
it. The rules below are enforced by `Cargo.toml` `[lints]`, CI (`.github/workflows/ci.yml`), and
review. Primary sources: `discordrsdocs/docs/guide/architecture.md` ("Code rules", module
layout), `discordrsdocs/docs/guide/testing-and-coverage.md` (every check below), `ci/README.md`,
`ROADMAP.md`, `docs/design/*.md` (design records, mostly Korean).

## Where things go

- Endpoint: a row in `src/http/routes.rs` (route manifest: method, docs path template, auth
  `bot|bearer|token|interaction|none|client`, query, body and response types, `api [methods]`,
  optional `was [old => new]`), then a method in the matching `src/http/<domain>.rs`
  `impl RestClient` block that passes its `RouteId` to the existing shims (`send`, `send_unit`,
  `send_optional`, `send_bytes`, `send_bearer`). Paths in `src/http/paths.rs`, body encoding in
  `src/http/body.rs`, rate-limit state in `src/http/rate_limit.rs`. Never add another generic
  `async fn` around the transport; `RestClient::execute` is the only request loop.
- Request body: `src/request/<domain>.rs` (Serialize-only, `validate()`, `Patch`/`NullablePatch`
  for modify bodies). Received model: `src/model/<domain>.rs` plus one re-export line in
  `src/model.rs` (and the crate root if common).
- Gateway dispatch: `src/event.rs` payload + `src/event/decode.rs` table arm; cache effects in
  the pipeline (`src/gateway/bot/pipeline.rs`); update `tests/perf_report/inbound.rs` when the
  pipeline, `apply_cache_updates`, or collector publishing changes.
- Limits, opcodes, close codes, protocol sizes: named constants with a doc comment citing the
  Discord source (`command::limits`, `builders/limits.rs`, `OP_*`, `CLOSE_*`).
- Long-lived `()` tasks in voice/sharding code: spawn through `crate::task::spawn_erased`
  (the module exists only under `cfg(any(feature = "voice", feature = "sharding"))`).

## Code rules (library code)

| Rule | Enforced by |
|---|---|
| No `unsafe` | `#![forbid(unsafe_code)]` in `src/lib.rs`, `unsafe_code = "deny"` elsewhere |
| No `unwrap()` / `expect()` / `panic!` / `todo!` / `unimplemented!` / `dbg!` / `mem::forget` | clippy deny lints |
| No `as` conversions: `From`/`TryFrom` (saturating where the value cannot exceed), or a named helper where wrapping is intended | `clippy::as_conversions` |
| No silent `let _ = ..` of a `#[must_use]` value or a future: handle, log, or `.ok()` with a comment saying why failure is expected | `let_underscore_must_use`, `let_underscore_future` |
| Every suppression has a reason: `#[expect(lint, reason = "...")]` at the firing site; `allow` only when the lint does not fire on every supported toolchain | `allow_attributes_without_reason` |
| No std lock or `RefCell` guard across `.await`; each shared mutable field has a one-line comment saying who shares it | `await_holding_lock`, `await_holding_refcell_ref`, review |
| `Arc::clone(&x)` for pointer copies | `clippy::clone_on_ref_ptr` |
| Intra-doc links resolve | `RUSTDOCFLAGS="-D warnings" cargo doc` |

Tests and examples may unwrap/panic/cast only behind a crate- or file-level
`allow(..., reason = "...")`. Public async traits use `fn … -> impl Future<Output = T> + Send`
(no `async-trait`); `tests/async_traits.rs` implements each with plain `async fn`.

```rust
// features: default
/// Discord's documented maximum number of choices per option
/// (developers/interactions/application-commands.mdx, "Application Command Option Structure").
const MAX_CHOICES: usize = 25;

/// Clamps a length into the u8 a wire field holds, without an `as` cast.
fn wire_count(len: usize) -> u8 {
    u8::try_from(len.min(MAX_CHOICES)).unwrap_or(u8::MAX)
}

fn notify(sender: &tokio::sync::mpsc::UnboundedSender<u8>, value: u8) {
    // The receiver is gone only during shutdown, when the value is no longer needed.
    sender.send(value).ok();
}
```

## Why-comments and Decision Logs

Comments explain why (intent, constraint, rejected alternatives, what must hold when editing),
not what the code does. New features, complex logic, and structural changes carry a Decision Log
in the code, the guide, or `docs/design/`:

```text
[Decision Log]
- 목적과 의도 (Purpose):
- 기존 구현 및 제약 조건 (Existing implementation and constraints):
- 검토한 주요 대안 (Alternatives considered):
- 선택한 방식 (Chosen approach):
- 다른 대안 대신 이 방식을 선택한 이유 (Why this over the alternatives):
- 장점, 단점 및 영향 (Pros, cons, and impact):
```

## Docs move with the code (same change)

- `CHANGELOG.md` (Keep a Changelog; a new section above the latest, `## 3.1.0`) and the condensed
  `discordrsdocs/docs/guide/changelog.md`.
- `README.md`, `USAGE.md`, the API pages in `discordrsdocs/docs/api/`, guides in
  `discordrsdocs/docs/guide/`, and the Korean copies under `discordrsdocs/ko/` where one exists
  (`ko/api`: builders, core-types-and-constants, gateway, http-and-helpers,
  interactions-endpoint, parsers; `ko/guide`: architecture, deployment, full-manual,
  getting-started, interaction-flow, migration-3.0, usage-guide).
- Migration guide snippets: every `rust` block in `discordrsdocs/docs/guide/migration-3.0.md`
  and its Korean copy is a region `// snippet-start: NAME` … `// snippet-end` in
  `tests/migration_guide.rs`, shown after `<!-- snippet: NAME -->`; 2.x "before" blocks are
  marked `<!-- snippet: 2.x -->`. Edit the region, `cargo fmt`, paste into both guides, then
  `cargo test --all-features --locked --test migration_guide`.
- Examples in `examples/` must compile (`cargo check --examples --all-features --locked`).

## Checks before a PR (CI parity)

CI's blocking jobs use the pinned toolchain `1.99.0`; MSRV is `1.88`.

```bash
cargo +1.99.0 fmt --all -- --check
cargo +1.99.0 check --all-features --locked && cargo +1.99.0 check --locked
cargo +1.99.0 check --examples --all-features --locked
cargo +1.99.0 test --all-features --locked --no-fail-fast && cargo +1.99.0 test --locked
cargo +1.99.0 clippy --all-features --all-targets --locked -- -D warnings
cargo +1.99.0 clippy --all-targets --locked -- -D warnings
RUSTDOCFLAGS="-D warnings" cargo +1.99.0 doc --all-features --no-deps --locked
RUSTDOCFLAGS="-D warnings" cargo +1.99.0 doc --no-deps --locked
# Each of the ten feature sets alone, every target:
for feature in "" cache gateway collectors sharding zstd-stream voice voice-encode dave interactions; do
  cargo +1.99.0 clippy --all-targets --no-default-features ${feature:+--features "$feature"} --locked -- -D warnings
done
# Compile-fail snapshots (tests/ui/*.stderr are kept for the pinned toolchain only):
DISCORDRS_TRYBUILD=1 cargo +1.99.0 test --locked --test compile_fail
# after a toolchain bump or a new case: DISCORDRS_TRYBUILD=1 TRYBUILD=overwrite ..., then review git diff tests/ui/
# Coverage gate (90% lines, whole tree, no ignore regex):
cargo +1.99.0 llvm-cov --all-features --locked --summary-only --fail-under-lines 90
# MSRV:
cargo +1.88 test --locked && cargo +1.88 test --all-features --locked
# Route manifest, allowlist, drift tooling (Python 3.11+, stdlib only):
python3 ci/api_drift.py --self-check
python3 -m unittest discover -s ci/tests -v
# REST request goldens after an intended request change, then review the diff:
DISCORDRS_UPDATE_GOLDENS=1 cargo test --all-features --lib http::tests::goldens
```

`ci/api_drift.py --self-check` fails when a `RestClient` endpoint is missing from the manifest,
a row lists a method that does not send its `RouteId`, a `was` forward is not deprecated or does
not call its replacement, or a deprecated forward lacks a `forward!` golden case. Allowlist
entries in `ci/api-drift-allowlist.toml` need a `reason` of 15+ characters.

## Performance gates (gateway inbound, cache, collectors, outbound bodies)

```bash
cargo test --release --all-features --locked --test perf_report -- --ignored --nocapture --test-threads=1
python3 ci/perf_diff.py docs/design/perf/23775d1.json target/perf-report.json --deterministic-only --strict --fail-on-regression 2
python3 ci/perf_diff.py --gates ci/perf-gates.json --checkpoint C --strict target/perf-report.json
cargo test --release --all-features --locked --test interaction_decode_footprint -- --nocapture
```

Allocation counts, bytes, retained, and peak are deterministic; times and RSS are not. A
deterministic regression over 2% needs a recorded reason (see the `note`s in
`ci/perf-gates.json`). Checkpoint C inherits B and overrides the rows phase 4 C changed; the
guides show `--checkpoint B`, and 3.x is past C, so check C. These gates are run by hand
before merging gateway/cache/collector/outbound work: the `perf-report` CI job only posts the
diff and gate status and never fails (`continue-on-error`). `interaction_decode_footprint` is a
real test that fails above its allocation cap. Method and baselines:
`docs/design/perf-baseline.md`.

## Testing style

Hermetic only: local TCP harness for REST (`RestClient::new_with_base_url`, test-only), local
websocket harness (`tokio_tungstenite::accept_async`) for gateway and voice, tiny payloads per
event variant, prefill → apply one event → assert the mutation and the untouched neighbours. Unit
tests build models with `T::fixture()` and IDs with `crate::model::test_id(n)`. Live Discord
tests are `#[ignore]`d (DAVE: `tests/live_voice_dave.rs`). Documented example payloads round-trip
in `src/model/doc_examples.rs` (regenerate with `python3 ci/doc_examples.py --docs <clone>`).

## Secrets

Never print, log, commit, or paste a bot token, webhook/interaction token, client secret, or
public key file contents into docs, tests, fixtures, issues, or chat. Live verification records
no tokens or guild names (see `docs/design/perf-baseline.md` §11). Read tokens from the
environment. New diagnostics must keep the token scrubbing (`route_token`, `scrub_token`,
`redact_path_tokens`) and redacted `Debug` output.

Voice/DAVE (3.1.0, `src/voice_runtime/dave.rs`, design in `docs/design/dave-voice.md`): every
davey call the runtime makes runs under the scoped `DaveyTraceFilter` dispatcher (davey 0.1.5
logs media keys at trace level), so route new davey calls through it; runtime key material uses
`zeroize`/`Zeroizing` and stays out of `Debug`; logs of received packets carry header fields and
the reason, never the payload. DAVE changes are tested hermetically with two independent davey
sessions and the test voice gateway; `tests/live_voice_dave.rs` stays `#[ignore]` and needs an
explicitly prepared voice session.
