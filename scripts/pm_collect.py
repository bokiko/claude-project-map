#!/usr/bin/env python3
"""pm_collect: fact collection for project-map 3.2 (INTERFACES-3.2 sections 6.1, 6.2, 6.7, 7).

Used by project-map-facts.py and project-map-embed.py (mechanical mode). Read-only apart from the in-memory
watch cache the caller persists. Every git call goes through pm_git.
"""
import copy
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
import pm_validate as VAL

HERE = os.path.dirname(os.path.abspath(__file__))
FAIL_RE = re.compile(r"fail|revert|broken|rollback", re.I)
LEDGER_KEYS = (("goal", r"goal"), ("now", r"now"), ("next", r"next"), ("blockers", r"blockers?"))
SKIP_DIRS = {".git", ".project-map", "node_modules", "__pycache__", ".venv"}
DEFAULT_WATCH = ("README*", "PLAN*", "ROADMAP*", "TODO*", "CHANGELOG*", "docs", "thoughts/ledgers")
GIT_KEYS = ("heads", "branches", "status_hash", "release")
MAX_COMMITS = 40
PACK_MAX = 8192
PACK_REV = 2        # 3.6.1: the pack revision; a judgement that read a CUT pack of an older revision is redone once (facts decide)
DIRTY_LIST = 20     # changed files the snapshot lists one by one (work first, hidden folders last)
DIRTY_DIRS_MAX = 12  # folder counts for the changed files not listed one by one
HEX40 = re.compile(r"^[0-9a-f]{40}$")


class GitCollectError(Exception):
    """A git command failed to run: the verdict is ERROR, never NO_CHANGE."""


class AnswersUnreadable(Exception):
    pass


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


# ---------------------------------------------------------------- release facts (3.3.0)
# Local evidence only: tags that point at the pinned HEAD, and the branch's configured upstream as the local
# tracking ref records it. No fetch, no ls-remote, no network: a "ref" here can be stale, so every sentence built
# from these facts says "local tracking state" and never claims a release or a push.
SYNC_STATES = ("aligned", "ahead", "behind", "diverged", "no_upstream", "missing_upstream", "detached", "unborn", "unknown")
MAX_TAG_ROWS = 20000   # streamed and hashed, never held; past this the tag set is reported as partial coverage
HEAD_TAGS_SHOWN = 20
NAME_MAX = 120


def _max_tag_rows():
    try:
        return max(1, int(os.environ.get("PM_MAX_TAG_ROWS", "") or MAX_TAG_ROWS))   # test hook
    except ValueError:
        return MAX_TAG_ROWS


def _tag_row(ln):
    """One for-each-ref row (fixed %00 format) -> {name, kind, oid, commit} or None; kind lightweight | annotated | noncommit."""
    f = ln.split("\0")
    if len(f) != 5 or not f[0].startswith("refs/tags/") or len(f[0]) == 10:
        return None
    otype, oid, ptype, poid = f[1:]
    if otype == "commit" and HEX40.match(oid):
        kind, commit = "lightweight", oid
    elif otype == "tag" and ptype == "commit" and HEX40.match(poid):
        kind, commit = "annotated", poid
    else:   # tree/blob targets, or a tag of a tag: kept as a marker, never called a commit
        kind, commit = "noncommit", None
    return {"name": f[0][10:], "kind": kind, "oid": oid if HEX40.match(oid) else None, "commit": commit}


def _tag_rows(out, limit=5):
    rows = []
    for ln in out.split("\n")[:limit]:
        r = _tag_row(ln)
        if r:
            rows.append(r)
    return rows


def _up_name(ref, kind):
    if not ref:
        return ""
    if kind == "local":
        return "local " + (ref[11:] if ref.startswith("refs/heads/") else ref)
    return ref[13:] if ref.startswith("refs/remotes/") else ref


def release_line(rel):
    """The one script-owned sentence about tags and branch sync (<= 200 bytes). Never says released or pushed."""
    if not isinstance(rel, dict):
        return ""
    sy = rel.get("sync") or {}
    st, up = sy.get("state"), C.trim(_up_name(sy.get("upstream_ref"), sy.get("upstream_kind")), 50)
    parts = []
    if rel.get("head_tags") is None:
        parts.append("tags unknown")   # exhausted re-reads: tag coverage was not verified, so no absence is claimed
    elif rel.get("head_oid"):
        names = [C.trim(t["name"], 40) for t in rel.get("head_tags") or []]
        total = rel.get("head_tags_total", len(names))
        if total:
            more = " +%d" % (total - 3) if total > 3 else ""
            parts.append("tagged %s%s at HEAD%s" % (", ".join(names[:3]), more, " (tag list incomplete)" if rel.get("head_tags_partial") else ""))
        elif rel.get("head_tags_partial"):
            parts.append("tag list incomplete")
        else:
            parts.append("no tag at HEAD")
    n_a, n_b = sy.get("ahead"), sy.get("behind")
    if st == "aligned":
        parts.append("in sync with %s (local tracking state)" % up)
    elif st == "ahead":
        parts.append("%d commit%s ahead of %s" % (n_a, "" if n_a == 1 else "s", up))
    elif st == "behind":
        parts.append("%d commit%s behind %s" % (n_b, "" if n_b == 1 else "s", up))
    elif st == "diverged":
        parts.append("diverged from %s (%d ahead, %d behind)" % (up, n_a, n_b))
    elif st == "no_upstream":
        parts.append("no upstream")
    elif st == "missing_upstream":
        parts.append("upstream %s missing locally" % up)
    elif st == "detached":
        parts.append("detached HEAD")
    elif st == "unborn":
        parts.append("no commits yet")
    else:
        parts.append("sync unknown")
    if rel.get("shallow"):
        parts.append("shallow clone")
    line = " · ".join(parts)
    if rel.get("shared"):
        line = "shared repo: " + line
    return C.trim(line, 200)


def release_key(rel, tags):
    """Change-key entry: head-tag identity digest (over the COMPLETE set) + upstream ref + sync state + ahead count. Not
    the behind count, not recent_tags, no timestamps. In a shared (sub-folder) repository only 'ahead > 0' counts, so a
    colleague's unrelated commit does not re-judge every package. tags = {"hash", "n", "partial"}; a partial tag set
    carries partial True: compare_keys compares it like any other field (a change is a move) and reports it as incomplete coverage."""
    sy = rel["sync"]
    ahead = sy.get("ahead")
    if rel.get("shared") and ahead is not None:
        ahead = 1 if ahead > 0 else 0
    key = {"tags": tags["hash"], "n": tags["n"], "upstream": C.ref_ident(sy["upstream_ref"]) if sy.get("upstream_ref") else None,
           "state": sy.get("state"), "ahead": ahead}
    if tags.get("partial"):
        key["partial"] = True
    return key


def collect_release(repo, git_timeout=20.0, shared=False):
    """Tags at the pinned HEAD, five recent tags (display only) and branch sync, from local refs only.
    -> release dict, or None when the object format is unsupported (not 40-hex). Failures of the tag listing raise
    GitCollectError; failures on the upstream side give sync.state 'unknown' with null counts (never an invented 0).
    Reads several refs, so HEAD, the symbolic branch and the literal upstream ref are pinned first and re-read last; a
    move in between retries, then reports unknown. Every name that reaches the result is in display-safe form; the
    raw identities only feed the key (hashed) and the git calls."""
    def g(sub, *args):
        try:
            return grun(repo, sub, *args, timeout=git_timeout)
        except G.GitArgError as ex:
            raise GitCollectError("git argument rejected: %s" % ex)
        except BudgetOut:
            raise
        except Exception as ex:   # noqa: BLE001
            raise GitCollectError("git %s failed: %s" % (sub, type(ex).__name__))

    def ref_state(ref):
        """Existence and type of ONE literal ref -> 'absent' | 'commit' | 'other' | 'broken' | 'error'. Only a successful
        query with no row documents absence. 'broken' = the query itself failed the way git fails on a ref to a missing
        object (rc 1/128): a stable condition, kept apart from 'absent' and from a timeout. 'error' = timeout or any other
        failure: unverified, it never equals an earlier answer."""
        rc, out = g("for-each-ref", G.REF_TYPE_FMT, ref)
        if rc in (1, 128):
            return "broken"
        if rc != 0:
            return "error"
        rows = [ln.split("\0") for ln in out.split("\n") if ln]
        rows = [r for r in rows if r and r[0] == ref]   # the pattern also matches refs below it
        if not rows:
            return "absent"
        if len(rows) == 1 and len(rows[0]) == 3 and rows[0][1] == "commit" and HEX40.match(rows[0][2]):
            return "commit"
        return "other"

    def up_meta(branch_ref):
        rc6, out6 = g("for-each-ref", G.UP_FMT, branch_ref)
        f = out6.rstrip("\n").split("\0")
        if rc6 != 0 or len(f) != 4 or f[0] != branch_ref:
            return None
        return f[1], f[2]   # literal upstream ref ("" = none), remote name

    def one_pass():
        rel = {"shared": bool(shared), "head_oid": None, "head_tags": [], "head_tags_total": 0, "recent_tags": [],
               "sync": {"branch_ref": None, "upstream_ref": None, "upstream_kind": None, "state": "unknown",
                        "ahead": None, "behind": None}, "shallow": None}
        sy = rel["sync"]
        pin = {"oid": None, "branch": None, "up": None, "uoid": None, "hs": None, "us": None}
        tags = {"h": hashlib.sha256(), "n": 0, "partial": False}
        rc, out = g("rev-parse", "--verify", "--end-of-options", "HEAD^{commit}")
        oid = out.strip()
        if rc == 0 and not HEX40.match(oid):
            return None, None, None   # SHA-256 or an unexpected form: unsupported, reported as no release facts
        if rc not in (0, 1, 128):
            raise GitCollectError("git rev-parse failed (rc %d)" % rc)
        if rc == 0:
            rel["head_oid"] = pin["oid"] = oid
        rc2, out2 = g("symbolic-ref", "--quiet", "HEAD")
        if rc2 == 0 and out2.strip():
            pin["branch"] = out2.strip()
        elif rc2 != 1:
            raise GitCollectError("git symbolic-ref failed (rc %d)" % rc2)
        rc3, out3 = g("rev-parse", "--is-shallow-repository")
        if rc3 == 0 and out3.strip() in ("true", "false"):
            rel["shallow"] = out3.strip() == "true"
        if oid and rc == 0:
            shown = []

            def on_row(ln):
                t = _tag_row(ln)
                if not t or t["kind"] == "noncommit" or t["commit"] != oid:
                    return
                tags["h"].update(("%s\0%s\0%s\n" % (t["name"], t["oid"] or "", t["commit"] or "")).encode("utf-8", "replace"))
                tags["n"] += 1
                if len(shown) < HEAD_TAGS_SHOWN:
                    shown.append(t)
            t_s = step(git_timeout)
            try:
                rc4, trunc = G.stream_lines(repo, "for-each-ref", "--sort=refname", G.TAG_FMT, "--points-at=" + oid, "refs/tags",
                                            timeout=t_s, max_rows=_max_tag_rows(), on_row=on_row)
            except G.GitArgError as ex:
                raise GitCollectError("git argument rejected: %s" % ex)
            if rc4 == 124 and left() < 0.05:
                raise BudgetOut("budget")
            if rc4 != 0:
                raise GitCollectError("git for-each-ref failed (rc %d)" % rc4)
            tags["partial"] = bool(trunc)
            rel["head_tags_total"] = tags["n"]
            if trunc:
                rel["head_tags_partial"] = True   # more tags than were read: the count is a lower bound
            rel["head_tags"] = [{"name": C.display_safe(t["name"], NAME_MAX), "kind": t["kind"], "tid": C.tag_tid(t["name"])} for t in shown]
        rc5, out5 = g("for-each-ref", "--sort=refname", "--sort=-creatordate", "--count=5", G.TAG_FMT, "refs/tags")
        if rc5 != 0:
            raise GitCollectError("git for-each-ref failed (rc %d)" % rc5)
        rel["recent_tags"] = [{"name": C.display_safe(t["name"], NAME_MAX), "kind": t["kind"],
                               "at": t["commit"][:7] if t["commit"] else None} for t in _tag_rows(out5)]
        # ---- sync (raw refs live in pin; sy gets display forms at the end)
        raw_up = None
        if rc != 0:   # no commit at HEAD: an attached branch whose ref genuinely does not exist is unborn, anything else unknown
            sy["state"] = "unknown"
            if pin["branch"] and G.branch_ref_ok(pin["branch"]):
                pin["hs"] = ref_state(pin["branch"])   # absent / commit / other / broken / error, pinned like any other identity
                if pin["hs"] == "absent":
                    sy["state"] = "unborn"
        elif pin["branch"] is None:
            sy["state"] = "detached"
        elif not G.branch_ref_ok(pin["branch"]):
            sy["state"] = "unknown"
        else:
            meta = up_meta(pin["branch"])
            if meta is None:
                sy["state"] = "unknown"
            elif not meta[0]:
                sy["state"] = "no_upstream"
            elif not G.upstream_ref_ok(meta[0]):
                sy["state"] = "unknown"
            else:
                raw_up = pin["up"] = meta[0]
                sy["upstream_kind"] = "local" if meta[1] == "." else "remote"
                rc7, out7 = g("rev-parse", "--verify", "--end-of-options", raw_up + "^{commit}")
                uo = out7.strip()
                if rc7 == 0 and HEX40.match(uo):
                    pin["uoid"], pin["us"] = uo, "ok"
                    rc8, out8 = g("rev-list", "--left-right", "--count", "%s...%s" % (oid, uo))
                    m = re.fullmatch(r"([0-9]+)\s+([0-9]+)\s*", out8) if rc8 == 0 else None
                    if not m:
                        sy["state"] = "unknown"
                    else:
                        a, b = int(m.group(1)), int(m.group(2))
                        sy.update(ahead=a, behind=b, state="aligned" if not a and not b else "ahead" if not b
                                  else "behind" if not a else "diverged")
                elif rc7 in (1, 128):   # not a commit: absent, or present but malformed? ask a narrow existence/type query
                    st = pin["us"] = ref_state(raw_up)
                    sy["state"] = "missing_upstream" if st == "absent" else "unknown"
                else:
                    pin["us"] = "bad" if rc7 == 0 else "err"   # "err" never equals a final answer (pin_now reports None for it)
                    sy["state"] = "unknown"
        sy["branch_ref"] = C.display_safe(pin["branch"]) if pin["branch"] else None
        sy["upstream_ref"] = C.display_safe(raw_up) if raw_up else None
        return rel, tags, (pin, raw_up)

    UNREAD = object()
    final = {"oid": UNREAD}   # the HEAD oid the last pin_now read (None = verified unborn/unresolvable), UNREAD = the read failed

    def pin_now():
        """The identities one_pass pinned, read again: HEAD oid, symbolic branch, literal upstream ref and its oid.
        -> the pin dict, or None when ANY of the reads did not succeed (timeout, error, malformed answer). Absence is
        only what a successful query documents (HEAD unborn: branch ref genuinely absent; detached symbolic-ref rc 1; no
        upstream configured; upstream ref genuinely absent): a failed query is never folded into those, so it can never
        match an earlier pin. rc 1/128 of rev-parse is not that evidence: it goes through the same exact existence/type
        query (ref_state) as the first pass, and absent / commit / other / broken stay distinct in the pin."""
        final["oid"] = UNREAD
        rc, out = g("rev-parse", "--verify", "--end-of-options", "HEAD^{commit}")
        if rc == 0:
            cur = {"oid": out.strip(), "branch": None, "up": None, "uoid": None, "hs": None, "us": None}
            final["oid"] = cur["oid"]
        elif rc in (1, 128):
            cur = {"oid": None, "branch": None, "up": None, "uoid": None, "hs": None, "us": None}
            final["oid"] = None
        else:
            return None
        rc2, out2 = g("symbolic-ref", "--quiet", "HEAD")
        if rc2 == 0 and out2.strip():
            cur["branch"] = out2.strip()
        elif rc2 != 1:
            return None
        if not cur["oid"] and cur["branch"] and G.branch_ref_ok(cur["branch"]):
            cur["hs"] = ref_state(cur["branch"])
            if cur["hs"] == "error":
                return None
        if cur["oid"] and cur["branch"] and G.branch_ref_ok(cur["branch"]):   # one_pass reads the upstream only for a born HEAD
            meta = up_meta(cur["branch"])
            if meta is None:
                return None
            if meta[0] and G.upstream_ref_ok(meta[0]):
                cur["up"] = meta[0]
                rc3, out3 = g("rev-parse", "--verify", "--end-of-options", meta[0] + "^{commit}")
                if rc3 == 0:
                    if HEX40.match(out3.strip()):
                        cur["uoid"], cur["us"] = out3.strip(), "ok"
                    else:
                        cur["us"] = "bad"   # malformed: one_pass reports unknown for it too
                elif rc3 in (1, 128):
                    cur["us"] = ref_state(meta[0])
                    if cur["us"] == "error":
                        return None
                else:
                    return None
        return cur

    rel, tags, pr = one_pass()
    for attempt in range(3):
        if rel is None:
            return None
        now_pin = pin_now()   # None = a read failed: unverified, treated like a move (re-read, then unknown)
        if now_pin is not None and now_pin == pr[0]:
            break
        if attempt == 2:   # still moving after two re-reads: say so instead of publishing a mixed picture
            rel["sync"].update(state="unknown", ahead=None, behind=None, branch_ref=None, upstream_ref=None, upstream_kind=None)
            if not (pr[0]["oid"] and final["oid"] == pr[0]["oid"]):
                # The tag set was read for a HEAD that was not verified to be the same at the end (moved, unresolvable or
                # unread): tag coverage is UNKNOWN, never "no tag at HEAD". A set read for a HEAD oid that is verified
                # unchanged (only the branch or its upstream kept moving) stays: that fact was checked independently.
                rel["head_oid"], rel["head_tags"], rel["head_tags_total"] = None, None, None
                rel.pop("head_tags_partial", None)
                tags = None
            pr = (pr[0], None)
            rel["inconsistent"] = True
            break
        rel, tags, pr = one_pass()   # something moved while the refs were read: read again
    rel["key"] = release_key(rel, {"hash": tags["h"].hexdigest()[:12], "n": tags["n"], "partial": tags["partial"]}
                             if tags else {"hash": "unknown", "n": None, "partial": False})
    if rel.get("inconsistent"):
        rel["key"]["unverified"] = True   # script-owned uncertainty: stable while the world stays the same, never a bare "current"
    if pr[1] and not rel.get("inconsistent"):   # key identity of the raw upstream ref (hashed when it is not display-safe)
        rel["key"]["upstream"] = C.ref_ident(pr[1])
    rel["line"] = release_line(rel)
    return rel


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
    if "retired_decisions" in S and not isinstance(S["retired_decisions"], str):
        return "key retired_decisions is not str"
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
         "judged_key": None, "applied": 0, "applied_hash": None, "retired": [], "replay": False}
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
            P["replay"] = True   # an outstanding --accept-answers rebaseline: its rewritten prefix is not consumed until a judgement
            if "accepted" in ov:   # 3.5: the focus a replay computed (the last F-set line of the file, or none)
                acc = ov["accepted"]
                P["accepted_override"] = {"accepted": acc if _rec_ok(acc, ("outcome", "done_when", "exclusions", "hash", "line")) else None}
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


def hash_watch(root, entries, cache, hash_deadline, fp_out=None):
    """Content-hash every watched path. cache: {abs: {dev, ino, size, mtime_ns, ctime_ns, sha256}} (mutated).
    -> (watch list, covered, total). An entry whose files were not all hashed in time gets hash 'partial'.
    fp_out (a dict, optional): receives, for every entry that is ONE regular file, {entry: {fp, status}} with the content
    fingerprint (sha256 of the bytes, first 12 hex) or {status: unknown} when the file could not be hashed in time (15.2)."""
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
                if fp_out is not None and kind == "file":
                    fp_out[ent] = {"status": "unknown"}
                continue
            try:
                st = os.lstat(ap)
            except OSError:
                h.update(rel.encode("utf-8", "replace") + b"\0gone\n")
                covered += 1
                if fp_out is not None and kind == "file":
                    fp_out[ent] = {"status": "unknown"}
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
            if fp_out is not None and kind == "file":   # I4: a symlinked watch entry has NO usable file identity (as on the dirty route)
                fp_out[ent] = {"fp": sha[:12], "status": "verified"} if statmod.S_ISREG(st.st_mode) and re.fullmatch(r"[0-9a-f]{64}", sha) \
                    else {"status": "unknown"}
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


def collect_repo(root, rp, prev_head, watch_rel, git_timeout, rel_cache=None):
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
    info.update(vcs="git", head=head[:12] if head else None, branch=C.ref_ident(br.strip()) if br.strip() else None,
                head_at=C.iso(_dt().fromtimestamp(recs0[0][1]).astimezone()) if recs0 else None)
    if sub:
        info["toplevel"], info["scope"] = topr, rel
    # release facts are per Git toplevel, collected once: a package in a monorepo shows the SHARED repository's state
    rkey = (topr, sub)
    cache = rel_cache if rel_cache is not None else {}
    if rkey not in cache:
        cache[rkey] = collect_release(repo, git_timeout, shared=sub)
    info["release"] = copy.deepcopy(cache[rkey])
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
        commits.append({"r": rp, "h": sha[:7], "o": sha, "day": _day(ts), "s": C.trim(subj, 60), "f": f})   # "o": the full id, kept for fit evidence (15.2)
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
def read_answers_ex(pm):
    """-> (lines, tail). lines: (physical line no, raw bytes without line terminator) for the non-blank, COMPLETE
    (newline-terminated) lines of answers.jsonl. tail: True when the file ends in non-blank bytes without a newline. An
    unterminated tail is a record the owner's editor or script is still appending: it is not a line yet, so it is neither
    applied, counted, hashed nor reported as bad, and the next run sees it as an ordinary append once its newline arrives.
    A missing file is empty; any other read failure raises AnswersUnreadable (an unreadable file is never mistaken for an
    empty one)."""
    try:
        with open(os.path.join(pm, "answers.jsonl"), "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return [], False
    except OSError as ex:
        raise AnswersUnreadable("answers.jsonl cannot be read (%s)" % (ex.strerror or type(ex).__name__))
    parts = data.split(b"\n")
    return [(no, ln.rstrip(b"\r")) for no, ln in enumerate(parts[:-1], 1) if ln.strip()], bool(parts[-1].strip())


def answers_image(pm):
    """ONE read of answers.jsonl as the (lines, tail) image that a caller hands to collect() and to its own decisions, so the
    decision and the snapshot describe the same bytes (embed --apply-answers, 14.3)."""
    return read_answers_ex(pm)


def read_answers(pm):
    """The complete lines of answers.jsonl (see read_answers_ex)."""
    return read_answers_ex(pm)[0]


def prefix_hash(lines, n):
    h = hashlib.sha256()
    for _, ln in lines[:n]:
        h.update(ln + b"\n")
    return h.hexdigest()


# an owner line's `at`: absent, or a clean ISO-8601 timestamp that starts with its date (it is shown on the page, in the handoff and
# stored in the state, so it is validated like every other string an owner line can put there)
_AT_RE = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?(?:[Zz]|[+-]\d{2}:?\d{2})?)?")


def at_problem(at):
    """None when `at` is absent (null) or a clean timestamp; else why not. Strings only, at most 40 characters, no control, bidi,
    zero-width or line-separator character and nothing secret-shaped, the strict ISO shape, and a value the parser accepts."""
    if at is None:
        return None
    if not isinstance(at, str) or len(at) > 40:
        return "at must be an ISO-8601 timestamp of at most 40 characters"
    if C.unsafe_strings([at], "at") or C.display_safe(at) != at or not _AT_RE.fullmatch(at) or C.parse_iso(at) is None:
        return "at must be an ISO-8601 timestamp (no control characters or other text)"
    return None


F_SET = "F-set"          # the one owner record that is not a decision answer: the confirmed focus (14.2)
FOCUS_MAX = 120          # bytes: outcome (answer) and done-when (note)
EXCL_MAX, EXCL_N = 80, 3  # bytes per exclusion, how many


def _focus_problem(o):
    """Why an F-set line is unusable (None when fine). `answer` is the outcome, `note` (REQUIRED) the done-when, `exclusions`
    (optional) at most three short strings. Every string must be display-safe and secret-free: such a line is `bad` and
    never stored, so the accepted record can only hold text that is safe to put on the page, in the brief and in the handoff."""
    for what, v in (("answer (the outcome)", o.get("answer")), ("note (done when)", o.get("note"))):
        if not isinstance(v, str) or not 1 <= C.blen(v) <= FOCUS_MAX:
            return "F-set %s must be a string of 1..%d bytes" % (what, FOCUS_MAX)
    ex = o.get("exclusions", [])
    if not isinstance(ex, list) or len(ex) > EXCL_N or not all(isinstance(x, str) and 1 <= C.blen(x) <= EXCL_MAX for x in ex):
        return "F-set exclusions must be at most %d strings of 1..%d bytes" % (EXCL_N, EXCL_MAX)
    strings = [o["answer"], o["note"]] + list(ex)
    if C.unsafe_strings(strings, "F-set") or any(C.display_safe(x) != x for x in strings):
        return "F-set text holds control characters or looks like a secret"
    return None


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
        focus = o["id"] == F_SET
        extra = sorted(set(o) - {"id", "answer", "at", "by", "note"} - ({"exclusions"} if focus else set()))   # exclusions: F-set only
        if extra:
            bad.append({"line": no, "why": "unknown keys: %s" % ", ".join(map(str, extra))[:60]})
            continue
        if o.get("by", "owner") != "owner":
            bad.append({"line": no, "why": "by must be \"owner\""})
            continue
        why_at = at_problem(o.get("at"))
        if why_at:
            bad.append({"line": no, "why": why_at})
            continue
        note = o.get("note")
        if note is not None and (not isinstance(note, str) or C.blen(note) > 16384):
            bad.append({"line": no, "why": "note must be a string of at most 16384 bytes"})
            continue
        rec = {"id": o["id"], "answer": o["answer"], "at": o["at"] if isinstance(o.get("at"), str) else None,
               "by": o["by"] if isinstance(o.get("by"), str) else "owner", "note": note, "line": no}
        if focus:
            why = _focus_problem(o)
            if why:
                bad.append({"line": no, "why": why})
                continue
            rec["exclusions"] = list(o.get("exclusions", []))
        pending.append(rec)
    return pending, bad


# ---- the confirmed focus (14.1-14.3): state.intent = {accepted, proposed, target}
def accepted_record(a):
    """The owner's record, a PURE function of one F-set line (so --accept-answers replays deterministically)."""
    ex = list(a.get("exclusions") or [])
    return {"outcome": a["answer"], "done_when": a["note"], "exclusions": ex, "hash": C.intent_hash(a["answer"], a["note"], ex),
            "at": a.get("at"), "line": a["line"]}


def _rec_ok(x, keys):
    return isinstance(x, dict) and all(k in x for k in keys) and isinstance(x.get("hash"), str) \
        and isinstance(x.get("outcome"), str) and isinstance(x.get("done_when"), str) \
        and (not isinstance(x.get("exclusions", []), list) or all(isinstance(e, str) for e in x.get("exclusions", [])))


def _drift_ok(x):
    ack = x.get("acknowledged") if isinstance(x, dict) else None
    hd = x.get("heads") if isinstance(x, dict) else None
    return isinstance(x, dict) and isinstance(x.get("hash"), str) and isinstance(x.get("streak"), int) and not isinstance(x.get("streak"), bool) \
        and x["streak"] >= 0 and isinstance(x.get("revise_requested"), bool) \
        and (hd is None or (isinstance(hd, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in hd.items()))) \
        and (ack is None or (isinstance(ack, dict) and isinstance(ack.get("observations"), list)
                             and all(isinstance(o, str) for o in ack["observations"])))


def intent_of(S):
    """A published state's intent, shape-checked: {accepted, proposed, target}, each a well-formed record or None; plus `drift` (3.6)
    when the state carries a well-formed record of it (the key is absent otherwise, so a map without an accepted focus looks as it
    did before 3.6). A state from before 3.5 (no intent) and anything malformed give None entries; nothing here raises."""
    it = S.get("intent") if isinstance(S, dict) else None
    out = {"accepted": None, "proposed": None, "target": None}
    if isinstance(it, dict):
        for k, keys in (("accepted", ("outcome", "done_when", "exclusions", "hash", "line")), ("proposed", ("outcome", "done_when", "hash")),
                        ("target", ("outcome", "done_when", "exclusions", "hash"))):
            if _rec_ok(it.get(k), keys):
                out[k] = copy.deepcopy(it[k])
        if _drift_ok(it.get("drift")):
            out["drift"] = copy.deepcopy(it["drift"])
    return out


def intent_base(prev):
    """The intent a collection starts from: the pinned state's, with the accepted record replaced by the one a
    `--accept-answers` replay computed for this very generation (a replay that found no F-set line makes it null)."""
    it = intent_of(prev.get("state")) if prev.get("kind") == "v4" else intent_of(None)
    ao = prev.get("accepted_override")
    if isinstance(ao, dict):
        it["accepted"] = copy.deepcopy(ao["accepted"])
    return it


def reconcile_intent(it):
    """A proposal that says what the accepted focus says is no proposal (the model cannot set exclusions, so they are the
    accepted record's own). 3.6: the drift record belongs to ONE accepted identity: with no accepted record there is none, and a
    record of another identity (a replay, a focus set outside the reducer) is replaced by a fresh one."""
    a, p = it.get("accepted"), it.get("proposed")
    if a and p and C.intent_hash(p["outcome"], p["done_when"], a.get("exclusions")) == a["hash"]:
        it["proposed"] = None
    d = it.get("drift")
    if not isinstance(a, dict):
        it.pop("drift", None)
    elif not (isinstance(d, dict) and d.get("hash") == a.get("hash")):
        it["drift"] = C.new_drift(a["hash"])
    return it


def confirmation_only(prev_state, lines, applied):
    """14.3 fast-path predicate (facts' `decide` and `embed --mechanical --apply-answers` use exactly this): True iff the pinned
    state has an intent.target, its accepted record is null or equal to it, and every COMPLETE line after `applied` (at least
    one) is a well-formed F-set whose identity (exclusions included) equals target.hash. A decision answer, a bad line, another
    intention or one with other exclusions is not a confirmation. `lines`: read_answers_ex(pm)[0]."""
    it = intent_of(prev_state)
    tg, acc = it["target"], it["accepted"]
    if tg is None or (acc is not None and acc["hash"] != tg["hash"]):
        return False
    rest = lines[applied:]
    if not rest:
        return False
    pending, bad = parse_pending(rest)
    return not bad and len(pending) == len(rest) and all(
        a["id"] == F_SET and C.intent_hash(a["answer"], a["note"], a.get("exclusions")) == tg["hash"] for a in pending)


def drift_focus_set(intent, acc):
    """3.6 (15.2): an F-set line is the owner speaking about the focus. A new identity starts a fresh drift record (streak, heads,
    acknowledgement and revision request all belong to the words that were accepted); the same identity only clears a pending
    revision request ("cleared by the next F-set")."""
    d = intent.get("drift")
    if isinstance(d, dict) and d.get("hash") == acc["hash"]:
        d["revise_requested"] = False
    else:
        intent["drift"] = C.new_drift(acc["hash"])


def drift_answer(intent, dec, answer):
    """3.6 (15.3): the side effect of an owner's answer to a drift decision on the drift record IN EFFECT AT THAT LINE. EVERY effect is
    guarded by `decision.intent_hash == drift.hash`: an answer to a question about an older intention is recorded by the ordinary
    `D-` lifecycle and its side effect is moot. A: acknowledge the observations the decision was raised about, streak 0. B: ask for
    a revision (cleared by the next F-set). C: nothing."""
    d = intent.get("drift")
    if answer not in ("A", "B") or not isinstance(d, dict) or dec.get("about") != "drift" or dec.get("intent_hash") != d.get("hash"):
        return
    if answer == "A":
        d["acknowledged"] = {"observations": [o for o in (dec.get("observations") or []) if isinstance(o, str)]}
        d["streak"] = 0
    else:
        d["revise_requested"] = True


def apply_answers(by_id, pending, intent=None):
    """THE reducer for owner lines (14.2), in file order. A `D-` line answers an open/overdue decision of by_id (the last one
    per decision wins); an `F-set` line sets intent["accepted"] (the last one wins) and is never a decision answer. With
    intent=None an F-set line is skipped. 3.6: the same pass keeps intent["drift"] (15.2/15.3): an F-set resets or clears it, an
    answer to a drift decision acts on it under the intent_hash guard, each with the record as it is at that line. Used by
    lifecycle, late_answers and the --accept-answers replay alike. -> list of bad {line, why}."""
    bad, applied = [], {}
    for a in pending:
        if a["id"] == F_SET:
            if intent is not None:
                intent["accepted"] = accepted_record(a)
                drift_focus_set(intent, intent["accepted"])
            continue
        d = by_id.get(a["id"])
        if not d:
            bad.append({"line": a["line"], "why": "unknown or closed decision %s" % a["id"]})
        elif a["answer"] != "hold" and a["answer"] not in {o.get("id") for o in d.get("options", []) if isinstance(o, dict)}:
            bad.append({"line": a["line"], "why": "%s is not an option of %s" % (C.trim(a["answer"], 20), a["id"])})
        else:
            d.update(status="answered", answer=a["answer"], answered_by=a["by"], answered_at=a["at"])
            applied.setdefault(a["id"], []).append(a["line"])
            if intent is not None:
                drift_answer(intent, d, a["answer"])
    for i, ls in applied.items():
        if len(ls) > 1:
            bad.append({"line": ls[0], "why": "%s answered %d times, last kept" % (i, len(ls))})
    return bad


def lifecycle(prev_decs, pending, t, intent=None):
    """Apply answers and expiries to a copy of the previous OPEN/OVERDUE decisions (closed ones are dropped here). `intent`
    (optional, mutated in place) receives the F-set lines through the same reducer."""
    by_id = {d["id"]: dict(d) for d in prev_decs if d.get("status") in ("open", "overdue")}
    bad = apply_answers(by_id, pending, intent)
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


def late_answers(pm, snap, ids, image=None):
    """Owner answers appended to answers.jsonl AFTER the snapshot was staged, when a judgement is about to close decisions
    `ids` by events (INTERFACES 12.5). None when no valid new answer targets one of them: the new lines then stay pending
    exactly as before (the key's answers_count marks the map for a re-judgement). Otherwise every line appended since is
    applied in file order to the staged open decisions (the applied count is a prefix, so a later answer cannot be applied
    alone) and the owner's answer wins: -> {decisions, answers, intent, won}, the staged view with those decisions answered and
    answers.applied advanced past the new lines. 3.5.0: "every line" includes the owner's F-set lines, which go through the same
    reducer into `intent` (what the owner's record is at publication); `won` is still decided from D- lines only, so an F-set
    alone is not a late answer (None: it stays pending). Raises AnswersRewritten when the staged prefix no longer matches.
    `image`: the complete lines of ONE read of answers.jsonl (read_answers_ex(pm)[0]) when the caller also needs the
    unterminated-tail flag of that same read; the file is then not read again, so the tail flag and the late answers
    describe the same bytes (Codex OV330-R4-1)."""
    lines = read_answers(pm) if image is None else image   # complete lines only; raises AnswersUnreadable when unreadable
    a = snap["answers"]
    # the staged prefix is verified whatever was appended: a shortened file (fewer lines) or a rewritten one with the same
    # number of lines can hide an owner answer that the staged hash no longer covers
    if len(lines) < a["total"] or prefix_hash(lines, a["total"]) != a["total_hash"]:
        raise AnswersRewritten("answers rewritten")
    if len(lines) == a["total"]:
        return None
    pending, bad = parse_pending(lines[a["total"]:])
    by_id = {d["id"]: dict(d) for d in snap["decisions"] if d.get("status") in ("open", "overdue")}
    intent = reconcile_intent(copy.deepcopy(snap.get("intent") or intent_of(None)))   # staged view, then ALL appended lines
    bad += apply_answers(by_id, pending, intent)
    reconcile_intent(intent)
    won = sorted(i for i in ids if (by_id.get(i) or {}).get("status") == "answered")   # decided by D- lines only
    if not won:
        return None
    ph = prefix_hash(lines, len(lines))
    return {"decisions": [by_id[d["id"]] if (by_id.get(d["id"]) or {}).get("status") == "answered" else d for d in snap["decisions"]],
            "answers": dict(a, total=len(lines), applied=len(lines), applied_hash=ph, total_hash=ph, pending=[],
                            bad=list(a["bad"]) + bad),
            "intent": intent, "won": won}


# ---------------------------------------------------------------- completion evidence (3.6.0, INTERFACES 15.1)
# The pinned state's completion refs (a done criterion's ref, a done part's ref) are re-checked a few at a time on every facts run
# and mechanical refresh. A ref that is gone is a LOSS: the script never flips `done`, it marks the item unverified, moves the key
# and queues a repair for the next judgement. Absence is only ever what a SUCCESSFUL query documents; a timeout, a permission
# error or a repository that cannot be read is `unknown`.
EVID_CAP = 40                                   # checks per pass
EVID_RANK = {"ok": 0, "unknown": 1, "lost": 2}  # the equal-epoch safety rule: the worse status wins
EVID_WHY = VAL.EVID_WHY


def evidence_items(S):
    """The completion refs of a published state: [(id, ref)] sorted, one per done criterion and per done part that carries a ref."""
    out = set()
    if isinstance(S, dict):
        for ph in S.get("phases") or []:
            for c in (ph.get("criteria") or []) if isinstance(ph, dict) else []:
                if isinstance(c, dict) and c.get("done") is True and isinstance(c.get("id"), str) and isinstance(c.get("ref"), str) and c["ref"]:
                    out.add((c["id"], c["ref"]))
        for p in S.get("parts") or []:
            if isinstance(p, dict) and p.get("status") == "done" and isinstance(p.get("id"), str) and isinstance(p.get("ref"), str) and p["ref"]:
                out.add((p["id"], p["ref"]))
    return sorted(out)


evidence_key = C.evidence_key


def evidence_set(items):
    """Identity of the completion-ref list of one pinned generation (sha256 of the sorted (id, ref) pairs, first 16 hex)."""
    return C.sha256_bytes(C.canon(sorted([i, r] for i, r in items)).encode("utf-8", "replace"))[:16]


def evidence_record_ok(x):
    """cache.json `evidence` is script-owned but lives in a mutable file: anything malformed counts as no record."""
    return isinstance(x, dict) and isinstance(x.get("set"), str) and isinstance(x.get("gen"), str) \
        and isinstance(x.get("epoch"), int) and not isinstance(x.get("epoch"), bool) and x["epoch"] >= 0 \
        and isinstance(x.get("results"), dict) \
        and all(isinstance(k, str) and isinstance(v, dict) and v.get("status") in EVID_RANK and isinstance(v.get("epoch"), int)
                and not isinstance(v.get("epoch"), bool) for k, v in x["results"].items())


def _evid_pick(a, b):
    """Two results for ONE key: the higher epoch wins; an equal epoch (impossible across passes, kept as a safety rule) by status
    rank lost > unknown > ok."""
    if a is None:
        return b
    if b is None:
        return a
    if a["epoch"] != b["epoch"]:
        return a if a["epoch"] > b["epoch"] else b
    return a if EVID_RANK[a["status"]] >= EVID_RANK[b["status"]] else b


def evidence_merge(stored, mine, keys):
    """15.1 merge rules (the pass itself runs inside one critical section and reads the stored record under the lock, so this is
    also the pure function the tests drive): a pass whose `gen` is OLDER than the stored one discards its own results; a NEWER
    `gen`, or a changed `set` for the same gen, replaces the record and keeps the stored results whose key is still in the set
    (`keys`); the same set merges per key by the higher epoch, an equal epoch by rank. -> the record to store."""
    if not evidence_record_ok(stored):
        return copy.deepcopy(mine)
    if mine["gen"] < stored["gen"]:
        return copy.deepcopy(stored)
    same = mine["gen"] == stored["gen"] and mine["set"] == stored["set"]
    base = stored["results"] if same else {k: v for k, v in stored["results"].items() if k in keys}
    res = {k: copy.deepcopy(v) for k, v in base.items()}
    for k, v in mine["results"].items():
        res[k] = copy.deepcopy(_evid_pick(res.get(k), v))
    return {"set": mine["set"], "gen": mine["gen"], "epoch": max(stored["epoch"], mine["epoch"]), "results": res}


def _crit_first(i):
    return (0 if VAL.CRIT_ID.match(i) else 1, i)


def evidence_view(items, rec):
    """snapshot.evidence from the completion refs and a stored record: {checked, n, done, lost[{id, ref, why}], unknown[ids],
    ok[{id, ref}]}. `done` = refs visited since the set formed; `checked` is complete iff every ref has been visited and none is
    unknown (an empty list is trivially complete)."""
    res = rec.get("results", {}) if evidence_record_ok(rec) else {}
    lost, unknown, ok, done = [], [], [], 0
    for i, r in items:
        v = res.get(evidence_key(i, r))
        if v is None:
            continue
        done += 1
        if v["status"] == "lost":
            lost.append({"id": i, "ref": r, "why": v.get("why") if v.get("why") in EVID_WHY else "file missing"})
        elif v["status"] == "unknown":
            unknown.append(i)
        else:
            ok.append({"id": i, "ref": r})
    lost.sort(key=lambda e: _crit_first(e["id"]))
    return {"checked": "complete" if done == len(items) and not unknown else "partial", "n": len(items), "done": done,
            "lost": lost, "unknown": sorted(unknown), "ok": ok}


def empty_evidence():
    return {"checked": "complete", "n": 0, "done": 0, "lost": [], "unknown": [], "ok": []}


def _repo_probe(root, r, sha, t):
    """One repository row against a commit: ok | absent | moved | unknown. A repository is `moved` when its recorded path is no
    longer a directory under ROOT (removed, or replaced by a link elsewhere); a failing query is `absent` only when the
    repository itself still answers (git can name its toplevel), otherwise `unknown`."""
    prob, rp = VAL._confined(root, r.get("path") if isinstance(r.get("path"), str) else "", "repo path")
    if prob:   # an established confinement failure (a path replaced by a link elsewhere, a bad path)
        return "moved"
    try:   # I5: only ESTABLISHED absence (ENOENT / ENOTDIR) or a non-directory is `moved`; a permission or I/O error is unknown
        isdir = statmod.S_ISDIR(os.stat(rp).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return "moved"
    except OSError:
        return "unknown"
    if not isdir:
        return "moved"
    try:
        rc, out = G.run(rp, "cat-file", "-t", sha, timeout=t)
    except G.GitArgError:
        return "unknown"
    if rc == 0:
        return "ok" if out.strip() == "commit" else "absent"
    if rc in (1, 128):
        return "absent" if G.toplevel(rp, timeout=t) else "unknown"
    return "unknown"   # 124 timeout, 127 no git, anything else


def evidence_repos(repos, state):
    """The repositories a commit ref is looked for in: the collected git rows PLUS every git repository the pinned state already knows
    (I5): collection drops a nested repository it cannot even enter (or sees it as a plain folder), and that must never turn a commit
    into "missing". A known repository the collection did not report as git is probed by its recorded path."""
    have = {r.get("path") for r in repos if isinstance(r, dict) and r.get("vcs") == "git"}
    extra = [{"path": r["path"], "vcs": "git"} for r in ((state or {}).get("repos") or [])
             if isinstance(r, dict) and r.get("vcs") == "git" and isinstance(r.get("path"), str) and r["path"] not in have]
    return list(repos) + extra


def check_ref(root, repos, ref, deadline=None):
    """-> (status, why). status ok | lost | unknown; why is one of EVID_WHY for lost. 15.1: `file:` -> lstat of the confined path is
    a regular file and a given line exists; `commit:` -> cat-file in the confined repositories. Absence is only what a successful
    query documents (ENOENT, a cat-file answer from a repository that still works)."""
    if not isinstance(ref, str):
        return "lost", "file missing"
    if ref.startswith("file:"):
        rest, line = ref[5:], None
        m = re.match(r"^(.*):([0-9]+)$", rest)
        if m:
            rest, line = m.group(1), int(m.group(2))
        prob, rp = VAL._confined(root, rest, "file ref")
        if prob:
            return "lost", "file missing"
        orig = os.path.join(root, rest)   # the entry the ref NAMES, not what a link resolves to (I3)
        try:
            st = os.lstat(orig)
        except (FileNotFoundError, NotADirectoryError):
            return "lost", "file missing"
        except OSError:
            return "unknown", ""
        if not statmod.S_ISREG(st.st_mode):   # a symlink (internal, dangling, escaping) or a directory is not a regular file
            return "lost", "file missing"
        if line is not None:
            if line < 1:
                return "lost", "line past end"
            try:
                n = C.line_count(orig)
            except OSError:
                return "unknown", ""
            if line > n:
                return "lost", "line past end"
        return "ok", ""
    if ref.startswith("commit:"):
        sha = ref[7:]
        if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
            return "lost", "commit missing"
        t = 5.0 if deadline is None else max(0.3, min(5.0, deadline - time.monotonic()))
        seen = set()
        for r in repos:
            if isinstance(r, dict) and r.get("vcs") == "git":
                st = _repo_probe(root, r, sha, t)
                if st == "ok":
                    return "ok", ""
                seen.add(st)
        if "unknown" in seen:
            return "unknown", ""
        return "lost", "repo moved" if "moved" in seen else "commit missing"
    return "lost", "file missing"


def _evidence_gate():
    """Test seam PM_EVIDENCE_GATE=<file>: inside the evidence critical section (epoch reserved, nothing checked yet) create <file>
    and wait (at most 20 s) for <file>.go, so a test can run a second process against a busy lock or change the world between
    two passes deterministically."""
    sig = os.environ.get("PM_EVIDENCE_GATE")
    if not sig:
        return
    try:
        with open(sig, "w"):
            pass
    except OSError:
        return
    end = time.monotonic() + 20.0
    while not os.path.exists(sig + ".go") and time.monotonic() < end:
        time.sleep(0.02)


def check_evidence(root, repos, items, cache, deadline, gen, only=None, held=False, limit=EVID_CAP):
    """THE evidence scheduler (facts' collect, embed's mechanical collect and the publication recheck all use it). `items` =
    the completion refs [(id, ref)] of the pinned generation `gen`; the pass checks at most `limit` of them (or of `only`, a
    subset, for the recheck), least recently checked first (unvisited first, then the lowest epoch, ties by id), until the
    absolute time.monotonic() `deadline`.

    The whole pass is ONE critical section under the publish lock (non-blocking; `held=True` when the caller, embed, already
    holds it): re-read cache.json, reserve epoch + 1, check, merge, write, release. Two passes therefore never overlap, so epoch
    order IS observation order and a physically later loss can never be discarded by an earlier `ok`. A busy lock skips the
    pass: the record is untouched and the view is built from what is stored, never "complete" by assumption.
    -> (view, ran): view as evidence_view; ran = {key: {status, why}} of the checks THIS pass made ({} when it was skipped)."""
    pm = os.path.join(root, ".project-map")
    items = sorted(set(items))
    keys = {evidence_key(i, r): (i, r) for i, r in items}
    sid = evidence_set(items)
    cpath = os.path.join(pm, "cache.json")

    def stored_record():
        rec = (C.load_json(cpath, {}) or {}).get("evidence") if os.path.isfile(cpath) else None
        return rec if evidence_record_ok(rec) else None

    def compat(rec):   # a stored record viewed through THIS pass's keys
        return {"set": sid, "gen": gen, "epoch": rec["epoch"], "results": {k: v for k, v in rec["results"].items() if k in keys}} if rec else None

    if not items or not os.path.isdir(pm):
        return empty_evidence() if not items else evidence_view(items, None), {}
    lock = None
    if not held:
        try:
            lock = C.PMLock(pm).acquire()
        except (C.Busy, OSError):
            return evidence_view(items, compat(stored_record())), {}   # busy: the record is untouched
    try:
        stored = stored_record()
        if stored is not None and stored["gen"] > gen:   # a newer generation already owns the record: this pass discards its own
            return evidence_view(items, compat(stored)), {}
        epoch = (stored["epoch"] if stored else 0) + 1
        _evidence_gate()
        base = compat(stored)["results"] if stored else {}
        pool = [k for k in keys if only is None or keys[k] in only]
        pool.sort(key=lambda k: (k in base, base[k]["epoch"] if k in base else 0, k))
        mine, ran = {"set": sid, "gen": gen, "epoch": epoch, "results": {}}, {}
        for k in pool[:limit]:
            if deadline is not None and time.monotonic() >= deadline:
                break
            st, why = check_ref(root, repos, keys[k][1], deadline)
            ran[k] = {"status": st, "why": why}
            mine["results"][k] = {"status": st, "why": why, "at": C.iso(), "epoch": epoch}
        merged = evidence_merge(stored, mine, set(keys))
        try:
            cur = C.load_json(cpath, {}) or {}
            cur = cur if isinstance(cur, dict) else {}
            cur["evidence"] = merged
            C.atomic_write(cpath, C.dumps(cur))
        except OSError:
            pass   # the observation stands for this run even when it could not be stored
        cache["evidence"] = merged
        return evidence_view(items, compat(merged)), ran
    finally:
        if lock is not None:
            lock.release()


# ---------------------------------------------------------------- file identity (3.6.0, INTERFACES 15.2)
FP_MAX_DIRTY = 20


def fp_key(path):
    return os.path.normpath(path)


def file_fingerprint(abspath, cache, deadline):
    """{fp, status: verified} (sha256 of the bytes, first 12 hex) of ONE regular file, or {status: unknown} for anything else
    (a directory, a link, a missing or unreadable file, a hash that did not finish before the deadline). `cache` is the small
    fp_cache {abs: {dev, ino, size, mtime_ns, ctime_ns, sha256}} so an unchanged file is read once."""
    try:
        st = os.lstat(abspath)
    except OSError:
        return {"status": "unknown"}
    if not statmod.S_ISREG(st.st_mode):
        return {"status": "unknown"}
    ident = {"dev": st.st_dev, "ino": st.st_ino, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "ctime_ns": st.st_ctime_ns}
    c = cache.get(abspath)
    if isinstance(c, dict) and all(c.get(k) == v for k, v in ident.items()) and isinstance(c.get("sha256"), str):
        sha = c["sha256"]
    else:
        h = hashlib.sha256()
        try:
            with open(abspath, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    if time.monotonic() >= deadline:
                        return {"status": "unknown"}
                    h.update(chunk)
        except OSError:
            return {"status": "unknown"}
        sha = h.hexdigest()
        cache[abspath] = dict(ident, sha256=sha)
    return {"fp": sha[:12], "status": "verified"}


# ---------------------------------------------------------------- usage / hashes
USAGE_MIN = 0.5   # below this many seconds a scan cannot make progress worth its start-up: keep the previous numbers


def _usage_at(u):
    return C.parse_iso(u.get("at")) if isinstance(u, dict) else None


USAGE_ALLOW = 2   # the label allowlist version project-map-usage.py stamps on its snapshot ("allow")


def clean_usage(u):
    """A usage dict from an earlier state is trusted only when it carries the counters-only label allowlist stamp; one from a
    3.3.0 development build may hold free-text job labels (a Codex user-message excerpt, a title), so its job list is
    dropped (the totals and per-model rows stay). -> u itself when it is current."""
    if not isinstance(u, dict) or u.get("allow") == USAGE_ALLOW:
        return u
    return dict(u, jobs=[])


def stale_usage(prev):
    """The previous usage numbers, marked stale with their ORIGINAL as-of time ("at"), or None when there are none."""
    if not (isinstance(prev, dict) and isinstance(prev.get("totals"), dict)):
        return None
    u = {k: v for k, v in clean_usage(prev).items() if k != "partial"}
    u["stale"] = True
    return u


def collect_usage(root, timeout, prev=None):
    """Usage snapshot for the state. NEVER raises and never makes its caller fail: a complete scan gives the fresh snapshot
    (no marker); a scan that ran out of budget (the script hands back its last complete result, "partial"), a timeout, a crash
    or a skipped scan (timeout < USAGE_MIN) gives the newest previous numbers (the script's last complete result or `prev`,
    the state's usage) with `stale: true` and their original as-of time in "at"; no numbers at all give None.
    PM_USAGE_SKIP=1 (tests, 'no usage') gives None."""
    if os.environ.get("PM_USAGE_SKIP"):
        return None
    got = None
    if timeout >= USAGE_MIN:
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "project-map-usage.py"), root, "--max-jobs", "15",
                                "--budget", "%.2f" % max(timeout - 0.35, 0.15)],
                               capture_output=True, text=True, timeout=timeout, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
            o = C.loads(r.stdout)
            snap = o.get("snapshot_for_state")
            if isinstance(snap, dict):
                if not o.get("partial") and not snap.get("partial"):
                    return snap
                got = snap
        except Exception:   # noqa: BLE001 - timeout, crash, garbage: fall back to the previous numbers
            pass
    cands = [u for u in (stale_usage(got), stale_usage(prev)) if u]
    if not cands:
        return None
    return max(cands, key=lambda u: (_usage_at(u).timestamp() if _usage_at(u) else 0.0))


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
def collect(root, prev, hash_deadline, cache, git_timeout=20.0, want_usage=False, usage_timeout=60.0, usage_until=None, usage_prev=None,
            answers_image=None, image_out=None, evidence_held=False):
    """Build the complete snapshot (6.1). hash_deadline: absolute time.monotonic() limit for content hashing only.
    answers_image: (lines, tail) of ONE read_answers_ex the caller already made (embed --apply-answers, 14.3: the decision and
    the snapshot then describe the same bytes); image_out (a dict) receives {lines, tail} of the read this collection used.
    3.6: the completion-evidence pass (check_evidence) is the one thing collect() writes itself (cache.json `evidence`, inside its
    own critical section under the publish lock); evidence_held=True when the caller already holds that lock (embed).
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

    base, base_from = window_base(root, prev)   # 16.6: an earlier start while commits in between were never read
    repos, commits, sh, dirty, total_count = [], [], hashlib.sha256(), [], 0
    rel_cache, window_heads = {}, {}
    for rp in ["."] + nested:
        ph = base.get(rp, "") if base is not None else heads_prev.get(rp)   # J1: unnamed in a held window = from its history
        ph = ph if isinstance(ph, str) and re.match(r"^[0-9a-f]{7,40}$", ph or "") else None
        window_heads[rp] = ph or ""   # every repository, "" = this window starts at its history (no earlier head)
        info, cnt, sig, dp, cm = collect_repo(root, rp, ph, watch, git_timeout, rel_cache)
        commits += cm
        total_count += cnt
        repos.append(info)
        sh.update(rp.encode() + b"\0" + str(sig).encode())
        dirty += dp
    commits.sort(key=lambda c: c["day"], reverse=True)
    dirty.sort(key=dirty_rank)   # 3.6.1: work first; files inside hidden folders (backups, caches) after it (stable within each)

    wc = cache.setdefault("watch_cache", {})
    fpw = {}
    wl, covered, total = hash_watch(root, watch, wc, hd, fp_out=fpw)
    partial = any(w["hash"] == "partial" for w in wl)
    cache["coverage_cursor"] = {"covered": covered, "total": total, "at": C.iso(t)}
    # 15.2: ONE content fingerprint per file, frozen now: every retained dirty path (<= 20) and every watch entry that is a single
    # regular file. Both routes land in the same map (a file reachable both ways has one identity); a directory has none.
    fpc = cache.setdefault("fp_cache", {})
    file_fp = {fp_key(w["path"]): fpw[w["path"]] for w in wl if w.get("kind") == "file" and w["path"] in fpw}
    for dpath in dirty[:FP_MAX_DIRTY]:
        file_fp.setdefault(fp_key(dpath), file_fingerprint(os.path.join(root, dpath), fpc, hd))
    keep = {os.path.join(root, dpath) for dpath in dirty[:FP_MAX_DIRTY]}
    for k in [k for k in fpc if k not in keep]:
        del fpc[k]
    # 15.1: the completion refs of the pinned state, a few per run (the scheduler is shared with embed and the publication recheck)
    ev_items = evidence_items(prev["state"]) if prev.get("kind") == "v4" else []
    evidence, _ran = check_evidence(root, evidence_repos(repos, prev.get("state")), ev_items, cache, hd, prev.get("gen"), held=evidence_held)

    lname = pj.get("ledger") if isinstance(pj.get("ledger"), str) else None
    ledger = parse_ledger(root, lname)

    lines, tail = answers_image if answers_image is not None else read_answers_ex(pm)
    if image_out is not None:
        image_out.update(lines=lines, tail=tail)
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
    intent = intent_base(prev)
    decs, bad2 = lifecycle(prev["decisions"], pending, t, intent)   # one reducer: D- lines answer decisions, F-set sets intent.accepted
    reconcile_intent(intent)
    bad += bad2
    expired = sorted(d["id"] for d in decs if d.get("status") in ("overdue", "defaulted"))
    th, eh = plugin_hashes()
    key = {"heads": {r["path"]: r["head"] for r in repos}, "branches": {r["path"]: r["branch"] for r in repos},
           "status_hash": sh.hexdigest()[:12],
           "release": {r["path"]: r["release"]["key"] for r in repos if r.get("release")},
           "watch_hashes": {w["path"]: w["hash"] for w in wl},
           "ledger_hash": ledger["hash"] if ledger else None, "answers_count": len(lines), "expired_ids": expired,
           "schema": C.SCHEMA_STATE,
           # 14.3: the OPERATIVE intention's identity: the owner's accepted record, else what the last judgement served
           "intent_hash": intent["accepted"]["hash"] if intent["accepted"] else (intent["target"] or {}).get("hash"),
           # 15.1: the ids of the completion refs that are known lost (script-owned; a state judged before 3.6 has none)
           "evidence_lost": sorted(e["id"] for e in evidence["lost"])}
    usage = None
    if want_usage:   # usage_until (absolute time.monotonic()) is evaluated NOW, after the git and hashing work above
        ut = usage_timeout if usage_until is None else min(usage_timeout, usage_until - time.monotonic())
        usage = collect_usage(root, max(ut, 0.0), usage_prev)
    snap = {
        "schema": "project-map-snapshot-1", "generation": None, "base": prev["gen"], "root": root, "facts_at": C.iso(t),
        "repos": repos, "commits": group_commits(commits, total_count),
        "status": {"hash": key["status_hash"], "dirty": len(dirty), "coverage": "partial" if partial else "complete",
                   "covered": covered, "total": total, "git_error": None},
        "dirty_paths": dirty[:DIRTY_LIST], "dirty_dirs": dirty_dirs(dirty[DIRTY_LIST:]), "watch": wl, "watch_dropped": dropped, "ledger": ledger,
        "answers": {"total": len(lines), "applied": ap, "applied_hash": ah, "total_hash": prefix_hash(lines, len(lines)),
                    "pending": pending, "bad": bad, "tail": tail},
        "decisions": decs, "usage": usage, "key": key, "prev_key": prev.get("judged_key"),
        "template_hash": th, "embed_hash": eh, "intent": intent,
        "evidence": evidence, "file_fp": file_fp,
        "commit_oids": {"%s|%s" % (c["r"], c["h"]): c["o"] for c in commits if c.get("o")},
    }
    snap["since"] = since_baseline(prev, t, snap["commits"]["count"], len(dirty), base_from)
    snap["window_heads"] = window_heads   # 16.6: where this commit window started, per repository (read by build_state)
    return snap


GEN_RE = re.compile(r"^[0-9]{6,}-[0-9a-f]{8}$")
HEAD_RE = re.compile(r"^[0-9a-f]{7,40}$")


def _heads_norm(h):
    """K1: a null head (a plain folder, an unborn repository) is the history-start marker "": the same start, one spelling."""
    return {r: ("" if v is None else v) for r, v in h.items()} if isinstance(h, dict) else h


def _heads_ok(h, jh):
    """A window start: {repo: head}, where "" means the repository's window starts at its history (no earlier head: it was new).
    Both sides are compared normalized (null = "")."""
    h, jh = _heads_norm(h), _heads_norm(jh)
    return isinstance(h, dict) and bool(h) and h != jh and all(isinstance(r, str) and isinstance(v, str) and (v == "" or HEAD_RE.match(v))
                                                               for r, v in h.items())


def window_base(root, prev):
    """3.6.1 (16.6): where the commit window starts. Commits leave the window only once a judgement read every commit its snapshot
    listed (`state.read`, written by every judged publication). -> (heads {repo: head}, {generation, assessed_at}), or (None, None)
    for the ordinary window (the judged heads, since the previous generation). A state from before 3.6.1 has no `read`: when its
    judgement read fewer commits than its snapshot listed (its pack cut them), the window restarts at the judged heads of the
    generation that judgement was measured from (`since.from.generation`) while that generation is on disk and verifies.
    J1: a repository the returned start does not name starts at its history ("" in `window_heads`), never at its judged head."""
    S = prev.get("state") if prev.get("kind") == "v4" else None
    if not isinstance(S, dict):
        return None, None
    jk = prev.get("judged_key")
    jh = jk.get("heads") if isinstance(jk, dict) else None
    rd = S.get("read")
    if isinstance(rd, dict):
        h = rd.get("heads")
        if _heads_ok(h, jh):
            return _heads_norm(h), {"generation": rd.get("generation"), "assessed_at": rd.get("assessed_at")}
        return None, None
    seen = S.get("judged_seen")
    cm = S.get("commits")
    listed = cm.get("listed") if isinstance(cm, dict) else None
    if not (isinstance(seen, dict) and isinstance(seen.get("commits"), int) and isinstance(listed, int) and seen["commits"] < listed):
        return None, None
    sn = S.get("since")
    g = (sn.get("from") or {}).get("generation") if isinstance(sn, dict) and isinstance(sn.get("from"), dict) else None
    pm = os.path.join(root, ".project-map")
    if not isinstance(g, str) or not GEN_RE.match(g) or not C.verify_generation(os.path.join(pm, C.gen_dir_name(g))):
        return None, None
    try:
        B = C.loads(C.read_pinned(pm, g, "state.json") or b"null")
    except ValueError:
        return None, None
    bk = B.get("judged_key") if isinstance(B, dict) else None
    h = bk.get("heads") if isinstance(bk, dict) else None
    if not _heads_ok(h, jh):
        return None, None
    return _heads_norm(h), {"generation": g, "assessed_at": B.get("judged_at")}


def since_baseline(prev, t, commits, dirty, base_from=None):
    """13.1: what moved since the PREVIOUS ASSESSMENT (never "your last visit"): {generation, assessed_at, commits, dirty,
    hours}. Commits are counted against judged_key.heads, which a mechanical refresh keeps, so the baseline is the previous
    JUDGED generation. None on a first map and on a 3.x (legacy) migration: there is no previous assessment to compare with.
    `base_from` (16.6): the window starts earlier because commits in between were never read: the baseline is that point."""
    if prev.get("kind") != "v4" or not isinstance(prev.get("state"), dict):
        return None
    raw = base_from.get("assessed_at") if isinstance(base_from, dict) else prev["state"].get("judged_at")
    at = C.parse_iso(raw) if isinstance(raw, str) else None
    gen = base_from.get("generation") if isinstance(base_from, dict) and isinstance(base_from.get("generation"), str) else prev.get("gen")
    return {"generation": gen, "assessed_at": raw if at is not None else None, "commits": commits, "dirty": dirty,
            "hours": max(0, int((t - at).total_seconds() // 3600)) if at is not None else None}


def compare_keys(judged, key, snap):
    """judged vs fresh key -> {'moved': [names], 'git': bool, 'adopt': [paths], 'why': text, 'incomplete': [paths]}.
    'incomplete' = repositories whose fresh tag listing is partial, 'unverified' = repositories whose tags/sync read kept moving
    (exhausted re-reads): script-owned coverage warnings, independent of 'moved'."""
    if not isinstance(judged, dict):
        return {"moved": ["heads"], "git": True, "adopt": [], "why": "no judged key", "incomplete": [], "unverified": []}
    moved, adopt = [], []
    for k in ("heads", "branches", "status_hash", "ledger_hash", "answers_count", "intent_hash", "expired_ids", "schema"):
        if key.get(k) != judged.get(k) and (k in judged or k in ("heads",)):   # a key judged before 3.5 has no intent_hash: not a move
            moved.append(k)
    # release (3.3.0): a key judged before 3.3.0 has no "release" entry; that forces ONE re-judgement, after which the
    # new key is stored. Raw behind counts and recent tags are not in the key, so they never re-judge.
    rel_why = []
    fresh_rel = key.get("release") or {}
    incomplete = sorted(p for p, v in fresh_rel.items() if isinstance(v, dict) and v.get("partial"))
    unverified = sorted(p for p, v in fresh_rel.items() if isinstance(v, dict) and v.get("unverified"))
    if "release" not in judged:
        moved.append("release")
        rel_why.append("tags and branch sync not yet judged")
    elif judged.get("release") != key.get("release"):
        # the entries include n and the partial flag, so a tag-count or coverage change (complete -> partial included) is
        # a move. An UNCHANGED partial entry (same prefix digest, count, sync, partial flag) is not: it is incomplete
        # coverage the scripts own and report (`incomplete`, the release line), not new evidence for a paid judgement.
        moved.append("release")
        if incomplete:
            rel_why.append("tag list too large to verify")
        jr, nr = judged.get("release") or {}, key.get("release") or {}
        paths = set(jr) | set(nr)
        if any((jr.get(p) or {}).get("tags") != (nr.get(p) or {}).get("tags") for p in paths):
            rel_why.append("tags changed")
        if any({k: v for k, v in (jr.get(p) or {}).items() if k not in ("tags", "n", "partial", "unverified")}
               != {k: v for k, v in (nr.get(p) or {}).items() if k not in ("tags", "n", "partial", "unverified")} for p in paths):
            rel_why.append("branch sync changed")
        if not rel_why:
            rel_why.append("tag count or coverage changed")
    # a closure by events that publication deferred because answers.jsonl ended in an uncommitted record (closure_deferred in
    # the judged key): once that tail is committed or removed, the map re-judges so the owner's answer can win or the closure
    # can be made again. While the tail is still there nothing moves (the owner is still writing).
    dfr = judged.get("closure_deferred")
    deferred_moved = sorted(i for i in dfr if isinstance(i, str)) if isinstance(dfr, list) \
        and not (snap.get("answers") or {}).get("tail") else []
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
    if "release" in moved:
        why.append(" and ".join(rel_why) or "tags changed")
    if "ledger_hash" in moved:
        why.append("ledger changed")
    pend = snap["answers"]["pending"]
    if "intent_hash" in moved:   # a different focus is set by the owner (a confirmation of the served one does not move this)
        why.append("focus set by owner")
    if "answers_count" in moved and not ("intent_hash" in moved and pend and all(a.get("id") == F_SET for a in pend)):
        why.append("%d pending answers" % max(len(pend), 1))
    if deferred_moved:
        moved.append("closure_deferred")
        if "answers_count" not in moved[:-1]:
            why.append("answers pending: closure of %s was deferred past an uncommitted answer tail" % ", ".join(deferred_moved))
    # 15.1 completion evidence: a loss the judged key does not know (`completion evidence lost`) or one it carried and nobody has repaired
    # yet (`N completion repairs pending`: the carried ones still need their batch) moves the key; ids that left the fresh set
    # because their refs verify again are not a move on their own (decide then asks for a mechanical refresh that clears the marks)
    fl = set(key.get("evidence_lost") or [])
    jl = set(judged.get("evidence_lost") or [])
    if fl - jl or fl & jl:
        moved.append("evidence_lost")
        if fl - jl:
            ids = sorted(fl - jl)
            why.append("completion evidence lost: " + ", ".join(ids[:3]) + (" +%d" % (len(ids) - 3) if len(ids) > 3 else ""))
        if fl & jl:
            why.append("%d completion repairs pending" % len(fl & jl))
    if "expired_ids" in moved:
        why.append("deadline passed: " + ", ".join(snap["key"]["expired_ids"] or judged.get("expired_ids", [])))
    if "schema" in moved:
        why.append("schema")
    return {"moved": moved, "git": any(m in GIT_KEYS for m in moved), "adopt": adopt, "why": "; ".join(why),
            "incomplete": incomplete, "unverified": unverified}


# ---------------------------------------------------------------- pack (6.2)
def dirty_rank(path):
    """3.6.1: 1 for a changed file inside a hidden folder (a component starting with '.') or a __pycache__ folder, else 0."""
    return 1 if any(x.startswith(".") or x == "__pycache__" for x in path.split("/")[:-1]) else 0


def dirty_dir(path):
    """The top-level folder a changed file is counted under ('./' for a file at the root)."""
    return path.split("/", 1)[0] + "/" if "/" in path else "./"


def dirty_dirs(paths, counts=None):
    """3.6.1: [{dir, n}] for `paths` (added to `counts`), most files first, then by name, at most DIRTY_DIRS_MAX folders. A folder
    past the cap is not counted, so the pack's `seen` shows the files it did not account for."""
    cnt = dict(counts or {})
    for q in paths:
        cnt[dirty_dir(q)] = cnt.get(dirty_dir(q), 0) + 1
    return [{"dir": k, "n": n} for k, n in sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))[:DIRTY_DIRS_MAX]]


def build_pack(snap, inv_name):
    """Bounded model-facing view, <= 8192 bytes. Never in it: the usage detail (per model, per job), which no judgement needs.
    Trim order (3.6.1, commit subjects are the last optional detail to go): recent tags, watch hashes, listed changed files folded
    into their folder counts, answer notes, decision text, ledger lines, answers, commit items; then the hard steps."""
    p = {k: snap[k] for k in ("schema", "base", "root", "facts_at")}
    p["since"] = snap.get("since")   # 13.1: the baseline the model judges against; small, never trimmed
    # 14.4: the owner's immediate objective and the standing proposal, RESERVED (placed before every optional detail, never
    # trimmed, part of every size measurement below): the model copies accepted and cannot change it
    it = snap.get("intent") or {}
    acc, prop = it.get("accepted"), it.get("proposed")
    p["intent"] = {"accepted": {k: acc.get(k) for k in ("outcome", "done_when", "exclusions")} if isinstance(acc, dict) else None,
                   "proposed": {k: prop.get(k) for k in ("outcome", "done_when")} if isinstance(prop, dict) else None}
    # 15.1: the repair queue, RESERVED like intent (never trimmed, part of every size measurement): the first 12 completion refs the
    # script found lost (criteria before parts, by id), ref cut to 60 bytes, and how many more wait for a later batch
    ev = snap.get("evidence") or {}
    p["repairs"] = {"lost": [{"id": e["id"], "ref": C.trim(e["ref"], 60), "why": e["why"]} for e in VAL.repairs_listed(ev)],
                    "more": max(0, len(ev.get("lost") or []) - VAL.REPAIRS_MAX)}
    # 15.2/15.3: the staged drift record, RESERVED and small: what the model needs to know before it may raise a drift decision
    dr = it.get("drift") if isinstance(acc, dict) else None
    p["drift"] = {"streak": dr["streak"], "new_work": C.drift_new_work(dr, (snap.get("key") or {}).get("heads"), (snap.get("since") or {}).get("commits", 0)),
                  "acknowledged": [], "revise_requested": dr["revise_requested"],   # K1: filled below from the pack as it stands
                  "open": any(isinstance(d, dict) and d.get("about") == "drift" and d.get("status") in VAL.OPEN_ST for d in snap.get("decisions") or [])
                  } if isinstance(dr, dict) else None
    p.update({k: snap[k] for k in ("repos", "commits", "status", "watch", "ledger", "answers", "decisions", "usage", "watch_dropped",
                                   "dirty_paths", "template_hash")})
    p["dirty_dirs"] = snap.get("dirty_dirs") or []   # a snapshot staged before 3.6.1 has none: its unlisted files count as not seen
    p = C.loads(C.dumps(p))   # deep copy
    if isinstance(p.get("usage"), dict):   # 3.6.1: totals only; the per-model and per-job detail is page material, never the model's
        p["usage"] = {k: v for k, v in p["usage"].items() if k not in ("by_model", "jobs")}
    p["schema"] = "project-map-pack-1"
    p["rev"] = PACK_REV
    p["generation"] = inv_name
    p["key_digest"] = C.digest(snap["key"])
    p["prev_key_digest"] = C.digest(snap["prev_key"]) if snap.get("prev_key") else None
    p["answers"].pop("applied_hash", None)
    p["answers"].pop("total_hash", None)
    p["answers"].pop("tail", None)
    for d in p["decisions"]:   # the script's verdict on each decision's resolves_when (the model never has to guess)
        if isinstance(d, dict):
            d.pop("intent_hash", None)   # drift decisions: script-owned fields the model neither needs nor may write
            d.pop("observations", None)
        if isinstance(d, dict) and d.get("status") in ("open", "overdue") and d.get("resolves_when"):
            try:
                ok, _ev, _unmet, why = VAL.evaluate_resolves_when_ex(snap["root"], snap, d["resolves_when"])
                d["resolved"] = bool(ok)
                if why:   # a predicate that could not be established says so: unknown is not the same as "not yet"
                    d["resolved_why"] = C.trim("; ".join(why), 100)
            except Exception:   # noqa: BLE001 - an evaluation that cannot run is "not resolved"
                d["resolved"] = False
        if isinstance(d, dict) and isinstance(d.get("resolves_when"), list):
            # the identity of a named tag belongs to the script's predicates (snapshot, state); the model sees and copies
            # only the public fields, so a verbatim copy of a carried predicate is the predicate it was raised with
            d["resolves_when"] = VAL.strip_tids(d["resolves_when"])
    for r in p["repos"]:
        r.pop("recent_files", None)
        rl = r.get("release")
        if isinstance(rl, dict):
            r["release_line"] = rl.get("line", "")
            rl.pop("line", None)
            rl.pop("key", None)
            for ht in rl.get("head_tags") or []:
                if isinstance(ht, dict):
                    ht.pop("tid", None)   # an identity for the script's predicates; the model names a tag by what it sees
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

    def fold_dirty():   # every listed changed file joins its folder count: nothing is lost at folder level, so this is no cut
        cnt = {r["dir"]: r["n"] for r in p["dirty_dirs"]}
        p["dirty_dirs"] = dirty_dirs(p["dirty_paths"], cnt)
        p["dirty_paths"] = []

    def cut_recent():
        for r in p["repos"]:
            if isinstance(r.get("release"), dict) and r["release"].get("recent_tags"):
                r["release"]["recent_tags"] = []
                r["release"]["recent_trimmed"] = True

    def cut_release():   # detail goes before the script-owned line does: the line stays in every later step
        for r in p["repos"]:
            if isinstance(r.get("release"), dict):
                r["release"] = {"head_tags_total": r["release"].get("head_tags_total"), "trimmed": True}

    steps = [cut_recent, cut_watch, fold_dirty, cut_notes, cut_decisions, cut_ledger, drop_answers,
             lambda: cut_items(5), lambda: cut_items(2), lambda: cut_items(1), lambda: cut_items(0),
             lambda: p["watch"].__setitem__(slice(40, None), []),
             lambda: p["repos"].__setitem__(slice(8, None), []), lambda: p.update(watch_dropped=p["watch_dropped"][:5]),
             lambda: p["commits"].update(days=p["commits"]["days"][:3]),
             lambda: p["decisions"].__setitem__(slice(6, None), []),
             lambda: p.update(dirty_paths=[], dirty_dirs=[], watch=[], watch_dropped=[], ledger=None),
             cut_release,
             lambda: p["answers"].update(pending=[], bad=[]),
             lambda: p["commits"].update(days=[]),
             lambda: p.update(decisions=[dict({"id": d.get("id"), "status": d.get("status")},
                                                           **({"resolved": d["resolved"]} if "resolved" in d else {})) for d in p["decisions"]]),
             lambda: p.update(repos=[{"path": r.get("path"), "vcs": r.get("vcs"), "head": r.get("head"),
                                                    "release_line": r.get("release_line")} for r in p["repos"][:4]])]
    # `seen` (13.3) describes the pack the model will actually read, so it is computed from the FINAL pack object and then
    # counted in the size check: after every step the pack is measured WITH its current `seen`; if that is over the cap the
    # next trim step runs and `seen` is recomputed from the new state. `seen` is small and never trimmed itself.
    n_steps = 0
    while True:
        p["seen"] = compute_seen(snap, p)
        if isinstance(p.get("drift"), dict):   # K1: the acknowledged refs the pack still lists; recomputed after every trim, counted in every measurement
            p["drift"]["acknowledged"] = VAL.acknowledged_refs(snap, p)
        if size() <= PACK_MAX:
            break
        if n_steps >= len(steps):
            raise PackOverflow("pack over 8 KB")
        steps[n_steps]()
        n_steps += 1
    return p


SEEN_KEYS = ("commits", "commits_total", "dirty", "dirty_total", "decisions_cut", "answers_dropped", "ledger_cut", "repos_cut",
             "watch_moved", "watch_moved_cut")


def watch_moved_paths(snap):
    """Watched paths whose hash moved against the judged key (see pm_validate.watch_moved_paths)."""
    return VAL.watch_moved_paths(snap)


def compute_seen(snap, p):
    """What the model can see of the staged snapshot (13.3), measured on the pack object `p` itself, after every trim step
    that has run. Hash-only cuts, recent tags and usage detail are not omissions of relevant work."""
    days = (p.get("commits") or {}).get("days") or []
    shown = sum(len(d.get("items") or []) for d in days if isinstance(d, dict))
    pdec = {d.get("id"): d for d in (p.get("decisions") or []) if isinstance(d, dict)}
    dec_cut = 0
    lab = lambda dd: [o.get("label") for o in (dd.get("options") or []) if isinstance(o, dict)]
    for d in snap.get("decisions") or []:
        x = pdec.get(d.get("id"))
        if x is None or x.get("q") != d.get("q") or lab(x) != lab(d):
            dec_cut += 1   # a decision the pack lost, or whose question or option text was cut
    led, pled = snap.get("ledger"), p.get("ledger")
    ledger_cut = bool(led) and (not pled or any(pled.get(k) != led.get(k) for k in ("goal", "now", "next", "blockers")))
    listed = {w["path"] if isinstance(w, dict) else w for w in (p.get("watch") or [])}
    moved = watch_moved_paths(snap)
    return {"commits": shown, "commits_total": (snap.get("commits") or {}).get("count", 0),
            # 3.6.1: a changed file is seen when the pack lists it or counts it under its folder (dirty_dirs)
            "dirty": min(len(p.get("dirty_paths") or []) + sum(r.get("n", 0) for r in p.get("dirty_dirs") or [] if isinstance(r, dict)),
                         (snap.get("status") or {}).get("dirty", 0)),
            "dirty_total": (snap.get("status") or {}).get("dirty", 0),
            "decisions_cut": dec_cut,
            "answers_dropped": max(0, len((snap.get("answers") or {}).get("pending") or []) - len((p.get("answers") or {}).get("pending") or [])),
            "ledger_cut": ledger_cut, "repos_cut": max(0, len(snap.get("repos") or []) - len(p.get("repos") or [])),
            "watch_moved": len(moved), "watch_moved_cut": sum(1 for q in moved if q not in listed)}


def valid_seen(x):
    """A `seen` record as stored in a pack (shape check for embed, which reads it back from STAGE/pack.json)."""
    return isinstance(x, dict) and set(x) == set(SEEN_KEYS) \
        and all(isinstance(x[k], bool) if k == "ledger_cut" else (isinstance(x[k], int) and not isinstance(x[k], bool) and x[k] >= 0)
                for k in SEEN_KEYS)
