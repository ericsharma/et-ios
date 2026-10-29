# PLAN-agents: every Claude agent, its login and its usage limits

Status: 2026-10-28. AG1 DONE (app only, et-ios). AG2 (etd) is a proposal for A.

Next: [PLAN-multi-agent.md](PLAN-multi-agent.md) makes this page and AG2 work for every agent vendor (Codex, Gemini CLI, Grok Build), not only Claude.

## 1. Goal

The owner sees every Claude agent on the E.T. network in one place:

- the Claude login of each machine (what Claude's `/status` shows: email, organization, plan);
- the usage limits of each login (what `/usage` shows: the 5-hour and weekly limits, in percent, with the reset times);
- each running agent: its machine and manymux session, busy or idle, model, context size, Claude Code version, folder.

The session view shows the same line for the agent in that session.

## 2. Where the data comes from

| Data | Source on the machine |
|---|---|
| Login | `oauthAccount` in `~/.claude.json` |
| Plan | `claudeAiOauth.subscriptionType` and `rateLimitTier` in the credentials (macOS keychain item "Claude Code-credentials", Linux `~/.claude/.credentials.json`) |
| Usage limits | `GET https://api.anthropic.com/api/oauth/usage` with the login's token (what `/usage` calls) |
| Running agents | `~/.claude/sessions/<pid>.json` (pid, sessionId, cwd, status, version), the process's `MM_SESSION`, its parent pid |
| Model, context | the last assistant line of the transcript |

The token never leaves the machine. Only the answer (no token) goes to the app.

## 3. AG1: app only (done)

- `App/AgentsUI/Agents.swift`: the model and the script. The app runs the script on each connected machine with etd's exec (`IrohHost.run`). It needs `jq` and `curl`. A machine with no `~/.claude` answers "no Claude".
- Refresh: when a view that shows agents appears, then every 60 s while it is shown. The usage API is asked at most once a minute per machine.
- Claude's status "shell" is shown as busy, "waiting" as idle.
- A Claude process whose parent is pid 1 (its manymux session ended) is listed under "with no session".
- Mac: sidebar "Agents" row (under Files), toolbar buttons Agents and Logbook, the Agents page, and a line over the terminal of a session where Claude runs.
- iOS: ⋯ → Agents, and the same line over the terminal.

## 4. AG2: in etd (proposal for A)

The script works, but etd can do it better:

1. etd reads the same data, so `jq` is not needed (racknerd has none).
2. etd asks the usage API at most once a minute and keeps the answer, so many apps do not each ask.
3. et-link gets `agents() -> [AgentsInfo]`, one call to the hub for all machines.

The app keeps the same views. Only `Agents.refresh` changes.
