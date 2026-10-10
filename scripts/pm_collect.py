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


def read_answers(pm):
    """The complete lines of answers.jsonl (see read_answers_ex)."""
    return read_answers_ex(pm)[0]


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


def apply_answers(by_id, pending):
    """Apply owner answers (in file order, the last one per decision wins) to by_id's open/overdue decisions in place.
    -> list of bad {line, why}."""
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
    return bad


def lifecycle(prev_decs, pending, t):
    """Apply answers and expiries to a copy of the previous OPEN/OVERDUE decisions (closed ones are dropped here)."""
    by_id = {d["id"]: dict(d) for d in prev_decs if d.get("status") in ("open", "overdue")}
    bad = apply_answers(by_id, pending)
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
    alone) and the owner's answer wins: -> {decisions, answers, won}, the staged view with those decisions answered and
    answers.applied advanced past the new lines. Raises AnswersRewritten when the staged prefix no longer matches.
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
    bad += apply_answers(by_id, pending)
    won = sorted(i for i in ids if (by_id.get(i) or {}).get("status") == "answered")
    if not won:
        return None
    ph = prefix_hash(lines, len(lines))
    return {"decisions": [by_id[d["id"]] if (by_id.get(d["id"]) or {}).get("status") == "answered" else d for d in snap["decisions"]],
            "answers": dict(a, total=len(lines), applied=len(lines), applied_hash=ph, total_hash=ph, pending=[],
                            bad=list(a["bad"]) + bad),
            "won": won}


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
def collect(root, prev, hash_deadline, cache, git_timeout=20.0, want_usage=False, usage_timeout=60.0, usage_until=None, usage_prev=None):
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
    rel_cache = {}
    for rp in ["."] + nested:
        ph = heads_prev.get(rp)
        info, cnt, sig, dp, cm = collect_repo(root, rp, ph if isinstance(ph, str) and re.match(r"^[0-9a-f]{7,40}$", ph or "") else None, watch, git_timeout, rel_cache)
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

    lines, tail = read_answers_ex(pm)
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
           "status_hash": sh.hexdigest()[:12],
           "release": {r["path"]: r["release"]["key"] for r in repos if r.get("release")},
           "watch_hashes": {w["path"]: w["hash"] for w in wl},
           "ledger_hash": ledger["hash"] if ledger else None, "answers_count": len(lines), "expired_ids": expired,
           "schema": C.SCHEMA_STATE}
    usage = None
    if want_usage:   # usage_until (absolute time.monotonic()) is evaluated NOW, after the git and hashing work above
        ut = usage_timeout if usage_until is None else min(usage_timeout, usage_until - time.monotonic())
        usage = collect_usage(root, max(ut, 0.0), usage_prev)
    snap = {
        "schema": "project-map-snapshot-1", "generation": None, "base": prev["gen"], "root": root, "facts_at": C.iso(t),
        "repos": repos, "commits": group_commits(commits, total_count),
        "status": {"hash": key["status_hash"], "dirty": len(dirty), "coverage": "partial" if partial else "complete",
                   "covered": covered, "total": total, "git_error": None},
        "dirty_paths": dirty[:20], "watch": wl, "watch_dropped": dropped, "ledger": ledger,
        "answers": {"total": len(lines), "applied": ap, "applied_hash": ah, "total_hash": prefix_hash(lines, len(lines)),
                    "pending": pending, "bad": bad, "tail": tail},
        "decisions": decs, "usage": usage, "key": key, "prev_key": prev.get("judged_key"),
        "template_hash": th, "embed_hash": eh,
    }
    return snap


def compare_keys(judged, key, snap):
    """judged vs fresh key -> {'moved': [names], 'git': bool, 'adopt': [paths], 'why': text, 'incomplete': [paths]}.
    'incomplete' = repositories whose fresh tag listing is partial, 'unverified' = repositories whose tags/sync read kept moving
    (exhausted re-reads): script-owned coverage warnings, independent of 'moved'."""
    if not isinstance(judged, dict):
        return {"moved": ["heads"], "git": True, "adopt": [], "why": "no judged key", "incomplete": [], "unverified": []}
    moved, adopt = [], []
    for k in ("heads", "branches", "status_hash", "ledger_hash", "answers_count", "expired_ids", "schema"):
        if key.get(k) != judged.get(k) and (k in judged or k in ("heads",)):
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
    if "answers_count" in moved:
        why.append("%d pending answers" % max(len(snap["answers"]["pending"]), 1))
    if deferred_moved:
        moved.append("closure_deferred")
        if "answers_count" not in moved[:-1]:
            why.append("answers pending: closure of %s was deferred past an uncommitted answer tail" % ", ".join(deferred_moved))
    if "expired_ids" in moved:
        why.append("deadline passed: " + ", ".join(snap["key"]["expired_ids"] or judged.get("expired_ids", [])))
    if "schema" in moved:
        why.append("schema")
    return {"moved": moved, "git": any(m in GIT_KEYS for m in moved), "adopt": adopt, "why": "; ".join(why),
            "incomplete": incomplete, "unverified": unverified}


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
    p["answers"].pop("tail", None)
    for d in p["decisions"]:   # the script's verdict on each decision's resolves_when (the model never has to guess)
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

    def cut_usage():
        if p.get("usage"):
            p["usage"] = {k: v for k, v in p["usage"].items() if k not in ("by_model", "jobs")}
            tr["usage"] = True

    def cut_recent():
        for r in p["repos"]:
            if isinstance(r.get("release"), dict) and r["release"].get("recent_tags"):
                r["release"]["recent_tags"] = []
                r["release"]["recent_trimmed"] = True

    def cut_release():   # detail goes before the script-owned line does: the line stays in every later step
        for r in p["repos"]:
            if isinstance(r.get("release"), dict):
                r["release"] = {"head_tags_total": r["release"].get("head_tags_total"), "trimmed": True}

    steps = [cut_recent, lambda: cut_items(5), lambda: cut_items(2), lambda: cut_items(1), lambda: cut_items(0), cut_watch,
             cut_ledger, cut_notes, drop_answers, cut_decisions, cut_usage,
             lambda: p.update(dirty_paths=[]), lambda: p["watch"].__setitem__(slice(40, None), []),
             lambda: p["repos"].__setitem__(slice(8, None), []), lambda: p.update(watch_dropped=p["watch_dropped"][:5]),
             lambda: p["commits"].update(days=p["commits"]["days"][:3]),
             lambda: p["decisions"].__setitem__(slice(6, None), []),
             lambda: p.update(dirty_paths=[], watch=[], watch_dropped=[], ledger=None),
             cut_release,
             lambda: p["answers"].update(pending=[], bad=[]),
             lambda: p["commits"].update(days=[]),
             lambda: p.update(decisions=[dict({"id": d.get("id"), "status": d.get("status")},
                                                           **({"resolved": d["resolved"]} if "resolved" in d else {})) for d in p["decisions"]]),
             lambda: p.update(repos=[{"path": r.get("path"), "vcs": r.get("vcs"), "head": r.get("head"),
                                                    "release_line": r.get("release_line")} for r in p["repos"][:4]])]
    for s in steps:
        if size() <= PACK_MAX:
            break
        s()
    if size() > PACK_MAX:
        raise PackOverflow("pack over 8 KB")
    return p
