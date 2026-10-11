# project-map 3.4 / 3.5 / 3.6: return brief, confirmed focus and handoff, drift and lost evidence

Design for three releases, reviewed as one document (Codex round 1: P1-P14, round 2: Q1-Q8, round 3: R1-R7, round 4: S1-S4, all
addressed and cited by number), implemented and shipped one release at a time. Product direction: the Codex brainstorm of 2026-10-10
(`codex-brainstorm.json`): the promise is "return to a project, understand what changed, and know what to do next"; a
roadmap mismatch is one finding inside that promise. Every rule is global (every project, fresh install, no setup) and keeps
the 3.2/3.3 contracts: scripts own facts and lifecycle, the model only judges, one bounded UPDATE (4 calls), pack <= 8 KB,
judgement hard 6144 bytes, brief <= 1000 bytes, `state.schema` stays `project-map-4` (additive fields only; every existing
key keeps its meaning), no new model call, a refresh with no relevant change stays model-free.

Notation as in `INTERFACES-3.2.md`. "ref" = `file:<rel>[:line]` | `commit:<sha7+>` checked by `ref_problem`. "R" required,
"O" optional. **Intent identity** = sha256 (first 16 hex) of the canonical JSON `[outcome, done_when, exclusions]` after NFC
normalisation and whitespace collapsing of each string (`exclusions` sorted; `[]` when absent). **Observation identity**
(15.2) = `commit:<repo path>:<oid40>` or `file:<rel path>:<fp>` where `fp` is the ONE canonical per-file content
fingerprint frozen at collection (R1, S3): `snapshot.file_fp = {path: {fp: sha12 of the file bytes, status: "verified"}}`
computed for every retained dirty path (<= 20) and every watch entry that is a single regular file; an unreadable file has
`status: "unknown"` and no `fp`; a watched DIRECTORY has no file identity (its aggregate hash stays change detection only,
never evidence). Both evidence routes (dirty path, moved watch file) use `file_fp`, so an unchanged file has the same
identity whichever route makes it eligible.

---------------------------------------------------------------------------------------------------------------------------

## 13. 3.4.0: make returning easy (return brief)

Problem: the first screen and the brief lead with phase counts and the headline; what changed since the last assessment and
what deserves attention are buried. A returning owner re-reads chats.

### 13.1 Baseline (script-owned)
`snapshot.since` = `{generation: <base gen>|null, assessed_at: <previous state's judged_at>|null, commits: <commits.count>,
dirty: <status.dirty>, hours: int|null}`; `null` on a first map. Commits are counted against `judged_key.heads` (the previous
JUDGED generation; a mechanical refresh keeps `judged_key`), so the baseline is always "the previous assessment", never
"your last visit".

### 13.2 Model output (`judgement.out.json`, new top-level key `since`)
Required on every UPDATE and FULL whose pack carries a non-null `since`; must be absent or `null` when the pack's `since` is
`null`. Unknown keys rejected.
```
since: {
  changes: [ {text <=120, state: "landed"|"uncommitted", ref: ref|null} ]   0..3, most consequential first
  attention: {kind: "decision"|"continue"|"waiting"|"unchecked", text <=120, why <=120, id: D-nnn}   R
  not_checked: [ <=80 ]   O, 0..3
}
```
- `text` states the consequence ("Import landed; nothing here shows it works"), not a commit subject. Texts unique.
- `landed`: in a commit (`ref` R: `commit:` resolving in a known repo; in a project without git, `file:`). `uncommitted`:
  working-tree work (`ref` O, `file:` only, must resolve). There is NO "checked" state (P13): a 4-call UPDATE cannot establish
  that behaviour was verified, and a resolving ref proves only that a file or commit exists. Page and brief say `landed · not
  checked by the map`; what would show it works belongs in `not_checked` and in the plan's criteria refs.
- `attention`: exactly one primary item. `kind: decision` (`id` R: a decision open or overdue with `ready != false` in the
  staged snapshot and not closed by `overtaken` in this judgement, or raised ready in this judgement) is MANDATORY whenever
  such a decision exists after this judgement. `continue`: work can proceed without the owner (`text` says what). `waiting`:
  blocked outside the project (`text` names it). `unchecked`: the pack did not allow a judgement (`text` says what is
  missing). `why` = consequence of waiting / of not checking.
- `not_checked`: what the pack could not tell (plain words).

### 13.3 What the model saw (script-owned, from the exact staged input; Q3)
`pack.seen` is computed by `build_pack` AFTER the last trim step from the pack object itself and written into the pack:
`{commits: <commit items retained>, commits_total: <snapshot commits.count>, dirty: <dirty_paths retained>, dirty_total:
<status.dirty>, decisions_cut: <n with q or options cut>, answers_dropped: <n>, ledger_cut: bool, repos_cut: <n repos
dropped>, watch_moved: <watch entries whose hash moved against the judged key (snapshot prev_key)>, watch_moved_cut: <of
those, how many the pack no longer lists, by ANY step: the >40 cut, the whole-list drop>}` (hash-only cuts, recent tags and
usage detail are not omissions; S4). `commits_total` counts the collector's own cap too (`group_commits` lists at most 40:
`commits` can never exceed what was listed). At a judged publication embed reads `STAGE/pack.json` (the file the model read,
not the pack `finish_files` rebuilds) and stores its `seen` as `state.judged_seen`; a mechanical refresh carries it.
`state.since.listed` = `judged_seen.commits`; (3.6) `fit.scope.shown` too. "Relevant work omitted" = `commits <
commits_total` or `dirty < dirty_total` or `decisions_cut` or `answers_dropped` or `ledger_cut` or `repos_cut` or
`watch_moved_cut > 0`.

### 13.4 Assurance predicate (script-owned, ONE for page, brief and handoff; P1, Q8)
`state.assurance = {ok: bool, why: [<=40]}` computed by `build_state` and recomputed by every mechanical refresh from its own
snapshot and the carried judgement. `ok` iff ALL of:
- no decision `open`/`overdue` with `ready != false`;
- `state.stale` is null;
- collection complete: `coverage == complete`, no `git_error`, no release entry `partial`/`unverified`, the facts run was not
  cut by its budget;
- (3.6) `evidence.checked == complete`, no `unverified` criterion or part, `evidence.recheck` complete;
- the carried `since.attention.kind == continue`;
- no relevant work omitted from the judged pack (`judged_seen`, 13.3);
- (3.5) `intent.accepted` is null or its identity equals `intent.target.hash`.
Each failing clause adds a short `why` (`decision open`, `assessment behind: <stale.why>`, `coverage partial`, `tags
unverified`, `facts cut by budget`, `evidence check incomplete`, `P5.c3 unverified`, `attention: waiting`, `12 of 30 commits
shown to the model`, `focus changed after the assessment`).
**Three-way wording** (page pill and "Needs you" tile, brief, handoff; Q8): (a) a ready open/overdue decision exists ->
`Needs you` (tile: the count; brief: the existing `D-004 needs you:` lines; handoff line 10 reserved); (b) none and
`assurance.ok` -> `Nothing needs you`; (c) none and not ok -> `No decision identified in the checked information` + the
`why` list (page: all; brief line 2 and handoff line 2: the first, cut to 40 bytes).
Hook: a verdict line carrying `(deferred: budget)` makes the SessionStart context `project-map: facts not refreshed (budget);
run /project-map` (the old brief is not presented as refreshed).

### 13.5 State and page
`state.since = {from: {generation, assessed_at}, commits, listed, dirty, hours, changes[], attention{}, not_checked[]}`
(script counts as staged, `listed` from `judged_seen`, the model block verbatim). A mechanical refresh keeps `since` (it
describes the judged batch; live drift is `stale`). **Reconciled attention** (R7, S1): after the final answers read, deferred
closures and late answers (12.5), `build_state` compares the judged attention with the FINAL ready open/overdue decision
ids: (i) the judged attention names one of them -> kept; (ii) it does not (kind != decision, or its id was answered,
defaulted, closed or made not ready meanwhile) and such ids exist -> `since.attention = {kind: "decision", id: <the lowest
eligible id>, text: <its q cut to 120>, why: "still open at publication", by: "script"}`; (iii) it named a decision and none
remains -> `{kind: "unchecked", text: "<id> was answered after the assessment; attention not reassessed", why: "pending the
next judgement", by: "script"}` (an answered id is never rendered as a current owner decision). In (ii) and (iii) the
model's block is kept as `since.attention_judged`. One code path (`build_state`) serves every publication; page, brief and
handoff render `attention`. No model call; the next judgement re-judges attention as usual. `state.assurance`, `state.judged_seen` as above.
Page: one new section `#since` between the header and the tiles: eyebrow `Since the previous assessment · <assessed_at
date>`, line `<N> commits · <M> uncommitted files` (+ ` · <listed> of <N> shown to the model` when `listed < N`), the
attention row (kind eyebrow, text, why), up to 3 change rows `<text> · landed, not checked by the map | uncommitted`, `not
checked: ...`. Pill and tile per 13.4; the tile note lists the first two `why`. textContent only. Section absent when
`state.since` is missing (older generations still render). Nothing else on the page moves.

### 13.6 Brief (<= 1000 bytes, whole lines, fixed display order, dropped by priority)
```
1 <name> · <folder> · phase k/n <label> · <tone>
2 as of <snapshot_at minute> · assessed <judged_at minute> · current | behind: <stale.why <=60> [· <first assurance.why <=40>]
3 <headline>
4 D-004 needs you: ... (existing; then +N more decisions)
5 attention: <text> · <why>            (omitted when kind == decision and the D line is shown)
6 next: <title> (<actor>)
6b focus: ...                            (3.5)
7 since <assessed_at minute>: <N> commits · <M> uncommitted · <k> changes [· <listed> of <N> shown]
8 - <text> · landed, not checked | uncommitted   (0..3)
9 D-001 overtaken by events: ...          (existing)
10 git: <release line>                   (existing)
11 stale: / coverage partial              (existing)
11b evidence lost: ...                    (3.6)
12 tokens ...                             (existing)
13 generation <seq>-<id>
```
Line 2 is never dropped and never cut mid-field (`stale.why` to 60 bytes, the qualifier to 40, qualifier present only when
case (c) of 13.4 applies). `<folder>` is bounded: `_fit_folder` keeps a `~` path up to 60 bytes, else `…/<last two
components>` cut to 60 bytes with `…` (P14). With every capped field at its maximum, lines 1-3, 6 and 13 fit in 1000 bytes
(test RB-brief-max). Drop order when over the cap: 12, 10, 8 (last first), 7, 6b, 5, 9, 11b, 11, then the existing `+N more`
collapsing of 4.

### 13.7 Pack, prompt, skill
Pack: `since` and `seen` (never trimmed). Agent prompt: the `since` rules (consequence not subject; `landed` needs a commit;
no "checked"; a decision is always the primary attention; `seen` says what was cut: never `continue` as if the batch were
complete when it was not). Skill: unchanged (the brief carries the block; the SessionStart hook prints it).

### 13.8 Tests (test_embed.sh RB-*, test_hooks.sh)
RB-required; RB-landed-ref; RB-attention-decision (open ready decision + `continue` rejected; `id` not open rejected;
`ready:false` does not force; a decision closed by `overtaken` in the same judgement does not force); RB-seen (a repo with
60 commits: `seen.commits_total` 60, `commits` 40 or fewer after byte cuts, `since.listed` equals the retained count, the
page says "N of 60 shown", assurance why; a late-answer publication keeps `judged_seen` from STAGE/pack.json);
RB-assurance (each clause flips `ok`; three-way wording in page, brief line 2 and (3.5) handoff; open decision + stale ->
"Needs you", never the denial); RB-baseline (two judgements: `since.from.assessed_at` == previous `judged_at`; mechanical
refresh keeps `since`, bumps `stale`, recomputes `assurance`); RB-brief-max (every field at its cap + 6 decisions + a
200-byte folder: <= 1000, drop order exact, line 2 present); RB-page (rows, `<script>` in a text inert); RB-reconcile (a
judgement closing a ready decision by events with `attention: continue`, an uncommitted tail appended after staging: the
deferred decision is published open and `since.attention` is the script's decision item on page and brief,
`attention_judged` kept; two committed late answers answering the primary D-001 while D-003 stays open -> attention moves
to D-003; the primary answered and none left -> the `unchecked` fallback, never an answered id); RB-watch-omitted (cap
pressure with only watched-file changes and the whole watch list dropped: `watch_moved_cut > 0`, assurance false, qualifier
shown); H-deferred.

---------------------------------------------------------------------------------------------------------------------------

## 14. 3.5.0: keep the next piece of work clear (confirmed focus, copyable handoff)

Problem: the brief mixes the owner's objective with the model's proposed next step; a new agent gets context but no bounded
assignment; the owner cannot cheaply say "this is what I want next" in a way that survives sessions.

### 14.1 Intent records (state key `intent`; `state.focus` keeps its 3.2 meaning: P14)
`judgement.intent` (R on every UPDATE/FULL): `{outcome <=120, done_when <=120}`: the immediate objective the next step
serves, in the owner's terms; no dates, no percentages.
```
state.intent: {
  accepted: {outcome, done_when, exclusions: [<=80] 0..3, hash, at, line} | null   the owner's record (14.2)
  proposed: {outcome, done_when, hash} | null        the model's text when it differs from accepted (a suggestion only)
  target:   {outcome, done_when, exclusions, hash}    the intention THIS judgement served (14.3)
  drift: {...}                                        (3.6)
}
```
No revision numbers (P2/P3): consent binds to the words. **Operative intention** = `accepted` when it exists, else the
model's text. The model's `next_step` serves the operative intention: when `accepted` exists and the model writes a different
`intent`, that text is published as `proposed` ("the map suggests changing the focus"), the next step is still judged against
`accepted`, and the prompt says so (Q1: a proposal never redirects the operative next step). The model never changes
`accepted`.

### 14.2 The one owner record (answers.jsonl, same file, same prefix hash, same recovery)
`{"id":"F-set","answer":"<outcome <=120>","note":"<done_when <=120>","exclusions":[<=80]<=3,"at":iso,"by":"owner"}`
(`exclusions` O, legal on `F-set` lines only; `note` R). Applied by the SAME reducer as `D-` lines, in file order (P4):
`apply_answers(by_id, pending, intent)` routes by id; the reduction of an `F-set` line is a pure function of the line
(`accepted = {outcome, done_when, exclusions, hash, at, line}`), so `--accept-answers` replays deterministically: after a
replay `accepted` = the LAST `F-set` line of the file, or null (an intentional rewrite that removes every `F-set` line removes
the accepted focus; the recovery line says so). Strings pass the secret scan and `display_safe` (a secret-shaped string makes
the line `bad`, never stored). An `F-set` line never counts as a decision answer. `late_answers` (12.5) decides which `D-`
closures lost to an owner answer by looking at `D-` lines only, but when it applies the appended lines it applies ALL of them
through the shared reducer (P4).
Skill: "confirm focus" = append `F-set` with the proposal's verbatim `outcome`/`done_when` AND the currently accepted
`exclusions` (preserved unless the owner asked to drop them; Q1); "the focus is X, done when Y" = the owner's words (and
exclusions only when the owner states them). No question is asked on an ordinary refresh.

### 14.3 Target, model-free confirmation, paid re-judgement (P4/P5, Q1/Q2)
At a judged publication the script freezes `intent.target` from the STAGED input before any late-answer reduction: `accepted`
(after the lifecycle applied the pending lines at staging) if it exists, else the model's `intent` with `exclusions: []`.
**Key component `intent_hash`** (R3) = the OPERATIVE intention's identity: `accepted.hash` when `accepted` exists, else
the pinned state's `target.hash` (null before the first 3.5 judgement). At a judgement `judged_key.intent_hash =
target.hash`. A confirming `F-set` (identity == target) therefore leaves the component unchanged; a different identity moves
it ("focus set by owner").
`decide` (facts): when `compare_keys` reports ONLY `answers_count` moved and every complete line after `applied` parses as an
`F-set` whose identity equals the pinned state's `intent.target.hash` (a confirmation of exactly the intention that was
served, exclusions included; `accepted` null or equal to target) -> `NEEDS_REFRESH focus confirmed`: facts calls
`embed --mechanical --apply-answers`. That flag exists only for this path (the hook's refresh and the stale-stamping refresh
inside `NEEDS_JUDGEMENT` never apply answers, so a staged snapshot can never carry a line as pending that a refresh already
applied). **Inside** `embed_mechanical` the whole predicate is re-validated against ITS pinned generation and ONE complete
read of `answers.jsonl` (Q2): the staged prefix verifies, every complete line after `applied` is a well-formed `F-set` with
the target identity (a `bad` line, a `D-` line, another intention or an uncommitted tail -> not applied), and its own
`compare_keys` shows only `answers_count` moved. On success it reduces those lines, sets `accepted`, advances
`answers.applied`/`applied_hash` through exactly them and stores the new `answers_count` and `intent_hash` in `judged_key`.
On any failure it publishes the ordinary refresh with the answers left pending and prints `PM_EMBED_NOTE answers not
applied: <reason>`. **Fallback** (R2): facts then reloads `prev` (the refreshed generation) and COLLECTS AGAIN against it
(the snapshot it stages must contain the very line that declined the fast path and the refreshed lifecycle), runs `decide`
once more with the fast path disabled (`declined`), and stages `NEEDS_JUDGEMENT <N> pending answers inv <id>`; if the budget
cannot afford the second collection it returns `NEEDS_JUDGEMENT <N> pending answers (deferred: budget)` without staging. A
failed or SUPERSEDED refresh consumes nothing. Any `F-set` with another identity (a new intention, added or removed
exclusions) or `F-set` lines mixed with `D-` lines -> `NEEDS_JUDGEMENT focus set by owner` / `N pending answers`. Should
`accepted.hash != target.hash` ever be published (a SUPERSEDED retry, a partial run), the assurance predicate and line 2
say `focus changed after the assessment` and the next facts run returns `NEEDS_JUDGEMENT`.

### 14.4 Pack and prompt (P12)
Pack `intent` = `{accepted: {outcome, done_when, exclusions}|null, proposed: {outcome, done_when}|null}` is RESERVED: placed
before every optional detail, never trimmed (~400 bytes). Prompt: "`intent.accepted` is the owner's immediate objective. Copy
it as `intent` unless the evidence shows it is reached or wrong; a different text is a suggestion the owner must confirm and
does not change what `next_step` serves; never write dates or percentages."

### 14.5 Handoff (script-rendered, every generation)
`handoff.txt` (<= 1500 bytes) in every generation, listed in the manifest (signed), fifth stable symlink `PM/handoff.txt`
(`C.STABLE`, `repair_links`, layout tests). Lines in display order; drop order after the list:
```
1 Handoff · <name> · as of <snapshot_at minute> · assessed <judged_at minute>
2 Status: Needs you: D-004 <q <=80> | Nothing needs you | No decision identified in the checked information: <first why>
3 Focus (confirmed <date> | proposed, not confirmed): <outcome>
4 Done when: <done_when>
5 Not in scope (owner): <exclusions '; '>           (only when present)
6 Where it stands: <headline>
7 Since <assessed_at>: <N> commits · <M> uncommitted [· <listed> of <N> shown]
8 - <change text> · landed, not checked | uncommitted   (0..3)
9 Next: <title> (<actor>): <why>
9b Fit: <concern>                                      (3.6, departure only)
10 Needs the owner: D-004 <q> (default <d>) | +N more   (every ready open decision, cut to 100 bytes each)
11 Open risk: R-1 <text>                               (highest severity, at most 2)
12 Evidence: git: <release line>
13 Context only, not permission: no push, delete, spend, deploy or infrastructure change without the owner.
```
Never dropped: 1, 2, 3, 5, 13 (line 2 carries the primary decision when one is known, so the handoff never denies a known
decision: Q8). Drop order: 12, 11 (second first), 8 (last first), 7, 9b, 6, 10 (collapsing to `+N more` first), 9, 4. Page:
a "Handoff" disclosure (first in the context list) with the text in a `<pre>` (textContent) and a Copy button
(`navigator.clipboard.writeText` inside the click handler; on rejection the text is selected; the label never claims success
it did not get). Brief line 6b: `focus: <outcome> (confirmed | proposed: say "confirm focus")`. Skill: "handoff" -> `cat
<ROOT>/.project-map/current/handoff.txt`; "confirm focus" / "the focus is X" -> append `F-set` (14.2), rerun.

### 14.6 Tests (FC-*)
FC-required; FC-proposed (model text == accepted -> no `proposed`; different -> `proposed` shown, `target` == accepted,
next step judged against accepted); FC-set (`F-set` -> accepted with exclusions and line; exclusions on a `D-` line -> bad;
secret-shaped outcome -> bad); FC-confirm-mech (proposed-only map, confirming `F-set` -> `NEEDS_REFRESH focus confirmed`, no
staging, `applied` advanced, prefix hash verifies, next run `NO_CHANGE`); FC-confirm-exclusions (accepted A with exclusions,
confirming F-set keeps them -> model-free; drops them -> `NEEDS_JUDGEMENT`); FC-ab (accepted A, proposed B, F-set B ->
`NEEDS_JUDGEMENT focus set by owner`, never model-free); FC-gate (gated: a `D-` line or a different `F-set` appended between facts'
collection and the `--apply-answers` refresh -> nothing applied, `PM_EMBED_NOTE`, facts re-collects and stages
`NEEDS_JUDGEMENT` whose pack carries the line that declined the fast path and whose `base` is the refreshed generation; a bad
line -> same; `current` moved -> SUPERSEDED, nothing consumed; out of budget -> `(deferred: budget)`, no staging);
FC-first-confirm (proposed-only map, confirm -> model-free, `intent_hash` unchanged, next run `NO_CHANGE`); FC-new-judged; FC-mixed; FC-late (appended `F-set` then a winning `D-` answer during
a judgement closing by events: both reduced, `applied` advanced through both; `F-set` alone appended: not a late answer,
closure proceeds, line stays pending); FC-no-double; FC-replay (`--accept-answers` with two `F-set` lines and D lines between:
accepted = last `F-set`; removing all `F-set` lines -> null); FC-handoff (in generation and manifest, stable link, <= 1500,
drop order, lines 1/2/3/5/13 always present, known decision on line 2 under cap pressure, `<script>` inert); FC-assessed.

---------------------------------------------------------------------------------------------------------------------------

## 15. 3.6.0: notice when the situation no longer matches the intention (lost evidence, drift)

### 15.1 Lost completion evidence (script-owned; P6/P7/P8, Q4/Q5)
Scope: the pinned state's `done:true` criteria refs and `done` part refs ("completion refs").
- Cache (`cache.json.evidence = {set, gen, epoch, results: {"<id>|<ref>": {status: ok|lost|unknown, why, at, epoch}}}`;
  S2, T1, U1): `set` = sha256 of the sorted `(id, ref)` list of the pinned generation `gen` (its name sorts by
  publication order). The whole evidence pass is ONE critical section under the publish lock (`PMLock`, non-blocking, the
  lock facts already takes for the sweep and embed already holds): re-read the cache file, reserve `epoch + 1`, perform the
  bounded checks, merge, write the file, release; nothing else (collection, hashing, staging, rendering) runs inside it. Two
  checkers therefore never overlap: the check interval of a run with a higher epoch lies entirely after the interval of
  every lower one, so epoch order IS observation order and a physically later loss can never be discarded by an earlier
  `ok`. A busy lock skips the pass for that run (the record is untouched, `checked` stays what it was, never "complete" by
  assumption). Every result carries the epoch of the pass that produced it; inherited entries are never restamped. There is
  NO integer cursor: the schedule is "least recently checked first" (lowest result `epoch`,
  unvisited entries first, ties by id), ONE fair bounded schedule (R4) of at most 40 checks or until the hash deadline per
  facts run or mechanical refresh; known `lost` and `unknown` entries are re-checked when their turn comes (within `ceil(n /
  40)` runs), never ahead of unvisited ones. Merge (facts `cache_save`, embed `cache_merge`, under the lock, after re-reading
  the file, inside the same critical section): a pass whose `gen` is older than the stored `gen` discards its own results; a
  newer `gen` (or a changed `set` for the same gen) replaces the record, keeping results whose key is still in the set; the
  same set merges per key by the higher `epoch`, and an equal epoch (impossible across runs, kept as a safety rule) by status
  rank `lost > unknown > ok`. Verification is restored only by a successful check in a later pass. The R2 re-collection runs
  its own pass (a new epoch).
- A check: `file:` -> `lstat` regular file under ROOT (not under `.project-map/`), line <= line count; `commit:` ->
  `cat-file -e` in the confined repository. Absence is established only by a successful query (`ENOENT`, `cat-file` rc 1); a
  timeout, permission error or collection failure is `unknown` (never "lost"; a previously `ok` ref that is now `unknown`
  loses its verification: `checked` becomes `partial` until it succeeds, no item is marked unverified by it).
- `snapshot.evidence = {checked: complete|partial, n: <refs>, done: <checked since the set formed>, lost: [{id, ref, why}],
  unknown: [ids]}` (`why`: `file missing` | `line past end` | `commit missing` | `repo moved`). `checked == complete` iff
  every ref's latest status is `ok` or `lost` and every ref was visited since the set formed. Key component
  `evidence_lost: [ids]`. `decide`: a change of the state's evidence view (`checked`, `lost` ids, `unverified` ids, `done`
  count) with no key move -> `NEEDS_REFRESH evidence status changed` (as 10.3; Q5).
- Visibility: every known loss is shown `unverified: true` on its criterion/part (page "completion unverified", progress
  note "(N unverified)", brief line 11b `evidence lost: P5.c3 (<ref>)`, first two then `+N`); set by the judged publication
  and by every mechanical refresh from the snapshot; `done` is never flipped by the script; cleared only when the ref
  verifies `ok` again or the model resolves it.
- Repair queue (Q4): the pack carries `repairs` RESERVED: the first 12 losses `{id, ref <=60, why}` by id (parts after
  criteria) plus `more: N`. Validation (UPDATE and FULL): each LISTED criterion must appear in `criteria_updates` as
  `done:false` or `done:true` with a new resolving ref (FULL: validated against the FINAL plan after updates; an id absent
  from the final plan is resolved by removal); each listed part must be not `done`, or `done` with a new resolving ref.
  UNLISTED known losses may be carried with exactly their prior ref and status under a narrow exception: `ref_problem` is
  skipped for a part whose `(id, ref)` is in the staged `evidence.lost` and not in `repairs`, and `validate_plan(check_refs)`
  skips such criteria; they stay `unverified`, never recertified. After publication `judged_key.evidence_lost` is rebaselined
  to the ids still lost in the PUBLISHED state (the carried unlisted ones). `compare_keys` (R6): moved iff the fresh lost set
  has an id not in the judged set (`completion evidence lost: <ids>`) or the two sets intersect (`N completion repairs
  pending`: the carried ones still need their batch); ids that left the fresh set because their refs verify again are NOT a
  move: the evidence view changed, so `decide` returns `NEEDS_REFRESH evidence status changed`, the mechanical refresh clears
  their `unverified` flag and rebases `judged_key.evidence_lost` to the fresh set; the run after that is `NO_CHANGE`.
- Publication recheck (`light_stale`): the completion refs the staged snapshot verified `ok`, re-checked within the deadline
  (bounded by 40); `evidence.recheck = {done, n}` is stored; a new loss publishes the item `unverified: true` with `stale.why`
  "completion evidence lost: <id>" (the next run re-judges); an incomplete recheck is an assurance `why` ("publication
  recheck k of n").

### 15.2 Fit against the intention (model; P9/P12, Q7)
`judgement.fit` (R when the pack carries `intent` (accepted or the model's own proposal in `judgement.in`) and a non-null
`since`; absent otherwise): `{verdict: "consistent"|"departure"|"unknown", concern <=160, evidence: [ref] 1..3, exclusion: int}`.
- `departure`: `concern` R, `evidence` R, `exclusion` O (index into `accepted.exclusions`). Each evidence ref must be an
  OBSERVATION SUPPLIED IN THE STAGED PACK (Q7): a `commit:` among the pack's retained commit items (resolved to
  `commit:<repo>:<oid40>` from the staged snapshot's full ids), or a `file:` path among the pack's retained `dirty_paths` or
  a watch FILE entry whose hash moved since the judged key, resolved to `file:<path>:<fp>` from the STAGED `file_fp` (R1,
  S3; a `status: unknown` fingerprint or a watched directory is not material evidence and is rejected): validation never
  reads the live file for the identity, so a file that changed while the judgement was written keeps the judged identity
  (the publication recheck may flag the assessment stale, it never rebinds the observation). Anything else is rejected
  ("fit evidence must be an observation the pack supplied"). `consistent`/`unknown`: no concern, no evidence; `unknown` is always legal.
- Script-owned `state.fit = {verdict, concern, evidence: [refs], observations: [identities], exclusion, scope: {shown:
  judged_seen.commits, total: since.commits}, against: "accepted"|"proposed"}`; page and handoff say `consistent with the
  inspected work (12 of 30 commits shown)` when `shown < total`. Against a proposed-only intent a departure is a quiet note,
  never a decision.
- Drift state (`state.intent.drift = {hash, streak, heads: {repo: sha12}, acknowledged: {observations: [...]}|null,
  revise_requested}`; `hash` = the accepted identity the record belongs to). **Effective staged drift state** (Q6): at
  staging, after the lifecycle reduced the pending owner lines, if `accepted.hash` differs from `drift.hash` the staged drift
  record is reset (`streak 0, heads null, acknowledged null, revise_requested false, hash = accepted.hash`); validation and
  publication both use that staged record. At publication: `departure` against `accepted` increments `streak` iff
  `since.commits > 0` and some repo head differs from `drift.heads` (then `heads` := snapshot heads); `consistent`/`unknown`
  resets `streak` to 0. A late `F-set` at publication that changes `accepted` resets the drift record again (the already
  written `fit` is published as judged, `against` unchanged).

### 15.3 One deduplicated drift decision (P9/P10/P11, Q6/Q7)
A decision may carry `about: "drift"` (only value). Eligibility for a NEW id, computed by validation from the effective staged
drift state and the CURRENT judgement: `accepted` exists AND `fit.verdict == departure` AND (`staged streak >= 1` and this
batch is distinct new work per 15.2, OR `fit.exclusion` is set) AND no open `about: drift` decision exists AND the concern is
not acknowledged (`acknowledged` null, or `fit.observations` contains an identity not in `acknowledged.observations`:
re-alert only on new material evidence, not new wording or a re-spelled ref). The pack shows the staged drift state and the
prompt the rule. Options exactly `A Keep the focus`, `B Revise the focus (then say the new one)`, `C Unclear, keep watching`;
`default: "hold"`; script-bound at raise: `about`, `intent_hash` (= accepted hash), `observations` (= `fit.observations`),
and `resolves_when = [{kind: "intent_changed", hash}]` (true when `accepted.hash != hash`; evidence `focus:changed`), so the
existing events closure retires the question once the owner sets a new focus. A carried drift decision must repeat `about`
unchanged (`CARRY_KEYS` includes `about`); the gate applies to new ids only, so a carried decision stays legal after `fit`
turns `consistent` (carried until the owner answers or the intention changes). Answers (reduced in file order with the
intention in effect at that line; EVERY side effect is guarded by `decision.intent_hash == the drift record's hash in effect
at that line`, otherwise the answer is recorded by the ordinary `D-` lifecycle and its side effect is moot; R5): `A` ->
`acknowledged = {observations}`, streak 0; `B` -> `revise_requested: true` (brief 6b: `focus: revision requested: say the
new one`; cleared by the next `F-set`); `C` -> nothing. The same guard applies in `late_answers` and in `--accept-answers`
replay (the reducer is one function).

### 15.4 Display
`attention.kind` gains `drift` (allowed only when `fit.verdict == departure`; a needs-you decision still wins). Brief line 5b
`fit: <concern>` (priority with line 5, dropped before it). Page: `fit` line in `#since` with the scope; "completion
unverified" on criteria and parts; progress note; evidence check `k of n` when partial. Handoff line 9b.

### 15.5 Tests (DR-*)
DR-lost-file / -line / -commit / -part; DR-queue (24 lost criteria + 1 lost done part: first 12 listed, the carried
unlisted ones accepted verbatim as `unverified`, repaired ones leave the key, `repairs_left` forces the next batch, third
run after the last repair is `NO_CHANGE`); DR-cursor (60 refs, cap 40: a loss at ref 55 found on the second run, `partial`
then `complete`, a changed set resets, a repaired loss cleared when its turn comes, persistently unreadable first refs: the
loss at 55 is still found within two runs); DR-cache-merge (two facts runs started together: the pass holding the lock
completes before the other starts its pass (gated with `PM_EVIDENCE_GATE`, a test hook that pauses inside the critical
section), the file deleted between them: the later pass records `lost`, no `ok` survives; a busy lock skips the pass and
leaves `checked` unchanged; an older-gen pass after a newer one keeps the newer record; a completion-set change replaces
the record; the equal-epoch rank rule); DR-fp-routes (a file eligible by watch, by dirty path, or both yields one identical observation identity,
also after earlier dirty paths are committed and it enters the retained dirty list); DR-restore (a carried
unlisted loss restored by the owner between batches -> `NEEDS_REFRESH evidence status changed`, `unverified` cleared
mechanically, then `NO_CHANGE`); DR-unknown (unreadable repo -> `unknown`, `checked partial`, no unverified mark; ok again ->
complete); DR-refresh (evidence status change with no key move -> `NEEDS_REFRESH evidence status changed`);
DR-publish-recheck (file deleted between staging and publish -> `unverified`, stale why, recheck coverage stored, next run
re-judges, `done` untouched); DR-fit (required when intent + since; departure evidence outside the supplied observations
rejected; `unknown` without evidence accepted; scope shown); DR-streak (A streak 1 -> F-set B -> first departure: not
eligible; same heads twice: no increment; consistent resets); DR-exclusion; DR-ack (A acknowledges by observation identity:
same observations re-raise rejected, a changed file at the same path is new evidence, a re-spelled sha is not; B sets
`revise_requested`, cleared by `F-set`; C keeps; `F-set` new then old `B`, and old `B` then `F-set` new, through collection,
`late_answers` and `--accept-answers`: the old answer never marks the new intention); DR-frozen-fp (a dirty file changed
between staging and validation keeps the staged identity in `fit.observations`); DR-proposed-quiet; DR-carry (carried after consistent; `about` removal
rejected; second open drift decision rejected; `F-set` with new words -> `resolved: true`, `overtaken` accepted, evidence
`focus:changed`; late `F-set` resets drift, the raised decision closes by events on the next judgement).

---------------------------------------------------------------------------------------------------------------------------

## Not doing
Portfolio dashboard; transcript ingestion; remote checks; automatic test runs; per-commit criterion mappings; milestone
scheduling; a new approval ceremony on refresh; growing the caps; revision numbers; any new model call.

## Release order and process
3.4.0, then 3.5.0, then 3.6.0: Sonnet agents implement from this document; suites green under bash 5 and /bin/bash 3.2 with
mutation checks; a live run in an interactive Claude session; Codex review of the diff until AGREE; commit, tag
`project-map--v3.x.0`, push. Docs per release: INTERFACES section, CHANGELOG, README, FAQ, agent prompt, SKILL.md,
full-run.md, plugin.json.
