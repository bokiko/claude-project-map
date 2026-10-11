#!/usr/bin/env python3
"""pm_validate: judgement / plan validation and the merge into state.json (INTERFACES-3.2 sections 6.3-6.5).

Strict types, unknown keys rejected, every limit in UTF-8 bytes. Pure functions apart from the ref checks, which
read files under ROOT and ask git (through pm_git) whether a commit exists.
"""
import copy
import json
import os
import re

import pm_common as C
import pm_git as G

PART_ID = re.compile(r"^[a-z][a-z0-9-]{1,23}$")
PHASE_ID = re.compile(r"^P[1-9]$")
CRIT_ID = re.compile(r"^P[1-9]\.c[1-8]$")
DEC_ID = re.compile(r"^D-\d{3}$")
LOOP_ID = re.compile(r"^L-\d{2}$")
RISK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,15}$")
PART_ST = ("done", "in_progress", "stuck", "unknown")
TONES = ("ok", "watch", "blocked")   # "stale" is set by the script (stale record), never by the model
ACTORS = ("claude", "codex", "owner", "external")
TOP_KEYS = {"generation", "project", "run", "watch", "repos", "headline", "parts", "current_phase", "criteria_updates",
            "eta", "next_step", "decisions", "loops", "risks", "template_feedback", "since", "intent"}
SCRIPT_OWNED = ("answer", "answered_by", "answered_at", "status", "raised_at", "frozen",
                "closed_by", "closed_at", "overtaken_why", "overtaken_ref")
OPEN_ST = ("open", "overdue")
CLOSED_ST = ("answered", "defaulted", "overtaken")   # a closed decision lives for exactly one generation


# ---------------------------------------------------------------- decision tombstones (permanent)
_DEC_RANGE = re.compile(r"^D-(\d{3})(?:\.\.D-(\d{3}))?$")


def decode_decision_ids(text):
    """'D-000..D-003,D-007' -> {'D-000', ..., 'D-003', 'D-007'}. Tolerant: anything that is not a range or id is skipped."""
    out = set()
    for tok in (text.split(",") if isinstance(text, str) else []):
        m = _DEC_RANGE.match(tok.strip())
        if m:
            lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
            out.update("D-%03d" % n for n in range(lo, max(lo, hi) + 1))
    return out


def encode_decision_ids(ids):
    """The inverse: consecutive numbers collapse into ranges, so the whole D-nnn space stays within a few KB."""
    nums = sorted({int(i[2:]) for i in ids if isinstance(i, str) and DEC_ID.match(i)})
    out, k = [], 0
    while k < len(nums):
        j = k
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        out.append("D-%03d" % nums[k] if j == k else "D-%03d..D-%03d" % (nums[k], nums[j]))
        k = j + 1
    return ",".join(out)


def retired_decision_ids(prev):
    """Every decision id ever retired: the permanent set plus any decision id still in the (windowed) retired_ids list."""
    if not prev:
        return set()
    return decode_decision_ids(prev.get("retired_decisions")) | {i for i in prev.get("retired_ids", []) if isinstance(i, str) and DEC_ID.match(i)}


def retire_decisions(S, ids):
    """Add decision ids to S's permanent tombstones (and, as before, to the windowed retired_ids list)."""
    ids = [i for i in ids if isinstance(i, str) and DEC_ID.match(i)]
    S["retired_decisions"] = encode_decision_ids(retired_decision_ids(S) | set(ids))
    ri = list(S.get("retired_ids", []))
    ri += [i for i in ids if i not in ri]
    S["retired_ids"] = ri[-200:]


# ---------------------------------------------------------------- tiny checkers
class V(object):
    def __init__(self):
        self.errs = []

    def e(self, msg):
        self.errs.append(msg)

    def obj(self, v, where, required, optional=()):
        if not isinstance(v, dict):
            self.e("%s must be an object" % where)
            return False
        unknown = sorted(set(v) - set(required) - set(optional))
        if unknown:
            self.e("%s has unknown keys: %s" % (where, ", ".join(map(str, unknown))))
        miss = [k for k in required if k not in v]
        if miss:
            self.e("%s is missing: %s" % (where, ", ".join(miss)))
        return not unknown and not miss

    def s(self, v, where, maxb, minb=1):
        if not isinstance(v, str):
            self.e("%s must be a string" % where)
            return False
        n = C.blen(v)
        if n < minb or n > maxb:
            self.e("%s must be %d..%d bytes (is %d)" % (where, minb, maxb, n))
            return False
        return True

    def lst(self, v, where, lo, hi):
        if not isinstance(v, list):
            self.e("%s must be a list" % where)
            return False
        if not lo <= len(v) <= hi:
            self.e("%s has %d entries, allowed %d..%d" % (where, len(v), lo, hi))
            return False
        return True

    def integer(self, v, where, lo=0):
        if isinstance(v, bool) or not isinstance(v, int) or v < lo:
            self.e("%s must be an integer >= %d" % (where, lo))
            return False
        return True

    def boolean(self, v, where):
        if not isinstance(v, bool):
            self.e("%s must be true or false" % where)
            return False
        return True

    def one_of(self, v, where, allowed):
        if not isinstance(v, str) or v not in allowed:
            self.e("%s must be one of %s" % (where, "|".join(allowed)))
            return False
        return True

    def ident(self, v, where, rx, seen):
        if not isinstance(v, str) or not rx.match(v):
            self.e("%s has a bad id %r" % (where, v if isinstance(v, (str, int)) else type(v).__name__))
            return None
        if v in seen:
            self.e("%s: duplicate id %s" % (where, v))
            return None
        seen.add(v)
        return v


# ---------------------------------------------------------------- refs
def _confined(root, rest, label):
    """(problem|None, realpath): rest is a relative path that stays inside ROOT, outside .project-map/ and .git/."""
    if not rest or rest.startswith("/") or ".." in rest.split("/") or "\0" in rest or "\n" in rest:
        return "%s %r must be a relative path inside the project" % (label, rest[:60]), None
    rp = os.path.realpath(os.path.join(root, rest))
    if not C.under(rp, root):
        return "%s %s is outside the project" % (label, rest[:60]), None
    low = [x.casefold() for x in rest.split("/") + os.path.relpath(rp, os.path.realpath(root)).split("/")]
    if ".project-map" in low:
        return "%s %s points into .project-map/" % (label, rest[:60]), None
    if ".git" in low:
        return "%s %s points into .git/" % (label, rest[:60]), None
    return None, rp


def ref_problem(root, repos, ref):
    """None when ref is evidence that exists now: file:<rel>[:line] under ROOT, or commit:<sha7+> in a known repo."""
    if not isinstance(ref, str):
        return "ref must be a string"
    if ref.startswith("file:"):
        rest, line = ref[5:], None
        m = re.match(r"^(.*):([0-9]+)$", rest)
        if m:
            rest, line = m.group(1), int(m.group(2))
            if line < 1:
                return "line number must be a positive integer"
        prob, rp = _confined(root, rest, "file ref")
        if prob:
            return prob
        if not os.path.isfile(rp):
            return "file ref %s is not an existing regular file" % rest[:60]
        if line is not None and line > C.line_count(rp):
            return "file ref %s has no line %d" % (rest[:60], line)
        return None
    if ref.startswith("commit:"):
        sha = ref[7:]
        if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
            return "commit ref must be 7-40 hex characters (not HEAD or a branch)"
        for r in repos:
            if r.get("vcs") != "git":
                continue
            repo = root if r["path"] == "." else os.path.join(root, r["path"])
            try:
                rc, out = G.run(repo, "cat-file", "-t", sha, timeout=10.0)
            except G.GitArgError:
                continue
            if rc == 0 and out.strip() == "commit":
                return None
        return "commit %s not found in any known repository" % sha
    return "ref must start with file: or commit:"


# ---------------------------------------------------------------- closure predicates (resolves_when, section 12)
PRED_KINDS = {"tag_at_head": (("kind", "repo"), ("name",)), "branch_in_sync": (("kind", "repo"), ()),
              "commit": (("kind", "repo", "sha"), ()), "file": (("kind", "path"), ("exists",))}
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")


def normalize_resolves_when(rw):
    """-> (normalized list | None, [problems]). Syntax only: 1-3 predicates, closed key sets, every optional key explicit."""
    if not isinstance(rw, list) or not 1 <= len(rw) <= 3:
        return None, ["resolves_when must be a list of 1-3 predicates"]
    out, errs = [], []
    for n, p in enumerate(rw, 1):
        w = "resolves_when[%d]" % n
        if not isinstance(p, dict) or p.get("kind") not in PRED_KINDS:
            errs.append("%s kind must be one of %s" % (w, "|".join(PRED_KINDS)))
            continue
        req, opt = PRED_KINDS[p["kind"]]
        unknown = sorted(set(p) - set(req) - set(opt))
        miss = [k for k in req if k not in p]
        if unknown or miss:
            errs.append("%s (%s) %s" % (w, p["kind"], "has unknown keys: " + ", ".join(map(str, unknown)) if unknown
                                        else "is missing: " + ", ".join(miss)))
            continue
        q = {"kind": p["kind"]}
        for k in ("repo", "path"):
            if k in p:
                if not isinstance(p[k], str) or not 1 <= C.blen(p[k]) <= 200:
                    errs.append("%s %s must be a string of 1..200 bytes" % (w, k))
                    break
                q[k] = p[k]
        else:
            if p["kind"] == "tag_at_head":
                nm = p.get("name")
                if nm is not None and (not isinstance(nm, str) or not 1 <= C.blen(nm) <= 100):
                    errs.append("%s name must be a tag name (1..100 bytes) or null" % w)
                    continue
                q["name"] = nm
            elif p["kind"] == "commit":
                if not isinstance(p["sha"], str) or not SHA_RE.match(p["sha"]):
                    errs.append("%s sha must be 7-40 lowercase hex characters" % w)
                    continue
                q["sha"] = p["sha"]
            elif p["kind"] == "file":
                ex = p.get("exists", True)
                if not isinstance(ex, bool):
                    errs.append("%s exists must be true or false" % w)
                    continue
                q["exists"] = ex
            out.append(q)
    return (None, errs) if errs else (out, [])


def _snap_repo(snap, path):
    return next((r for r in snap.get("repos", []) if isinstance(r, dict) and r.get("path") == path), None)


REPO_GONE = "repo path escaped or changed; refresh facts"


def repo_dir(root, r):
    """The live directory of snapshot repository r, or None when it can no longer be trusted: the recorded path is
    resolved under ROOT (realpath), must stay inside ROOT's realpath, be a directory, and still be the root of its own git
    work tree (git's toplevel there is that same directory). A path swapped for a symlink to a repository elsewhere, a
    vanished directory or a different repository all fail closed."""
    path = r.get("path") if isinstance(r, dict) else None
    if not isinstance(path, str):
        return None
    prob, rp = _confined(root, path, "repo path")
    if prob or not os.path.isdir(rp):
        return None
    try:
        top = G.toplevel(rp, timeout=10.0)
    except Exception:   # noqa: BLE001 - anything that stops the check means "cannot confirm"
        return None
    return rp if top and os.path.realpath(top) == rp else None


def _tag_ident(snap, repo, name):
    """Display name of a tag -> (tid | None, problem | None). A tag at HEAD is bound by the identity (hash of its raw ref name)
    the script recorded for it; a display name that matches more than one head tag ('[redacted]' twice) is ambiguous. A
    name that is not at HEAD yet (the tag the decision waits for) is bound by the hash of the plain name itself, which is
    only possible for a name that is its own display form and legal in git (no backslash, no bracket)."""
    r = _snap_repo(snap, repo) or {}
    rel = r.get("release") if isinstance(r.get("release"), dict) else {}
    hits = [t for t in (rel.get("head_tags") or []) if isinstance(t, dict) and t.get("name") == name]
    if len(hits) > 1:
        return None, "tag name %s matches %d tags at HEAD of %s; it is ambiguous (several tags display the same)" \
            % (C.trim(name, 40), len(hits), C.trim(repo, 40))
    if hits:
        tid = hits[0].get("tid")
        return (tid, None) if isinstance(tid, str) and tid else (None, "tag %s has no recorded identity; refresh facts" % C.trim(name, 40))
    if C.display_safe(name) != name or "\\" in name or "[" in name:
        return None, "tag name %s is not a tag at HEAD of %s and is not a plain tag name (an escaped or redacted display form " \
            "cannot name a tag that is not there)" % (C.trim(name, 40), C.trim(repo, 40))
    why = G.tag_name_problem(name)
    if why:   # a name git can never create as a tag could never hold: refused when the decision is raised
        return None, "tag name %s is not a legal git tag name (%s); a future tag must be a name git accepts" % (C.trim(name, 40), why)
    return C.tag_tid(name), None


def _tag_at_head(snap, repo, name):
    rel = (_snap_repo(snap, repo) or {}).get("release")
    return any(isinstance(t, dict) and t.get("name") == name for t in ((rel or {}).get("head_tags") or [])) \
        if isinstance(rel, dict) else False


def bind_tids(snap, preds):
    """Copy of well-formed predicates with the identity of every named tag stored beside its display name."""
    out = []
    for p in preds:
        q = dict(p)
        if q["kind"] == "tag_at_head" and q.get("name") is not None:
            q["tid"] = _tag_ident(snap, q["repo"], q["name"])[0]
        out.append(q)
    return out


def strip_tids(preds):
    return [{k: v for k, v in p.items() if k != "tid"} for p in preds if isinstance(p, dict)]


def predicates_in_snapshot(root, snap, preds):
    """Raise-time checks of well-formed predicates against the snapshot: the repo exists (and is git, and its path is still
    confined under ROOT), the path is confined, a named tag is unambiguous."""
    errs = []
    for n, p in enumerate(preds, 1):
        w = "resolves_when[%d]" % n
        if p["kind"] == "file":
            prob, _rp = _confined(root, p["path"], "path")
            if prob:
                errs.append("%s %s" % (w, prob))
            continue
        r = _snap_repo(snap, p["repo"])
        if r is None:
            errs.append("%s repo %s is not a repository of this project (see repos[] in the pack)" % (w, C.trim(p["repo"], 60)))
        elif r.get("vcs") != "git":
            errs.append("%s repo %s is not a git repository" % (w, C.trim(p["repo"], 60)))
        elif repo_dir(root, r) is None:
            errs.append("%s repo %s: %s" % (w, C.trim(p["repo"], 60), REPO_GONE))
        elif p["kind"] == "tag_at_head" and p.get("name") is not None:
            tid, prob = _tag_ident(snap, p["repo"], p["name"])
            if prob:
                errs.append("%s %s" % (w, prob))
            elif not _tag_at_head(snap, p["repo"], p["name"]) \
                    and G.tag_name_git_ok(repo_dir(root, r), p["name"]) is False:   # the real git has the last word when it can speak
                errs.append("%s tag name %s is not a legal git tag name (git check-ref-format refuses it)"
                            % (w, C.trim(p["name"], 40)))
    return errs


def _describe(p):
    k = p["kind"]
    if k == "tag_at_head":
        return "tag %s at HEAD of %s" % (p["name"] or "(any)", p["repo"])
    if k == "branch_in_sync":
        return "%s in sync with its upstream" % p["repo"]
    if k == "commit":
        return "commit %s in %s" % (p["sha"], p["repo"])
    return "file %s %s" % (p["path"], "exists" if p["exists"] else "is absent")


def _eval(root, snap, p):
    """-> (holds, evidence, why). `why` is set only when the predicate could not be established (unknown), never for a
    plain "not yet": anything that cannot be established is false."""
    k = p["kind"]
    if k == "file":
        prob, rp = _confined(root, p["path"], "path")
        if prob:
            return False, "", "path is not confined to the project"
        if p["exists"]:
            return os.path.isfile(rp), "file:" + p["path"], ""
        # absence of the REQUESTED directory entry: lstat of the confined original path, never of its dereferenced target
        # (a dangling symlink is an entry that exists)
        try:
            os.lstat(os.path.join(root, p["path"]))
        except (FileNotFoundError, NotADirectoryError):
            return True, "absent:" + p["path"], ""
        except OSError as ex:
            return False, "", "cannot check %s: %s" % (C.trim(p["path"], 40), ex.strerror or type(ex).__name__)
        return False, "absent:" + p["path"], ""
    r = _snap_repo(snap, p["repo"])
    if r is None or r.get("vcs") != "git":
        return False, "", ""
    repo = repo_dir(root, r)
    if repo is None:   # a path swapped for a link elsewhere, removed or turned into another repository: facts are stale
        return False, "", "%s: %s" % (C.trim(p["repo"], 40), REPO_GONE)
    rel = r.get("release") if isinstance(r.get("release"), dict) else {}
    if k == "tag_at_head":
        tags = [t for t in (rel.get("head_tags") or []) if isinstance(t, dict) and isinstance(t.get("name"), str)]
        want = p["name"]
        if want is None:
            hit = tags[0]["name"] if tags else None
        else:
            tid = p.get("tid") or C.tag_tid(want)
            hit = next((t["name"] for t in tags if t.get("tid") == tid), None)
        return hit is not None, ("tag:" + (hit or want or "")), ""
    if k == "branch_in_sync":
        return (rel.get("sync") or {}).get("state") == "aligned", "sync:aligned", ""
    sha = p["sha"]
    ev = "commit:" + sha
    if len(sha) == 7 and any(i.get("h") == sha and i.get("r") == p["repo"] for d in (snap.get("commits") or {}).get("days", [])
                             if isinstance(d, dict) for i in d.get("items", []) if isinstance(i, dict)):
        return True, ev, ""
    try:
        rc, out = G.run(repo, "cat-file", "-t", sha, timeout=10.0)
    except G.GitArgError:
        return False, ev, ""
    return (rc == 0 and out.strip() == "commit"), ev, ""


def eval_predicate(root, snap, p):
    """-> (holds, evidence string). Script-evaluated against the staged snapshot (file: against the disk, commit: against
    git, in the repository's confined live directory); anything that cannot be established is false."""
    return _eval(root, snap, p)[:2]


def evaluate_resolves_when_ex(root, snap, preds):
    """-> (every predicate holds, [evidence of those that hold], [descriptions of those that do not], [reasons a predicate
    could not be established])."""
    ok, ev, unmet, why = True, [], [], []
    for p in preds:
        holds, e, w = _eval(root, snap, p)
        if holds:
            ev.append(e)
        else:
            ok = False
            unmet.append(_describe(p))
            if w:
                why.append(w)
    return ok, ev, unmet, why


def evaluate_resolves_when(root, snap, preds):
    """-> (every predicate holds, [evidence strings of the predicates that hold], [descriptions of those that do not])."""
    return evaluate_resolves_when_ex(root, snap, preds)[:3]


# ---------------------------------------------------------------- plan
def validate_plan(v, plan, root, repos, check_refs):
    if not v.obj(plan, "plan", ("schema", "generation", "origin", "phases")):
        return
    for m in C.unsafe_strings(plan, "plan"):
        v.e(m)
    if plan["schema"] != C.SCHEMA_PLAN:
        v.e("plan.schema must be %s" % C.SCHEMA_PLAN)
    v.one_of(plan["origin"], "plan.origin", ("proposed", "owner"))
    if not v.lst(plan["phases"], "plan.phases", 1, 7):
        return
    pids, cids = set(), set()
    for ph in plan["phases"]:
        if not v.obj(ph, "phase", ("id", "label", "criteria")):
            continue
        pid = v.ident(ph["id"], "phase", PHASE_ID, pids)
        v.s(ph["label"], "phase %s label" % ph.get("id"), 60)
        if not v.lst(ph["criteria"], "phase %s criteria" % ph.get("id"), 0, 8):
            continue
        for c in ph["criteria"]:
            if not v.obj(c, "criterion", ("id", "text", "done"), ("ref",)):
                continue
            cid = v.ident(c["id"], "criterion", CRIT_ID, cids)
            if cid and pid and not cid.startswith(pid + "."):
                v.e("criterion %s does not belong to phase %s" % (cid, pid))
            v.s(c["text"], "criterion %s text" % c.get("id"), 80)
            v.boolean(c["done"], "criterion %s done" % c.get("id"))
            ref = c.get("ref")
            if ref is not None and not isinstance(ref, str):
                v.e("criterion %s ref must be a string or null" % c.get("id"))
            elif c.get("done") is True:
                if not ref:
                    v.e("criterion %s is done but has no ref" % c.get("id"))
                elif check_refs and (pr := ref_problem(root, repos, ref)):
                    v.e("criterion %s: %s" % (c.get("id"), pr))


def apply_updates(plan, updates):
    P = copy.deepcopy(plan)
    idx = {c["id"]: c for ph in P["phases"] for c in ph["criteria"]}
    for u in updates:
        c = idx[u["id"]]
        c["done"] = u["done"]
        c["ref"] = u.get("ref") or None
    return P


def derive_phases(plan, current_phase):
    """-> (phases for state.json, current id, blocking labels)."""
    phs = []
    for ph in plan["phases"]:
        total = len(ph["criteria"])
        dn = sum(1 for c in ph["criteria"] if c["done"])
        phs.append({"id": ph["id"], "label": ph["label"], "done": dn, "total": total, "complete": total >= 1 and dn == total,
                    "criteria": [dict(c) for c in ph["criteria"]]})
    by = {p["id"]: p for p in phs}
    cur = current_phase if not by[current_phase]["complete"] else next((p["id"] for p in phs if not p["complete"]), current_phase)
    ci = [p["id"] for p in phs].index(cur)
    nxt = next((p["id"] for p in phs[ci + 1:] if not p["complete"]), None)
    blocking = []
    for i, p in enumerate(phs):
        if p["complete"]:
            p["state"] = "done"
        elif p["id"] == cur:
            p["state"] = "current"
        elif i < ci:
            p["state"] = "open"
            p["blocking"] = True
            blocking.append(p["label"])
        elif p["id"] == nxt:
            p["state"] = "next"
        else:
            p["state"] = "later"
        p.pop("complete")
    return phs, cur, blocking


# ---------------------------------------------------------------- judgement
def validate_judgement(J, raw_len, ctx):
    """ctx: root, snap, plan (the plan updates apply to), prev (state|None), full (bool). -> list of error strings."""
    v = V()
    root, snap, plan, prev = ctx["root"], ctx["snap"], ctx["plan"], ctx["prev"]
    repos = snap.get("repos", [])
    if raw_len > 6144:
        v.e("judgement.out.json is %d bytes, hard limit 6144 (target 3072)" % raw_len)
    REQ = ("generation", "project", "run", "headline", "parts", "current_phase", "next_step", "intent")
    if not v.obj(J, "judgement", REQ, tuple(TOP_KEYS - set(REQ))):
        if not isinstance(J, dict):
            return v.errs
    if J.get("generation") != ctx["inv_name"]:
        v.e("generation %r does not match this invocation (%s)" % (str(J.get("generation"))[:30], ctx["inv_name"]))
    pr = J.get("project")
    if v.obj(pr, "project", ("name", "goal"), ("tagline", "ledger")):
        v.s(pr["name"], "project.name", 40)
        v.s(pr["goal"], "project.goal", 160)
        if "tagline" in pr:
            v.s(pr["tagline"], "project.tagline", 80)
        if pr.get("ledger") is not None:
            v.s(pr["ledger"], "project.ledger", 200)
    run = J.get("run")
    if v.obj(run, "run", ("type", "model")):
        v.one_of(run["type"], "run.type", ("UPDATE", "FULL"))
        v.s(run["model"], "run.model", 40)
        if run["type"] != ("FULL" if ctx["full"] else "UPDATE"):
            v.e("run.type %s does not match this invocation" % run["type"])
    if "watch" in J:
        if v.lst(J["watch"], "watch", 0, 40):
            seen_w = set()
            for w in J["watch"]:
                if not v.s(w, "watch entry", 200):
                    continue
                pr_ = C.watch_problem(w)
                if pr_:
                    v.e("watch entry %r %s" % (w[:60], pr_))
                norm = os.path.normpath(w)
                if norm in seen_w:
                    v.e("watch entry %r is a duplicate" % w[:60])
                seen_w.add(norm)
    if "repos" in J and v.lst(J["repos"], "repos", 0, 12):
        for r in J["repos"]:
            if v.s(r, "repos entry", 200) and C.watch_problem(r):
                v.e("repos entry %r %s" % (r[:60], C.watch_problem(r)))
    hl = J.get("headline")
    if v.obj(hl, "headline", ("text", "tone")):
        v.s(hl["text"], "headline.text", 180)
        v.one_of(hl["tone"], "headline.tone", TONES)

    pids = set()
    parts = J.get("parts")
    if v.lst(parts, "parts", 1, 12):
        for p in parts:
            if not v.obj(p, "part", ("id", "label", "status"), ("line", "ref", "blocked_by")):
                continue
            pid = v.ident(p["id"], "part", PART_ID, pids)
            v.s(p["label"], "part %s label" % p.get("id"), 40)
            v.one_of(p["status"], "part %s status" % p.get("id"), PART_ST)
            if "line" in p:
                v.s(p["line"], "part %s line" % p.get("id"), 100, 0)
            if "ref" in p and p["ref"] is not None:
                pr_ = ref_problem(root, repos, p["ref"])
                if pr_:
                    v.e("part %s: %s" % (p.get("id"), pr_))
            if p.get("status") == "done" and not p.get("ref"):
                v.e("part %s is done but has no ref" % p.get("id"))
        for p in parts:
            if isinstance(p, dict) and p.get("status") == "stuck":
                b = p.get("blocked_by")
                if not isinstance(b, str) or b not in pids or b == p.get("id"):
                    v.e("part %s is stuck: blocked_by must name another part id" % p.get("id"))
            elif isinstance(p, dict) and "blocked_by" in p and (not isinstance(p["blocked_by"], str) or p["blocked_by"] not in pids):
                v.e("part %s blocked_by must name a part id" % p.get("id"))

    phase_ids = {ph["id"] for ph in plan.get("phases", [])} if isinstance(plan, dict) else set()
    if not isinstance(J.get("current_phase"), str) or J["current_phase"] not in phase_ids:
        v.e("current_phase must be one of the plan's phase ids")
    ups = J.get("criteria_updates", [])
    if v.lst(ups, "criteria_updates", 0, 64):
        crit = {c["id"] for ph in plan.get("phases", []) for c in ph.get("criteria", [])} if isinstance(plan, dict) else set()
        seen = set()
        for u in ups:
            if not v.obj(u, "criteria_updates entry", ("id", "done"), ("ref",)):
                continue
            if u["id"] not in crit:
                v.e("criteria_updates: unknown criterion %r" % str(u["id"])[:20])
            elif u["id"] in seen:
                v.e("criteria_updates: duplicate %s" % u["id"])
            seen.add(u["id"])
            v.boolean(u["done"], "criteria_updates %s done" % u["id"])
            ref = u.get("ref")
            if ref is not None and not isinstance(ref, str):
                v.e("criteria_updates %s ref must be a string or null" % u["id"])
            elif u.get("done") is True:
                pr_ = ref_problem(root, repos, ref) if ref else "done needs a ref"
                if pr_:
                    v.e("criteria_updates %s: %s" % (u["id"], pr_))
    eta = J.get("eta")
    if eta is not None and v.obj(eta, "eta", ("low", "high", "unit", "basis", "confidence")):
        if v.integer(eta["low"], "eta.low") and v.integer(eta["high"], "eta.high") and eta["high"] < eta["low"]:
            v.e("eta.high must be >= eta.low")
        v.one_of(eta["unit"], "eta.unit", ("days", "weeks"))
        v.s(eta["basis"], "eta.basis", 80)
        v.one_of(eta["confidence"], "eta.confidence", ("low", "med", "high"))
    ns = J.get("next_step")
    if v.obj(ns, "next_step", ("title", "why", "actor"), ("unblocks",)):
        v.s(ns["title"], "next_step.title", 80)
        v.s(ns["why"], "next_step.why", 160)
        v.one_of(ns["actor"], "next_step.actor", ACTORS)
        if v.lst(ns.get("unblocks", []), "next_step.unblocks", 0, 12):
            for u in ns.get("unblocks", []):
                if u not in pids:
                    v.e("next_step.unblocks references unknown part %r" % str(u)[:24])
    _decisions(v, J, ctx)
    _since(v, J, ctx)
    _intent(v, J)
    if v.lst(J.get("loops", []), "loops", 0, 4):
        lseen = set()
        for lp in J.get("loops", []):
            if v.obj(lp, "loop", ("id", "kind", "rounds", "failed", "note")):
                v.ident(lp["id"], "loop", LOOP_ID, lseen)
                v.one_of(lp["kind"], "loop.kind", ("review", "retry", "wait"))
                v.integer(lp["rounds"], "loop.rounds")
                v.integer(lp["failed"], "loop.failed")
                v.s(lp["note"], "loop.note", 100, 0)
    if v.lst(J.get("risks", []), "risks", 0, 4):
        rseen = set()
        for r in J.get("risks", []):
            if v.obj(r, "risk", ("id", "text", "severity")):
                v.ident(r["id"], "risk", RISK_ID, rseen)
                v.s(r["text"], "risk.text", 120)
                v.one_of(r["severity"], "risk.severity", ("low", "med", "high"))
    if v.lst(J.get("template_feedback", []), "template_feedback", 0, 5):
        for t in J.get("template_feedback", []):
            if v.obj(t, "template_feedback entry", ("where", "text")):
                v.s(t["where"], "template_feedback.where", 40)
                v.s(t["text"], "template_feedback.text", 160)
    retired = set(prev.get("retired_ids", [])) if prev else set()
    in_prev = {x["id"] for k in ("parts", "decisions") for x in (prev or {}).get(k, []) if isinstance(x, dict)}
    for i in sorted(pids):
        if i in retired and i not in in_prev:
            v.e("part id %s was retired, ids are never reused" % i)
    for m in C.unsafe_strings(J, "judgement"):
        v.e(m)
    return v.errs


def _decisions(v, J, ctx):
    decs = J.get("decisions", [])
    if not v.lst(decs, "decisions", 0, 6):
        return
    prev = ctx["prev"]
    retired = retired_decision_ids(prev)
    in_prev = {d["id"] for d in (prev or {}).get("decisions", []) if isinstance(d, dict)}
    seen = set()
    sd = {x["id"]: x for x in ctx["snap"].get("decisions", []) if isinstance(x, dict) and isinstance(x.get("id"), str)}
    for d in decs:
        if isinstance(d, dict):
            for k in SCRIPT_OWNED:
                if k in d:
                    v.e("decision %s: %s is owned by the script and must not be supplied" % (d.get("id"), k))
        if not v.obj(d, "decision", ("id", "q", "options", "default"),
                     ("recommended", "hard_rule", "deadline", "ready", "overtaken", "resolves_when") + SCRIPT_OWNED):
            continue
        did = v.ident(d["id"], "decision", DEC_ID, seen)
        if did and did in retired and did not in in_prev:
            v.e("decision id %s was retired, ids are never reused (drop it from decisions[])" % did)
        w = "decision %s" % d.get("id")
        v.s(d["q"], w + " q", 140)
        oids = set()
        if v.lst(d["options"], w + " options", 2, 5):
            for o in d["options"]:
                if v.obj(o, w + " option", ("id", "label")):
                    v.ident(o["id"], w + " option", re.compile(r"^[A-E]$"), oids)
                    v.s(o["label"], w + " option label", 60)
        if d.get("recommended") is not None and d["recommended"] not in oids:
            v.e("%s: recommended must be an option id or null" % w)
        if not isinstance(d["default"], str) or (d["default"] != "hold" and d["default"] not in oids):
            v.e("%s: default must be an option id or 'hold'" % w)
        hr = d.get("hard_rule")
        if hr is not None:
            v.s(hr, w + " hard_rule", 40)
        v.boolean(d.get("ready", True), w + " ready")
        if (hr is not None or d.get("ready", True) is False) and d["default"] != "hold":
            v.e("%s: a hard_rule or ready:false decision must have default 'hold'" % w)
        if d.get("deadline") is not None and C.parse_iso(d["deadline"]) is None:
            v.e("%s: deadline must be an ISO timestamp or null" % w)
        staged = sd.get(d["id"])
        if "resolves_when" in d:
            norm, errs = normalize_resolves_when(d["resolves_when"])
            if staged is not None:   # a carried decision: its closure predicate was fixed when it was raised
                if errs or norm != strip_tids(staged.get("resolves_when") or []):
                    v.e("%s: resolves_when is fixed when the decision is raised; it cannot be added or changed later" % w)
            else:
                for m in errs or predicates_in_snapshot(ctx["root"], ctx["snap"], norm):
                    v.e("%s %s" % (w, m))
        if "overtaken" in d:
            ov = d["overtaken"]
            if v.obj(ov, w + " overtaken", ("why",), ("ref",)) and v.s(ov["why"], w + " overtaken.why", 120):
                if (staged or {}).get("status") not in OPEN_ST:
                    v.e("%s: overtaken closes an open or overdue decision only" % w)
                elif not staged.get("resolves_when"):
                    v.e("%s: overtaken needs the resolves_when predicate set when the decision was raised; this one has none, "
                        "so only the owner's answer closes it" % w)
                else:
                    ok, ev, unmet, why = evaluate_resolves_when_ex(ctx["root"], ctx["snap"], staged["resolves_when"])
                    if not ok:
                        v.e("%s: overtaken, but resolves_when does not hold yet (%s)%s"
                            % (w, "; ".join(unmet), " [could not be established: %s]" % "; ".join(why) if why else ""))
                    elif "ref" in ov and ov["ref"] not in ev:
                        v.e("%s overtaken.ref must be one of the checked evidence strings: %s" % (w, ", ".join(ev)))
    for i in sorted(sd):   # never-vanish: an open decision is carried or closed by events, never silently dropped
        if sd[i].get("status") in OPEN_ST and i not in seen:
            if sd[i].get("resolves_when"):
                v.e("decision %s is open: carry it, or close it with overtaken{why} once its resolves_when holds" % i)
            else:
                v.e("decision %s is open and has no resolves_when: carry it unchanged, only the owner's answer closes it" % i)


# ---------------------------------------------------------------- intent: the immediate objective (14.1)
def _intent(v, J):
    """judgement.intent (required on every UPDATE and FULL): {outcome, done_when}, <= 120 bytes each. The model never writes
    `accepted` (the owner's record), exclusions or a hash: those are script-owned."""
    it = J.get("intent")
    if v.obj(it, "intent", ("outcome", "done_when")):
        v.s(it["outcome"], "intent.outcome", 120)
        v.s(it["done_when"], "intent.done_when", 120)


# ---------------------------------------------------------------- since: what changed, what needs attention (13.2)
SINCE_KINDS = ("decision", "continue", "waiting", "unchecked")
CHANGE_STATES = ("landed", "uncommitted")


def attention_candidates(J, ctx):
    """Ids of the decisions that make `since.attention.kind` MANDATORY (13.2): open or overdue with ready != false in the
    STAGED snapshot and not closed by overtaken in this judgement, plus decisions raised in this judgement with
    ready != false. A staged decision with ready:false never forces (the model may flip it ready, the script reconciles
    at publication, 13.5)."""
    snap, prev = ctx["snap"], ctx.get("prev")
    jd = {d["id"]: d for d in (J.get("decisions") or []) if isinstance(d, dict) and isinstance(d.get("id"), str)}
    staged = {x["id"]: x for x in snap.get("decisions", []) if isinstance(x, dict) and isinstance(x.get("id"), str)}
    prev_closed = {d.get("id") for d in (prev or {}).get("decisions", []) if isinstance(d, dict) and d.get("status") in CLOSED_ST}
    out = []
    for i, x in staged.items():
        if x.get("status") in OPEN_ST and x.get("ready", True) is not False and not isinstance((jd.get(i) or {}).get("overtaken"), dict):
            out.append(i)
    for i, d in jd.items():
        if i not in staged and i not in prev_closed and d.get("ready", True) is not False:
            out.append(i)
    return sorted(out)


def _since(v, J, ctx):
    """judgement.since: required when the pack carries a baseline (snapshot.since not null), absent or null on a first map."""
    base = ctx["snap"].get("since")
    s = J.get("since")
    if base is None:
        if s is not None:
            v.e("since must be absent or null: this pack has no previous assessment to compare with (first map)")
        return
    if s is None:
        v.e("since is required: the pack carries a baseline (changes[0-3], attention{kind,text,why[,id]}, not_checked[0-3])")
        return
    if not v.obj(s, "since", ("changes", "attention"), ("not_checked",)):
        return
    root, repos = ctx["root"], ctx["snap"].get("repos", [])
    root_git = (next((r for r in repos if isinstance(r, dict) and r.get("path") == "."), None) or {}).get("vcs") == "git"
    if v.lst(s["changes"], "since.changes", 0, 3):
        seen_t = set()
        for n, c in enumerate(s["changes"], 1):
            w = "since.changes[%d]" % n
            if not v.obj(c, w, ("text", "state"), ("ref",)):
                continue
            if v.s(c["text"], w + " text", 120):
                norm = " ".join(c["text"].split()).casefold()
                if norm in seen_t:
                    v.e("%s text duplicates another change (texts must be unique)" % w)
                seen_t.add(norm)
            if not v.one_of(c["state"], w + " state", CHANGE_STATES):
                continue
            ref = c.get("ref")
            if ref is not None and not isinstance(ref, str):
                v.e("%s ref must be a string or null" % w)
            elif c["state"] == "landed":
                if not ref:
                    v.e("%s is landed but has no ref: name the commit (commit:<sha7+>)" % w)
                elif ref.startswith("commit:") or (ref.startswith("file:") and not root_git):
                    pr_ = ref_problem(root, repos, ref)
                    if pr_:
                        v.e("%s ref: %s" % (w, pr_))
                else:
                    v.e("%s is landed: its ref must be commit:<sha7+>%s, not %s" % (
                        w, "" if root_git else " (or file:<rel> in a project without git)", C.trim(ref, 40)))
            elif ref is not None:   # uncommitted: working-tree work, a file ref at most
                if not ref.startswith("file:"):
                    v.e("%s is uncommitted: its ref must be file:<rel>[:line] or null, not %s" % (w, C.trim(ref, 40)))
                else:
                    pr_ = ref_problem(root, repos, ref)
                    if pr_:
                        v.e("%s ref: %s" % (w, pr_))
    att = s["attention"]
    must = attention_candidates(J, ctx)
    if v.obj(att, "since.attention", ("kind", "text", "why"), ("id",)):
        kind_ok = v.one_of(att["kind"], "since.attention.kind", SINCE_KINDS)
        v.s(att["text"], "since.attention.text", 120)
        v.s(att["why"], "since.attention.why", 120)
        if kind_ok and att["kind"] == "decision":
            aid = att.get("id")
            if not isinstance(aid, str) or not DEC_ID.match(aid):
                v.e("since.attention.id is required when kind is decision: a decision id (D-nnn)")
            elif aid not in must:
                v.e("since.attention.id %s is not an open decision that needs the owner (%s)" % (
                    aid, "open and ready: " + ", ".join(must) if must else "none is open and ready in this pack"))
        elif kind_ok:
            if "id" in att:
                v.e("since.attention.id must be absent unless kind is decision")
            if must:
                v.e("since.attention.kind must be decision (id %s): %s open and ready, the owner's decision always comes first"
                    % (must[0], ", ".join(must)))
    nc = s.get("not_checked", [])
    if v.lst(nc, "since.not_checked", 0, 3):
        for n, x in enumerate(nc, 1):
            v.s(x, "since.not_checked[%d]" % n, 80)


# ---------------------------------------------------------------- merge
def diff_changes(prev, S, t):
    """What materially moved between the previous and the new state: [{id, label, text, to, at}] (cap 8)."""
    out = []

    def add(i, label, text, to=None):
        out.append({"id": i, "label": label, "text": text, "to": to, "at": t})

    if (prev.get("headline") or {}).get("text") != S["headline"]["text"]:
        add("headline", "Headline", "changed")
    po, pn = prev.get("next_step") or {}, S["next_step"]
    if po.get("title") != pn["title"] or po.get("actor") != pn["actor"]:
        add("next_step", "Next step", "now %s (%s)" % (pn["title"], pn["actor"]))
    old_p = {p["id"]: p for p in prev.get("parts", [])}
    for p in S["parts"]:
        o = old_p.get(p["id"])
        if not o:
            add(p["id"], p["label"], "added as %s" % p["status"], p["status"])
        elif o.get("status") != p["status"]:
            add(p["id"], p["label"], "status: %s → %s" % (o.get("status"), p["status"]), p["status"])
        elif o.get("line") != p.get("line"):
            add(p["id"], p["label"], "line changed")
    for i, o in old_p.items():
        if i not in {p["id"] for p in S["parts"]}:
            add(i, o.get("label", i), "removed")
    old_ph = {p["id"]: p for p in prev.get("phases", [])}
    for ph in S["phases"]:
        o = old_ph.get(ph["id"])
        if o and o.get("done") != ph["done"]:
            add(ph["id"], ph["label"], "criteria %d of %d done" % (ph["done"], ph["total"]))
    if (prev.get("focus") or {}).get("phase") != S["focus"]["phase"] and prev.get("focus"):
        add("phase", "Phase", "current is now %s" % S["focus"]["phase"])
    if prev.get("eta") != S.get("eta"):
        add("eta", "ETA", "changed")
    old_d = {d["id"]: d for d in prev.get("decisions", [])}
    for d in S["decisions"]:
        o = old_d.get(d["id"])
        if not o:
            add(d["id"], d["id"], "opened", "open")
        elif o.get("status") != d["status"]:
            add(d["id"], d["id"], "overtaken: %s" % d.get("overtaken_why", "") if d["status"] == "overtaken"
                else "status: %s → %s" % (o.get("status"), d["status"]), d["status"])
        elif o.get("q") != d.get("q") or [x.get("id") for x in o.get("options", [])] != [x.get("id") for x in d.get("options", [])]:
            add(d["id"], d["id"], "question or options changed")
    if prev.get("risks") != S["risks"]:
        add("risks", "Risks", "changed")
    return out[:8]


def merge_decisions(J, snap, prev, root=None):
    """Model text for open/overdue decisions, script copy for answered/defaulted ones (6.4 freezing). A decision the model
    closes with overtaken{why} becomes status "overtaken" (script-owned, one generation, like answered): the record is a
    verbatim copy of the STAGED decision, the model's text for that id is ignored apart from overtaken.why, and the
    script re-evaluates the frozen resolves_when (the evidence it holds becomes overtaken_ref)."""
    sd = {d["id"]: d for d in snap["decisions"]}
    pd = {d["id"]: d for d in (prev or {}).get("decisions", [])}
    t = snap["facts_at"]
    out, seen = [], set()
    for m in J.get("decisions", []):
        i = m["id"]
        seen.add(i)
        s = sd.get(i)
        if s is None and (pd.get(i) or {}).get("status") in CLOSED_ST:
            continue   # a closed decision lives for one run: the model still carrying it does not keep it
        if s is not None and s["status"] in ("answered", "defaulted"):
            out.append(copy.deepcopy(s))
            continue
        if s is not None and s["status"] in OPEN_ST and isinstance(m.get("overtaken"), dict) and s.get("resolves_when"):
            ok, ev, _unmet = evaluate_resolves_when(root or snap["root"], snap, s["resolves_when"])
            if ok:
                d = copy.deepcopy(s)
                d.update(status="overtaken", closed_by="events", closed_at=t, overtaken_why=m["overtaken"]["why"],
                         overtaken_ref=" + ".join(ev))
                d.setdefault("raised_at", t)
                out.append(d)
                continue
        d = {"recommended": None, "hard_rule": None, "deadline": None, "ready": True}
        d.update({k: copy.deepcopy(m[k]) for k in ("id", "q", "options", "recommended", "default", "hard_rule", "deadline", "ready") if k in m})
        if d["deadline"] is not None:
            d["deadline"] = C.iso(C.parse_iso(d["deadline"]))
        if s is not None and s["status"] == "overdue" and (s.get("hard_rule") or s.get("ready") is False):
            d["hard_rule"], d["default"], d["ready"] = s.get("hard_rule"), "hold", s.get("ready", True)
        rw = s.get("resolves_when") if s is not None else \
            (bind_tids(snap, normalize_resolves_when(m["resolves_when"])[0] or []) if "resolves_when" in m else None)
        if rw:
            d["resolves_when"] = copy.deepcopy(rw)
        d["status"] = s["status"] if s is not None else "open"
        d["raised_at"] = (s or pd.get(i) or {}).get("raised_at") or t
        out.append(d)
    for i, s in sd.items():
        if i not in seen and s["status"] in ("answered", "defaulted"):
            out.append(copy.deepcopy(s))
    for d in out:
        d.setdefault("raised_at", t)
    return out


# ---------------------------------------------------------------- since in the state, assurance, wording (13.4, 13.5)
def ask_ids(decisions):
    """Ids of the decisions that need the owner now: open or overdue with ready != false."""
    return sorted(d["id"] for d in decisions if isinstance(d, dict) and d.get("status") in OPEN_ST and d.get("ready", True) is not False)


def reconcile_attention(judged, decisions):
    """R7/S1: the judged attention against the FINAL ready open/overdue decisions (after the final answers read, deferred
    closures and late answers). -> (attention, judged-or-None). `judged` is kept as since.attention_judged whenever the script
    replaced it. An answered decision id is never rendered as a current owner decision."""
    ids = ask_ids(decisions)
    kind, aid = judged.get("kind"), judged.get("id")
    if kind == "decision" and aid in ids:
        return judged, None
    if ids:   # the judged attention is not about a decision that is still open: the lowest eligible one is the primary item
        q = next((d.get("q") for d in decisions if d.get("id") == ids[0]), "")
        return {"kind": "decision", "id": ids[0], "text": C.trim(q, 120), "why": "still open at publication", "by": "script"}, judged
    if kind == "decision":   # it named a decision and none remains
        return {"kind": "unchecked", "text": C.trim("%s was answered after the assessment; attention not reassessed" % aid, 120),
                "why": "pending the next judgement", "by": "script"}, judged
    return judged, None


def build_since(snap, J, decisions, judged_seen):
    """state.since (13.5): the script's counts as staged, `listed` from judged_seen, the model block verbatim, with the
    attention reconciled against the final decisions. None when the pack had no baseline (first map)."""
    base = snap.get("since")
    block = J.get("since")
    if not isinstance(base, dict) or not isinstance(block, dict):
        return None
    att, was = reconcile_attention(copy.deepcopy(block["attention"]), decisions)
    out = {"from": {"generation": base.get("generation"), "assessed_at": base.get("assessed_at")},
           "commits": base.get("commits"), "listed": (judged_seen or {}).get("commits") if judged_seen else None,
           "dirty": base.get("dirty"), "hours": base.get("hours"),
           "changes": copy.deepcopy(block.get("changes", [])), "attention": att, "not_checked": list(block.get("not_checked", []))}
    if was is not None:
        out["attention_judged"] = was
    return out


def _intent_view(rec, keys):
    return {k: copy.deepcopy(rec[k]) for k in keys if k in rec}


def build_intent(staged, final, model):
    """state.intent (14.1, 14.3). `staged`: the intent of the STAGED snapshot (the accepted record the lifecycle had applied when
    the judgement was staged); `final`: the intent after the late-answer reduction (the owner's record at publication);
    `model`: judgement.intent. TARGET = the intention this judgement served, frozen from the staged input: the staged accepted
    record if there was one, else the model's text with no exclusions. ACCEPTED = the final record. PROPOSED = the model's text
    unless it says what the final accepted record says (exclusions are the record's own: the model cannot set them); with no
    accepted record the model's text is the standing proposal, awaiting "confirm focus"."""
    sacc = (staged or {}).get("accepted")
    facc = (final or {}).get("accepted")
    mo, md = model["outcome"], model["done_when"]
    if isinstance(sacc, dict):
        target = _intent_view(sacc, ("outcome", "done_when", "exclusions", "hash"))
    else:
        target = {"outcome": mo, "done_when": md, "exclusions": [], "hash": C.intent_hash(mo, md, [])}
    mh = C.intent_hash(mo, md, facc.get("exclusions") if isinstance(facc, dict) else [])
    proposed = None if (isinstance(facc, dict) and mh == facc.get("hash")) else {"outcome": mo, "done_when": md, "hash": mh}
    return {"accepted": copy.deepcopy(facc) if isinstance(facc, dict) else None, "proposed": proposed, "target": target}


def _release_unverified(S):
    for r in S.get("repos") or []:
        rel = r.get("release") if isinstance(r, dict) else None
        if not isinstance(rel, dict):
            continue
        key = rel.get("key") if isinstance(rel.get("key"), dict) else {}
        if rel.get("inconsistent") or rel.get("head_tags_partial") or key.get("partial") or key.get("unverified"):
            return True
    return False


def omitted_work(seen):
    """Short phrases (<= 40 bytes) for the relevant work the judged pack left out (13.3 "Relevant work omitted")."""
    out = []
    if seen.get("commits", 0) < seen.get("commits_total", 0):
        out.append("%d of %d commits shown to the model" % (seen["commits"], seen["commits_total"]))
    if seen.get("dirty", 0) < seen.get("dirty_total", 0):
        out.append("%d of %d changed files shown" % (seen["dirty"], seen["dirty_total"]))
    if seen.get("decisions_cut"):
        out.append("%d decisions cut in the pack" % seen["decisions_cut"])
    if seen.get("answers_dropped"):
        out.append("%d answers left out of the pack" % seen["answers_dropped"])
    if seen.get("ledger_cut"):
        out.append("ledger cut in the pack")
    if seen.get("repos_cut"):
        out.append("%d repos left out of the pack" % seen["repos_cut"])
    if seen.get("watch_moved_cut"):
        out.append("%d changed watch files not shown" % seen["watch_moved_cut"])
    return [C.trim(x, 40) for x in out]


def assurance(S):
    """The ONE predicate behind page, brief and handoff (13.4): {ok, why[<=40 bytes each]}. Computed by build_state and
    recomputed by every mechanical refresh from its own state; `ok` iff no clause adds a reason. 3.5/3.6 clauses (intent,
    evidence) join here. A facts run that ran out of its budget before collecting publishes nothing (the verdict says
    `(deferred: budget)`), so a published map's budget cut shows as partial coverage, which is the clause below."""
    why = []
    if ask_ids(S.get("decisions") or []):
        why.append("decision open")
    st = S.get("stale")
    if st:
        why.append(C.trim("assessment behind: %s" % (st.get("why") or "the project moved"), 40))
    cv = S.get("coverage") or {}
    if cv.get("coverage") != "complete":
        why.append("coverage partial")
    if (S.get("status") or {}).get("git_error"):
        why.append("git error")
    if _release_unverified(S):
        why.append("tags unverified")
    att = ((S.get("since") or {}).get("attention") or {}).get("kind")
    if att is None:
        why.append("attention not assessed")
    elif att not in ("continue", "decision"):   # "decision" is already the first reason above
        why.append("attention: %s" % att)
    seen = S.get("judged_seen")
    if not isinstance(seen, dict):
        why.append("pack coverage unknown")
    else:
        why += omitted_work(seen)
    it = S.get("intent")   # 3.5: a published accepted focus that is not the one the assessment served (a retried or partial run)
    if isinstance(it, dict) and isinstance(it.get("accepted"), dict) \
            and it["accepted"].get("hash") != (it.get("target") or {}).get("hash"):
        why.append("focus changed after the assessment")
    return {"ok": not why, "why": why}


NEEDS_TEXT = {"a": "Needs you", "b": "Nothing needs you", "c": "No decision identified in the checked information"}


def needs_case(S):
    """a: a decision needs the owner; b: none, and the assessment is complete; c: none, but it is not complete."""
    if ask_ids(S.get("decisions") or []):
        return "a"
    a = S.get("assurance")
    return "b" if (a if isinstance(a, dict) else assurance(S)).get("ok") else "c"


def needs_text(S):
    """The ONE three-way wording (13.4) of "does anything need the owner": page pill and tile, brief, handoff."""
    return NEEDS_TEXT[needs_case(S)]


def build_state(ctx):
    """ctx: root, snap, J (accepted, carried-forward), plan (after updates), prev (state|None), genstr, base, kept,
    judged_at, n (run number), mode, stale, judged_seen (the `seen` of the pack the model read, or None).
    -> state dict (generation_files filled by the publisher)."""
    snap, J, prev, root = ctx["snap"], ctx["J"], ctx["prev"], ctx["root"]
    t = snap["facts_at"]
    phases, cur, blocking = derive_phases(ctx["plan"], J["current_phase"])
    curp = next(p for p in phases if p["id"] == cur)
    decs = merge_decisions(J, snap, prev, root)
    open_ids = [d["id"] for d in decs if d["status"] == "overdue"]
    key = copy.deepcopy(snap["key"])
    key["expired_ids"] = sorted(open_ids)
    intent = build_intent(ctx.get("staged_intent", snap.get("intent")), snap.get("intent"), J["intent"])
    key["intent_hash"] = intent["target"]["hash"]   # rebased: the component now names the intention THIS judgement served
    parts = J["parts"]
    r0 = snap["repos"][0] if snap["repos"] else {}
    name = J["project"]["name"] or os.path.basename(root)
    hl = dict(J["headline"])
    if blocking:
        hl["note"] = "Unfinished earlier phase: " + ", ".join(blocking)[:120]
    S = {
        "schema": C.SCHEMA_STATE, "generation": ctx["genstr"], "base": ctx["base"], "generation_files": [],
        "identity": {"name": name, "folder": C.short_path(root), "branch": r0.get("branch") or "", "head": (r0.get("head") or "")[:7],
                     "snapshot_at": t, "generation": ctx["genstr"]},
        "project": J["project"], "phases": phases, "headline": hl,
        "focus": {"phase": cur, "label": curp["label"], "done": curp["done"], "total": curp["total"], "next_step": J["next_step"]},
        "decisions": decs, "parts": parts, "changes": [], "risks": J.get("risks", []), "loops": J.get("loops", []),
        "eta": J.get("eta"), "next_step": J["next_step"], "history": list((prev or {}).get("history", [])),
        "usage": snap.get("usage"), "stale": ctx.get("stale"),
        "coverage": {"coverage": snap["status"]["coverage"], "covered": snap["status"]["covered"], "total": snap["status"]["total"]},
        "template_hash": snap["template_hash"], "embed_hash": snap["embed_hash"],
        "judged_at": ctx["judged_at"], "judged_key": key,
        "answers": {"total": snap["answers"]["total"], "applied": snap["answers"]["total"],
                    "applied_hash": snap["answers"]["total_hash"], "bad": [b["line"] for b in snap["answers"]["bad"]][:5]},
        "watch": list(J.get("watch", [])), "watch_dropped": snap.get("watch_dropped", []),
        "repos": [dict({k: r.get(k) for k in ("path", "vcs", "branch", "head", "head_at")},
                       **({"release": r["release"]} if isinstance(r.get("release"), dict) else {})) for r in snap["repos"]],
        "commits": snap["commits"], "status": dict({k: snap["status"][k] for k in ("dirty", "hash")},
                                                    git_error=snap["status"].get("git_error")),
        "ledger": ({k: snap["ledger"][k] for k in ("path", "name", "goal", "now", "next", "blockers")} if snap.get("ledger") else None),
        "run": {"n": ctx["n"], "type": J["run"]["type"], "model": J["run"]["model"], "at": t},
        "template_feedback": J.get("template_feedback", []), "kept": ctx.get("kept", []),
        "retired_ids": [], "retired_decisions": "",
    }
    S["intent"] = intent
    S["changes"] = diff_changes(prev, S, t) if prev else []
    S["judged_seen"] = ctx.get("judged_seen")   # what the model saw of the staged snapshot (13.3); None = unknown
    S["since"] = build_since(snap, J, decs, S["judged_seen"])
    S["assurance"] = assurance(S)
    old_ids = [x["id"] for k in ("parts", "decisions") for x in (prev or {}).get(k, [])]
    new_ids = {p["id"] for p in parts} | {d["id"] for d in decs}
    retired = list((prev or {}).get("retired_ids", []))
    for i in old_ids:
        if i not in new_ids and i not in retired:
            retired.append(i)
    S["retired_ids"] = retired[-200:]
    # decision ids are retired for good: the 200-id window above is for parts; the tombstones are a compact range set
    gone = [d["id"] for d in (prev or {}).get("decisions", []) if isinstance(d, dict) and d.get("id") not in new_ids]
    S["retired_decisions"] = encode_decision_ids(retired_decision_ids(prev) | set(gone))
    u = (snap.get("usage") or {}).get("totals") or {}
    opened = [d["id"] for d in decs if d["id"] not in {x["id"] for x in (prev or {}).get("decisions", [])} and d["status"] == "open"]
    closed = [d["id"] for d in decs if d["status"] in CLOSED_ST]
    hchanged = [{k: c[k] for k in ("id", "label", "text")} for c in S["changes"]]
    for d in decs:   # the history keeps the closing even when the changes list was cut or reset (legacy base)
        if d["status"] == "overtaken" and not any(c["id"] == d["id"] for c in hchanged):
            hchanged.append({"id": d["id"], "label": d["id"], "text": "overtaken: %s" % d.get("overtaken_why", "")})
    S["history"].append({"run": ctx["n"], "at": t, "generation": ctx["genstr"],
                         "counts": {k: sum(1 for p in parts if p["status"] == k) for k in PART_ST},
                         "phase": {"current": cur, "done": curp["done"], "total": curp["total"]},
                         "changed": hchanged,
                         "decisions_opened": opened, "decisions_closed": closed,
                         "usage": {"claude": u.get("claude"), "codex": u.get("codex"), "all": u.get("all")}})
    S["history"] = S["history"][-10:]
    return S
