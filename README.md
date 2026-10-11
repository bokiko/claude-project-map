<!-- HEADER: Capsule-render wave banner -->
<p align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&height=200&section=header&text=project-map&fontSize=60&fontColor=ffffff&animation=fadeIn&fontAlignY=38&desc=One%20command.%20One%20page.%20Where%20your%20project%20stands.&descAlignY=55&descAlign=50" alt="project-map" />
</p>

<!-- PRIMARY BADGES: for-the-badge style -->
<p align="center">
  <a href="https://github.com/bokiko/claude-project-map#get-started-in-3-steps"><img src="https://img.shields.io/badge/Claude%20Code-Plugin-blue?style=for-the-badge&logo=anthropic&logoColor=white" alt="Claude Code plugin"></a>
  <a href="https://x.com/bokiko"><img src="https://img.shields.io/badge/X-@bokiko-000000?style=for-the-badge&logo=x&logoColor=white" alt="X"></a>
</p>

<!-- TECH BADGES: flat-square style, unified color 2ecc71 -->
<p align="center">
  <img src="https://img.shields.io/badge/Version-3.6.0-2ecc71?style=flat-square" alt="Version 3.6.0">
  <img src="https://img.shields.io/badge/Python-3.9%2B-2ecc71?style=flat-square&logo=python&logoColor=white" alt="Python">
  <img src="https://img.shields.io/badge/Bash-3.2%2B-2ecc71?style=flat-square&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Tests-3629%20passing-2ecc71?style=flat-square" alt="3629 tests passing">
  <img src="https://img.shields.io/badge/License-MIT-2ecc71?style=flat-square" alt="License MIT">
</p>

<!-- TYPING SVG: animated tagline -->
<p align="center">
  <a href="https://git.io/typing-svg"><img src="https://readme-typing-svg.demolab.com?font=Fira+Code&size=18&pause=1200&color=2ecc71&center=true&vCenter=true&width=520&lines=Scripts+gather+the+facts.;The+model+only+judges.;%240+when+nothing+changed." alt="Typing SVG" /></a>
</p>

---

<p align="center">
  <img src="docs/screenshot.png" alt="project-map screenshot" width="860" />
</p>

<details>
<summary>On a phone</summary>
<p align="center">
  <img src="docs/screenshot-mobile.png" alt="project-map on a phone" width="240" />
</p>
</details>

**project-map is a Claude Code plugin.** It adds one skill, the slash command `/project-map`, to [Claude Code](https://claude.com/claude-code), Anthropic's coding agent for the terminal. It is not a standalone program: you type the command inside a Claude Code session, and Claude does the rest.

The command gives you a one-page view of where your project stands.
It shows what is done, what comes next, and what needs your decision.
Open the page in your browser, or read a short summary in Claude Code.

**Needs:** Claude Code (2.1 or newer), plus `python3` 3.9+, `jq` and `git`, on macOS or Linux. Google Chrome is optional (only used for screenshots on the first map). It maps any project folder inside your home folder, such as `~/code/my-app` or `~/projects/my-app`. It never maps the home folder itself, hidden folders like `~/.config`, or `~/Library`, and the path must not contain spaces or brackets.

## Get started in 3 steps

1. **Install from GitHub.** Paste these commands into your terminal:

   ```bash
   claude plugin marketplace add bokiko/claude-project-map
   claude plugin install project-map@bokiko-tools
   ```


2. **Run `/reload-plugins` (or open a new Claude Code session).** The plugin's safety checks (hooks) load at session start and at `/reload-plugins`, nothing else. A session that has not done either will not have them.

3. **Make your map.** Open Claude Code in your project folder and type the skill's command at the Claude prompt (not in your shell):

   ```text
   /project-map
   ```

   Claude gives you a short summary and the path to the page. Open that file in your browser.

The first map costs about half a dollar of Opus. Later refreshes are a few cents or free; the measured update below was about $0.10. These are estimates, not a fixed price.

From then on, every new Claude Code session in a mapped project starts with the short summary already in context (about 300 tokens, no model call). It says what changed since Claude last assessed the project (commits landed, files not yet committed, the few changes that matter, and the one thing that deserves your attention), so an old assessment is never presented as fresh. For example:

```text
demo-app · ~/code/demo-app · phase 2/3 Full-model check passes · watch
as of 2026-10-11T09:40 · assessed 2026-10-10T17:05 · current
Full-model check failed twice on router error bounds; diagnosis running.
D-001 needs you: Keep the 1e-2 error bar, or relax it? (default hold, by 2026-10-12)
next: Finish the cycle-2 diagnosis report (claude)
since 2026-10-10T17:05: 3 commits · 2 uncommitted · 2 changes
- Import landed; nothing here shows it works · landed, not checked
- Plan edits are not committed yet · uncommitted
git: no tag at HEAD · in sync with origin/main (local tracking state)
generation 000014-3fa09c1e
```

## Keep it updated

- **Local-path install** (a checkout added with `claude plugin marketplace add /path/to/project-map`): the plugin loads in place and re-reads its source at every session start or `/reload-plugins`. No version bump is needed.
- **GitHub install:** in Claude Code, open `/plugin` > Marketplaces and choose Enable auto-update (off by default for third-party marketplaces), or run in your terminal:

  ```bash
  claude plugin marketplace update bokiko-tools
  claude plugin update project-map@bokiko-tools
  ```

After an update, run `/reload-plugins` or start a new session. The map of a mapped project re-renders itself (no model call) on your next prompt and says so in one line.

## Reading the map

- **Since the previous assessment:** (new in 3.4) the first thing under the header: commits landed and files uncommitted since Claude last assessed the project, up to three changes (each `landed, not checked by the map` or `uncommitted`), the one item that deserves your attention, and what the map could not check. A decision that waits for you is always that item. When the model saw only part of the new work, it says so (`40 of 60 commits shown to the model`).
- **Focus and handoff:** (new in 3.5) the map proposes one immediate objective and what done means for it, and says plainly that it is only a proposal until you confirm it (the page shows it under the attention item, the brief on a `focus:` line). A "Handoff" row, first in the context list, holds a bounded text for the next agent or session (focus, done when, out of scope, where it stands, the next step, what needs you, and a standing reminder that it is context, not permission) with a Copy button; the same text is `.project-map/handoff.txt`.
- **Completion unverified:** (new in 3.6) every finished criterion and part points at a file or commit. The scripts re-check those references a few at a time on every run; one that is gone is marked "completion unverified" on the page (with the reason), counted in the progress tile and named on a brief line (`evidence lost: P5.c3 (<ref>)`). Nothing is flipped for you: the item stays done until the next assessment repairs it (reopened, or given a new reference that exists), and the map does not call itself "Nothing needs you" while any reference is unchecked or unverified. A reference that cannot be read (a permission error, a timeout) is never called lost; it just keeps the check incomplete.
- **Fit and drift:** (new in 3.6) once you have confirmed a focus, each assessment also says whether the work it saw fits it (`consistent`, `departure` with the reason, or `unknown`) and how much of the work it saw (`12 of 30 commits shown`). A departure is cited only against things the model was actually shown. One departure is a note; a second one on different new work, or one that breaks something you listed as out of scope, raises a single question ("keep the focus / revise it / unclear"). Answer A and the map will not ask again about the same evidence; answer B and the brief asks for your new focus until you say it.
- **Top of the page:** the project name, its folder, the branch and short commit, when the snapshot was taken, and whether anything needs you. The headline under it is the main thing to know right now.
- **Tiles:** a few at-a-glance numbers: the current phase, checks done out of total, the next step with who needs to act, and whether a decision waits for you.
- **Phase list:** every phase is marked done, current, next or later, with its own checks done out of total. The current phase is open (“where we are”); the next phase sits beside it (“what's coming”).
- **Checklist:** open a phase to see its checks, each with its status and the evidence behind it (a file or a commit). The full list across phases doubles as plan vs shipped: the goals against what actually landed.
- **Decision:** the panel shows a choice that belongs to you, why it matters, its default and deadline, and when it is ready. “Coming up” means it is waiting for more information.
- **A little more context:** scroll down and open the rows for individual areas of work, recent changes, other decisions, risks, history and usage totals. Only available details appear.

**“Assessment may be out of date”** means the project changed after Claude assessed it. The map stays visible with that warning. Run `/project-map` again to refresh it. If another session keeps changing the project, the warning may return.

**“No decision identified in the checked information”** replaces “Nothing needs you” whenever the assessment is incomplete: it is behind the project, coverage is partial, tags are unverified, the attention item is not “continue”, or the model saw only part of the new work. The reasons are listed on the page (first two on the tile, all in the Snapshot row). “Nothing needs you” appears only when nothing is open and nothing is missing.

To answer a decision, open “View the choices” or “Preview the choices,” then reply in Claude Code chat with the option letter, such as `A`. If several decisions are open, include the decision number: `D-004=A`. The page itself does not submit answers.

If you already did what a decision asked about (for example you tagged and pushed by hand), the next refresh closes it as “Resolved by events” for one run, with the evidence it relied on, instead of asking you again; the map only does this when the facts it set down when it raised the question (for example “tag v1.0.0 at HEAD and the branch in sync”) are all true, an answer you give always wins over it, and it never decides for you.

Hard-rule decisions always wait for you. These include deleting things, publishing to someone else's project, pushing changes, spending money, or changing infrastructure. Answering the map records your choice; Claude still needs your explicit approval for the action itself.

## Everyday use

Type `/project-map` again whenever you want a refresh. If nothing changed, it returns the summary without another model call.

You can also ask **“where are we?”** Claude checks for changes and answers from the short summary.

Three phrases work on the focus (new in 3.5): **"confirm focus"** makes the proposed focus yours (your out-of-scope list is kept unless you ask to drop it); **"the focus is X, done when Y"** sets your own (and, if you state them, up to three things that are out of scope); **"handoff"** prints `.project-map/handoff.txt`. A plain confirmation is applied without a model call; a different focus costs one ordinary update. Nothing is asked about the focus on an ordinary refresh.

When the map says **“a decision needs you,”** read the choices and reply in chat with a letter. Claude records your answer and refreshes the map. Check any stated deadline or default: ordinary decisions can have a default, but hard-rule decisions always stay on hold.

Your project folder contains `.project-map/index.html` (the browser page), `.project-map/brief.txt` (the short text summary) and `.project-map/handoff.txt` (the text for the next agent), all stable paths. The folder name starts with a dot, so your file browser may hide it. Ask Claude for the full path if you cannot find it. There is also a `mobile.html` view.

The map never changes your project's code or does the proposed work. It writes its own map files and adds `.project-map/` to your project's `.gitignore` so those files stay out of commits.

Upgrading from 3.1: your existing map is migrated on the next `/project-map` (one Opus run); ids, ledger link and answered decisions carry over, and the old files are kept under `.project-map/gen-*/legacy/`.

See the [FAQ](docs/FAQ.md) for safety, costs, updates, and uninstalling.

## For developers

Current plugin version: **3.6.0**. Projects without Git history are supported; they use documents and file modification times.

### Local installation

Try a checkout for one session without installing:

```bash
claude --plugin-dir /path/to/project-map
```

Permanent local install from a checkout:

```bash
claude plugin marketplace add /path/to/project-map
claude plugin install project-map@bokiko-tools
```

Needs `python3` 3.9+, `jq` and `git`. FULL runs take screenshots with Google Chrome (macOS path) when it is present and skip them when it is not.

After installing or updating, run `/reload-plugins` or start a new session to load the hooks, including the guard. Older sessions run the agent unguarded.

### Command and outputs

`/project-map [ROOT]` defaults to the Git toplevel, else the current folder. If the toplevel is `$HOME`, it uses the current folder instead; ROOT is never `$HOME`. The facts script prints one verdict:

| Verdict | Meaning | Cost |
|---|---|---|
| `NO_CHANGE` | Nothing moved. Prints the brief, no agent. | 0 tokens |
| `NEEDS_REFRESH` | A mechanical re-render was needed and done (no model). | 0 tokens |
| `NEEDS_JUDGEMENT` | Something changed. The agent revises the judgement (Sonnet). | about $0.10 |
| `NEEDS_FULL` | First map, migration, invalid state or schema change. Opus explores and proposes phases. | about $0.5 |
| `REFRESH_FAILED` | The re-render failed; the previous map stays current. | 0 tokens |
| `ERROR` | Git failure, unsupported location, missing prerequisite. | 0 tokens |

Outputs in `<ROOT>/.project-map/`: an immutable `gen-<seq>-<id>/` per published generation (state, `index.html`, `mobile.html`, `brief.txt`, `handoff.txt`, snapshot, pack, plan, judgement), one `current` symlink switched atomically, and the stable symlinks `index.html`, `mobile.html`, `brief.txt`, `state.json` and `handoff.txt` into it. Also `answers.jsonl` (your answers), and `cache.json`. The folder is added to the project's `.gitignore`.

### How it works

1. `scripts/project-map-facts.py` uses the Python standard library and prints a verdict. Its change key covers repository heads and branches, the working-tree signature, watched files (hashed by content), the ledger, answers, the focus you confirmed (3.5), the references of finished work that are gone (3.6), and expired deadlines. Scripts own the decision lifecycle. Confirming exactly the focus the last assessment proposed is applied by the scripts without a model call.
2. When judgement is needed, facts stages an invocation folder (`inv-<id>/`). The skill spawns the `project-map` agent with three prompt lines (`ROOT`, `INV`, `RUN`). The agent Reads the bounded `pack.json` (8 KB maximum) and the frozen `judgement.in.json`, writes `judgement.out.json` (3 KB target, 6 KB hard limit; FULL also `plan.out.json`) and runs the embed. Routine updates allow at most 8 tool calls.
3. `scripts/project-map-embed.py` validates ids, evidence references, hard rules, frozen decisions and path confinement, then publishes a new generation under a lock, only if the generation the agent judged is still current. If another run published first, the result is `SUPERSEDED` and nothing is lost.
4. The agent returns `ASK:` lines because it cannot ask questions directly. The main session asks you, appends the answer to `.project-map/answers.jsonl`, and reruns `/project-map`. Hard-rule decisions never auto-default. “Where are we?” uses `brief.txt`, not `state.json`.
5. Two hooks keep the map current without a model: SessionStart injects the brief (`brief.txt`, at most 1000 bytes, about 300 tokens), and a UserPromptSubmit hook re-renders the map once after the plugin's template or embed script changed.

### Measured cost (unique API calls, context at the last call)

| Run | Model | Calls | Context at end | Est. |
|---|---|---|---|---|
| v2 FULL (old, pilot project, 2026-10-07) | opus | 40 | 171K | about $2.20 |
| v3.1 FULL (pilot project) | opus | 16 | 59K | about $0.46 |
| v3.2 FULL, first map (scratch clone, 2026-10-08) | opus | 9 | 42K | about $0.30 |
| v3.2 FULL, migration of a 3.1 map (this repo) | opus | 12 | 56K | about $0.40 |
| v3.1 UPDATE | sonnet | 3-4 | 37K | about $0.10 |
| v3.2 UPDATE (scratch clone, three runs) | sonnet | 3 | 24K | about $0.04 |
| no change, session start, plugin-change re-render | none | 0 | - | $0 (about 300 injected tokens at session start) |

Measured per release on the pilot project and this repo; estimates, not a fixed price.

### Security and guard

Plugin agents cannot declare hooks in frontmatter. The plugin registers `scripts/project-map-guard.sh` as a `PreToolUse` hook (matcher `Agent|Read|Grep|Glob|Edit|Write|Bash`) plus `PostToolUse` and `PostToolUseFailure` hooks on the Agent tool and `SubagentStart` / `SubagentStop` hooks. What it enforces:

- **Modes.** A call without `agent_id` is the main session and is allowed, except that it may not spawn a second map agent, a resumed one, one with an explicit `run_in_background`, or one for a root that was not bound by a facts call in this session. Claude Code itself launches subagents in the background; that is supported: the launch result names the agent, only that agent can claim the job, and `SubagentStop` closes it. A call whose `agent_type` ends in `:project-map` is the map agent and is checked as below. Any other subagent is left alone (exit 0, never trusted).
- **Binding.** The guard, not the agent, decides the agent's authority: a spawn creates a pending record (root, invocation, mode) under the plugin's data folder; the agent's first call claims it. One map agent at a time; a finished agent is denied every further call; `--close-session` blocks all further spawns and claims in that session.
- **Bash (agent):** one simple command, optionally one pipe into head/tail/wc/grep/sort; no shell metacharacters, globs or `~`; only the plugin's facts, embed, usage and `pm-git.sh` scripts for the bound root, read-only `ls`, `cat`, `head`, `tail`, `wc`, `stat`, `find`, `date`, `gh issue list`, `gh pr list` with fixed flags, and (FULL only) the two exact headless Chrome screenshot commands. Raw `git` is denied; `pm-git.sh` runs a fixed set of read-only git subcommands with config, hooks, pager and external-diff helpers disabled. For the map agent, a command over 2 KB is denied before any other check. Nested repositories listed in the snapshot are reachable through `pm-git.sh`; no other subfolder is.
- **Read:** paths are resolved (symlinks followed) and must sit under the bound root, the plugin, the agent's memory folder, or the ledger file recorded in the staged snapshot. Secret-looking names and folders (`.env*`, credentials, keys, `.ssh`, `.aws`, `.git`, `*_history`, `settings*.json`, ...) are denied on both the requested and resolved path. Grep and Glob are denied.
- **Write/Edit:** only the invocation's `judgement.out.json` (FULL also `plan.out.json`), the agent's memory notes, and a one-line `.project-map/` append to the root `.gitignore`. Existing targets must be regular, unlinked files.
- **Fail closed, with one documented exception.** The guard parses its whole input linearly and the main session is never denied for size; for the map agent an input over 8 MB is denied before any other check, and an input whose mode cannot be established is denied. Claude Code treats a PreToolUse command hook that times out as non-blocking (documented fail-open), so the guard is linear-time (one pass, no per-character loops) and a 40 KB padded command is denied in under a second; the 30 s hook timeout is never meant to be reached.

Every deny is logged to `~/.claude/agent-memory/project-map/guard.log`. These checks govern the map agent, not the whole Claude Code session or the trusted scripts, which hash watched files and read local session records to count usage. The generated page makes no network requests and renders data with `textContent`. The usage scan's cache (which holds transcript paths, so a refresh reads only what grew) is private to the plugin (`~/.claude/agent-memory/project-map/usage/`, denied to the map agent), and only token counters and generic job labels (an ai-title only for a session run in the project folder itself) ever reach the project folder, the page or the brief.

### Tests

```bash
bash tests/test_guard.sh    # 1053 cases: guard modes, binding, background launches, grammar, secret paths
bash tests/test_embed.sh    # 1794 cases: facts + embed, generations, locks, migration, usage never failing a refresh, decisions overtaken by events, since / seen / assurance / brief / page (RB-*), confirmed focus / model-free confirmation / handoff (FC-*; PM_FC_ONLY=1 runs these alone), lost completion evidence / fit / drift (DR-*; PM_DR_ONLY=1 runs these alone)
bash tests/test_git.sh      # 416 cases: pm_git core and the pm-git.sh agent wrapper
bash tests/test_hooks.sh    # 151 cases: SessionStart, UserPromptSubmit, SubagentStart/Stop hooks, preflight sentences
bash tests/test_usage.sh    # 215 cases: incremental usage scan equals a full rescan, cache reuse, private counters-only output, budget and resume
```

Run all five under both `bash` and `/bin/bash` (3.2) after any change. `HOOKS_DIR=<dir>` points the suites at a scratch copy of `scripts/`.

### Layout

```
.claude-plugin/plugin.json        manifest (version lives here)
.claude-plugin/marketplace.json   single-plugin marketplace "bokiko-tools"
agents/project-map.md             the judging agent (Sonnet; Opus for FULL)
skills/project-map/SKILL.md       /project-map entry point
skills/project-map/full-run.md    FULL-run instructions (read by the agent)
hooks/hooks.json                  guard (PreToolUse/PostToolUse/PostToolUseFailure/SubagentStart/SubagentStop), SessionStart, UserPromptSubmit
scripts/                          facts, embed, git core, usage, guard, session hooks, template.html
tests/                            guard, embed, git, hooks and usage suites, fixture, pm_page.js (Node DOM shim that runs the page script)
docs/                             design spec, plans, interfaces, FAQ, history
```

### Versioning

Bump `version` in `.claude-plugin/plugin.json` for every release: users stay on the pinned version until it changes. Update `CHANGELOG.md`, then run `claude plugin tag` to create the release tag. The marketplace entry sets no version.

### Limits

Paths with spaces are rejected; nested repos only one level deep; no dependency-cycle check; usage undercounts sessions started in `~`; same-size edits with restored timestamps on unwatched dirty files are invisible to the working-tree signature. macOS and Linux only (Chrome path, bash 3.2 compatibility); no Windows.

## License

MIT, see [LICENSE](LICENSE) for details.

---

<!-- FOOTER: Capsule-render wave footer -->
<img src="https://capsule-render.vercel.app/api?type=waving&color=gradient&height=100&section=footer" alt="" />

<p align="center">
  Made by <a href="https://bokiko.io">@bokiko</a>
</p>
