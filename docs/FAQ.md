# project-map FAQ

## What do I need installed?

`python3` 3.9 or newer, `jq` and `git`, on macOS or Linux. Google Chrome is optional: it is only used to screenshot the page on a first map, and the map works without it. Windows is not supported.

## Where does it work?

On any project folder inside your home folder (or a Claude scratchpad). Your home folder itself, hidden top-level folders such as `~/.config`, and `~/Library` are never mapped, and the path must not contain spaces or brackets. If you are in a subfolder of a Git repository, the repository's top folder is the project. Outside these locations `/project-map` stops with one sentence saying so.

## Is it safe?

The map agent is checked by a guard that runs before every tool call it makes. The guard allows only read-only commands, a fixed set of read-only Git subcommands, reads inside the project and the plugin, and writes to its own output files, its own notes and one `.gitignore` line. It denies secret-looking paths and shell tricks, and the agent can only act on the one project that your own session started it for. Start a new session or run `/reload-plugins` after installing or updating so the guard loads.

The guard applies to the map agent, not your whole session. One documented limit: Claude Code lets a tool call through if a hook times out, so the guard is written to be fast and refuses oversized input rather than parse it. Decisions covered by hard rules always wait for your approval.

## Does it read my secrets?

The agent is instructed not to open secrets, and the guard denies names such as `.env`, credentials, tokens, private keys, `.ssh`, `.aws` and `.git`, also when a symlink points at them. That is a filename check, not a guarantee that every secret is detected. Ordinary project documents can be read and sent to Claude for assessment. Trusted helper scripts also hash watched files and read local Claude/Codex session records to count usage; their reads are not covered by the guard.

## Can it change my code?

No. It writes map files inside `.project-map/`, can save its own memory notes, and adds `.project-map/` to the project's `.gitignore`. It records decisions but does not carry out the proposed work. Approving a choice in the map does not itself authorize a hard-rule action.

## Why do I see a short summary when I start Claude Code?

In a mapped project, a SessionStart hook shows the saved brief (about 300 tokens, no model call). Its second line says when the snapshot was taken and when Claude last assessed the project (and `behind:` plus the reason when the project has moved on), and a later line says what changed since that assessment, so you can tell a stale map from a fresh one. It ends with a line saying to run `/project-map` to re-judge. Unmapped projects show nothing.

## Why does it say “not checked by the map”?

Each change in the “Since the previous assessment” section is either `landed, not checked by the map` or `uncommitted`. The map reads commits and files; it does not run your tests or try the feature, and a routine update is far too small to do that. So a change that landed is shown as landed, with the commit it points to, but never as “works”. What would show it works (a test run, a manual check) is listed under “not checked”. The same cautious wording appears when the model only saw part of the work: `40 of 60 commits shown to the model` means the update was written from 40 of the 60 new commits, and the map then says “No decision identified in the checked information” instead of “Nothing needs you”.

## What does it cost?

The first map uses Opus and was measured at about $0.46. A routine Sonnet update was about $0.10. If nothing changed, no model is called and the refresh costs $0. Actual cost depends on the project and your Claude billing arrangement; these are measured estimates.

## Why does it say “Assessment may be out of date”?

The project changed after Claude assessed it, possibly while the map was being built. The map keeps the assessment visible and marks it as out of date. Run `/project-map` again. A project being changed by another session may show the warning again.

## How do I answer a decision?

Open the choices on the page, then reply in Claude Code chat with the letter, such as `A` or `D-004=A`. Claude records the answer and refreshes the map. “Coming up” means the choice is not ready yet. Hard-rule decisions stay on hold until you answer, and the action itself still needs your explicit approval.

## How do I set the focus?

Each assessment ends with one proposed focus: the immediate objective the next step serves, and what "done" means for it. The brief (`focus: ... (proposed: say "confirm focus")`) and the page say it is only a proposal until you confirm it. Tell Claude **"confirm focus"** to make it yours, or **"the focus is X, done when Y"** to set your own; you can add up to three things that are out of scope, and a later "confirm focus" keeps them unless you say to drop them. Your words are stored as one `F-set` line in `.project-map/answers.jsonl`; the map never rewrites it and never changes your focus itself (it can only suggest a different one). Confirming exactly what the map proposed is applied without a model call and the next summary says `(confirmed)`; a different focus costs one ordinary update. Say **"handoff"** (or open the "Handoff" row on the page and press Copy) to get `.project-map/handoff.txt`: a short, bounded text for the next agent or session with the focus, what done means, what is out of scope, where the work stands, the next step, and what still needs you. It is context for the work, not permission: it always ends by saying that pushes, deletions, spending, deploys and infrastructure changes still need you.

## What does "completion unverified" mean?

A criterion or a part is marked done because it points at a file (a line of it) or a commit. The scripts re-check those references on every run, forty at a time, and a reference that is no longer there (the file was deleted or shortened, the commit pruned or its repository moved) marks that item "completion unverified". The map never un-finishes anything on its own: the item stays done, and the page, the progress tile and the brief (`evidence lost: ...`) say the evidence is gone. The next assessment must repair every item it was shown (reopen it, or give it a new reference that exists); if more than twelve are lost, the rest wait and the following assessment takes the next twelve. If you restore the file, the mark disappears on the next run without a judgement. A reference the scripts could not read at all (a permission error, a timeout, an unreadable repository) is not called lost; it only keeps the evidence check "incomplete" until a later run reads it.

## What is a drift decision?

When you have confirmed a focus, each assessment compares the work it was shown with it. A first departure is only a note (the brief's `fit:` line); the map asks once, as an ordinary decision (`A Keep the focus`, `B Revise the focus (then say the new one)`, `C Unclear, keep watching`, default hold), after a second departure on different new work, or at once when the work breaks something you listed as out of scope. It never asks while another such question is open, and after you answer A it asks again only about evidence it has not shown you before (a file that changed, a new commit), never because the model reworded its concern. If you set a new focus, the open question closes by itself. Answering B makes the brief say "revision requested: say the new one" until you do. Against a focus you have not confirmed a departure is only a note.

## Where is my map, and why can’t I see it?

Open `.project-map/index.html` inside your project folder in a browser. The text summary is `.project-map/brief.txt`; the handoff for the next agent is `.project-map/handoff.txt`. Folders beginning with a dot may be hidden by your file browser; ask Claude for the full path. If a refresh fails, the previous map is kept, so check the chat for errors before treating it as current.

## How do I update?

If you installed from a local checkout, the plugin loads in place and picks up changes at the next session start or `/reload-plugins`.

If you installed from GitHub, either turn on auto-update (`/plugin` > Marketplaces > Enable auto-update; it is off by default for third-party marketplaces) or run in your terminal:

```bash
claude plugin marketplace update bokiko-tools
claude plugin update project-map@bokiko-tools
```

Then run `/reload-plugins` or start a new session. In a mapped project, the page re-renders itself on your next prompt and says so in one line.

## I had a 3.1 map; what happens?

Your next `/project-map` migrates it with one FULL run (one Opus run, about $0.5). Ids, the ledger link and answered decisions carry over. The old files are kept inside the first 3.2 generation under `legacy/` instead of being deleted, and the stable paths `index.html`, `mobile.html`, `brief.txt` and `state.json` keep working throughout. Until you run it, the session summary says “map needs migration to 3.2”.

## What are all these gen-* folders?

Each published map is an immutable generation folder, `.project-map/gen-<number>-<id>/`, and `current` points at the newest. Writing a new generation and switching one link means a crash or a second session never leaves a half-written map. Old generations are pruned to the newest 10.

## How do I uninstall?

Run this in your terminal, then start a new Claude Code session:

```bash
claude plugin uninstall project-map@bokiko-tools
```

The generated `.project-map/` folder and its `.gitignore` entry are project files and remain. You can remove them yourself if you no longer want the saved map.

## Does it work without Git?

Yes. In a folder without Git history, it uses project documents and file modification times, and says so in the headline. It still needs `python3`, `jq` and `git` installed.

## What if it says my agent type is unknown?

The plugin was installed after the session started. Run `/reload-plugins` or open a new session. project-map never falls back to an unguarded agent.
