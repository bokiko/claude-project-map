#!/usr/bin/env python3
"""pm_collect: fact collection for project-map 3.2 (INTERFACES-3.2 sections 6.1, 6.2, 6.7, 7).

Used by project-map-facts.py and project-map-embed.py (mechanical mode). Read-only apart from the in-memory
watch cache the caller persists. Every git call goes through pm_git.
"""
import glob
import hashlib
import os
import re
import stat as statmod
import subprocess
import sys
import time

import pm_common as C
import pm_git as G

HERE = os.path.dirname(os.path.abspath(__file__))
FAIL_RE = re.compile(r"fail|revert|broken|rollback", re.I)
LEDGER_KEYS = (("goal", r"goal"), ("now", r"now"), ("next", r"next"), ("blockers", r"blockers?"))
SKIP_DIRS = {".git", ".project-map", "node_modules", "__pycache__", ".venv"}
DEFAULT_WATCH = ("README*", "PLAN*", "ROADMAP*", "TODO*", "CHANGELOG*", "docs", "thoughts/ledgers")
GIT_KEYS = ("heads", "branches", "status_hash")
MAX_COMMITS = 40
PACK_MAX = 8192
HEX40 = re.compile(r"^[0-9a-f]{40}$")


class GitCollectError(Exception):
    """A git command failed to run: the verdict is ERROR, never NO_CHANGE."""


class AnswersRewritten(Exception):
    pass


class PackOverflow(Exception):
    """The pack cannot be brought under 8 KB even with every trimmable field reduced to markers."""


# ---------------------------------------------------------------- git
class BudgetOut(Exception):
    """The wall budget ran out between collection steps."""


_BUDGET = {"until": None}   # absolute time.monotonic() limit for the whole run, or None


def set_budget(until):
    _BUDGET["until"] = until


def left():
    return float("inf") if _BUDGET["until"] is None else _BUDGET["until"] - time.monotonic()


def step(timeout):
    """Called before every collection step: out of budget -> BudgetOut; else the step's timeout (min of remainder and
    the default). PM_FACTS_DELAY injects a per-step delay (test hook) that is cut off by the timeout like a slow git."""
    r = left()
    if r < 0.05:
        raise BudgetOut("budget")
    t = min(timeout, r)
    d = float(os.environ.get("PM_FACTS_DELAY", "0") or 0)
    if d:
        time.sleep(min(d, t))
        if left() < 0.05:
            raise BudgetOut("budget")
        t = min(timeout, left())
    return t


def grun(repo, sub, *args, timeout=20.0):
    """pm_git.run behind the budget: -> (rc, out)."""
    t = step(timeout)
    rc, out = G.run(repo, sub, *args, timeout=t)
    if rc == 124 and left() < 0.05:
        raise BudgetOut("budget")
    return rc, out


def gcall(repo, sub, *args, timeout=20.0):
    try:
        rc, out = grun(repo, sub, *args, timeout=timeout)
    except G.GitArgError as ex:
        raise GitCollectError("git argument rejected: %s" % ex)
    except BudgetOut:
        raise
    except Exception as ex:   # noqa: BLE001 - any spawn failure is a collection failure
        raise GitCollectError("git %s failed: %s" % (sub, type(ex).__name__))
    if G.collection_failure(sub, rc):
        raise GitCollectError("git %s failed (rc %d)" % (sub, rc))
    return rc, out


def log_records(repo, n, paths=(), timeout=20.0):
    """-> [(sha40, epoch, subject)] newest first, via the fixed internal format (%x1e record separator)."""
    args = ["--format=%x1e%H%x1f%ct%x1f%s", "-n", str(max(1, min(int(n), 200)))]
    if paths:
        args += ["--"] + list(paths)
    _, out = gcall(repo, "log", *args, timeout=timeout)
    recs = []
    for blk in out.split("\x1e"):
        blk = blk.strip("\n")
        if not blk:
            continue
        parts = blk.split("\x1f", 2)
        if len(parts) == 3 and HEX40.match(parts[0]) and parts[1].isdigit():
            recs.append((parts[0], int(parts[1]), parts[2].split("\n", 1)[0]))
    return recs


# ---------------------------------------------------------------- state shape
def _is_str(x):
    return isinstance(x, str)


def state_problem(S):
    """None when S has the project-map-4 shape the scripts rely on, else a short reason."""
    if not isinstance(S, dict):
        return "state is not an object"
    if S.get("schema") != C.SCHEMA_STATE:
        return "schema %s" % str(S.get("schema"))[:30]
    need = (("generation", str), ("generation_files", list), ("identity", dict), ("phases", list), ("headline", dict),
            ("focus", dict), ("decisions", list), ("parts", list), ("changes", list), ("risks", list), ("history", list),
            ("coverage", dict), ("template_hash", str), ("embed_hash", str), ("judged_key", dict), ("answers", dict),
            ("retired_ids", list), ("watch", list), ("repos", list))
    for k, t in need:
        if not isinstance(S.get(k), t):
            return "key %s is not %s" % (k, t.__name__)
    if not C.GENSTR_RE.match(S["generation"]):
        return "bad generation stamp"
    if S.get("base") is not None and not (_is_str(S["base"]) and C.GENSTR_RE.match(S["base"])):
        return "bad base"
    if not all(isinstance(S["identity"].get(k), str) for k in ("name", "folder", "snapshot_at", "generation")):
        return "identity incomplete"
    if not all(isinstance(p, dict) and _is_str(p.get("id")) and _is_str(p.get("label")) and _is_str(p.get("state"))
               and isinstance(p.get("done"), int) and isinstance(p.get("total"), int) for p in S["phases"]):
        return "phases malformed"
    if not all(isinstance(d, dict) and _is_str(d.get("id")) and _is_str(d.get("status")) for d in S["decisions"]):
        return "decisions malformed"
    if not all(isinstance(p, dict) and _is_str(p.get("id")) for p in S["parts"]):
        return "parts malformed"
    if not (_is_str(S["headline"].get("text")) and _is_str(S["headline"].get("tone"))):
        return "headline malformed"
    cv = S["coverage"]
    if cv.get("coverage") not in ("complete", "partial") or not isinstance(cv.get("covered"), int) or not isinstance(cv.get("total"), int):
        return "coverage malformed"
    a = S["answers"]
    if not isinstance(a.get("applied"), int) or not _is_str(a.get("applied_hash")):
        return "answers malformed"
    for k in ("usage", "stale"):
        if S.get(k) is not None and not isinstance(S[k], dict):
            return "%s malformed" % k
    jk = S["judged_key"]
    if not (isinstance(jk.get("heads"), dict) and isinstance(jk.get("watch_hashes"), dict)):
        return "judged_key malformed"
    return None


def load_prev(pm):
    """What exists under PM. kind: none | v4 | legacy | invalid. One pinned read of `current`."""
    P = {"kind": "none", "why": "", "gen": None, "state": None, "judgement": None, "plan": None, "decisions": [],
         "judged_key": None, "applied": 0, "applied_hash": None, "retired": []}
    if C.current_exists(pm):
        gen = C.current_gen(pm)
        P["gen"] = gen
        if gen is None:
            P.update(kind="invalid", why="invalid state")
            return P
        src = gen
        C.get_key()   # a missing key is created here (once); old generations then fail verification
        if not C.verify_generation(os.path.join(pm, C.gen_dir_name(gen))):
            # a generation that fails verification is never trusted: re-render from the newest VERIFIED one. A key that
            # this very run had to create (it was missing) cannot verify anything: adopt the structurally complete current once.
            if C.adoptable(os.path.dirname(pm), gen, os.path.join(pm, C.gen_dir_name(gen))):
                P["unverified"] = True
            else:
                older = [n[4:] for _s, n in reversed(C.list_gen_dirs(pm)) if not n.endswith(".tmp") and n[4:] != gen]
                src = next((g for g in older if C.verify_generation(os.path.join(pm, C.gen_dir_name(g)))), None)
                if src is None:
                    P.update(kind="invalid", why="no verified generation")
                    return P
                P["unverified"] = True
        P["src"] = src
        raw = {}
        for name in ("state.json", "judgement.json", "plan.json"):
            b = C.read_pinned(pm, src, name)
            try:
                raw[name] = C.loads(b) if b is not None else None
            except ValueError:
                raw[name] = None
        S = raw["state.json"]
        prob = state_problem(S)
        if prob:
            P.update(kind="invalid", why="schema mismatch" if isinstance(S, dict) and S.get("schema") != C.SCHEMA_STATE and S.get("schema") else "invalid state")
            P["state"] = S if isinstance(S, dict) else None
            return P
        if not isinstance(raw["judgement.json"], dict) or not isinstance(raw["plan.json"], dict) \
                or not isinstance(raw["plan.json"].get("phases"), list):
            P.update(kind="invalid", why="invalid state")
            return P
        P.update(kind="v4", state=S, judgement=raw["judgement.json"], plan=raw["plan.json"], decisions=S["decisions"],
                 judged_key=S["judged_key"], applied=S["answers"]["applied"], applied_hash=S["answers"]["applied_hash"],
                 retired=list(S.get("retired_ids", [])))
        ov = (C.load_json(os.path.join(pm, "cache.json"), {}) or {}).get("answers_accept")
        if isinstance(ov, dict) and ov.get("gen") == gen and isinstance(ov.get("applied"), int):
            P["applied"], P["applied_hash"] = ov["applied"], ov.get("applied_hash")
        return P
    sp = os.path.join(pm, "state.json")
    if os.path.isfile(sp) and not os.path.islink(sp):
        S = C.load_json(sp)
        J = C.load_json(os.path.join(pm, "judgement.json"))
        S = S if isinstance(S, dict) else {}
        decs = [d for d in S.get("decisions", []) if isinstance(d, dict) and isinstance(d.get("id"), str)]
        key = (S.get("facts") or {}).get("key") if isinstance(S.get("facts"), dict) else None
        jk = {"heads": key.get("heads", {}) if isinstance(key, dict) and isinstance(key.get("heads"), dict) else {}}
        applied = S.get("answers_applied") if isinstance(S.get("answers_applied"), int) else 0
        P.update(kind="legacy", why="migrate", state=S, judgement=J if isinstance(J, dict) else {}, decisions=decs,
                 judged_key=jk, applied=applied, applied_hash=None,
                 retired=[x for x in S.get("retired_ids", []) if isinstance(x, str)])
    return P


# ---------------------------------------------------------------- watch / repos
def default_watch(root):
    found = []
    for pat in DEFAULT_WATCH:
        found += [os.path.relpath(m, root) for m in sorted(glob.glob(os.path.join(glob.escape(root), pat)))]
    return found[:40]


def discover_nested(root):
    out = []
    try:
        for d in sorted(os.listdir(root)):
            if d not in SKIP_DIRS and not d.startswith(".") and os.path.exists(os.path.join(root, d, ".git")):
                out.append(d)
    except OSError:
        pass
    return out


def _walk_files(base, hash_deadline):
    """Regular files under base (no symlinks, no .git / .project-map directories) -> ([(abs, rel)], cut)."""
    out, stack, cut = [], [(base, "")], False
    while stack:
        if time.monotonic() >= hash_deadline:
            cut = True
            break
        d, rel = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_symlink():
                    continue
                if e.is_dir(follow_symlinks=False):
                    if e.name not in (".git", ".project-map"):
                        stack.append((e.path, rel + e.name + "/"))
                elif e.is_file(follow_symlinks=False):
                    out.append((e.path, rel + e.name))
            except OSError:
                continue
    out.sort(key=lambda x: x[1])
    return out, cut


def hash_watch(root, entries, cache, hash_deadline):
    """Content-hash every watched path. cache: {abs: {dev, ino, size, mtime_ns, ctime_ns, sha256}} (mutated).
    -> (watch list, covered, total). An entry whose files were not all hashed in time gets hash 'partial'."""
    slow = float(os.environ.get("PM_FACTS_SLOW", "0") or 0)
    res, covered, total = [], 0, 0
    live = set()
    for ent in entries:
        step(1.0)   # budget check between watch entries (hash_deadline bounds the files inside one)
        p = ent if os.path.isabs(ent) else os.path.join(root, ent)
        if os.path.isdir(p) and not os.path.islink(p):
            files, cut = _walk_files(p, hash_deadline)
            kind = "dir"
        elif os.path.isfile(p):
            files, cut, kind = [(p, os.path.basename(p))], False, "file"
        else:
            res.append({"path": ent, "kind": "missing", "hash": "missing", "n": 0})
            continue
        h, ok = hashlib.sha256(), not cut
        for ap, rel in files:
            total += 1
            if time.monotonic() >= hash_deadline:
                ok = False
                continue
            try:
                st = os.lstat(ap)
            except OSError:
                h.update(rel.encode("utf-8", "replace") + b"\0gone\n")
                covered += 1
                continue
            live.add(ap)
            ident = {"dev": st.st_dev, "ino": st.st_ino, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "ctime_ns": st.st_ctime_ns}
            c = cache.get(ap)
            if isinstance(c, dict) and all(c.get(k) == v for k, v in ident.items()) and isinstance(c.get("sha256"), str):
                sha = c["sha256"]
            else:
                if slow:
                    time.sleep(slow)
                try:
                    sha = C.sha256_file(ap)
                except OSError:
                    sha = "unreadable"
                cache[ap] = dict(ident, sha256=sha)
            covered += 1
            h.update(rel.encode("utf-8", "replace") + b"\0" + sha.encode() + b"\n")
        res.append({"path": ent, "kind": kind, "hash": h.hexdigest()[:12] if ok else "partial", "n": len(files)})
    for k in [k for k in cache if k not in live]:
        del cache[k]
    return res, covered, total


# ---------------------------------------------------------------- repos
def _parse_status(out):
    ent, paths, dirty, i = out.split("\0"), [], 0, 0
    while i < len(ent):
        e = ent[i]
        if len(e) > 3:
            dirty += 1
            paths.append(e[3:])
            if e[0] in "RC" or e[1] in "RC":
                i += 1   # origin path field
        i += 1
    return paths, dirty


def _stat_sig(path):
    try:
        st = os.lstat(path)
        return "%d,%d,%d" % (st.st_size, st.st_mtime_ns, st.st_ctime_ns)
    except OSError:
        return "gone"


def plain_signature(repo, limit):
    """No git: (path, size, mtime_ns, ctime_ns) over the tree. -> (sig, files, recent, truncated)"""
    h, rows, trunc = hashlib.sha256(), [], False
    for dp, dn, fn in os.walk(repo):
        dn[:] = sorted(d for d in dn if d not in SKIP_DIRS)
        for f in sorted(fn):
            fp = os.path.join(dp, f)
            try:
                st = os.lstat(fp)
            except OSError:
                continue
            h.update(("%s\0%d\0%d\0%d\n" % (os.path.relpath(fp, repo), st.st_size, st.st_mtime_ns, st.st_ctime_ns)).encode("utf-8", "replace"))
            rows.append((st.st_mtime, os.path.relpath(fp, repo)))
            if len(rows) >= limit:
                trunc = True
                break
        if trunc:
            break
    rows.sort(reverse=True)
    recent = [{"f": r, "at": C.iso(_dt().fromtimestamp(m).astimezone())} for m, r in rows[:10]]
    return h.hexdigest(), len(rows), recent, trunc


def _dt():
    import datetime
    return datetime.datetime


def _day(ts):
    return _dt().fromtimestamp(ts).astimezone().strftime("%Y-%m-%d")


def _plain(repo, info):
    sig = plain_signature(repo, int(os.environ.get("PM_SCAN_CAP", "200000")) or 200000)
    info.update(files=sig[1], recent_files=sig[2])
    if sig[3]:
        info["truncated"] = True
    return info, 0, sig[0], [], []


def collect_repo(root, rp, prev_head, watch_rel, git_timeout):
    """-> (info, count, status signature, dirty paths relative to ROOT, listed commits)."""
    repo = root if rp == "." else os.path.join(root, rp)
    info = {"path": rp, "vcs": "none", "head": None, "branch": None, "head_at": None, "rewritten": False, "commits": 0}
    if not os.path.isdir(repo):
        info["missing"] = True
        return info, 0, "", [], []
    step(3.0)
    top = G.toplevel(repo, timeout=min(3.0, max(left(), 0.05)))
    if not top or os.path.realpath(top) == C.home():   # a repository shared with $HOME behaves like a plain folder
        return _plain(repo, info)
    real, topr = os.path.realpath(repo), os.path.realpath(top)
    sub = real != topr
    rel = os.path.relpath(real, topr) if sub else None
    scope = ["."] if sub else []
    recs0 = []
    try:
        rc_h, _o = grun(repo, "rev-parse", "HEAD", timeout=git_timeout)
    except G.GitArgError as ex:
        raise GitCollectError("git argument rejected: %s" % ex)
    if rc_h == 0:   # commits exist: a failing log is a collection failure, never "no history"
        _, out = gcall(repo, "log", "--format=%x1e%H%x1f%ct%x1f%s", "-n", "1", *(["--", "."] if sub else []), timeout=git_timeout)
        for blk in out.split("\x1e"):
            parts = blk.strip("\n").split("\x1f", 2)
            if len(parts) == 3 and HEX40.match(parts[0]) and parts[1].isdigit():
                recs0.append((parts[0], int(parts[1]), parts[2]))
    # no HEAD (unborn branch) or nothing under this sub-folder yet: still a git repository with 0 commits; the
    # status call below is what separates it from a broken one (a broken index fails there and becomes git_error)
    head = recs0[0][0] if recs0 else None
    if head:
        _, br = gcall(repo, "rev-parse", "--abbrev-ref", "HEAD", timeout=git_timeout)
    else:
        _, br = gcall(repo, "branch", "--show-current", timeout=git_timeout)
    info.update(vcs="git", head=head[:12] if head else None, branch=br.strip() or None,
                head_at=C.iso(_dt().fromtimestamp(recs0[0][1]).astimezone()) if recs0 else None)
    if sub:
        info["toplevel"], info["scope"] = topr, rel
    _, st_out = gcall(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", timeout=git_timeout)
    raw_paths, _dirty = _parse_status(st_out)
    paths = []
    for p in raw_paths:
        if sub:
            if not p.startswith(rel + "/"):
                continue
            p = p[len(rel) + 1:]
        if p == ".project-map" or p.startswith(".project-map/") or not p:
            continue
        paths.append(p)
    paths = sorted(set(paths))
    h = hashlib.sha256()
    for p in paths:
        h.update(("%s\0%s\n" % (p, _stat_sig(os.path.join(real, p)))).encode("utf-8", "replace"))
    info["dirty"] = len(paths)
    # commits since the judged head: ONE log call (-n once), walked until the judged head is met
    recs = log_records(repo, 200 if prev_head else MAX_COMMITS, scope and ["."] or (), git_timeout) if head else []
    count, listed = len(recs), recs
    if not head:
        count, listed = 0, []
    elif prev_head and prev_head == head[:12]:
        count, listed = 0, []
    elif prev_head:
        idx = next((i for i, r in enumerate(recs) if r[0].startswith(prev_head)), None)
        if idx is not None:
            count, listed = idx, recs[:idx]
        else:
            rc, _ = grun(repo, "merge-base", "--is-ancestor", prev_head, "HEAD", timeout=git_timeout)
            if rc == 0:
                count, listed = len(recs), recs
                if not sub:
                    rc2, o2 = grun(repo, "rev-list", "--count", "%s..HEAD" % prev_head, timeout=git_timeout)
                    if rc2 == 0 and o2.strip().isdigit():
                        count = int(o2.strip())
            else:
                info["rewritten"] = True
                listed = recs[:20]
                count = len(listed)
    listed = listed[:MAX_COMMITS]
    if not prev_head:
        count = len(listed)
    flagged_watch = set()
    wpaths = [w for w in watch_rel if w and not w.startswith((":", "-", "/")) and ".." not in w.split("/")]
    if listed and wpaths:
        flagged_watch = {r[0] for r in log_records(repo, 200, wpaths, git_timeout)}
    commits = []
    for sha, ts, subj in listed:
        f = "watch" if sha in flagged_watch else ("fail" if FAIL_RE.search(subj) else None)
        commits.append({"r": rp, "h": sha[:7], "day": _day(ts), "s": C.trim(subj, 60), "f": f})
    info["commits"] = count
    return info, count, h.hexdigest(), [p if rp == "." else rp + "/" + p for p in paths], commits


def group_commits(commits, total_count, cap=MAX_COMMITS):
    flagged = [c for c in commits if c["f"]]
    must = flagged[:60]
    rest = [c for c in commits if not c["f"]][: max(cap - len(must), 0)]
    shown = {id(c) for c in must + rest}
    days = {}
    for c in commits:
        d = days.setdefault(c["day"], {"day": c["day"], "n": 0, "items": []})
        d["n"] += 1
        if id(c) in shown:
            d["items"].append({k: c[k] for k in ("r", "h", "s", "f") if c[k]})
    return {"count": total_count, "listed": len(shown), "flagged": len(flagged),
            "days": sorted(days.values(), key=lambda d: d["day"], reverse=True)}


# ---------------------------------------------------------------- ledger
def _allowed_ledger_dirs(root):
    return (os.path.join(root, "thoughts", "ledgers"), os.path.expanduser("~/thoughts/ledgers"))


def find_ledger(root, name):
    """Explicit name first, then the ROOT basename (and basename minus -digits), then the newest local ledger.
    Returns (path, binding) or (None, None). Only ROOT/thoughts/ledgers and ~/thoughts/ledgers are read."""
    allowed = _allowed_ledger_dirs(root)
    base = os.path.basename(root)
    stems = []
    if isinstance(name, str) and name:
        stems.append(("judgement", name))
    stems += [("basename", base), ("basename", re.sub(r"-\d+$", "", base))]
    cands = []
    for binding, n in stems:
        n = os.path.expanduser(n)
        if os.path.isabs(n):
            cands.append((n, binding))
            continue
        cands += [(os.path.join(allowed[0], n), binding), (os.path.join(allowed[0], n + ".md"), binding),
                  (os.path.join(allowed[1], "CONTINUITY_CLAUDE-%s.md" % n), binding)]
    local = sorted(glob.glob(os.path.join(glob.escape(allowed[0]), "*.md")), key=os.path.getmtime, reverse=True)
    cands += [(p, "newest") for p in local]
    for p, binding in cands:
        if os.path.isfile(p) and any(C.under(p, a) for a in allowed):
            return os.path.realpath(p), binding
    return None, None


def parse_ledger(root, name):
    path, binding = find_ledger(root, name)
    if not path:
        return None
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    secs, cur = {}, None
    for ln in data.decode("utf-8", "replace").splitlines():
        m = re.match(r"##\s+(.*)", ln)
        if m:
            cur = None
            for key, pat in LEDGER_KEYS:
                if re.match(pat + r"\b", m.group(1), re.I):
                    cur = []
                    secs.setdefault(key, []).append(cur)
                    break
        elif cur is not None and not ln.startswith("<!--") and ln.strip():
            cur.append(C.trim(ln.rstrip(), 200))
    out = {"path": path, "name": os.path.basename(path), "binding": binding, "hash": C.sha12(data)}
    for key, _ in LEDGER_KEYS:
        out[key] = "\n".join(next((s[:12] for s in secs.get(key, []) if s), []))
    return out


# ---------------------------------------------------------------- answers / decisions
def read_answers(pm):
    """-> list of (physical line no, raw bytes without line terminator) for non-blank lines."""
    try:
        with open(os.path.join(pm, "answers.jsonl"), "rb") as fh:
            data = fh.read()
    except OSError:
        return []
    return [(no, ln.rstrip(b"\r")) for no, ln in enumerate(data.split(b"\n"), 1) if ln.strip()]


def prefix_hash(lines, n):
    h = hashlib.sha256()
    for _, ln in lines[:n]:
        h.update(ln + b"\n")
    return h.hexdigest()


def parse_pending(lines):
    pending, bad = [], []
    for no, raw in lines:
        try:
            o = C.loads(raw)
        except ValueError:
            o = None
        if not (isinstance(o, dict) and isinstance(o.get("id"), str) and isinstance(o.get("answer"), str)):
            bad.append({"line": no, "why": "not a JSON object with string id and answer"})
            continue
        extra = sorted(set(o) - {"id", "answer", "at", "by", "note"})
        if extra:
            bad.append({"line": no, "why": "unknown keys: %s" % ", ".join(map(str, extra))[:60]})
            continue
        if o.get("by", "owner") != "owner" or not (o.get("at") is None or (isinstance(o.get("at"), str) and len(o["at"]) <= 40)):
            bad.append({"line": no, "why": "by must be \"owner\" and at a short ISO string"})
            continue
        note = o.get("note")
        if note is not None and (not isinstance(note, str) or C.blen(note) > 16384):
            bad.append({"line": no, "why": "note must be a string of at most 16384 bytes"})
            continue
        pending.append({"id": o["id"], "answer": o["answer"], "at": o["at"] if isinstance(o.get("at"), str) else None,
                        "by": o["by"] if isinstance(o.get("by"), str) else "owner", "note": note, "line": no})
    return pending, bad


def lifecycle(prev_decs, pending, t):
    """Apply answers and expiries to a copy of the previous OPEN/OVERDUE decisions (closed ones are dropped here)."""
    by_id = {d["id"]: dict(d) for d in prev_decs if d.get("status") in ("open", "overdue")}
    bad, applied = [], {}
    for a in pending:
        d = by_id.get(a["id"])
        if not d:
            bad.append({"line": a["line"], "why": "unknown or closed decision %s" % a["id"]})
        elif a["answer"] != "hold" and a["answer"] not in {o.get("id") for o in d.get("options", []) if isinstance(o, dict)}:
            bad.append({"line": a["line"], "why": "%s is not an option of %s" % (C.trim(a["answer"], 20), a["id"])})
        else:
            d.update(status="answered", answer=a["answer"], answered_by=a["by"], answered_at=a["at"])
            applied.setdefault(a["id"], []).append(a["line"])
    for i, ls in applied.items():
        if len(ls) > 1:
            bad.append({"line": ls[0], "why": "%s answered %d times, last kept" % (i, len(ls))})
    for d in by_id.values():
        if d["status"] in ("open", "overdue"):
            dl = C.parse_iso(d.get("deadline"))
            if dl is not None and dl <= t:
                holds = d.get("hard_rule") or d.get("ready") is False or d.get("auto_default") is False \
                    or d.get("default") in (None, "hold")
                if holds:
                    d["status"] = "overdue"
                else:
                    d.update(status="defaulted", answer=d["default"], answered_by="deadline", answered_at=C.iso(t))
    return list(by_id.values()), bad


# ---------------------------------------------------------------- usage / hashes
def collect_usage(root, timeout):
    if os.environ.get("PM_USAGE_SKIP"):
        return None
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, "project-map-usage.py"), root, "--max-jobs", "15"],
                           capture_output=True, text=True, timeout=max(timeout, 1.0), env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        return C.loads(r.stdout)["snapshot_for_state"]
    except Exception:   # noqa: BLE001
        return None


def plugin_hashes():
    def rd(n):
        try:
            with open(os.path.join(HERE, n), "rb") as fh:
                return fh.read()
        except OSError:
            return b""
    return (C.sha12(rd("project-map-template.html")),
            C.sha12(b"".join(rd(n) for n in ("project-map-embed.sh", "project-map-embed.py", "pm_validate.py", "pm_render.py", "pm_common.py"))))


# ---------------------------------------------------------------- the collector
def collect(root, prev, hash_deadline, cache, git_timeout=20.0, want_usage=False, usage_timeout=60.0):
    """Build the complete snapshot (6.1). hash_deadline: absolute time.monotonic() limit for content hashing only.
    Raises GitCollectError, AnswersRewritten."""
    t = C.now()
    pm = os.path.join(root, ".project-map")
    J = prev["judgement"] if prev.get("judgement") else {}
    pj = J.get("project") if isinstance(J.get("project"), dict) else {}
    dropped = []

    def confined(p, what, must_dir=False):
        if not isinstance(p, str) or not p or "\0" in p or "\n" in p:
            dropped.append({"path": C.trim(str(p), 80), "why": "bad %s entry" % what})
            return False
        full = p if os.path.isabs(p) else os.path.join(root, p)
        if C.watch_problem(p) or not C.under(full, root):
            dropped.append({"path": C.trim(p, 80), "why": "%s outside ROOT" % what})
            return False
        return not must_dir or os.path.isdir(full)

    jr = J.get("repos") if isinstance(J.get("repos"), list) else []
    nested = [r for r in dict.fromkeys(list(jr) + discover_nested(root)) if r != "." and confined(r, "repo", True)]
    watch_in = J.get("watch") if isinstance(J.get("watch"), list) else (default_watch(root) if prev["kind"] == "none" or not J else [])
    watch = [w for w in watch_in if confined(w, "watch")][:40]
    hd = hash_deadline
    heads_prev = (prev.get("judged_key") or {}).get("heads", {}) if isinstance(prev.get("judged_key"), dict) else {}

    repos, commits, sh, dirty, total_count = [], [], hashlib.sha256(), [], 0
    for rp in ["."] + nested:
        ph = heads_prev.get(rp)
        info, cnt, sig, dp, cm = collect_repo(root, rp, ph if isinstance(ph, str) and re.match(r"^[0-9a-f]{7,40}$", ph or "") else None, watch, git_timeout)
        commits += cm
        total_count += cnt
        repos.append(info)
        sh.update(rp.encode() + b"\0" + str(sig).encode())
        dirty += dp
    commits.sort(key=lambda c: c["day"], reverse=True)

    wc = cache.setdefault("watch_cache", {})
    wl, covered, total = hash_watch(root, watch, wc, hd)
    partial = any(w["hash"] == "partial" for w in wl)
    cache["coverage_cursor"] = {"covered": covered, "total": total, "at": C.iso(t)}

    lname = pj.get("ledger") if isinstance(pj.get("ledger"), str) else None
    ledger = parse_ledger(root, lname)

    lines = read_answers(pm)
    ap, ah = prev["applied"], prev["applied_hash"]
    if prev["kind"] == "none":
        ap, ah = 0, C.sha256_bytes(b"")
    if ap > len(lines):
        raise AnswersRewritten("answers rewritten")
    if ah is None:   # migration: trust the legacy applied count, baseline its hash now
        ah = prefix_hash(lines, ap)
    if prefix_hash(lines, ap) != ah:
        raise AnswersRewritten("answers rewritten")
    pending, bad = parse_pending(lines[ap:])
    decs, bad2 = lifecycle(prev["decisions"], pending, t)
    bad += bad2
    expired = sorted(d["id"] for d in decs if d.get("status") in ("overdue", "defaulted"))
    th, eh = plugin_hashes()
    key = {"heads": {r["path"]: r["head"] for r in repos}, "branches": {r["path"]: r["branch"] for r in repos},
           "status_hash": sh.hexdigest()[:12], "watch_hashes": {w["path"]: w["hash"] for w in wl},
           "ledger_hash": ledger["hash"] if ledger else None, "answers_count": len(lines), "expired_ids": expired,
           "schema": C.SCHEMA_STATE}
    usage = collect_usage(root, usage_timeout) if want_usage else None
    snap = {
        "schema": "project-map-snapshot-1", "generation": None, "base": prev["gen"], "root": root, "facts_at": C.iso(t),
        "repos": repos, "commits": group_commits(commits, total_count),
        "status": {"hash": key["status_hash"], "dirty": len(dirty), "coverage": "partial" if partial else "complete",
                   "covered": covered, "total": total, "git_error": None},
        "dirty_paths": dirty[:20], "watch": wl, "watch_dropped": dropped, "ledger": ledger,
        "answers": {"total": len(lines), "applied": ap, "applied_hash": ah, "total_hash": prefix_hash(lines, len(lines)),
                    "pending": pending, "bad": bad},
        "decisions": decs, "usage": usage, "key": key, "prev_key": prev.get("judged_key"),
        "template_hash": th, "embed_hash": eh,
    }
    return snap


def compare_keys(judged, key, snap):
    """judged vs fresh key -> {'moved': [names], 'git': bool, 'adopt': [paths], 'why': text}."""
    if not isinstance(judged, dict):
        return {"moved": ["heads"], "git": True, "adopt": [], "why": "no judged key"}
    moved, adopt = [], []
    for k in ("heads", "branches", "status_hash", "ledger_hash", "answers_count", "expired_ids", "schema"):
        if key.get(k) != judged.get(k) and (k in judged or k in ("heads",)):
            moved.append(k)
    jw, nw = judged.get("watch_hashes", {}), key["watch_hashes"]
    changed = sorted(p for p in nw if p in jw and "partial" not in (jw[p], nw[p]) and jw[p] != nw[p])
    adopt = sorted(p for p in nw if jw.get(p) == "partial" and nw[p] != "partial")
    setchg = set(jw) != set(nw)
    if changed or setchg:
        moved.append("watch_hashes")
    why = []
    if "heads" in moved:
        why.append("%d new commits" % snap["commits"]["count"])
    if "branches" in moved:
        why.append("branch changed")
    if "status_hash" in moved:
        why.append("working tree changed")
    if "watch_hashes" in moved:
        why.append("watch changed: " + ", ".join(changed[:3]) if changed else "watch set changed")
    if "ledger_hash" in moved:
        why.append("ledger changed")
    if "answers_count" in moved:
        why.append("%d pending answers" % max(len(snap["answers"]["pending"]), 1))
    if "expired_ids" in moved:
        why.append("deadline passed: " + ", ".join(snap["key"]["expired_ids"] or judged.get("expired_ids", [])))
    if "schema" in moved:
        why.append("schema")
    return {"moved": moved, "git": any(m in GIT_KEYS for m in moved), "adopt": adopt, "why": "; ".join(why)}


# ---------------------------------------------------------------- pack (6.2)
def build_pack(snap, inv_name):
    """Bounded model-facing view, <= 8192 bytes. Trim order: commit items, watch hashes, ledger, answers, decisions, usage."""
    p = {k: snap[k] for k in ("schema", "base", "root", "facts_at", "repos", "commits", "status", "watch", "ledger",
                              "answers", "decisions", "usage", "watch_dropped", "dirty_paths", "template_hash")}
    p = C.loads(C.dumps(p))   # deep copy
    p["schema"] = "project-map-pack-1"
    p["generation"] = inv_name
    p["key_digest"] = C.digest(snap["key"])
    p["prev_key_digest"] = C.digest(snap["prev_key"]) if snap.get("prev_key") else None
    p["answers"].pop("applied_hash", None)
    p["answers"].pop("total_hash", None)
    for r in p["repos"]:
        r.pop("recent_files", None)
    tr = {"items": 0, "watch": 0, "ledger": False, "answers": 0, "decisions": 0, "usage": False}
    p["trimmed"] = tr

    def size():
        return C.blen(C.dumps(p))

    def cut_items(n):
        for d in p["commits"]["days"]:
            flagged = [i for i in d["items"] if i.get("f")]
            rest = [i for i in d["items"] if not i.get("f")]
            keep = (flagged + rest)[:n] if n else []
            tr["items"] += len(d["items"]) - len(keep)
            d["items"] = keep

    def cut_watch():
        tr["watch"] = len(p["watch"])
        p["watch"] = [w["path"] for w in p["watch"]]

    def cut_ledger():
        if p["ledger"]:
            tr["ledger"] = True
            for k in ("goal", "now", "next", "blockers"):
                p["ledger"][k] = C.trim(p["ledger"][k], 200)

    def cut_notes():
        for a in p["answers"]["pending"]:
            if a.get("note") and C.blen(a["note"]) > 120:
                a["note"] = C.trim(a["note"], 120)
                tr["answers"] += 1

    def drop_answers():
        pend = p["answers"]["pending"]
        while pend and size() > PACK_MAX:
            pend.pop()
            tr["answers"] += 1
        bad = p["answers"]["bad"]
        while bad and size() > PACK_MAX:
            bad.pop()

    def cut_decisions():
        for d in p["decisions"]:
            if C.blen(d.get("q", "")) > 140:
                d["q"] = C.trim(d["q"], 140)
                tr["decisions"] += 1
            for o in d.get("options", []):
                if isinstance(o, dict) and C.blen(o.get("label", "")) > 60:
                    o["label"] = C.trim(o["label"], 60)

    def cut_usage():
        if p.get("usage"):
            p["usage"] = {k: v for k, v in p["usage"].items() if k not in ("by_model", "jobs")}
            tr["usage"] = True

    steps = [lambda: cut_items(5), lambda: cut_items(2), lambda: cut_items(1), lambda: cut_items(0), cut_watch,
             cut_ledger, cut_notes, drop_answers, cut_decisions, cut_usage,
             lambda: p.update(dirty_paths=[]), lambda: p["watch"].__setitem__(slice(40, None), []),
             lambda: p["repos"].__setitem__(slice(8, None), []), lambda: p.update(watch_dropped=p["watch_dropped"][:5]),
             lambda: p["commits"].update(days=p["commits"]["days"][:3]),
             lambda: p["decisions"].__setitem__(slice(6, None), []),
             lambda: p.update(dirty_paths=[], watch=[], watch_dropped=[], ledger=None),
             lambda: p["answers"].update(pending=[], bad=[]),
             lambda: p["commits"].update(days=[]),
             lambda: p.update(decisions=[{"id": d.get("id"), "status": d.get("status")} for d in p["decisions"]]),
             lambda: p.update(repos=[{"path": r.get("path"), "vcs": r.get("vcs"), "head": r.get("head")} for r in p["repos"][:4]])]
    for s in steps:
        if size() <= PACK_MAX:
            break
        s()
    if size() > PACK_MAX:
        raise PackOverflow("pack over 8 KB")
    return p
