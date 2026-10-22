# discordrs-skill

Agent skill `discordrs-dev` for building Discord bots with
[discord.rs](https://github.com/Ingwannu/discord.rs) (crate `discordrs`) **3.1.1** (3.x) and for
contributing to the crate. Works with Codex (`$discordrs-dev`, `agents/openai.yaml`) and Claude
Code (Skill tool, `SKILL.md` frontmatter).

## Layout

| Path | Purpose |
|---|---|
| `SKILL.md` | Entry point: lane selection, mental model, rules, pitfalls, reference index (kept under ~200 lines because agents load it whole) |
| `references/api-overview.md` | Features, module map, typed IDs, open discriminants, `Patch`/`Nullable`, bitfields and intents, permissions, formatters, webhook events, errors, how to find an API |
| `references/gateway-events-cache.md` | `Client`, `Arc<Event>`/`EventKind`, hook signatures, pipeline and builder knobs, `Context`, `fetch_members`, collectors, cache, `CacheBackend` epoch contract |
| `references/rest-requests-builders.md` | `RestClient`, `discordrs::request` bodies, `RawRequest`, retries and rate limits, `allowed_mentions`, Components V2 and other builders, Component Embed |
| `references/interactions.md` | `Interaction`, `InteractionResponse`/`EndpointReply`, responder state machine, HTTP endpoint, `AppFramework`, modals, commands |
| `references/voice-sharding.md` | Voice flow, transport crypto, DAVE, `AudioPlayer`, sharding (in-process and multi-process) |
| `references/migration-2x-to-3.md` | Condensed 2.x → 3.0 map; points at the crate's compiled migration guide |
| `references/contributing.md` | Rules for changing the crate itself: lints, Decision Logs, docs en/ko, snippet harness, route manifest, perf/trybuild/feature/coverage gates |
| `references/pitfalls-and-status.md` | Common mistakes, known limits, the 3.0 live-verification record |
| `references/discordrs-0.4.0.md` | Compatibility stub only (see Decision Log below) |
| `agents/openai.yaml` | Codex UI metadata |
| `scripts/check-examples.sh`, `scripts/extract-examples.py` | Compile every Rust example against the published crate |

## Verifying the examples

Every ```` ```rust ```` block in `SKILL.md` and `references/*.md` must compile against the
published crate. Its first line names the Cargo features it needs, added to discordrs' defaults:

```rust
// features: gateway, collectors
pub fn example() {}
```

(`// features: default` when none are needed.) Blocks must be complete items (functions,
structs, impls), not statement fragments. Code that must not be compiled (TOML, shell, 2.x
"before" code) uses another fence language.

```bash
scripts/check-examples.sh                                   # discordrs =3.1.1 from crates.io
DISCORDRS_VERSION=3.1.1 scripts/check-examples.sh           # a later published version
DISCORDRS_PATH=$HOME/discord.rs scripts/check-examples.sh   # an unpublished checkout
```

The script groups blocks by feature set into scratch crates under `/tmp/discordrs-skill-check`
(override with `CHECK_DIR`), each block in its own module, and runs `cargo check` per crate with
`#![deny(warnings)]` (so deprecated APIs and unused imports fail). It needs `python3` and `cargo`,
uses no token, and contacts nothing but crates.io. A cold run takes a few minutes (dependencies,
including `davey`/OpenMLS); later runs about 20-45 s per feature set.

Result for this revision (2026-10-22, rustc 1.97.1): 7 feature sets, 35 blocks, all compiled
against the published `discordrs =3.1.1` from crates.io (default run, no arguments). The
previous revision compiled 34 blocks against 3.0.0 from crates.io.

## Updating for a new discordrs release

1. Read the release's `CHANGELOG.md` section, the migration/API pages under `discordrsdocs/`,
   and the changed code.
2. Update the references and `SKILL.md` (version strings, frontmatter description,
   `agents/openai.yaml`).
3. `DISCORDRS_VERSION=<new> scripts/check-examples.sh` and fix every failing block.
4. Validate the frontmatter (no `<`/`>` in `description`, ≤ 1024 chars;
   `short_description` 25-64 chars).

## Install on ingwdev1 (one source of truth)

On ingwdev1 the git checkout itself is the skill source:

```text
~/.codex/skills/discordrs-dev/      <- this repository (real directory, git checkout)
~/discordrs-skill                   -> ~/.codex/skills/discordrs-dev   (convenience symlink)
~/.claude/skills/discordrs-dev      -> ~/.codex/skills/discordrs-dev   (made by agent-config-sync)
~/.claude-alt/skills/discordrs-dev  -> ~/.codex/skills/discordrs-dev   (made by agent-config-sync)
```

Edits through any of these paths change the same files, and `git` works from either repo path.
Check with `ls -l ~/.claude/skills/discordrs-dev ~/.claude-alt/skills/discordrs-dev` and
`codex debug prompt-input hi | grep -o 'discordrs-dev: [^"]*' | head -1`.

```text
[Decision Log]
- 목적과 의도: Codex, Claude Code, Claude Code Alt가 같은 discordrs-dev 스킬을 보고, 리포 수정이 곧 설치본 수정이 되게 한다.
- 기존 구현 및 제약 조건: 전역 규칙(~/.codex/AGENTS.md §8)상 스킬 원본은 ~/.codex/skills/<이름>이고,
  agent-config-sync가 원본을 Claude 두 계정에 링크한다. 그 스크립트는 원본 쪽의 symlink 항목을 건너뛴다
  (source_map의 `src.is_symlink()` 조건). 이 스킬은 GitHub 리포(Ingwannu/discordrs-skill)로 관리된다.
- 검토한 주요 대안: (1) ~/.codex/skills/discordrs-dev를 리포로의 symlink로 두고 sync 스크립트를 고친다,
  (2) ~/.codex/skills에 리포를 따로 clone한다, (3) 리포 체크아웃 자체를 ~/.codex/skills/discordrs-dev에 두고
  기존 경로 ~/discordrs-skill을 그쪽 symlink로 둔다.
- 선택한 방식: (3).
- 다른 대안 대신 이 방식을 선택한 이유: (1)은 공용 인프라 스크립트를 바꿔야 하고 Codex가 원본 symlink를 따라가는지도
  추가 검증이 필요하다. (2)는 작업 사본이 둘이라 갈라진다. (3)은 원본 위치 규칙과 sync 스크립트를 그대로 쓰고 사본이 하나다.
- 장점, 단점 및 영향: 설치·갱신이 git pull/commit 하나로 끝난다. 대신 스킬 폴더 안에 .git, README.md, scripts/가 있다
  (스킬 로더가 먼저 읽는 것은 SKILL.md와 Codex의 agents/openai.yaml뿐이고, 나머지는 필요할 때만 읽힌다). 리포를 다른 곳으로 옮기면 ~/discordrs-skill 링크도 고쳐야 한다.
```

Elsewhere, install by cloning into the agent's skill directory, for example
`git clone https://github.com/Ingwannu/discordrs-skill ~/.codex/skills/discordrs-dev` or
`~/.claude/skills/discordrs-dev`.

```text
[Decision Log]
- 목적과 의도: 3.0 개편 후 references/discordrs-0.4.0.md를 어떻게 할지 정한다.
- 기존 구현 및 제약 조건: 2.0.2판 SKILL.md와 openai.yaml이 이 경로를 가리켰고, 리포는 공개되어 다른 설치본·프롬프트가
  그 경로를 참조할 수 있다. 내용은 3.0과 맞지 않는다(문자열 Snowflake, Event enum, Value 빌더, async-trait).
- 검토한 주요 대안: (1) 삭제, (2) 3.0 내용으로 갱신해 이름 유지, (3) 짧은 호환 안내만 남김.
- 선택한 방식: (3).
- 다른 대안 대신 이 방식을 선택한 이유: (1)은 옛 링크를 깨뜨리고, (2)는 버전과 맞지 않는 파일명이 주제별 분할을 가린다.
  (3)은 16줄로 옛 링크를 살리고 새 파일로 안내한다.
- 장점, 단점 및 영향: 파일 하나가 더 남는다. 다음 메이저 개편 때 참조가 없으면 지운다.
```

## License

Apache-2.0 (see `LICENSE`).
