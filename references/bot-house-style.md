# House style: how the operator builds Discord bots

This is the default design for every Discord bot built for this operator. Follow it unless the
operator asks for something else. The reference implementation is the operator's private
`wicked-bot` (a discordrs replacement for an older discord.js bot); module names below refer to it.
Customer-facing text is Korean, and code comments and design docs explain *why*, with Decision Logs.

Contents: 1 Shape · 2 Modal wizards · 3 Customise everything · 4 Limits and validation ·
5 Storage · 6 Feature patterns · 7 Startup, deploy, no-downtime updates · 8 Process ·
9 Checklist.

## 1. Shape of a bot

- **Lane:** gateway bot (`features = ["gateway", "cache"]`), `gateway_intents::GUILDS` only.
  Interactions need no intent; add others only when a feature really needs them.
- **Mentions:** set `Client::builder(..).default_allowed_mentions(AllowedMentions::default())`
  (none). Staff write the panel text and must never ping @everyone or roles by accident. Only the
  sends that must ping, such as a new ticket's first card, set mentions explicitly.
- **Commands:** one slash command per feature, with an action option: `/티켓 [생성|수정|확인|삭제]`,
  `/역할자판기 …`, `/인증 …`, `/메시지 [생성|설정]`, plus `/도움말`.
  - Every command except `/도움말` needs Manage Server or Administrator, read from the
    interaction's member permissions.
  - Search-style commands (e.g. `/티켓검색`) use autocomplete. Autocomplete must answer within
    3 s, always with choices (empty on error), never with a message.
- **Modules:**

| Module | Responsibility |
|---|---|
| `main.rs` | `EventHandler`: `interaction_create` → router, `channel_delete` → cleanup. Starts background upkeep tasks |
| `config.rs` | Reads settings from the environment first, then a `.env` (0600) in the working dir. The token lives only there |
| `ids.rs` | `custom_id` grammar: `<feature>:<action>:<ids…>`, e.g. `tk:open:<panel>:<button>`, `mg:btn:<row>:<n>`. Kept under 100 chars |
| `router.rs` | Slash commands by name; components and modals by `custom_id` prefix; autocomplete by command. Each feature exposes `on_command`, `on_component`, `on_modal` (+ `on_autocomplete`), so a new feature touches one line per match |
| `wizard/` | The shared step-by-step modal engine (§2) |
| `features/<name>/` | `steps.rs` (wizard steps), `panel.rs` (render and publish), plus feature logic |
| `features/panels.rs`, `features/buttons.rs` | Shared publish/edit/delete for panels, and the one button-customisation module (§3) |
| `ui/` | Cards and the shared parsers: `style.rs` (accent, dividers, the 꾸미기 step), `image.rs` (the image rule), `emoji.rs` (button emoji) |
| `images.rs` | Uploaded card images, content-addressed on disk (§3) |
| `storage/` | SQLite on one dedicated thread, with migrations (§5) |
| `update/` | The no-downtime update (§7) |

- **Permissions in components:**
  - Panel action buttons (open a ticket, take a role, verify) are for everyone.
  - Wizard and management controls recheck Manage Server on every step.
  - Never `update_message` from an interaction on a public panel; that replaces the panel for
    everyone. Only the bot's own ephemeral cards may be updated (check the message's EPHEMERAL
    flag).
- **Errors:** if nothing has been sent yet, reply with an error card; otherwise send an
  ephemeral follow-up. The user should never see Discord's "This interaction failed".

## 2. All input goes through step-by-step modal wizards

- A `Wizard` trait per feature defines:
  - steps, each with a short code;
  - `modal(step, draft)` and `apply(step, form, draft) -> Result<(), String>`, where the `Err`
    is a Korean message shown in the wizard;
  - `preview(draft)` and `commit(...)`.
- **Progress:** the set of validated step codes. The next step is the first unfinished one.
- **The ephemeral wizard card:**
  - Shows the live preview, a [다음 단계] button and a "단계 수정" select.
  - The select is paged when there are more than 25 steps (23 per page plus ◀/▶ options).
  - Publishing takes a lock, so a double click publishes once.
- **수정 (edit):** every field is prefilled from the stored config, so an unchanged save changes
  nothing. A stored value that today's stricter rules would refuse is kept as it was. Only newly
  typed input meets the new rules.
- **Modal components:** at most 5 top-level components per modal. Mix text inputs,
  `FileUpload`, `CheckboxGroup`, `RadioGroup` and selects (≤25 options). When a step is full,
  add a step rather than cramming.
- **Placeholders** describe the empty and none cases in words, e.g. "비우면 기본 이미지 · 없음 또는 null을 쓰면
  이미지 없음 · https:// 주소를 쓰면 그 이미지". Write "없음 또는 null", never "없음/null" (it reads like
  "/null").
- **Optional fields:** a card needs a title or a body, not both (`/메시지` accepts either alone;
  panels need a title). Make inputs `required(false)` explicitly, because Discord text inputs
  are required by default.

## 3. Customise everything, in every command

The operator's rule: every customisation exists in every command. When you add an option to one
feature, add it to all of them through the shared module, then audit (design.md keeps a table of
every card and button and what it supports).

**Card (`ui::style`, the 꾸미기 step right after the content step):**
- **Title:** shown bold. A title starting with `# `, `## ` or `### ` is used as a Discord
  heading as-is.
- **Image rule (shared by every card):** empty means the default banner. `없음` or `null`
  (case-insensitive) means no image. An `https://` link means that image.
  - A file uploaded in the same modal (`FileUpload`: PNG, JPG, GIF, WEBP, up to 8 MB) wins over
    the link.
  - The bot stores uploads content-addressed (`data/images/<guild>/<sha256>.<ext>`, 0600) and
    re-attaches them as `attachment://` on every post and edit, because Discord attachment URLs
    expire.
  - Unreferenced files are garbage-collected at startup and every few hours. Count images used
    by open tickets as referenced.
  - In 수정, the field shows "첨부한 이미지 사용 중" while the upload is kept.
- **Accent colour:** empty means the default orange `#FF771F`. `없음` or `null` means no colour.
  `#RRGGBB` means that colour.
- **Dividers:** one checkbox per gap (below the image, below the title, above the bottom
  buttons), all on by default.

**Buttons (`features::buttons`, one module for every card):**
- **Label.**
- **Emoji:** one Unicode emoji or a server emoji `<:name:id>`, one parser (`ui::ButtonEmoji`).
  - Check Unicode input against a real emoji list (the `emojis` crate), capped at the newest
    version Discord's apps support (Emoji 15.1 as of 2026-10). ★ and similar symbols are
    refused in the wizard; Discord would reject the post with 50035.
  - If Discord still refuses the card, name the likely emoji and post nothing.
- **Colour:** 파랑, 회색, 초록, 빨강 (primary, secondary, success, danger). Link buttons are
  always grey, because Discord draws them that way.
- **Position:** in the card below the image, below the title or at the bottom, or outside the
  card. When the anchor is missing (no image or no title), move the button to the next position
  and say so in the preview.
- **Extra buttons on every card:** 0–10 link buttons or 안내 (notice) buttons.
  - A 안내 button answers ephemerally with stored text, so it keeps working after a restart.
  - It answers only on the message recorded for it. A post whose message id can't be saved is
    deleted again.
- **Per-feature colour UIs:**
  - Tickets: one colour select per button.
  - Role vending: a default colour plus "roles to make 파랑/회색/초록/빨강" lists, so the common
    case "all blue, these red" takes one modal.
  - Verification: name, emoji and colour in its own step.

**Defaults and compatibility:**
- Defaults reproduce the previous look and are not written into stored JSON (`#[serde(default)]`,
  skip when default), so old panels and imported data load and render unchanged.
- Cards that belong to a panel (results, captcha, ticket notices, wizard cards) follow that
  panel's accent. Error cards stay red.
- Leave things fixed only for a stated reason, and record it:
  - Discord allows no colour or emoji on select menus.
  - Link buttons are always grey.
  - System buttons are named in instruction texts.
  - Log colours encode the event type.

## 4. Limits and validation

- **Components:** at most 40 per message. Keep the wizard preview at 33 or fewer
  (`PREVIEW_PANEL_MAX`), leaving room for the wizard controls. Count after every step and refuse
  in Korean with a concrete hint, e.g. "역할 버튼 20개면 추가 버튼 1개까지".
- **Text:** at most 4,000 characters per message. Cap long inputs (a ticket intro at 500, answers
  at 700). Truncate summaries such as 확인 cards after the last whole line, with "…".
- **Other Discord limits:** 5 buttons per row, button label 80, `custom_id` 100, modal title 45,
  select options 25.
- **Tests run in CI (`cargo test`):**
  - Every step modal and the largest preview of every feature build and pass validation
    (`validate_step_modals`, `validate_preview_card`).
  - Old stored JSON loads and re-saves unchanged.
  - Worst-case fixtures use realistic 19-digit snowflakes and maximal emoji names.

## 5. Storage

- **Engine:** SQLite (`rusqlite` with `bundled`) in `data/` (0700).
  - One dedicated thread runs jobs in order: `Db::call(closure)` with a oneshot reply.
  - This means no `SQLITE_BUSY` and no blocking of Tokio workers.
  - Never await or do network calls inside a job.
- **Settings:** WAL mode, `synchronous=NORMAL`, foreign keys on.
- **Migrations:** an append-only list keyed by `user_version`. Never edit an entry after the
  first deploy.
- **Ids that appear in posted `custom_id`s** (panels, tickets, sent messages): use
  `AUTOINCREMENT`, so a deleted row's id is never reused by a new one.
- **Keys:** key everything by guild. Legacy ids imported from an older bot are `(kind, guild,
  legacy_id)`.
- **Long operations** (ticket close → transcript → channel delete):
  - Record status, a timestamp and a generation number.
  - A worker acts only while the row still holds its generation.
  - A stale claim expires, so a crash or a process swap can never leave a ticket stuck.

## 6. Feature patterns

- **Tickets:**
  - A panel has 1–5 buttons. Each button has its own category, staff roles, channel name format
    (`{번호}`, `{유저}`) and up to 4 questions.
  - The welcome card in the ticket channel is customisable: intro, image, accent, dividers, and
    label, emoji and colour for close, reopen, save and delete.
  - Closing swaps the close button for staff controls in one edit.
  - Saved tickets are archived locally with attachments (`data/transcripts/…`, capped, oldest
    pruned first) and indexed in SQLite.
  - `/티켓검색` autocompletes by user id, date, username or account name.
- **Role vending:**
  - Buttons or a dropdown (placeholder text customisable).
  - Per-role display `[emoji] name | description`.
  - Role changes for one member are serialised.
- **Verification:**
  - Methods: button, questions, or a real captcha image.
  - The captcha uses the `captcha` crate with the audio feature off. Codes are 4–8 characters
    (default 6). The picture is wide enough for the widest glyphs.
  - Retries are limited, and every attempt is logged.
- **Messages:** `/메시지` posts a card with buttons (§3). `/메시지 설정` holds per-server defaults.
- **Migrating from an older bot:**
  - An `import-<old-bot>` CLI with `--dry-run`, size limits and validation.
  - Legacy `custom_id` routing, so buttons the old bot posted keep working when the new bot runs
    as the same application.
  - Adopt the old bot's open tickets on first touch, with evidence matching.

## 7. Startup, deploy and no-downtime updates

- **Command registration:** register at startup over REST, not in `ready`. A process that resumed
  a session (§ handoff in [gateway-events-cache.md](gateway-events-cache.md)) gets no READY.
  Register globally by default; an optional dev-guild setting is for testing. Retry with backoff.
- **Hosting:** a Pterodactyl server with the Rust egg; the start command is `cargo run --release`.
  - The Wings user may be uid 0, so files in the volume are 0:0.
  - When container downloads are slow, vendor dependencies on the dev machine
    (`cargo vendor --locked`) and build offline (`.cargo/config.toml` with source replacement and
    `[net] offline = true`). Re-vendor whenever `Cargo.lock` changes.
- **No-downtime update:** the operator types `update` on the console, or the deploy script sends
  it through the panel API. The bot keeps serving throughout:
  1. Build as a child process (`nice`, `oom_score_adj=1000` so an OOM kills the build, not the
     bot; check `memory.oom.group`).
  2. Copy the binary to an immutable pinned path.
  3. Run the pinned binary with `--check`: config, plus migrations on a `VACUUM INTO` copy, no
     Discord connection. It must exit 0 and print a valid report.
  4. Wait for zero in-flight interactions, then hold new ones briefly.
  5. Freeze the DB thread between transactions, checkpoint, back up, and re-check against the
     frozen DB.
  6. Keep the previous binary and write the session file. If either fails, do not switch.
  7. `GatewayHandoff::request()` (close code 4000), then `take_sessions()`, written atomically
     with mode 0600.
  8. `exec` the pinned binary in the same PID.
  9. The new process uses `resume_sessions(..)` and gets RESUMED. Measured live: about 0.5 s.
- **Safety nets:**
  - If the new binary cannot open its config or DB, it restores the frozen backup and re-execs
    the previous binary.
  - Handled interaction ids travel in the session file (one expiring ledger), so a replayed
    interaction is not handled twice.
  - Refuse to start on a DB newer than the binary, or on an unfinished restore. Never create an
    empty DB next to existing backups.
- **Deploy script:**
  - Pack `git archive HEAD`.
  - Store vendor trees by `Cargo.lock` hash and verify checksums before installing.
  - Extract with `tar -m`, so cargo rebuilds even for older commits and rollbacks.
  - Pass ssh arguments through `printf %q`, because empty arguments vanish otherwise.
  - Back up a running DB only with the SQLite backup API (python3 when the `sqlite3` CLI is
    missing); copy files only after the server stops.
  - On restart, follow only the newly started container's log.
  - Read the panel token on the node into a variable and hand it to curl on stdin; never print
    it or put it in argv.
  - Offer `--restart` as the fallback, plus `--rollback <deploy>` and `--restore-db`.

## 8. Process

- **Before coding:** check for existing modules to reuse. Modularise so features share code
  rather than copy it.
- **Docs in the repo, updated with the code:**
  - `docs/design.md`: structure, step tables, the customisation audit table, and Decision Logs
    covering purpose, constraints, alternatives, choice, reason, and trade-offs.
  - `README.md`: run, test, deploy, rollback.
- **Gates:** `cargo clippy --all-targets -- -D warnings`, `cargo test`, and a check on the MSRV
  toolchain.
- **Review:** a different-family model (e.g. a GPT reviewer) reviews correctness before every
  production deploy, with severity, file:line and a failure scenario. Fix P0–P2 before shipping.
- **Never open a "passive" live gateway session with a production bot token.** Discord can route
  real users' interactions to it. Test with mocks or a separate dev application.
- **Disk:** use one shared `CARGO_TARGET_DIR` for all worktrees and delete targets of finished
  work. Per-worktree targets once filled a VM host's thin pool.
- **Customer-facing text:** Korean and plain. Never show internal vendor or stack names (billing
  panel, auth provider, captcha vendor…).

## 9. Checklist for a new feature

- [ ] Slash command action, routing line, `custom_id`s in `ids.rs` (≤100 chars).
- [ ] Wizard steps with prefill and validation in Korean. Unchanged 수정 is a no-op.
- [ ] Card uses the shared 꾸미기 step: image rule plus file upload, accent, dividers.
- [ ] Every button uses `features::buttons`: label, emoji, colour, position, extra buttons.
- [ ] Ephemeral results follow the panel accent; errors red.
- [ ] Component and text budgets enforced; tests for the largest config and old JSON.
- [ ] Permissions: Manage Server for management; public buttons for everyone; no
      `update_message` on public panels.
- [ ] Storage: append-only migration, guild-keyed, AUTOINCREMENT for ids in buttons.
- [ ] Docs (design.md table and Decision Log, README, `/도움말`), gates, cross-model review,
      deploy via `update`.
