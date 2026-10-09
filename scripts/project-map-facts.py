#!/usr/bin/env python3
"""project-map-facts.py ROOT [--json] [--budget S] | --close-session ROOT | --accept-answers ROOT

Fact collector and verdict for the project map (INTERFACES-3.2 sections 1, 2, 6.1, 6.2, 6.7).
Stdout is exactly one line (with --json: one JSON object):

    NO_CHANGE <note> | NEEDS_REFRESH <why> | NEEDS_JUDGEMENT <why> inv <id> | NEEDS_FULL <why> inv <id>
    | REFRESH_FAILED <why> (exit 3) | ERROR <why> (exit 2)

Notes. NEEDS_JUDGEMENT may be preceded by ONE mechanical re-render (a new generation that only stamps the page stale, so the
brief can say how far behind it is); the staging dir is created after it and bases on the new current. --budget bounds the whole
run and --deadline (embed) is checked between steps, never inside a render that is already stalled.

It writes only under ROOT/.project-map/: staging dirs (inv-<id>), cache.json, repaired stable symlinks and the sweep of
abandoned dirs. A mechanical re-render (NEEDS_REFRESH) is delegated to project-map-embed.py --mechanical.
"""
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

import pm_common as C      # noqa: E402
import pm_collect as K     # noqa: E402

EMBED_PY = os.path.join(HERE, "project-map-embed.py")
HOUR = 3600.0


class Out(Exception):
    def __init__(self, line, rc):
        Exception.__init__(self, line)
        self.line, self.rc = line, rc


def err(why):
    return Out("ERROR " + why, 2)


# ---------------------------------------------------------------- consistency of a published generation
def consistency(pm, gen):
    """None when every file of the pinned generation carries the same stamp, else a short reason."""
    gdir = os.path.join(pm, C.gen_dir_name(gen))
    if not C.is_complete(gdir):
        return "generation incomplete"
    man = C.read_manifest(gdir)
    if man.get("generation") != gen:
        return "manifest stamp"
    if not C.verify_generation(gdir):
        return "generation unverified"
    for name in ("state.json", "snapshot.json", "pack.json", "plan.json", "judgement.json"):
        o = C.load_json(os.path.join(gdir, name))
        if not isinstance(o, dict) or o.get("generation") != gen:
            return "%s stamp" % name
    for name in ("index.html", "mobile.html"):
        b = C.read_pinned(pm, gen, name)
        m = re.search(rb'<meta name="pm-generation" content="([^"]*)"', b or b"")
        if not m or m.group(1).decode("ascii", "replace") != gen:
            return "%s stamp" % name
    b = (C.read_pinned(pm, gen, "brief.txt") or b"").decode("utf-8", "replace").rstrip("\n").split("\n")
    if b[-1:] != ["generation " + gen]:
        return "brief.txt stamp"
    return None


# ---------------------------------------------------------------- repair / sweep (under the publish lock)
def repair_links(pm, gen):
    """The four stable symlinks must point at current/<name>. Returns True when something was repaired."""
    fixed = False
    for n in C.STABLE:
        want = "current/" + n
        p = os.path.join(pm, n)
        try:
            ok = os.readlink(p) == want
        except OSError:
            ok = False
        if not ok:
            C.symlink_replace(p, want)
            fixed = True
    return fixed


def bind_refs(root):
    """-> (active_inv_names, terminal_inv_names) from CLAUDE_PLUGIN_DATA/bind for this ROOT."""
    active, terminal = set(), set()
    data = os.environ.get("CLAUDE_PLUGIN_DATA")
    base = os.path.join(data, "bind") if data else None
    try:
        sessions = os.listdir(base) if base else []
    except OSError:
        sessions = []
    for s in sessions:
        d = os.path.join(base, s)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            if not (f == "pending" or f.endswith(".json")):
                continue
            o = C.load_json(os.path.join(d, f))
            if not (isinstance(o, dict) and isinstance(o.get("inv"), str) and isinstance(o.get("root"), str)):
                continue
            if os.path.realpath(o["root"]) != root:
                continue
            inv = o["inv"] if o["inv"].startswith("inv-") else "inv-" + o["inv"]
            (terminal if f.endswith(".done.json") else active).add(inv)
    return active, terminal


def sweep(pm, root, keep=()):
    cur = C.current_gen(pm)
    keepdirs = {C.gen_dir_name(cur)} if cur else set()
    for seq, name in C.list_gen_dirs(pm):
        p = os.path.join(pm, name)
        if name in keepdirs or not os.path.isdir(p) or os.path.islink(p):
            continue
        if name.endswith(".tmp") or not C.is_complete(p):
            shutil.rmtree(p, ignore_errors=True)
    for n in ("current.tmp",) + tuple(x + ".tmp" for x in C.STABLE):
        p = os.path.join(pm, n)
        if os.path.islink(p) or os.path.isfile(p):
            try:
                os.remove(p)
            except OSError:
                pass
    if cur:   # a migration killed after the pointer rename leaves the 3.x files behind; legacy/ already holds copies
        for n in ("judgement.json", "facts.json"):
            p = os.path.join(pm, n)
            if os.path.isfile(p) and not os.path.islink(p) and os.path.exists(os.path.join(pm, C.gen_dir_name(cur), "legacy", n)):
                try:
                    os.remove(p)
                except OSError:
                    pass
    active, terminal = bind_refs(root)
    now = time.time()
    leftovers(pm)
    for n in os.listdir(pm):
        p = os.path.join(pm, n)
        if C.INV_RE.match(n) and os.path.isdir(p) and not os.path.islink(p) and n not in keep and n not in active:
            inv = C.load_json(os.path.join(p, "invocation.json"), {}) or {}
            ct = C.parse_iso(inv.get("created_at")) if isinstance(inv, dict) else None
            age = now - (ct.timestamp() if ct else os.path.getmtime(p))
            if n in terminal or os.path.exists(os.path.join(p, "released")) or age > 24 * HOUR:
                shutil.rmtree(p, ignore_errors=True)
        elif re.match(r"^\..*\.tmp[.\d]", n) and os.path.isfile(p) and now - os.path.getmtime(p) > 600:
            try:
                os.remove(p)
            except OSError:
                pass
    prune_generations(pm, cur)


PID_FILE = re.compile(r"\.(?:in|tmp)\.(\d+)(?:\.|$)")


def pid_dead(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    return False


def leftovers(pm):
    """Staging / tmp files named .in.<pid> or .tmp.<pid>[.x] whose process is gone (PM and every inv-* dir)."""
    dirs = [pm] + [os.path.join(pm, n) for n in os.listdir(pm) if C.INV_RE.match(n) and os.path.isdir(os.path.join(pm, n))]
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            m = PID_FILE.search(n)
            p = os.path.join(d, n)
            if m and os.path.isfile(p) and not os.path.islink(p) and pid_dead(int(m.group(1))):
                try:
                    os.remove(p)
                except OSError:
                    pass


KEEP_GENS = 10


def prune_generations(pm, cur):
    """Keep the newest KEEP_GENS complete generations, the current one, and any generation a remaining staging dir
    names as its base; delete the rest (their invocation/ copies go with them). Caller holds the publish lock."""
    keep = {cur} if cur else set()
    for n in os.listdir(pm):
        if C.INV_RE.match(n):
            inv = C.load_json(os.path.join(pm, n, "invocation.json"), {})
            if isinstance(inv, dict) and isinstance(inv.get("base"), str):
                keep.add(inv["base"])
    gens = [(seq, n) for seq, n in C.list_gen_dirs(pm) if not n.endswith(".tmp")]
    for seq, n in gens[-KEEP_GENS:]:
        keep.add(n[4:])
    for seq, n in gens:
        if n[4:] not in keep and os.path.isdir(os.path.join(pm, n)) and not os.path.islink(os.path.join(pm, n)):
            shutil.rmtree(os.path.join(pm, n), ignore_errors=True)


def locked(pm, fn):
    """Run fn() under the publish lock; a busy lock skips it (returns None)."""
    if not os.path.isdir(pm):
        return None
    try:
        with C.PMLock(pm):
            return fn()
    except C.Busy:
        return None


# ---------------------------------------------------------------- staging
def derive_plan(J, name):
    """Plan input for a migration FULL run, from the 3.x milestone list."""
    ms = J.get("milestone") if isinstance(J, dict) and isinstance(J.get("milestone"), dict) else {}
    lst = [m for m in ms.get("list", []) if isinstance(m, dict)][:7]
    phases = [{"id": "P%d" % (i + 1), "label": C.trim(str(m.get("label", m.get("id", "phase"))), 60), "criteria": []} for i, m in enumerate(lst)]
    cur = next((i for i, m in enumerate(lst) if m.get("id") == ms.get("current")), 0)
    if phases:
        for j, c in enumerate([c for c in ms.get("criteria", []) if isinstance(c, dict)][:8]):
            ref = c.get("ref") if isinstance(c.get("ref"), str) and c["ref"].startswith(("file:", "commit:")) else None
            phases[cur]["criteria"].append({"id": "P%d.c%d" % (cur + 1, j + 1), "text": C.trim(str(c.get("text", "")), 80),
                                            "done": bool(c.get("done")) and bool(ref), "ref": ref})
    return {"schema": C.SCHEMA_PLAN, "generation": name, "origin": "proposed", "phases": phases}


def make_staging(pm, root, prev, snap):
    os.makedirs(pm, exist_ok=True)
    for _ in range(50):
        iid = C.new_id8()
        name = "inv-" + iid
        try:
            os.mkdir(os.path.join(pm, name))
            break
        except FileExistsError:
            continue
    else:
        raise err("could not allocate a staging id")
    d = os.path.join(pm, name)
    snap = dict(snap, generation=name)
    if prev["kind"] == "v4":
        plan = dict(prev["plan"], generation=name)
        jin = prev["judgement"]
    elif prev["kind"] == "legacy":
        plan = derive_plan(prev["judgement"], name)
        jin = prev["judgement"]
    else:
        plan = {"schema": C.SCHEMA_PLAN, "generation": name, "origin": "proposed", "phases": []}
        jin = {}
    inv = {"id": iid, "created_at": C.iso(), "base": prev["gen"], "root": root,
           "session_id": os.environ.get("CLAUDE_SESSION_ID") or None}
    try:
        for fn, obj, ind in (("snapshot.json", snap, 1), ("pack.json", K.build_pack(snap, name), None), ("plan.json", plan, 1),
                             ("judgement.in.json", jin, 1), ("invocation.json", inv, 1)):
            C.write_file(os.path.join(d, fn), C.dumps(obj, indent=ind))
    except K.PackOverflow:
        shutil.rmtree(d, ignore_errors=True)
        raise err("pack over 8 KB")
    C.fsync_dir(d)
    return iid


# ---------------------------------------------------------------- mechanical re-render
def mechanical(root, dl=8.0):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        r = subprocess.run([sys.executable, EMBED_PY, root, "--mechanical", "--deadline", "%.2f" % dl], capture_output=True,
                           text=True, timeout=dl + 10, env=env)
    except Exception as ex:   # noqa: BLE001
        return False, type(ex).__name__
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    if r.returncode == 0 and any(ln.startswith("PM_EMBED_OK") for ln in lines):
        return True, ""
    bad = next((ln for ln in lines if ln.startswith(("PM_EMBED_ERROR", "SUPERSEDED"))), "no output")
    return False, C.trim(bad.replace("PM_EMBED_ERROR ", ""), 120)


# ---------------------------------------------------------------- cache
def cache_load(pm):
    c = C.load_json(os.path.join(pm, "cache.json"), {})
    return c if isinstance(c, dict) else {}


def cache_save(pm, cache):
    """Persist watch_cache + coverage_cursor, preserving every other key (ack_hashes belong to the hooks)."""
    if not os.path.isdir(pm):
        return

    def go():
        cur = cache_load(pm)
        for k in ("watch_cache", "coverage_cursor"):
            if k in cache:
                cur[k] = cache[k]
        C.atomic_write(os.path.join(pm, "cache.json"), C.dumps(cur))
    try:
        locked(pm, go)
    except OSError:
        pass


# ---------------------------------------------------------------- the decision
def decide(root, pm, prev, snap):
    """-> (verdict, why). verdict in NEEDS_FULL | NEEDS_JUDGEMENT | NEEDS_REFRESH | NO_CHANGE."""
    if prev["kind"] == "none":
        return "NEEDS_FULL", "first map"
    if prev["kind"] == "legacy":
        return "NEEDS_FULL", "migrate"
    if prev["kind"] == "invalid":
        return "NEEDS_FULL", prev["why"] or "invalid state"
    S = prev["state"]
    cmp = K.compare_keys(prev["judged_key"], snap["key"], snap)
    st = snap["status"]
    partial = st["coverage"] == "partial"
    if partial:
        if cmp["git"]:
            return "NEEDS_JUDGEMENT", cmp["why"]
        return "NEEDS_REFRESH", "coverage partial %d/%d" % (st["covered"], st["total"])
    if cmp["moved"]:
        return "NEEDS_JUDGEMENT", cmp["why"]
    if prev.get("unverified"):
        return "NEEDS_REFRESH", "generation unverified"
    bad = consistency(pm, prev["gen"])
    if bad:
        return "NEEDS_REFRESH", "generation mismatch"
    if cmp["adopt"] or S["coverage"].get("coverage") == "partial":
        return "NEEDS_REFRESH", "coverage complete"
    if S["template_hash"] != snap["template_hash"] or S["embed_hash"] != snap["embed_hash"]:
        return "NEEDS_REFRESH", "plugin files changed"
    if S.get("stale"):
        return "NEEDS_REFRESH", "stale cleared"
    at = C.parse_iso(S["identity"].get("snapshot_at"))
    if at is None or (C.now() - at).total_seconds() >= HOUR:
        return "NEEDS_REFRESH", "map older than 1 h"
    return "NO_CHANGE", "nothing moved"


def run_facts(root, budget, as_json, stage=True):
    t0 = time.monotonic()
    if not os.path.isdir(root):
        raise err("unreadable root")
    if root == C.home():
        raise err("unsupported location ($HOME)")
    if re.search(r"[\s\[\]]", root):
        raise err("unsupported location (space or bracket in path)")
    pm = os.path.join(root, ".project-map")
    if os.path.islink(pm):
        raise err(".project-map is a symlink")
    if os.path.exists(pm) and not os.path.isdir(pm):
        raise err(".project-map is not a directory")
    if os.path.isdir(pm):
        locked(pm, lambda: sweep(pm, root))
    prev = K.load_prev(pm)
    if prev["kind"] == "v4":
        locked(pm, lambda: repair_links(pm, prev["gen"]))
    cache = cache_load(pm)
    hd = t0 + (budget * 0.6 if budget else 30.0)
    if prev["kind"] == "v4" and prev["state"]["coverage"].get("coverage") == "partial" and (not budget or budget >= 1):
        hd += 2.0
    gt = 5.0 if budget else 20.0
    K.set_budget(t0 + budget if budget else None)
    try:
        snap = K.collect(root, prev, hd, cache, git_timeout=gt)
    except K.BudgetOut:   # the best verdict available without the facts
        if prev["kind"] == "v4":
            return "NEEDS_REFRESH facts incomplete (deferred: budget)", None, None
        why = {"none": "first map", "legacy": "migrate"}.get(prev["kind"], prev.get("why") or "invalid state")
        return "NEEDS_FULL %s (deferred: budget)" % why, None, None
    except K.GitCollectError as ex:
        raise err("git_error: %s" % ex)
    except K.PackOverflow:
        raise err("pack over 8 KB")
    except K.AnswersRewritten:
        me = os.path.join(HERE, "project-map-facts.py")
        raise err("answers rewritten; run: python3 %s --accept-answers %s" % (me, root))
    if os.environ.get("PM_FACTS_DELAY_AFTER"):   # test hook: a slow collection must not break --budget
        time.sleep(float(os.environ["PM_FACTS_DELAY_AFTER"]))
    rem = (budget - (time.monotonic() - t0)) if budget else float("inf")   # --budget bounds the WHOLE run
    can_refresh = rem >= 1.0
    mdl = min(8.0, rem)
    verdict, why = decide(root, pm, prev, snap)
    inv = None
    if verdict == "NEEDS_REFRESH":
        if not can_refresh:   # out of budget: the best verdict without the refresh
            why += " (deferred: budget)"
        else:
            ok, e = mechanical(root, mdl)
            if not ok:
                raise Out("REFRESH_FAILED " + (e or "unknown"), 3)
    elif verdict in ("NEEDS_JUDGEMENT", "NEEDS_FULL"):
        if verdict == "NEEDS_JUDGEMENT":   # flag the page stale first: the brief must say how far behind it is
            want = {"judged_at": prev["state"].get("judged_at"), "commits_since": snap["commits"]["count"], "why": why}
            if prev["state"].get("stale") != want and can_refresh:
                ok, _e = mechanical(root, mdl)
                if ok:
                    prev = K.load_prev(pm)
                    if prev["kind"] != "v4":
                        raise err("map unreadable after refresh")
        if stage:
            snap["usage"] = K.collect_usage(root, min(60.0, rem)) if can_refresh else None
            inv = make_staging(pm, root, prev, snap)
    cache_save(pm, cache)
    line = "%s %s" % (verdict, why)
    if inv:
        line += " inv %s" % inv
    return line, inv, snap


def accept_answers(root):
    pm = os.path.join(root, ".project-map")
    prev = K.load_prev(pm) if os.path.isdir(pm) else {"kind": "none"}
    if prev["kind"] != "v4":
        raise err("no published map to re-baseline")
    cache = cache_load(pm)
    cache["answers_accept"] = {"gen": prev["gen"], "applied": 0, "applied_hash": C.sha256_bytes(b""), "at": C.iso()}

    def go():
        cur = cache_load(pm)
        cur["answers_accept"] = cache["answers_accept"]
        C.atomic_write(os.path.join(pm, "cache.json"), C.dumps(cur))
        return True
    if not locked(pm, go):
        raise err("another process holds the lock, retry")
    return "ACCEPTED answers re-baselined for generation %s; run /project-map" % prev["gen"]


def main(argv):
    args = argv[1:]
    as_json, budget, root, mode, stage = False, None, None, "run", True
    i = 0
    try:
        while i < len(args):
            a = args[i]
            if a == "--json":
                as_json = True
            elif a == "--no-stage":
                stage = False
            elif a == "--budget":
                budget = float(args[i + 1])
                i += 1
                if not 0 < budget < 3600:
                    raise ValueError
            elif a in ("--close-session", "--accept-answers"):
                mode = a
                root = args[i + 1]
                i += 1
            elif a.startswith("--") or root is not None:
                raise ValueError
            else:
                root = a
            i += 1
        if root is None or not os.path.isabs(root):
            raise ValueError
    except (ValueError, IndexError):
        print("usage: project-map-facts.py ABS_ROOT [--json] [--budget S] [--no-stage] | --close-session ROOT | --accept-answers ROOT", file=sys.stderr)
        return 2
    root = os.path.realpath(root).rstrip("/")
    try:
        if mode == "--close-session":
            line, rc, inv, snap = "CLOSE_SESSION recorded by the guard; start a new Claude Code session to run the map again", 0, None, None
        elif mode == "--accept-answers":
            line, rc, inv, snap = accept_answers(root), 0, None, None
        else:
            line, inv, snap = run_facts(root, budget, as_json, stage)
            rc = 0
    except Out as o:
        line, rc, inv, snap = o.line, o.rc, None, None
    except Exception as ex:   # noqa: BLE001 - nothing may escape as a traceback with a zero exit
        line, rc, inv, snap = "ERROR internal: %s: %s" % (type(ex).__name__, str(ex)[:120]), 2, None, None
    if as_json:
        print(C.dumps({"verdict": line, "exit": rc, "inv": inv, "snapshot": snap}, indent=1))
    else:
        print(line)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
