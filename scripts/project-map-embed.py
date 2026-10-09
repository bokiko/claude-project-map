#!/usr/bin/env python3
"""project-map-embed.py ROOT inv-<id> [--deadline S]   |   ROOT --mechanical [--deadline S]   (entry: project-map-embed.sh)

Publishes one immutable generation (INTERFACES-3.2 section 1.3) and prints exactly one of
    PM_EMBED_OK gen <seq>-<id> <bytes>        exit 0   (an extra PM_EMBED_STALE <why> line when the repo moved meanwhile)
    SUPERSEDED base <b> current <c>           exit 4   (nothing written)
    PM_EMBED_ERROR <why> (one line per reason) exit 1   (nothing replaced)

Normal mode validates STAGE/judgement.out.json (+ plan.out.json on FULL) against STAGE/snapshot.json and merges them with the
carried plan into state.json (schema project-map-4). Mechanical mode (2.1) re-renders the pinned current generation with fresh
mechanical facts only: same judgement, plan and assessment time, no history entry.
Test hook: PM_EMBED_CRASH_AT=tmpdir|files|manifest|gen_rename|pointer|links kills the process (os._exit) after that step.
"""
import copy
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

import pm_common as C        # noqa: E402
import pm_collect as K       # noqa: E402
import pm_git as G           # noqa: E402
import pm_render as R        # noqa: E402
import pm_validate as VAL    # noqa: E402

TEMPLATE = os.path.join(HERE, "project-map-template.html")
STATE_MAX = 65536
PLAN_OUT_MAX = 65536


class EmbedError(Exception):
    def __init__(self, msgs):
        Exception.__init__(self, "; ".join(msgs) if isinstance(msgs, list) else msgs)
        self.msgs = msgs if isinstance(msgs, list) else [msgs]


class Superseded(Exception):
    def __init__(self, base, cur):
        Exception.__init__(self, "superseded")
        self.base, self.cur = base, cur


def crash(stage):
    if os.environ.get("PM_EMBED_CRASH_AT") == stage:
        os._exit(99)


# ---------------------------------------------------------------- publish (1.3)
def publish(pm, make_files, legacy, clock=None):
    """Caller holds the lock and has verified base == current. make_files(genstr) -> {relpath: bytes}.
    Returns the new generation string."""
    seqs = [s for s, _ in C.list_gen_dirs(pm)]
    cur = C.current_gen(pm)
    if cur:
        seqs.append(int(cur[:6]))
    seq = max(seqs + [0]) + 1
    for _ in range(50):
        genstr = "%06d-%s" % (seq, C.new_id8())
        name = C.gen_dir_name(genstr)
        tmpd = os.path.join(pm, name + ".tmp")
        try:
            os.mkdir(tmpd)
            break
        except FileExistsError:
            continue
    else:
        raise EmbedError("could not allocate a generation directory")
    crash("tmpdir")
    try:
        return _publish_into(pm, tmpd, name, genstr, make_files, legacy, clock)
    except BaseException:
        import shutil
        shutil.rmtree(tmpd, ignore_errors=True)   # never reached by a kill (os._exit): the sweep handles that case
        raise


def _publish_into(pm, tmpd, name, genstr, make_files, legacy, clock):
    files = make_files(genstr)
    if clock:
        clock.check()   # the render is over: an expired deadline stops here, nothing replaced
    meta = {}
    for rel in sorted(files):
        p = os.path.join(tmpd, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        data = files[rel]
        C.write_file(p, data)
        meta[rel] = {"size": len(data) if isinstance(data, bytes) else len(data.encode("utf-8", "replace")),
                     "sha256": C.sha256_bytes(data if isinstance(data, bytes) else data.encode("utf-8", "replace"))}
    for dp, dn, fn in os.walk(tmpd):
        C.fsync_dir(dp)
    crash("files")
    base = C.loads(files["state.json"])["base"]
    C.write_file(os.path.join(tmpd, "manifest.json"), C.dumps({"generation": genstr, "base": base, "files": meta,
                                                              "hmac": C.sign_manifest(meta, genstr, base)}, indent=1))
    C.fsync_dir(tmpd)
    crash("manifest")
    final = os.path.join(pm, name)
    if clock:
        clock.check()
    os.rename(tmpd, final)
    C.fsync_dir(pm)
    crash("gen_rename")
    if clock:
        clock.check()   # immediately before the publish switch
    tmpl = os.path.join(pm, "current.tmp")
    try:
        os.remove(tmpl)
    except OSError:
        pass
    os.symlink(name, tmpl)
    os.rename(tmpl, os.path.join(pm, "current"))
    C.fsync_dir(pm)
    crash("pointer")
    for i, n in enumerate(C.STABLE):
        C.symlink_replace(os.path.join(pm, n), "current/" + n)
        if i == 0:
            crash("links")
    if legacy:   # 3.x leftovers: copied into legacy/, removed only after the switch
        for n in ("judgement.json", "facts.json"):
            p = os.path.join(pm, n)
            if os.path.isfile(p) and not os.path.islink(p):
                try:
                    os.remove(p)
                except OSError:
                    pass
    C.fsync_dir(pm)
    C.write_publish_record(os.path.dirname(pm), genstr, final)
    return genstr


def read_legacy_files(pm):
    out = {}
    for n in ("state.json", "judgement.json", "facts.json", "index.html", "mobile.html", "brief.txt"):
        p = os.path.join(pm, n)
        if os.path.isfile(p) and not os.path.islink(p):
            with open(p, "rb") as fh:
                out["legacy/" + n] = fh.read()
    return out


def cache_merge(pm, cache, moved_from=None, moved_to=None):
    """Persist watch_cache + coverage_cursor, keep every other key. An accepted answers re-baseline follows the
    current pointer when a mechanical re-render moves it (moved_from -> moved_to)."""
    cur = C.load_json(os.path.join(pm, "cache.json"), {})
    cur = cur if isinstance(cur, dict) else {}
    try:   # acknowledge the plugin files this publish rendered with (same hashes the prompt hook compares)
        cur["ack_hashes"] = {"template": C.sha256_file(TEMPLATE), "embed": C.sha256_file(os.path.abspath(__file__))}
        cur.pop("ack_attempt_at", None)
    except OSError:
        pass
    for k in ("watch_cache", "coverage_cursor"):
        if k in cache:
            cur[k] = cache[k]
    aa = cur.get("answers_accept")
    if moved_to and isinstance(aa, dict) and aa.get("gen") == moved_from:
        aa["gen"] = moved_to
    try:
        C.atomic_write(os.path.join(pm, "cache.json"), C.dumps(cur))
    except OSError:
        pass


def finish_files(S, snap, plan, judgement, extra, tpl=TEMPLATE):
    """Render everything for generation S["generation"]. -> {relpath: bytes}."""
    gen = S["generation"]
    files = {}
    files["snapshot.json"] = C.dumps(dict(snap, generation=gen, base=S["base"]), indent=1)
    try:
        files["pack.json"] = C.dumps(K.build_pack(dict(snap, generation=gen), gen))   # compact: the 8 KB cap counts file bytes
    except K.PackOverflow:
        raise EmbedError("pack over 8 KB")
    if os.environ.get("PM_EMBED_RENDER_DELAY"):   # test hook: a slow render must still honour --deadline
        time.sleep(float(os.environ["PM_EMBED_RENDER_DELAY"]))
    files["plan.json"] = C.dumps(dict(plan, generation=gen), indent=1)
    files["judgement.json"] = C.dumps(dict(judgement, generation=gen), indent=1)
    for rel, data in extra.items():
        files[rel] = data
    S["generation_files"] = sorted(list(files) + ["state.json", "index.html", "mobile.html", "brief.txt", "manifest.json"])
    blob = C.dumps(S, indent=1)
    if C.blen(blob) > STATE_MAX:
        raise EmbedError("state is %d bytes, over %d" % (C.blen(blob), STATE_MAX))
    files["state.json"] = blob
    try:
        files["index.html"] = R.render_html(S, tpl)
    except R.RenderError as ex:
        raise EmbedError(str(ex))
    files["mobile.html"] = R.render_mobile(S)
    br = R.brief(S)
    if C.blen(br) > R.BRIEF_MAX:
        raise EmbedError("brief over %d bytes" % R.BRIEF_MAX)
    files["brief.txt"] = br
    return files


# ---------------------------------------------------------------- normal mode
def light_stale(root, snap, judged_at):
    n = 0
    for r in snap["repos"]:
        if r.get("vcs") != "git" or not r.get("head"):
            continue
        repo = root if r["path"] == "." else os.path.join(root, r["path"])
        try:
            rc, out = G.run(repo, "rev-parse", "HEAD", timeout=5.0)
            if rc == 0 and out.strip()[:12] != r["head"]:
                rc2, o2 = G.run(repo, "rev-list", "--count", "%s..HEAD" % r["head"], timeout=5.0)
                n += int(o2.strip()) if rc2 == 0 and o2.strip().isdigit() and int(o2.strip()) else 1
        except G.GitArgError:
            continue
    return {"judged_at": judged_at, "commits_since": n, "why": "%d new commits" % n} if n else None


def _read(path, maxb=None):
    try:
        with open(path, "rb") as fh:
            b = fh.read()
    except OSError:
        return None
    return b


def embed_normal(root, inv_name, clock):
    pm = os.path.join(root, ".project-map")
    stage = os.path.join(pm, inv_name)
    if not C.INV_RE.match(inv_name) or not os.path.isdir(stage) or os.path.islink(stage):
        raise EmbedError("staging directory %s not found" % inv_name)
    try:
        lock = C.PMLock(pm).acquire()
    except C.Busy:
        raise EmbedError("another embed is running")
    try:
        cur = C.current_gen(pm)
        inv = C.load_json(os.path.join(stage, "invocation.json"))
        if not isinstance(inv, dict) or inv.get("root") != root or "base" not in inv:
            raise EmbedError("invocation.json is missing or belongs to another project")
        if inv["base"] != cur:
            raise Superseded(inv["base"], cur)
        snap = C.load_json(os.path.join(stage, "snapshot.json"))
        if not isinstance(snap, dict) or snap.get("generation") != inv_name:
            raise EmbedError("snapshot.json is missing or does not belong to %s" % inv_name)
        plan_in = C.load_json(os.path.join(stage, "plan.json"))
        jin = C.load_json(os.path.join(stage, "judgement.in.json"), {})
        raw = _read(os.path.join(stage, "judgement.out.json"))
        if raw is None:
            raise EmbedError("judgement.out.json is missing")
        try:
            J = C.loads(raw)
        except ValueError as ex:
            raise EmbedError("judgement.out.json is not valid JSON: %s" % str(ex)[:80])
        full = isinstance(J, dict) and isinstance(J.get("run"), dict) and J["run"].get("type") == "FULL"
        po_raw = _read(os.path.join(stage, "plan.out.json"))
        plan, v = None, VAL.V()
        if full:
            if po_raw is None:
                raise EmbedError("a FULL run needs plan.out.json")
            if len(po_raw) > PLAN_OUT_MAX:
                raise EmbedError("plan.out.json is %d bytes, hard limit %d" % (len(po_raw), PLAN_OUT_MAX))
            try:
                plan = C.loads(po_raw)
            except ValueError as ex:
                raise EmbedError("plan.out.json is not valid JSON: %s" % str(ex)[:80])
            VAL.validate_plan(v, plan, root, snap.get("repos", []), True)
            if isinstance(plan, dict) and plan.get("generation") != inv_name:
                v.e("plan.out.json generation does not match this invocation")
        else:
            if po_raw is not None:
                raise EmbedError("plan.out.json is only valid for a FULL run")
            plan = plan_in
            if not isinstance(plan, dict) or not plan.get("phases"):
                raise EmbedError("there is no plan yet: a FULL run is required")
            VAL.validate_plan(v, plan, root, snap.get("repos", []), False)
        if v.errs:
            raise EmbedError(v.errs)
        prevp = K.load_prev(pm)
        prev = prevp["state"] if prevp["kind"] == "v4" else None
        pseudo = prev
        if prevp["kind"] == "legacy":
            ls = prevp["state"]
            pseudo = {"retired_ids": prevp["retired"], "decisions": prevp["decisions"],
                      "parts": [p for p in ls.get("parts", []) if isinstance(p, dict) and isinstance(p.get("id"), str)],
                      "history": []}
        ctx = {"root": root, "snap": snap, "plan": plan, "prev": pseudo, "full": full, "inv_name": inv_name}
        errs = VAL.validate_judgement(J, len(raw), ctx)
        if errs:
            raise EmbedError(errs)
        # carry-forward of owner-visible lists the model tends to drop
        kept = []
        pj = jin if isinstance(jin, dict) else {}
        pproj = pj.get("project") if isinstance(pj.get("project"), dict) else {}
        if not J["project"].get("ledger") and isinstance(pproj.get("ledger"), str) and pproj["ledger"]:
            J["project"]["ledger"] = pproj["ledger"]
            kept.append("ledger")
        okp = lambda p: isinstance(p, str) and p and not C.watch_problem(p)
        if "watch" not in J:
            if isinstance(pj.get("watch"), list) and pj["watch"]:
                J["watch"] = [w for w in pj["watch"] if okp(w)][:40]
                kept.append("watch")
            else:
                J["watch"] = [w["path"] for w in snap.get("watch", [])][:40]
        if "repos" not in J:
            if isinstance(pj.get("repos"), list) and pj["repos"]:
                J["repos"] = [r for r in pj["repos"] if okp(r)][:12]
                kept.append("repos")
            else:
                J["repos"] = [r["path"] for r in snap.get("repos", []) if r["path"] != "."][:12]
        final_plan = VAL.apply_updates(plan, J.get("criteria_updates", []))
        clock.check()
        legacy = {}
        if inv["base"] is None and os.path.isfile(os.path.join(pm, "state.json")) and not os.path.islink(os.path.join(pm, "state.json")):
            legacy = read_legacy_files(pm)
        stage_files = {}
        for dp, dn, fn in os.walk(stage):
            for f in fn:
                if f in ("claimed", "released") or f.startswith("shot-"):
                    continue
                full_p = os.path.join(dp, f)
                with open(full_p, "rb") as fh:
                    stage_files["invocation/" + os.path.relpath(full_p, stage)] = fh.read()
        n = (prev["run"]["n"] if prev else (prevp["state"].get("run", {}).get("n", 0) if prevp["kind"] == "legacy" and isinstance(prevp["state"].get("run"), dict) and isinstance(prevp["state"]["run"].get("n"), int) else 0)) + 1
        stale = light_stale(root, snap, snap["facts_at"])
        th, eh = K.plugin_hashes()
        # the judged key must describe the lists the judgement now declares: a path the model added is hashed now,
        # a ledger binding that changed gets its new hash; everything else keeps the hashes of the judged world
        key = copy.deepcopy(snap["key"])
        kept_h = {p: h for p, h in key["watch_hashes"].items() if p in J["watch"]}
        new_paths = [p for p in J["watch"] if p not in kept_h]
        if new_paths:
            wl, _c, _t = K.hash_watch(root, new_paths, {}, time.monotonic() + 20.0)
            kept_h.update({w["path"]: w["hash"] for w in wl})
        key["watch_hashes"] = kept_h
        led, sled = K.parse_ledger(root, J["project"].get("ledger")), snap.get("ledger")
        if not ((led and sled and led["path"] == sled["path"]) or (not led and not sled)):
            key["ledger_hash"] = led["hash"] if led else None
        snap2 = dict(snap, template_hash=th, embed_hash=eh, key=key)
        box = {}

        def make(genstr):
            c = {"root": root, "snap": snap2, "J": J, "plan": final_plan, "prev": pseudo, "genstr": genstr, "base": cur,
                 "kept": kept, "judged_at": snap["facts_at"], "n": n, "stale": stale}
            S = VAL.build_state(c)
            if prevp["kind"] != "v4":
                S["changes"] = []
            box["S"] = S
            extra = dict(stage_files)
            extra.update(legacy)
            return {k: (v_.encode("utf-8", "replace") if isinstance(v_, str) else v_)
                    for k, v_ in finish_files(S, snap2, final_plan, dict(J, invocation=inv_name), extra).items()}

        genstr = publish(pm, make, bool(legacy), clock)
        S = box["S"]
        cache_merge(pm, K_cache(pm))
        return genstr, len(C.read_pinned(pm, genstr, "index.html") or b""), stale
    finally:
        lock.release()


def K_cache(pm):
    c = C.load_json(os.path.join(pm, "cache.json"), {})
    return c if isinstance(c, dict) else {}


# ---------------------------------------------------------------- mechanical mode (2.1)
def embed_mechanical(root, clock):
    pm = os.path.join(root, ".project-map")
    if not os.path.isdir(pm) or os.path.islink(pm):
        raise EmbedError("no .project-map directory")
    try:
        lock = C.PMLock(pm).acquire()
    except C.Busy:
        raise EmbedError("another embed is running")
    try:
        prev = K.load_prev(pm)   # `current` pinned once, here
        if prev["kind"] != "v4":
            raise EmbedError("no valid published map to refresh (%s)" % (prev["why"] or prev["kind"]))
        cur, S0 = prev["gen"], prev["state"]
        clock.check()
        cache = K_cache(pm)
        total = clock.total
        hd = clock.t0 + (total * 0.5 if total else 30.0)
        gt = min(5.0, max(clock.remaining(), 0.5)) if total else 20.0
        K.set_budget(clock.t0 + clock.total if clock.total else None)
        try:
            at0 = C.parse_iso(S0["identity"].get("snapshot_at"))
            want_usage = S0.get("usage") is None or at0 is None or (C.now() - at0).total_seconds() >= 3600   # D7
            snap = K.collect(root, prev, hd, cache, git_timeout=gt, want_usage=want_usage, usage_timeout=clock.remaining(60.0) if total else 60.0)
        except K.GitCollectError as ex:
            raise EmbedError("git_error: %s" % ex)
        except K.AnswersRewritten:
            raise EmbedError("answers rewritten")
        except K.BudgetOut:
            raise C.Deadline("deadline")
        clock.check()
        jk = copy.deepcopy(S0["judged_key"])
        cmp0 = K.compare_keys(jk, snap["key"], snap)
        for p in cmp0["adopt"]:   # a watched path hashed completely for the first time adopts that hash
            jk["watch_hashes"][p] = snap["key"]["watch_hashes"][p]
        cmp = K.compare_keys(jk, snap["key"], snap)
        S = copy.deepcopy(S0)
        th, eh = K.plugin_hashes()
        snap = dict(snap, template_hash=th, embed_hash=eh, prev_key=jk)

        def make(genstr):
            T = copy.deepcopy(S0)
            T["generation"], T["base"] = genstr, cur
            T["identity"]["generation"], T["identity"]["snapshot_at"] = genstr, snap["facts_at"]
            if snap.get("usage") is not None:
                T["usage"] = snap["usage"]
            T["coverage"] = {"coverage": snap["status"]["coverage"], "covered": snap["status"]["covered"], "total": snap["status"]["total"]}
            T["stale"] = ({"judged_at": S0.get("judged_at"), "commits_since": snap["commits"]["count"], "why": cmp["why"]}
                          if cmp["moved"] else None)
            T["template_hash"], T["embed_hash"], T["judged_key"] = th, eh, jk
            plan = C.loads(C.read_pinned(pm, prev["src"], "plan.json") or b"{}")
            J = C.loads(C.read_pinned(pm, prev["src"], "judgement.json") or b"{}")
            return {k: (v_.encode("utf-8", "replace") if isinstance(v_, str) else v_)
                    for k, v_ in finish_files(T, snap, plan, J, {}).items()}

        clock.check()
        if os.environ.get("PM_EMBED_PAUSE_BEFORE_PUBLISH"):   # test hook: lets a test move `current` meanwhile
            time.sleep(float(os.environ["PM_EMBED_PAUSE_BEFORE_PUBLISH"]))
        now_cur = C.current_gen(pm)
        if now_cur != cur:
            raise Superseded(cur, now_cur)
        genstr = publish(pm, make, False, clock)
        cache_merge(pm, cache, cur, genstr)
        return genstr, len(C.read_pinned(pm, genstr, "index.html") or b""), None
    finally:
        lock.release()


# ---------------------------------------------------------------- CLI
def default_root():
    cwd = os.getcwd()
    top = G.toplevel(cwd)
    if cwd == C.home():
        return None
    return cwd if not top or os.path.realpath(top) == C.home() else os.path.realpath(top)


def main(argv):
    args = argv[1:]
    mech, deadline, pos, i = False, None, [], 0
    try:
        while i < len(args):
            a = args[i]
            if a == "--mechanical":
                mech = True
            elif a == "--deadline":
                deadline = float(args[i + 1])
                i += 1
                if not 0 < deadline < 3600:
                    raise ValueError
            elif a.startswith("--"):
                raise ValueError
            else:
                pos.append(a)
            i += 1
        if mech and len(pos) > 1 or (not mech and len(pos) != 2):
            raise ValueError
    except (ValueError, IndexError):
        print("PM_EMBED_ERROR usage: project-map-embed.sh ROOT inv-<id> [--deadline S] | ROOT --mechanical [--deadline S]")
        return 1
    clock = C.Clock(deadline)
    try:
        root = pos[0] if pos else default_root()
        if not root or not os.path.isabs(root) or not os.path.isdir(root):
            raise EmbedError("need an absolute project root")
        root = os.path.realpath(root).rstrip("/")
        if mech:
            genstr, size, stale = embed_mechanical(root, clock)
        else:
            genstr, size, stale = embed_normal(root, pos[1], clock)
        print("PM_EMBED_OK gen %s %d" % (genstr, size))
        if stale:
            print("PM_EMBED_STALE %s" % stale["why"])
        return 0
    except Superseded as s:
        print("SUPERSEDED base %s current %s" % (s.base or "none", s.cur or "none"))
        return 4
    except C.Deadline:
        print("PM_EMBED_ERROR deadline")
        return 1
    except EmbedError as ex:
        for m in ex.msgs:
            print("PM_EMBED_ERROR " + str(m))
        return 1
    except Exception as ex:   # noqa: BLE001 - nothing is replaced before the pointer rename
        print("PM_EMBED_ERROR internal: %s: %s" % (type(ex).__name__, str(ex)[:160]))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
