---
name: project-map
argument-hint: "[ROOT]"
description: Build or refresh the one-page HTML project map for any project in your home folder (/project-map [ROOT]). Cheap when nothing changed.
---

# /project-map [ROOT]

Makes or refreshes a one-page map of a project: where it stands, what is stuck, what needs the owner's decision.
Call it three ways: `/project-map` (the current project), `/project-map <ROOT>` (another folder), or ask "where are we?".
You get a short text brief in chat and the path to `<ROOT>/.project-map/index.html` for the browser.
Cost: nothing changed = no model call; a routine update = one Sonnet agent, about $0.10; the first map or a migration = one Opus agent, about $0.5.
A SessionStart hook already shows the brief at the start of a session; this skill is the way to re-judge.

## 0. Preflight (main session, before any spawn)
ROOT = the argument, else `git rev-parse --show-toplevel`, else the cwd; take its realpath. If the toplevel is `$HOME`, use the cwd instead. Check, and on the first failure say the one sentence and stop:
- ROOT is `$HOME` itself: "project-map needs a project folder, not your home directory."
- ROOT is not inside your home folder (or a Claude scratchpad, `/private/tmp/claude-*/`, `$TMPDIR/claude-*`), or it is inside a hidden top-level folder (`~/.something`) or `~/Library`: "project-map only maps project folders inside your home folder (not hidden folders or ~/Library)."
- ROOT contains a space, `[` or `]`: "project-map cannot map a path containing spaces or brackets; move or rename the folder."
- `python3` missing or older than 3.9 (`python3 -c 'import sys;sys.exit(sys.version_info<(3,9))'`): "project-map needs python3 3.9 or newer."
- `jq` missing: "project-map needs jq installed." `git` missing: "project-map needs git installed."
- ROOT not a directory, or neither `ROOT/.project-map` nor ROOT writable: "project-map cannot write to <ROOT>."
Not a git repo is allowed: say once that the map will use documents and file times. Chrome is optional (FULL skips screenshots and says so).

## 1. Facts
Run `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/project-map-facts.py <ROOT>` BY ITSELF as one plain Bash command with the literal absolute ROOT: no `&&` chains, no `$ROOT`, no `cd`. The guard registers the root from that exact literal call, so do every preflight check in separate, earlier calls. It prints one verdict line, binds ROOT to this session and, for spawning verdicts, ends the line with `inv <id>`. Do not dump facts files into chat.

## 2. Verdict
| Verdict | Do |
|---|---|
| `NO_CHANGE` / `NEEDS_REFRESH` | `cat <ROOT>/.project-map/current/brief.txt`, print the index.html path, stop. No agent. |
| `NEEDS_JUDGEMENT` | Spawn the UPDATE agent (step 3, `model:"sonnet"`). |
| `NEEDS_FULL` | Say "This is one Opus run, about $0.5" (migration: "the map moves to the 3.2 layout"), then spawn FULL (`model:"opus"`). |
| `REFRESH_FAILED` | Report the line. Never print an old brief as fresh. Stop. |
| `ERROR` | Report the line, stop. `answers rewritten`: tell the owner and offer `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/project-map-facts.py --accept-answers <ROOT>`. |

## 3. Spawn (never pass `run_in_background`, never resume; Claude Code may still run the agent in the background, that is supported)
`Agent({subagent_type:"project-map:project-map", model:"sonnet"|"opus", description:"Update project map", prompt:"ROOT: <ROOT>\nINV: inv-<id>\nRUN: UPDATE|FULL"})`
Use the id printed after `inv` (prefix `inv-` only if missing). The first three lines must be exactly those; add nothing else. Unknown agent type: "run /reload-plugins (the plugin was installed after this session started)"; never fall back to another agent. Spawn denied: print the guard's reason and stop, except when the reason says ROOT was not registered: run the step 1 command again alone and spawn again (once).

## 4. Reply
The agent never prints the brief. On `DONE`, print `<ROOT>/.project-map/current/brief.txt` and the index.html path.
If the spawn returns "Async agent launched" the agent runs in the background: say the map is updating, keep working, and act on the table below when its completion message arrives. Never print the old brief while it runs.
| Agent reply | Do |
|---|---|
| `DONE gen <seq>-<id>` | Print the brief and path. |
| `DONE (stale)` | Say the repo moved while the agent judged, the map is published and flagged; rerun from step 1 once if the owner wants it current. |
| `SUPERSEDED` | Another run published first and nothing was lost. Rerun from step 1 once; if it says SUPERSEDED again, report it. |
| `PARTIAL <text>` | Report the text. Do not retry blindly; a guard deny means the agent was stopped on purpose. |
| `NEED_FULL` | Go to the `NEEDS_FULL` row. |
| no reply, interrupted, or unsure whether it finished | Tell the owner; print `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/project-map-facts.py --close-session <ROOT>` and say "start a new Claude Code session to run the map again". |
FULL runs may add `TEMPLATE_FEEDBACK:` lines: show them as suggestions only.

## 5. Decisions
Relay each `ASK:` line as one question (AskUserQuestion): recommended option first, the default and deadline stated; hard-rule decisions marked "waits until you answer". Keep working meanwhile. When the owner answers, append one line to `<ROOT>/.project-map/answers.jsonl`: `{"id":"D-004","answer":"A","at":"<iso>","by":"owner"}` (`"answer":"hold"` is valid), then rerun from step 1. The map never authorizes a hard-rule action; that needs the owner's explicit approval.

Focus (3.5), only when the owner says it. **"confirm focus"**: append `{"id":"F-set","answer":"<outcome>","note":"<done when>","exclusions":["..."],"at":"<iso>","by":"owner"}` with the proposal's (or the accepted record's) `outcome` and `done_when` verbatim and the CURRENTLY accepted `exclusions` kept unless the owner asks to drop them (read all three with `jq -c .intent <ROOT>/.project-map/current/state.json`), then rerun from step 1: a plain confirmation is applied without a model call (`NEEDS_REFRESH focus confirmed`).
**"the focus is X, done when Y"**: the same line with their words (`exclusions` only if they state them: at most 3, 80 bytes each). **"handoff"**: `cat <ROOT>/.project-map/current/handoff.txt` and print it.
Never ask about the focus on an ordinary refresh.

## 6. Recovery
- `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/project-map-facts.py --close-session <ROOT>`: after an uncertain agent termination; this session then accepts no further map agent.
- `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/project-map-facts.py --accept-answers <ROOT>`: after an intentional edit of `answers.jsonl`.

"Where are we?": run steps 0-1; on `NO_CHANGE` answer from `brief.txt` only, never from `state.json` or the HTML.
