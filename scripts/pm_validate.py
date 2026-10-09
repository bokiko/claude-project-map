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
            "eta", "next_step", "decisions", "loops", "risks", "template_feedback"}
SCRIPT_OWNED = ("answer", "answered_by", "answered_at", "status", "raised_at", "frozen")


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
        if not rest or rest.startswith("/") or ".." in rest.split("/") or "\0" in rest or "\n" in rest:
            return "file ref %r must be a relative path inside the project" % rest[:60]
        rp = os.path.realpath(os.path.join(root, rest))
        if not C.under(rp, root):
            return "file ref %s is outside the project" % rest[:60]
        low = [x.casefold() for x in rest.split("/") + os.path.relpath(rp, os.path.realpath(root)).split("/")]
        if ".project-map" in low:
            return "file ref %s points into .project-map/" % rest[:60]
        if ".git" in low:
            return "file ref %s points into .git/" % rest[:60]
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
    if not v.obj(J, "judgement", ("generation", "project", "run", "headline", "parts", "current_phase", "next_step"),
                 tuple(TOP_KEYS - {"generation", "project", "run", "headline", "parts", "current_phase", "next_step"})):
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
    retired = set(prev.get("retired_ids", [])) if prev else set()
    in_prev = {d["id"] for d in (prev or {}).get("decisions", []) if isinstance(d, dict)}
    seen = set()
    for d in decs:
        if isinstance(d, dict):
            for k in SCRIPT_OWNED:
                if k in d:
                    v.e("decision %s: %s is owned by the script and must not be supplied" % (d.get("id"), k))
        if not v.obj(d, "decision", ("id", "q", "options", "default"),
                     ("recommended", "hard_rule", "deadline", "ready") + SCRIPT_OWNED):
            continue
        did = v.ident(d["id"], "decision", DEC_ID, seen)
        if did and did in retired and did not in in_prev:
            v.e("decision id %s was retired, ids are never reused" % did)
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
            add(d["id"], d["id"], "status: %s → %s" % (o.get("status"), d["status"]), d["status"])
        elif o.get("q") != d.get("q") or [x.get("id") for x in o.get("options", [])] != [x.get("id") for x in d.get("options", [])]:
            add(d["id"], d["id"], "question or options changed")
    if prev.get("risks") != S["risks"]:
        add("risks", "Risks", "changed")
    return out[:8]


def merge_decisions(J, snap, prev):
    """Model text for open/overdue decisions, script copy for answered/defaulted ones (6.4 freezing)."""
    sd = {d["id"]: d for d in snap["decisions"]}
    pd = {d["id"]: d for d in (prev or {}).get("decisions", [])}
    t = snap["facts_at"]
    out, seen = [], set()
    for m in J.get("decisions", []):
        i = m["id"]
        seen.add(i)
        s = sd.get(i)
        if s is None and (pd.get(i) or {}).get("status") in ("answered", "defaulted", "withdrawn"):
            continue   # a closed decision lives for one run: the model still carrying it does not keep it
        if s is not None and s["status"] in ("answered", "defaulted"):
            out.append(copy.deepcopy(s))
            continue
        d = {"recommended": None, "hard_rule": None, "deadline": None, "ready": True}
        d.update({k: copy.deepcopy(m[k]) for k in ("id", "q", "options", "recommended", "default", "hard_rule", "deadline", "ready") if k in m})
        if d["deadline"] is not None:
            d["deadline"] = C.iso(C.parse_iso(d["deadline"]))
        if s is not None and s["status"] == "overdue" and (s.get("hard_rule") or s.get("ready") is False):
            d["hard_rule"], d["default"], d["ready"] = s.get("hard_rule"), "hold", s.get("ready", True)
        d["status"] = s["status"] if s is not None else "open"
        d["raised_at"] = (s or pd.get(i) or {}).get("raised_at") or t
        out.append(d)
    for i, s in sd.items():
        if i not in seen and s["status"] in ("answered", "defaulted"):
            out.append(copy.deepcopy(s))
    for d in out:
        d.setdefault("raised_at", t)
    return out


def build_state(ctx):
    """ctx: root, snap, J (accepted, carried-forward), plan (after updates), prev (state|None), genstr, base, kept,
    judged_at, n (run number), mode, stale. -> state dict (generation_files filled by the publisher)."""
    snap, J, prev, root = ctx["snap"], ctx["J"], ctx["prev"], ctx["root"]
    t = snap["facts_at"]
    phases, cur, blocking = derive_phases(ctx["plan"], J["current_phase"])
    curp = next(p for p in phases if p["id"] == cur)
    decs = merge_decisions(J, snap, prev)
    open_ids = [d["id"] for d in decs if d["status"] == "overdue"]
    key = copy.deepcopy(snap["key"])
    key["expired_ids"] = sorted(open_ids)
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
        "repos": [{k: r.get(k) for k in ("path", "vcs", "branch", "head", "head_at")} for r in snap["repos"]],
        "commits": snap["commits"], "status": {k: snap["status"][k] for k in ("dirty", "hash")},
        "ledger": ({k: snap["ledger"][k] for k in ("path", "name", "goal", "now", "next", "blockers")} if snap.get("ledger") else None),
        "run": {"n": ctx["n"], "type": J["run"]["type"], "model": J["run"]["model"], "at": t},
        "template_feedback": J.get("template_feedback", []), "kept": ctx.get("kept", []),
        "retired_ids": [],
    }
    S["changes"] = diff_changes(prev, S, t) if prev else []
    old_ids = [x["id"] for k in ("parts", "decisions") for x in (prev or {}).get(k, [])]
    new_ids = {p["id"] for p in parts} | {d["id"] for d in decs}
    retired = list((prev or {}).get("retired_ids", []))
    for i in old_ids:
        if i not in new_ids and i not in retired:
            retired.append(i)
    S["retired_ids"] = retired[-200:]
    u = (snap.get("usage") or {}).get("totals") or {}
    opened = [d["id"] for d in decs if d["id"] not in {x["id"] for x in (prev or {}).get("decisions", [])} and d["status"] == "open"]
    closed = [d["id"] for d in decs if d["status"] in ("answered", "defaulted")]
    S["history"].append({"run": ctx["n"], "at": t, "generation": ctx["genstr"],
                         "counts": {k: sum(1 for p in parts if p["status"] == k) for k in PART_ST},
                         "phase": {"current": cur, "done": curp["done"], "total": curp["total"]},
                         "changed": [{k: c[k] for k in ("id", "label", "text")} for c in S["changes"]],
                         "decisions_opened": opened, "decisions_closed": closed,
                         "usage": {"claude": u.get("claude"), "codex": u.get("codex"), "all": u.get("all")}})
    S["history"] = S["history"][-10:]
    return S
