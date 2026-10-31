# Plan: Logbook v2 — a Logbook window, then a meta agent that improves the agents

Status: 2026-10-31. D1–D10 ACCEPTED (owner). W0: DONE etd 82921c5, released 0.0.13, nixos-config 22568a4 (§8). A1: DONE etd da0bb5e, released 0.0.14, nixos-config ba48457 (§8). B3 can start. A2: DONE etd 8ef00bd, released 0.0.15, nixos-config 8d6a7fd (§8). A3: IN PROGRESS (trigkey). B1: DONE 3e49e03. B2: DONE 5a2a99b (stub; §8). B4: DONE 2c5f33f, TestFlight 202610311550. B5: DONE 0fe4c99 (stub), TestFlight 202610311600; signals JSON for A2 in §8. B3: DONE b758064 (etd 0.0.14), TestFlight 202610311617. B6: DONE 1603e8b (sample until A4), TestFlight 202610311642; Findings JSON additions for A4 in §8.

Follows [PLAN-logbook.md](PLAN-logbook.md) (L1–L5 built: capture, archive, read API, watcher report, Send to session, iOS) and [PLAN-multi-agent.md](PLAN-multi-agent.md) (M0–M5, in progress: profiles, one Rust parser per agent, live state with **needs you**).

Work split (changed from the earlier plans, so that more machines can work at the same time):

| Track | Who | Does |
|---|---|---|
| **A** | Any machine's agent (trigkey, gmktec, a RackNerd VPS, …) | etd, et-proto, et-link. Each A package is a separate unit that one machine claims (§6). |
| **B** | The **mac-mini** agent only | ET (iOS / iPad) and ET-mac code, Swift stubs, builds, TestFlight, `Vendor/etd` bumps, darwin-rebuild on mac-mini. |
| **C** | The owner | Decisions (§3), tests (§7). |

## 1. Goal

1. **The sidebar stops being a wall of rows.** Today the Mac sidebar shows every transcript (21 now, 3 live) as `machine/claude` rows with a dot, a branch and a time. The owner cannot use it.
2. **A dedicated Logbook interface.** A separate window on the Mac (iPad: a split view, iPhone: a stack). It answers, in this order: *what needs me*, *what runs now*, *what each project is doing*, *what a session said*.
3. **A meta agent.** It reads all transcripts of all machines and all agents, finds where the agents go wrong again and again (the owner interrupts, corrects, denies a tool, repeats an instruction), and proposes changes to the agents' instructions (`CLAUDE.md`, memory, skills, `AGENTS.md`). The owner accepts a change once; it goes to every machine. The next run shows if the change helped.

| Where | What the owner does | Result |
|---|---|---|
| Mac main window, sidebar | Looks at one **Logbook** row | "2 need you · 3 running". Click opens the Logbook window. |
| Logbook window → **Now** | Looks | Live sessions of all machines: a headline, the last thing asked, the last thing said. Needs-you first. |
| Logbook window → a project | Clicks | The project's goal, next steps, and its sessions as short cards. |
| Logbook window → a session | Clicks | The transcript. Machine, cwd, branch and ids are in an inspector (⌘I), hidden by default. |
| Logbook window → **Findings** | Clicks **Run** | The meta agent's findings, each with evidence (links into transcripts) and a proposed change as a diff. |
| A finding | **Apply on all machines** / **Send to agent…** / **Reject** | The file changes on each machine (with a backup), or an agent session gets the proposal to do it, or the meta agent does not propose it again. |
| Findings → **Applied** | Looks | "Since 2026-11-02: interrupts in etd sessions 6 → 1." |

## 2. Facts that decide the design (checked 2026-10-31 on trigkey)

| Fact | Where | Effect |
|---|---|---|
| The archive has **21 transcripts, 3 live**. 7 are from one manymux session (`gmktec/claude`) on 7 different goals. | `etd logbook` on trigkey | A transcript is the right unit, not the manymux session. Most rows are old: hide `gone` sessions older than 7 days by default. |
| **Every** cwd is the home folder (`/home/eric`, `/Users/ericsharma`). `repo` and `branch` are null for all 21. | `index.json` | Grouping by repo (the view before a report) puts all sessions in one group "~". Branch and cwd carry no information: remove them from rows. |
| `machine/mm session` labels are `trigkey/claude`, `mac-mini/claude2`, `gmktec/claude`. | `index.json` | The label tells nothing. The headline must come from the content. |
| Claude's own `title` exists for 11 of 21. Some are bad ("Study @etd and @et-", "Status check"). | `index.json` `title` | Headline = title, else the first prompt cut to 60 characters. The digest (watcher stage 1) replaces both when it exists. |
| A short transcript ("Status check", 169 bytes) is noise. | `index.json` | Mark `trivial` (< 2 prompts). Hide by default. |
| The sidebar Logbook section has: header + Refresh, a report row with progress and suggestions, groups with `●n`, and per session up to 3 lines. | `App/Mac/Sources/LogbookSidebar.swift` | Replace the whole section with one row (D1). |
| The Mac app already opens extra windows: `Window("Send Files", id: "send")`, `Window("Debug Log", id: "log")`. The toolbar has a **Logbook** button. | `ETMacApp.swift:69`, `MainWindow.swift:41` | A `Window("Logbook", id: "logbook")` is a small change. The toolbar button opens it. |
| The views are shared Mac + iOS in `App/LogbookUI/`. The model is `Logbook` (`@Observable`). | `App/LogbookUI/Logbook.swift` | Build the new window from the same model and views. iOS gets the same columns. |
| `Agents` and `Report` answers carry a **JSON string**, not a postcard struct. | `server.rs:570–573` | New answers carry JSON too. A can add a JSON field without breaking an installed app. B decodes with `decodeIfPresent`. |
| Postcard enums are positional. `Request::Agents` is the last variant now. PLAN-multi-agent reserves `SessionAgents` (M3) next. | `et-proto/src/lib.rs` | Two parallel packages that each append a variant collide. **W0 appends all new variants in one commit** before the A packages start (§5). |
| Friction is in the transcripts and is easy to find: 18 `[Request interrupted by user`, 8 tool denials ("The user doesn't want to proceed"), 73 tool errors (`is_error: true`), 6 compactions, in 2 256 user lines. | grep over the archive | A Rust pass can find signals with no model (A2). The model gets only the signals with context, not 92 MB. |
| Agent instructions are **different on each machine**: trigkey has 52 memory files, mac-mini has 8. Skills are one git repo synced every 15 min (`~/.claude/skills`). | `ls ~/.claude/projects/*/memory` via `etd-ssh` | The meta agent must see each machine's config. A plain diff between machines is a finding with no model ("drift"). Git-tracked files must change through git, not through a direct write. |
| The watcher already runs a headless agent with no tools on the archive, with digests cached by offset. | `logbook/watcher.rs` | The meta agent reuses `Model`, the digests, the progress frames and the decision store pattern (`projects.json`). |
| Send to session already types a file path into any session. | `LogSend`, PLAN-logbook L4 | "Send to agent…" for a proposal needs only a new `LogSelection` variant. No new transfer code. |

## 3. Decisions (ACCEPTED by the owner, 2026-10-31)

| # | Question | Proposal |
|---|---|---|
| D1 | Main window sidebar | **One row**: "Logbook · 2 need you · 3 running". Click opens the Logbook window. Remove the session rows, groups, report row and Refresh from the sidebar. (Other options: no row, toolbar button only; or a row per live session.) |
| D2 | Where the Logbook lives on the Mac | **A separate window** (`⌘⇧L`), so a terminal and the Logbook are side by side. The main window's detail column no longer shows Logbook pages. The Agents page stays in the main window. |
| D3 | Columns | 3 columns: **Places** (Now, Findings, projects, Unsorted, Archive) → **Cards** → **Transcript**. iPad: the same in a `NavigationSplitView`. iPhone: a stack. |
| D4 | What a session card shows | Headline, "You: <last prompt>", "<Agent>: <first line of last reply>", state, machine as a small chip, "3m ago". Nothing else. Friction counts as small marks when > 0. |
| D5 | What is hidden by default | `gone` sessions older than 7 days (in **Archive**), trivial sessions (< 2 prompts), and all ids, bytes, cwd, branch (in the inspector, ⌘I). |
| D6 | Fresh headlines | Free first: title / first prompt / last prompt / last reply come from etd with no model (A1). The digest replaces the headline when a report made one. No automatic model runs (PLAN-logbook D8 stays). |
| D7 | Meta agent cadence | **On demand** (Run button), plus an **optional** nightly run on the archive (off by default, `etd meta schedule on`). |
| D8 | How a change is made | Never automatic. The owner accepts each change. Two paths: **direct write** for files not in git (global `CLAUDE.md`, memory files), with a backup and a base hash check; **Send to agent…** for git-tracked files (skills repo, a repo's `CLAUDE.md` / `AGENTS.md`), so an agent commits and pushes as the owner's rules say. |
| D9 | What the meta agent may change | Allow-list: `~/.claude/CLAUDE.md` and the files it imports with `@`, `~/.claude/projects/*/memory/*.md`, `~/.claude/skills/**/SKILL.md`, and each agent profile's instruction file (`AGENTS.md`, `GEMINI.md`, …). **Never**: `settings.json`, hooks, shell rc files, keys. For those it can only write a note ("add `Bash(cargo test:*)` to allow") with no apply button. |
| D10 | Who runs the meta agent | The same agent as "Report written by" (PLAN-multi-agent D7). Default Claude Code headless, no tools. etd builds its whole input. |

## 4. Design

### 4.1 Mac Logbook window

```
┌ Logbook ─────────────────────────────────────────────────────────────────────────────────┐
│ ● Now          3 │ Now                                │ Sonarr fan edits of Naruto   gmktec │
│ ⚑ Findings     2 │                                    │ ● busy · Rebuild of Naruto     ⓘ    │
│                  │ ◉ Rebuild of Naruto        gmktec  │ ─────────────────────────────────── │
│ PROJECTS         │   Sonarr fan edits of Naruto  3m   │ You  replace S03E01 and reindex     │
│ ● E.T. Logbook   │   You: replace S03E01 and reindex  │ Claude  Replaced. Reindex runs…     │
│ ● Native macOS   │   Claude: Replaced. Reindex runs…  │   ▸ 4 tool calls                    │
│ ● Naruto         │ ○ E.T. Logbook          mac-mini   │ You  check the quality table        │
│ ◌ Media drive  ⚠ │   L4 and L5 views         idle 12m │ …                                   │
│ ○ Guitar AU      │   You: build and send to TestFlight│                                     │
│ Unsorted       4 │   Claude: Build 202610281807 is up │ [Show Terminal] [Send…] [⏸ Record]  │
│ Archive       14 │   ⚡2 interrupts                    │                                     │
└──────────────────┴────────────────────────────────────┴─────────────────────────────────────┘
  ◉ needs you   ● busy   ○ idle   ◌ blocked project   ⚡ friction
```

- **Now**: live sessions of all projects. Needs-you first (from PLAN-multi-agent M3; before M3: busy, then idle).
- **A project**: a header with goal, status and **Next** (from the report), then its cards. Report Refresh and suggestions move here (a project's header and a toolbar button), not in a sidebar.
- **Unsorted**: sessions the report did not place, and all sessions before the first report.
- **Archive**: everything, newest first, with search on headline and prompts.
- **Transcript**: as today (`LogbookTranscriptView`), with the noisy header replaced by headline + state + project. A friction mark in the scroll bar jumps to the turn (A2).
- **Inspector (⌘I)**: machine, manymux session, cwd, branch, session id, previous id, bytes, first/last time, Copy Session ID.

### 4.2 iOS and iPad

Entry stays ⋯ → **Logbook**. iPad: the same 3 columns. iPhone: Places → Cards → Transcript as a stack. Same model, same JSON.

### 4.3 Meta agent

Four stages. Stage 1 and the drift check need no model.

```
archive etd (trigkey)
1. signals   Rust pass over each transcript that grew → signals.jsonl (kind, key, turn uuid, time, excerpt)
2. config    AgentConfig to every machine → snapshot (files, sha256, content) → drift (no model)
3. findings  headless agent, no tools: signals with context + digests + config snapshot
             + past decisions → findings + proposals (JSON)
             etd checks each proposal: path in the allow-list (D9), patch applies to the
             base sha, no secret patterns. A failed check drops the proposal (logged).
4. follow-up for each applied proposal: the signal counts before and after (no model)

app ── Accept ──▶ archive etd ── ConfigWrite (base sha, content) ──▶ each target machine
                                  (backup to ~/.local/share/etd/config-backups/<time>/)
app ── Send to agent… ──▶ LogSend(Finding) ──▶ Markdown file + path typed into a session
```

Signal kinds (Claude first; one function per agent next to its `Reader`):

| Kind | Source in the JSONL |
|---|---|
| `interrupt` | user text starts with `[Request interrupted by user` |
| `denied` | `tool_result` text "The user doesn't want to proceed with this tool use" |
| `tool-error` | `tool_result` with `is_error: true` |
| `repeat-error` | the same tool + input fails 3 times in a row |
| `correction` | an owner prompt right after a reply that starts with: no, don't, stop, wrong, I said, again, not what (the model confirms or drops it in stage 3) |
| `compact` | `"subtype":"compact_boundary"` |
| `asked-needlessly` | a reply that ends in a question, and the owner's next prompt is only yes / do it / go / ok |

Findings JSON (stage 3 answer, after etd's checks):

```json
{ "id": "1793400000", "taken": 1793400000,
  "findings": [ {
    "id": "asks-before-tests", "title": "Claude asks \"Run the tests?\" instead of running them",
    "kind": "asked-needlessly", "count": 5, "sessions": 4,
    "evidence": [ { "key": "trigkey/3427a93a-…", "turn": "<uuid>", "excerpt": "…" } ],
    "proposals": [ {
      "id": "p1", "route": "write | agent | note",
      "targets": [ { "machine": "trigkey", "path": "~/.claude/CLAUDE.md", "base": "<sha256>" } ],
      "patch": "unified diff", "why": "…", "expect": "asked-needlessly drops in new sessions" } ] } ],
  "drift": [ { "path": "~/.claude/projects/-home-eric/memory/", "machines": { "trigkey": 52, "mac-mini": 8, "gmktec": 0 } } ],
  "followup": [ { "proposal": "p0", "applied": 1793300000, "kind": "interrupt", "before": 6, "after": 1 } ] }
```

Decisions are kept in `meta/decisions.json` (same pattern as `watcher/projects.json`): accepted, rejected (never proposed again for the same finding id), edited.

### 4.4 Protocol (et/1, appended in **W0**, all in one commit)

The numbers are given in W0 at the end of the enum as it is then. If PLAN-multi-agent `SessionAgents` lands first, these come after it.

```
Request::LogOverview { since: u64 }                  // archive → Response::Overview { json }   (§4.5)
Request::LogSignals  { since: u64 }                  // archive → Response::Signals  { json }
Request::AgentConfig                                 // ANY machine → Response::AgentConfig { json }
Request::Meta        { refresh: bool }               // archive → ReportProgress frames, then Response::Meta { json }
Request::MetaDecision { json: String }               // archive → Pong
Request::ConfigWrite { path: String, base: String, content: String } // ANY machine → Response::ConfigWritten { backup }
LogSelection::Finding { run_id: String, finding_id: String }        // appended to the existing enum, used by LogSend
```

- `AgentConfig` and `ConfigWrite` answer on every machine (members only, as every request). `ConfigWrite` refuses a path outside the allow-list (D9) and a `base` that does not match the file now (someone changed it).
- In W0, every handler answers `Response::Error("not built yet: <package>")`, so B can call the real API at once and get a clear error.

### 4.5 et-link (the A ↔ B contract)

B writes `App/Shared/LogbookV2Stub.swift` with these exact names and fixture JSON. A makes the real one match. JSON fields are read with `decodeIfPresent`; A may add fields, never rename.

```rust
// RemoteHost, on the archive:
async fn logbook_overview(&self, since: u64) -> Result<String, LinkError>;
async fn logbook_signals(&self, since: u64) -> Result<String, LinkError>;
async fn meta(&self, refresh: bool, progress: Arc<dyn ReportProgress>) -> Result<String, LinkError>;
async fn meta_decision(&self, decision_json: String) -> Result<(), LinkError>;
// RemoteHost, on any machine:
async fn agent_config(&self) -> Result<String, LinkError>;
async fn config_write(&self, path: String, base: String, content: String) -> Result<String, LinkError>; // backup path
// LogSelection gains: Finding { run_id: String, finding_id: String }
```

Overview JSON (one entry per transcript; the app joins it with the report by `key`):

```json
{ "sessions": [ {
    "key": "gmktec/05d5ccad-…", "agent": "claude", "machine": "gmktec", "mm": "claude",
    "headline": "Sonarr fan edits of Naruto", "headline_from": "title | prompt | digest",
    "asked": "replace S03E01 and reindex", "said": "Replaced. Reindex runs now.",
    "state": "busy | idle | needs-you | gone", "prompts": 42, "trivial": false,
    "friction": { "interrupt": 2, "denied": 0, "tool-error": 5 },
    "first": 1793211625, "last": 1793277192 } ] }
```

`friction` is empty until A2 is in. `state` = `needs-you` only after PLAN-multi-agent M3.

## 5. Work packages

Times are for the agent that runs the package. ✅ = the owner can see it work. "Starts when" is the only order. All other packages run at the same time on different machines.

### Wave 1 — now

| Pkg | Track | Starts when | Work | Time |
|---|---|---|---|---|
| **W0** | A (one machine) | owner accepts §3 | Append all §4.4 variants in et-proto + `PROTOCOL.md`. Empty handlers in `server.rs` that call one function per new module (`logbook/overview.rs`, `logbook/signals.rs`, `agentcfg.rs`, `meta/mod.rs`), each answering "not built yet". All §4.5 et-link methods. Swift names checked with uniffi-bindgen. Release etd (next patch), deploy trigkey + gmktec. | ~2 h |
| **B1** | B | now | Sidebar: delete `LogbookSection`, add one `LogbookRow` (D1) that counts from the current `logbook.sessions` (busy/idle). Toolbar **Logbook** button opens the window (empty for now). ✅ The sidebar has one Logbook row. | ~1 h |
| **B2** | B | now | `LogbookV2Stub.swift` with §4.5 names + fixtures made from the real archive (hand-written from §2 and §4.5; A1 makes `etd logbook overview --json` for real fixtures). `Window("Logbook", id: "logbook")` with the 3 columns, Now / projects / Unsorted / Archive, cards (D4), filters (D5), inspector. Transcript column reuses `LogbookTranscriptView` with the new header. | ~1 day |

### Wave 2 — after W0 is released

| Pkg | Track | Starts when | Work | Time |
|---|---|---|---|---|
| **A1** | A (any machine) | W0 | `logbook/overview.rs`: headline, asked, said, prompts, trivial per transcript; cached by offset in `overview.json`. `etd logbook overview [--json]`. Tests with fixture JSONL. ✅ `etd logbook overview` on trigkey shows a clear line per session. | ~½ day |
| **A2** | A (any machine) | W0 | `logbook/signals.rs`: the §4.3 signal kinds for Claude, cached by offset in `meta/signals.jsonl`; `LogSignals`; fill `friction` in the overview (one small edit in `overview.rs` after A1, or a merge with A1 if both land the same day). Fixture test per kind. `etd meta signals`. | ~1 day |
| **A3** | A (any machine) | W0 | `agentcfg.rs`: the D9 allow-list (from agent profiles + Claude paths), `AgentConfig` (files, sha256, size, mtime, content ≤ 64 KB each, `git: true` for a git-tracked file), `ConfigWrite` (base check, backup, mode kept). On the archive: `etd meta drift` (diff of all machines' snapshots, no model). Test: a changed base is refused; a path outside the list is refused. | ~1 day |
| **B3** | B | W0 + A1 released | Bump `Vendor/etd`. Logbook window on the real overview; delete the overview part of the stub. ✅ The Logbook window on mac-mini shows trigkey, gmktec and mac-mini sessions with real headlines. | ~½ day |
| **B4** | B | B2 | iPad split view and iPhone stack with the same views; replace `LogbookScreen`'s list. TestFlight. | ~1 day |
| **B5** | B | B2 (stub) | Friction marks on cards and in the transcript scroll bar; "jump to turn". Real data after A2. | ~½ day |

### Wave 3 — the meta agent

| Pkg | Track | Starts when | Work | Time |
|---|---|---|---|---|
| **A4** | A (any machine) | A2 + A3 | `meta/`: stage 3 prompt (signals with ±2 turns of context, digests, config snapshot, decisions), JSON answer, the checks (allow-list, patch applies, secret patterns), `Meta` with progress frames (reuse the watcher's `Model` and heartbeat), `MetaDecision`, `meta/decisions.json`, `LogSelection::Finding` Markdown for `LogSend`. `etd meta run`. First real run on trigkey; paste the findings into this plan (§8). | ~1½ days |
| **B6** | B | B2 (stub); real after A4 | **Findings** place: finding cards with evidence links (open the transcript at the turn), the diff, Apply on all / Send to agent… / Edit / Reject, progress while it runs. Apply calls `config_write` on each target machine with its `base`; a machine that is offline shows "not applied on gmktec · Retry". | ~1 day |

### Wave 4 — close the loop

| Pkg | Track | Starts when | Work | Time |
|---|---|---|---|---|
| **A5** | A (any machine) | A4 | Follow-up (stage 4): signal counts before / after each applied proposal, in the `Meta` JSON. Optional nightly run (D7): `etd meta schedule on` writes a systemd user timer / launchd agent on the archive. **Undo**: `ConfigWrite` of the backup. | ~½ day |
| **B7** | B | A3 (drift), A5 (follow-up) | **Applied** list with before / after and Undo. Drift view: one row per file that differs between machines, with "Make the same as <machine>" (a proposal with route `write`). | ~½ day |

### Order at a glance

```
Wave 1   W0 (A, one machine) ─────────┐        B1 ─ B2 (mac-mini, on stubs)
Wave 2   A1 ─┐   A2 ─┐   A3 ─┐ (3 machines)    B3 (needs A1)  B4  B5
Wave 3        └──────┴─ A4 ──┘                  B6 (stub first, real after A4)
Wave 4                  A5                      B7
```

## 6. Rules for agents that work at the same time

1. **Claim before you start.** In `~/et-ios`: `git pull`, change the package's line in the Status line at the top of this file to "A2: IN PROGRESS (gmktec)", commit, push. If the push fails or the package is claimed, take a different package.
2. **etd: commit on main.** `git pull --rebase` before each push. A packages touch only their own new module and its tests. `server.rs`, `et-proto/src/lib.rs` and `et-link/src/lib.rs` change only in W0. If a package needs a change there, it writes it in this plan and stops for the owner.
3. **Release one at a time.** Take the next patch version at push time ("release: etd 0.0.N (<package>)"). If the tag exists, pull and take the next number. Deploy trigkey + gmktec (nixos-config) as in PLAN-logbook.
4. **B owns the apps and `Vendor/etd`.** B bumps `Vendor/etd` to the newest release when it needs a package. B never changes Rust. An A agent never changes Swift.
5. **When done**, change the Status line to "A2: DONE <commit>, released 0.0.N" with one line of results, and push.

## 7. Tests (owner, C)

1. After B1 + B3: the main window sidebar has one Logbook row. The Logbook window opens with ⌘⇧L. **Now** shows only live sessions. Each card's headline says what the session does.
2. Interrupt a Claude session twice (Esc). After A2: the card shows ⚡2, and the mark jumps to the turn.
3. After A4: **Run** in Findings. Each finding has evidence that opens the right turn. No proposal touches `settings.json`.
4. Apply a `CLAUDE.md` proposal on all machines. Check `~/.claude/CLAUDE.md` on trigkey, gmktec and mac-mini, and the backup folder. Edit `CLAUDE.md` on gmktec by hand, then Apply a second proposal: gmktec refuses (base changed), the others apply.
5. **Send to agent…** a skill proposal into a session on trigkey: the agent changes the skill, commits and pushes. After A5: a week later, **Applied** shows before / after.

## 8. Results

(Each package adds its results here.)

**A2 (2026-10-31, trigkey):** etd 8ef00bd, release 0.0.15 (07ffd4f), deployed trigkey + gmktec (nixos-config 8d6a7fd). `LogSignals` answers B's JSON exactly (`kind`, `key`, `turn`, `uuid`, `time`, `excerpt`); `since` = all signals of each changed transcript. `turn` follows the Swift `Transcript.parse` code, not the note in B5: a `isCompactSummary` line and a `<task-notification>` DO start a turn there (only `isMeta`, `isSidechain`, `<command-`, `<local-command`, `[Request interrupted` do not), so they do here too. Kinds as §4.3; `denied` is not also a `tool-error`; `repeat-error` once per streak at the 3rd failure. The overview's `friction` = counts by kind (overview.rs calls `signals::scan`). Cache `logbook/signals.json` (scan state per transcript). Real archive: 83 signals (tool-error 57, interrupt 9, denied 7, compact 6, correction 2, asked-needlessly 2) in 13 of 22 transcripts; first scan 15.8 s (debug build), then only new lines. Heuristic misses seen: "Should I delete the 26 GB folder? → yes" is `asked-needlessly` (a real question): A4's model must drop such. B: delete `logbookSignals` from the stub after the `Vendor/etd` bump to 07ffd4f.

**A1 (2026-10-31, trigkey):** etd da0bb5e, release 0.0.14 (e3bc2ca), deployed trigkey + gmktec (nixos-config ba48457). `LogOverview` answers the §4.5 JSON with the stub's exact fields. Headline order: the digest's "Goal:" line (`headline_from: digest`), else the agent's title, else the first prompt (100 characters, cut at a word with "…"). `asked` / `said`: first line that is not only a tag (a paste's wrapper), 200 characters. Not prompts: slash commands, `[Request interrupted by user`, `<task-notification>`, `Caveat:`. `trivial` = `gone` and fewer than 2 prompts (a new live session is never hidden). Newest first. Cache `logbook/overview.json` (offset per transcript): on the real archive (22 transcripts, 98 MB) the first build takes 4.9 s (debug), then 12 ms. `etd logbook overview [--json]` on trigkey gives real fixtures for B. For B3: delete `logbookOverview` from `LogbookV2Stub.swift` after the `Vendor/etd` bump to e3bc2ca.

**W0 (2026-10-31, trigkey):** etd 82921c5, release 0.0.13 (120bcd9). Requests 34 `LogOverview`, 35 `LogSignals`, 36 `AgentConfig`, 37 `Meta`, 38 `MetaDecision`, 39 `ConfigWrite`; `LogSelection::Finding` = index 2. A test (`et-proto` `logbook_v2_request_numbers`) keeps the numbers. Each answers `Error("not built yet: … (PLAN-logbook-v2 <package>)")` (test `etd/tests/logbook_v2.rs`). Modules for the packages: A1 `crates/etd/src/logbook/overview.rs`, A2 `logbook/signals.rs`, A3 `crates/etd/src/agentcfg.rs`, A4 + A5 `crates/etd/src/meta/mod.rs`; CLI arms are in `main.rs` already (`etd logbook overview [--json]`, `etd meta signals|drift|run [--refresh]|schedule on|off`). et-link: `logbook_overview`, `logbook_signals`, `meta`, `meta_decision` (logbook.rs), `agent_config`, `config_write` (new `agentcfg.rs`). Swift names checked with uniffi-bindgen on Linux: `logbookOverview(since:)`, `logbookSignals(since:)`, `meta(refresh:progress:)`, `metaDecision(decisionJson:)`, `agentConfig()`, `configWrite(path:base:content:)`, `LogSelection.finding(runId:findingId:)`. Release 0.0.13 also carries the unreleased PLAN-multi-agent commits (f98347b, 8503d4d, 653013a). PLAN-multi-agent `SessionAgents` now takes 40.

**B1 (2026-10-31, mac-mini):** et-ios 3e49e03. The sidebar's Logbook section is one row, "Logbook · 3 running · 2 busy" (needs you once etd sends `needs-you`). The row, the toolbar's Logbook button and ⌘⇧L open `Window("Logbook")`.

**B2 (2026-10-31, mac-mini):** et-ios 5a2a99b, not yet on TestFlight / a Mac release. 3 columns in `App/LogbookUI/LogbookWindow.swift` (shared with iOS; `LogbookPlaces.swift` has the place logic): Now, Findings (empty until A4), Suggestions, the report's projects (goal, progress, Next over the cards), Unsorted, Archive (search). Cards per D4, filters per D5, inspector ⌘I. The main window shows only Agents in place of the terminal (D2). `App/Shared/LogbookV2Stub.swift` has W0's exact Swift names: `logbookOverview` is built on the device from the real archive (session list + the last 256 KB, 1 MB or 4 MB of each changed transcript, until one has a prompt), the other five throw "not built yet". Checked headless on mac-mini on the real archive (22 sessions; Now 3, Unsorted 6 after the trivial filter). iOS target builds; the iPad/iPhone screens are B4.
Notes for A1, from the stub on real data: (1) skip prompts that are not the owner's (`<task-notification>`, `<command-…>`, "This session is being continued from a previous conversation…") for both `headline` and `asked`; one session got the headline "<task-notification>". (2) A long session's last 256 KB is often only tool output; the prompt can be MBs back, so `asked` needs the last *prompt*, not the last N bytes. (3) Several gmktec sessions parse to 0 turns (`dd523b22`, 71 lines from 0): worth a fixture.

**B4 (2026-10-31, mac-mini):** et-ios 2c5f33f, TestFlight 202610311550 (owner test pending). ⋯ → Logbook is `LogbookWindow` in a full-screen cover: 3 columns on iPad, a stack on iPhone (starts at places). Show Terminal opens the session's page. The v1 list views (`LogbookReportView`, `ProjectCard`, `LogbookSessionRow`, `Logbook.groups`) are deleted.

**B5 (2026-10-31, mac-mini):** et-ios 0fe4c99, TestFlight 202610311600. Cards show a symbol + count per kind from the overview's `friction`. The transcript shows marks per turn, a strip of ticks beside the scroll bar (click → scroll to the turn, outlined 1.5 s), and a header menu listing every signal. The app polls `logbook_signals(since)` with the overview. Until A2, the stub finds interrupt / denied / tool-error / compact in the overview's tails (real data: 9 signals in 7 transcripts, mostly tool errors).
**Signals JSON, B's proposal for A2** (the app decodes this; fields read with `decodeIfPresent` except `kind` and `key`):
```json
{ "signals": [ { "kind": "interrupt", "key": "trigkey/3427a93a-…", "turn": "<uuid of the prompt that starts the turn>",
                 "uuid": "<uuid of the line with the signal>", "time": 1793277192, "excerpt": "[Request interrupted by user]" } ] }
```
- `turn` must be the uuid that `Transcript.parse` uses as the turn id: the last owner prompt before the signal (`type: user`, text content, not `isMeta`, not `isCompactSummary`, not `<command-`, `<local-command`, `[Request interrupted`). Before the first prompt: `"leading"`. The app jumps by this id.
- `since`: **all** signals of each transcript that changed at or after `since` (the app replaces that transcript's list), as the overview does.
- `friction` in the overview = the counts of these signals by `kind`.

**B3 (2026-10-31, mac-mini):** et-ios b758064, `Vendor/etd` e3bc2ca (0.0.14), TestFlight 202610311617. The Logbook window on mac-mini shows trigkey, gmktec and mac-mini sessions (22) with etd's headlines (checked headless; "<task-notification>" headlines are gone). `LogbookV2Stub.swift` keeps only the device-side signal finder: `IrohHost.logbookSignals` uses it while etd answers "not built yet", and cards count friction from the signals while the overview's `friction` is empty. After A2: delete the file and the fallback in `Iroh.swift`.

**B6 (2026-10-31, mac-mini):** et-ios 1603e8b, TestFlight 202610311642. Findings place in `App/LogbookUI/LogbookFindings.swift`: Run with progress, finding cards (kind, count, sessions), evidence links that open the transcript beside the findings and scroll to the turn (loading earlier parts until it has it), proposals by route with the diff, Apply on All Machines / Edit… / Send to Agent… / Reject. Until A4, `meta` answers "not built yet" and the place shows a sample made from the real signals (A2 is live: 57 tool errors in 13 sessions on the archive). Checked headless: the evidence link jumps to its turn; Apply on the sample was refused on all 6 machines, each with its reason and Retry. **mac-mini and the MacBook Air run etd 0.0.12**: ConfigWrite there needs a darwin-rebuild (owner) before test 4 of §7.
**Additions for A4** (the app reads these; all optional except `id`):
- Each target carries `"content"`: the whole file after the patch, as etd checked it against `base`. Apply sends `config_write(path, base, content)`; the app does not apply diffs itself. Edit… lets the owner change `content` per machine before Apply.
- `MetaDecision` JSON from the app: `{"run": "<run id>", "finding": "<id>", "proposal": "<id>", "decision": "accept | edit | reject", "applied": ["trigkey", "gmktec"], "content": {"trigkey": "<edited file>"}}`. `proposal` is missing when a whole finding is rejected; `applied` lists the machines whose `config_write` succeeded (Apply sends it once, after the writes); `content` only for `edit`.
- `meta(refresh: false)` with no run yet: `{"id": null}` (as the report does).
- Evidence `turn` is a prompt uuid, as in the signals JSON (B5).

## 9. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| **Prompt injection through transcripts.** Tool output (web pages, files) is in the transcripts. The meta agent reads it and can propose a bad instruction. An accepted change goes into every machine's `CLAUDE.md`, so every future session reads it. | Persistent bad instructions on all machines | The model has no tools. Every change needs the owner's Accept with the full diff shown. Allow-list (D9) excludes settings, hooks, shell files. Secret-pattern check. Backup + Undo. No auto-apply, not even in the nightly run (it only makes findings). |
| Proposals leak secrets from transcripts into config files that go into git (skills repo) | A secret in a GitHub repo | Secret-pattern check in A4 before a proposal reaches the app. Git-tracked files change only through an agent (D8), which runs its own checks before a commit. |
| `ConfigWrite` is a new way to write files on every machine | A larger attack surface | Members can already run a shell on every machine (SECURITY.md); this adds no new power. Allow-list, base check, backup. Document in SECURITY.md (A3). |
| Meta runs use the subscription limits | Other sessions slow down or stop | On demand by default (D7). Stage 1 and drift need no model. Only signals with context go to the model, not whole transcripts. |
| Heuristic signals are wrong (a "no" that is not a correction) | Noise in findings | Stage 3 confirms or drops `correction` and `asked-needlessly`. A rejected finding is not proposed again. |
| Parallel A packages edit the same files | Merge conflicts, enum index clash | W0 makes all shared-file changes first (§6 rule 2). |
| PLAN-multi-agent M2 moves transcript parsing into Rust | Two parsers for a time | A1 and A2 use etd's existing `render` code path (`watcher.rs`). When M2 lands, they switch to `parse_turns`. The app keeps `Transcript.swift` until M2-B. |
