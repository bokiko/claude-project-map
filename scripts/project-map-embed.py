#!/usr/bin/env python3
"""project-map-embed.py ROOT inv-<id> [--deadline S]   |   ROOT --mechanical [--deadline S] [--apply-answers]   (entry: project-map-embed.sh)

Publishes one immutable generation (INTERFACES-3.2 section 1.3) and prints exactly one of
    PM_EMBED_OK gen <seq>-<id> <bytes>        exit 0   (an extra PM_EMBED_STALE <why> line when the repo moved meanwhile)
    SUPERSEDED base <b> current <c>           exit 4   (nothing written)
    PM_EMBED_ERROR <why> (one line per reason) exit 1   (nothing replaced)

Normal mode validates STAGE/judgement.out.json (+ plan.out.json on FULL) against STAGE/snapshot.json and merges them with the
carried plan into state.json (schema project-map-4). Mechanical mode (2.1) re-renders the pinned current generation with fresh
mechanical facts only: same judgement, plan and assessment time, no history entry. `--apply-answers` (mechanical only, 3.5.0, used
by facts' model-free "focus confirmed" path and by nothing else) additionally applies the owner's F-set lines when they are a plain
confirmation of the focus the last assessment served (14.3); otherwise it publishes the ordinary refresh and prints
`PM_EMBED_NOTE answers not applied: <reason>` after PM_EMBED_OK.
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
USAGE_RENDER_MARGIN = 0.7   # seconds of the --deadline kept back for rendering and publishing when usage is collected


CARRY_KEYS = ("id", "q", "options", "recommended", "default", "hard_rule", "deadline", "ready", "about")   # a decision's model-owned fields


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


def cache_merge(pm, cache, moved_from=None, moved_to=None, clear_accept=False):
    """Persist watch_cache + coverage_cursor, keep every other key. An accepted answers re-baseline follows the
    current pointer when a mechanical re-render moves it (moved_from -> moved_to); a refresh that applied the owner's answers
    (--apply-answers) carries the new applied count in its own state, so the re-baseline is spent (clear_accept)."""
    cur = C.load_json(os.path.join(pm, "cache.json"), {})
    cur = cur if isinstance(cur, dict) else {}
    try:   # acknowledge the plugin files this publish rendered with (same hashes the prompt hook compares)
        cur["ack_hashes"] = {"template": C.sha256_file(TEMPLATE), "embed": C.sha256_file(os.path.abspath(__file__))}
        cur.pop("ack_attempt_at", None)
    except OSError:
        pass
    for k in ("watch_cache", "coverage_cursor", "fp_cache"):   # `evidence` is written by its own critical section (K.check_evidence), never here
        if k in cache:
            cur[k] = cache[k]
    aa = cur.get("answers_accept")
    if clear_accept:
        cur.pop("answers_accept", None)
    elif moved_to and isinstance(aa, dict) and aa.get("gen") == moved_from:
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
    ho = R.handoff(S)   # 14.5: every generation, signed through the manifest; the page prints S["handoff"], the same text
    if C.blen(ho) > R.HANDOFF_MAX:
        raise EmbedError("handoff over %d bytes" % R.HANDOFF_MAX)
    S["handoff"] = ho
    files["handoff.txt"] = ho
    S["generation_files"] = sorted(set(files) | set(C.STABLE) | {"state.json", "manifest.json"})
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


def seed_evidence(pm, J, snap, final_plan, genstr, recheck):
    """15.1: the checks the publication itself made are observations made under the publish lock, so they are recorded under the
    NEW generation in cache.json `evidence` (a pass of their own, one epoch up): every completion ref the validation just resolved
    (a repaired item with its new ref, every part, a FULL plan's criteria) is `ok` there. Without it the next facts run would find
    a record that has never seen them and the published state's view would flap back to partial. A ref the recheck found lost or
    unknown is NOT seeded (that observation was written by the recheck pass and is newer than the validation)."""
    items = VAL.completion_items(final_plan, J.get("parts"))
    valid = VAL.validated_now(J, snap, final_plan)
    for e in (recheck or {}).get("lost") or []:
        valid.discard((e["id"], e["ref"]))
    for pair in (recheck or {}).get("unknown") or []:
        valid.discard(tuple(pair))
    if not items or not valid:
        return
    cpath = os.path.join(pm, "cache.json")
    cur = C.load_json(cpath, {})
    cur = cur if isinstance(cur, dict) else {}
    stored = cur.get("evidence") if K.evidence_record_ok(cur.get("evidence")) else None
    epoch = (stored["epoch"] if stored else 0) + 1
    mine = {"set": K.evidence_set(items), "gen": genstr, "epoch": epoch,
            "results": {C.evidence_key(i, r): {"status": "ok", "why": "", "at": C.iso(), "epoch": epoch} for i, r in valid}}
    cur["evidence"] = K.evidence_merge(stored, mine, {C.evidence_key(i, r) for i, r in items})
    try:
        C.atomic_write(cpath, C.dumps(cur))
    except OSError:
        pass


# ---------------------------------------------------------------- normal mode
def _scoped_new_commits(repo, head12):
    """Commits under this sub-folder since the judged scoped head (the same path-scoped log collection uses): 0 when the
    scoped head is unchanged. head12 None = the judged package had NO scoped history: any scoped commit now is new
    activity (their count, at most 200). Raises GitCollectError / BudgetOut when the log cannot be read."""
    recs = K.log_records(repo, 200, ["."], 5.0)
    if not head12:
        return len(recs)
    if recs and recs[0][0][:12] == head12:
        return 0
    idx = next((i for i, x in enumerate(recs) if x[0][:12] == head12), None)
    return idx if idx else 1


def light_stale(root, snap, judged_at, clock=None):
    """The judged world versus now: new commits, moved tags / branch sync. What cannot be verified is reported as
    unverified (so the next run re-judges); an exhausted deadline raises C.Deadline."""
    n, rel_moved = 0, []
    if clock is not None and clock.total:
        K.set_budget(clock.t0 + clock.total)
    try:
        for r in snap["repos"]:
            if r.get("vcs") != "git":
                continue
            repo = root if r["path"] == "." else os.path.join(root, r["path"])
            if r.get("scope"):
                # sub-folder ROOT: r["head"] is the last PATH-SCOPED commit (null for a package with no commit of its own
                # yet), so compare scoped activity; the baseline being null does not skip the check
                try:
                    if r.get("head"):
                        n += _scoped_new_commits(repo, r["head"])
                    else:
                        rc_h, _o = G.run(repo, "rev-parse", "HEAD", timeout=5.0)
                        if rc_h == 0:   # the shared repository has commits: has the package gained its first one?
                            n += _scoped_new_commits(repo, None)
                except G.GitArgError:
                    pass
                except K.BudgetOut:
                    raise C.Deadline("deadline")
                except K.GitCollectError:
                    if clock is not None:
                        clock.check()
                    rel_moved.append("activity could not be re-verified (unverified)")
            elif r.get("head"):
                try:
                    rc, out = G.run(repo, "rev-parse", "HEAD", timeout=5.0)
                    if rc == 0 and out.strip()[:12] != r["head"]:
                        rc2, o2 = G.run(repo, "rev-list", "--count", "%s..HEAD" % r["head"], timeout=5.0)
                        n += int(o2.strip()) if rc2 == 0 and o2.strip().isdigit() and int(o2.strip()) else 1
                except G.GitArgError:
                    continue
            # tags and branch sync may have moved while the judgement was written: recheck them with HEAD, independently
            # of the scoped activity above (the release key is the SHARED repository's)
            want = (snap.get("key") or {}).get("release", {}).get(r["path"])
            if want is None:
                continue
            try:
                now = K.collect_release(repo, 5.0, shared=bool((r.get("release") or {}).get("shared")))
            except K.BudgetOut:
                raise C.Deadline("deadline")
            except K.GitCollectError:
                if clock is not None:
                    clock.check()
                rel_moved.append("tags and branch sync could not be re-verified (unverified)")
                continue
            if now is None:
                rel_moved.append("tags and branch sync unavailable on re-check (unverified)")
                continue
            nk = now["key"]
            if nk != want:
                if nk.get("tags") != want.get("tags"):
                    rel_moved.append("tags changed")
                if {k: v for k, v in nk.items() if k not in ("tags", "n", "partial", "unverified")} != {k: v for k, v in want.items() if k not in ("tags", "n", "partial", "unverified")}:
                    rel_moved.append("branch sync changed")
                if nk.get("n") != want.get("n") or bool(nk.get("partial")) != bool(want.get("partial")):
                    rel_moved.append("tag count or coverage changed (unverified)")
            if now.get("inconsistent"):
                # independent of the key comparison: refs that kept moving during the recheck were never verified, so the
                # judged world cannot be certified current even when the (unknown) key happens to match
                rel_moved.append("tags and branch sync kept changing during the re-check (unverified)")
            if nk.get("partial"):
                # independent of every comparison above: a partial tag listing (more tags than were read) can never
                # certify the judged world, whatever else is equal
                rel_moved.append("tag list too large to verify (unverified)")
    finally:
        if clock is not None and clock.total:
            K.set_budget(None)
    if clock is not None:
        clock.check()
    why = []
    if n:
        why.append("%d new commits" % n)
    why += [w for w in dict.fromkeys(rel_moved) if w]
    return {"judged_at": judged_at, "commits_since": n, "why": " and ".join(why)} if why else None


def staged_pack(stage, inv_name):
    """The pack the model READ (STAGE/pack.json), not the one finish_files rebuilds for the generation; None when the file is
    missing or belongs to another invocation. Fit evidence (15.2) may only be an observation THIS pack supplied."""
    pk = C.load_json(os.path.join(stage, "pack.json"))
    return pk if isinstance(pk, dict) and pk.get("generation") == inv_name else None


def staged_seen(stage, inv_name, pk=None):
    """13.3: the `seen` record of the pack the model READ (STAGE/pack.json), not of the pack finish_files rebuilds for the
    generation. None when the file is missing, belongs to another invocation or carries no well-formed `seen` (a pack from
    before 3.4): the assurance then says "pack coverage unknown"."""
    pk = pk if pk is not None else staged_pack(stage, inv_name)
    if isinstance(pk, dict) and K.valid_seen(pk.get("seen")):
        return dict(pk["seen"])
    return None


def evidence_recheck(root, snap, final_plan, J, prevp, cache, cur, clock):
    """15.1 publication recheck: the completion refs the STAGED snapshot verified ok and the judgement still carries are checked once
    more now (at most K.EVID_CAP, inside the publish lock this embed holds, within the deadline), because the world can change while the
    judgement is written. -> {done, n, lost[{id, ref, why}], unknown[(id, ref)]}, or None when there was nothing to recheck. `done` =
    refs whose recheck gave a definite answer (ok or lost); an unknown or unreached ref is not done and the assurance says so
    ("publication recheck k of n"). The result goes into the published state (build_evidence), never only into a note.
    Test hook PM_EMBED_EVIDENCE_DEADLINE: seconds for this check (default 20)."""
    final = set(VAL.completion_items(final_plan, J.get("parts")))
    ok_pairs = [(e["id"], e["ref"]) for e in (snap.get("evidence") or {}).get("ok") or [] if (e["id"], e["ref"]) in final]
    if not ok_pairs:
        return None
    out = {"done": 0, "n": len(ok_pairs), "lost": [], "unknown": []}
    items = K.evidence_items(prevp["state"]) if prevp["kind"] == "v4" else []
    by_key = {C.evidence_key(i, r): (i, r) for i, r in ok_pairs}
    dl = time.monotonic() + float(os.environ.get("PM_EMBED_EVIDENCE_DEADLINE") or min(20.0, clock.remaining()))
    _view, ran = K.check_evidence(root, K.evidence_repos(snap.get("repos", []), prevp["state"] if prevp["kind"] == "v4" else None), items, cache,
                                  dl, cur, only=ok_pairs, held=True)
    for k, r in ran.items():
        i, ref = by_key[k]
        if r["status"] == "unknown":
            out["unknown"].append((i, ref))
        else:
            out["done"] += 1
            if r["status"] == "lost":
                out["lost"].append({"id": i, "ref": ref, "why": r["why"]})
    return out


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
        pack = staged_pack(stage, inv_name)
        judged_seen = staged_seen(stage, inv_name, pack)
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
            # structure only here: the completion refs of a FULL plan are checked on the FINAL plan (after criteria_updates), below
            VAL.validate_plan(v, plan, root, snap.get("repos", []), False)
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
        ctx = {"root": root, "snap": snap, "plan": plan, "prev": pseudo, "full": full, "inv_name": inv_name, "pack": pack}
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
        if full:   # 15.1: a listed loss may be reopened or re-referenced by criteria_updates; the exact unlisted losses may be carried as they were
            v2 = VAL.V()
            VAL.check_plan_refs(v2, final_plan, root, snap.get("repos", []), VAL.lost_unlisted(snap.get("evidence")))
            if v2.errs:
                raise EmbedError(v2.errs)
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
        stale = light_stale(root, snap, snap["facts_at"], clock)
        recheck = evidence_recheck(root, snap, final_plan, J, prevp, K_cache(pm), cur, clock)
        if recheck and recheck["lost"]:   # a completion ref vanished while the judgement was written: published unverified, behind
            w = "completion evidence lost: " + ", ".join(sorted({e["id"] for e in recheck["lost"]})[:3])
            stale = {"judged_at": snap["facts_at"], "commits_since": (stale or {}).get("commits_since", 0),
                     "why": " and ".join(x for x in ((stale or {}).get("why"), w) if x)}
        th, eh = K.plugin_hashes()
        # the judged key must describe the lists the judgement now declares: a path the model added is hashed now,
        # a ledger binding that changed gets its new hash; everything else keeps the hashes of the judged world
        key = copy.deepcopy(snap["key"])
        kept_h = {p: h for p, h in key["watch_hashes"].items() if p in J["watch"]}
        new_paths = [p for p in J["watch"] if p not in kept_h]
        status2 = snap["status"]
        if new_paths:
            # test hook PM_EMBED_WATCH_DEADLINE: seconds for this publication-time check (default 20)
            wl, c_, t_ = K.hash_watch(root, new_paths, {}, time.monotonic() + float(os.environ.get("PM_EMBED_WATCH_DEADLINE") or 20.0))
            kept_h.update({w["path"]: w["hash"] for w in wl})
            # the check is part of what this generation publishes: its counts join the coverage, and a path it could not
            # hash completely makes the coverage partial (13.4: the assurance never certifies an incomplete check)
            status2 = dict(status2, covered=status2["covered"] + c_, total=status2["total"] + t_)
            if c_ < t_ or any(w["hash"] == "partial" for w in wl):
                status2["coverage"] = "partial"
        key["watch_hashes"] = kept_h
        led, sled = K.parse_ledger(root, J["project"].get("ledger")), snap.get("ledger")
        if not ((led and sled and led["path"] == sled["path"]) or (not led and not sled)):
            key["ledger_hash"] = led["hash"] if led else None
        snap2 = dict(snap, template_hash=th, embed_hash=eh, key=key, status=status2)
        # an owner answer that arrived while the judgement was written outranks a closure by events for the same decision:
        # re-read answers.jsonl under the lock (never written, never consumed as bad input)
        notes = []
        closing = [d["id"] for d in J.get("decisions", []) if isinstance(d.get("overtaken"), dict)]
        if closing:
            try:
                # ONE read serves both: the unterminated-tail flag and the late answers describe the same bytes, so a record
                # finished between two reads can neither be missed nor be seen by one check and not the other
                lines, tail = K.read_answers_ex(pm)
                late = K.late_answers(pm, snap, closing, image=lines)
            except K.AnswersUnreadable as ex:
                raise EmbedError("%s while the judgement was written: run facts again" % ex)
            except K.AnswersRewritten:
                raise EmbedError("answers rewritten while the judgement was written: run facts again")
            if late:
                # every appended line went through the one reducer: the owner's F-set lines are reduced with the D- answers
                snap2 = dict(snap2, decisions=late["decisions"], answers=late["answers"], intent=late["intent"])
                notes.append("owner answer for %s arrived during the judgement and wins over its closure by events; "
                             "the map is stale for the new answers, run /project-map again" % ", ".join(late["won"]))
            left = [i for i in closing if not late or i not in late["won"]]
            if tail and left:
                # answers.jsonl ends in a record that is not committed yet (no newline): it may be the owner's answer to the
                # very decision the judgement closes, and its bytes are never applied or hashed. The closure waits: the
                # decision is published still open (a verbatim copy of the staged one), the key remembers it, and the next
                # facts run re-judges once the tail is committed or removed. A COMMITTED late answer still wins above.
                sdec = {x["id"]: x for x in snap.get("decisions", []) if isinstance(x, dict)}
                J["decisions"] = [({k: copy.deepcopy(sdec[d["id"]][k]) for k in CARRY_KEYS if k in sdec[d["id"]]}
                                   if d["id"] in left and d["id"] in sdec else d) for d in J["decisions"]]
                snap2 = dict(snap2, key=dict(snap2["key"], closure_deferred=sorted(left)))
                notes.append("uncommitted answer tail; events closure of %s deferred" % ", ".join(sorted(left)))
        box = {}

        def make(genstr):
            c = {"root": root, "snap": snap2, "J": J, "plan": final_plan, "prev": pseudo, "genstr": genstr, "base": cur,
                 "kept": kept, "judged_at": snap["facts_at"], "n": n, "stale": stale, "judged_seen": judged_seen,
                 "staged_intent": snap.get("intent"),   # the target is frozen from the STAGED input (14.3), accepted from snap2
                 "fit_res": ctx.get("fit_res"), "recheck": recheck}
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
        seed_evidence(pm, J, snap2, final_plan, genstr, recheck)
        cache_merge(pm, K_cache(pm))
        return genstr, len(C.read_pinned(pm, genstr, "index.html") or b""), stale, notes
    finally:
        lock.release()


def K_cache(pm):
    c = C.load_json(os.path.join(pm, "cache.json"), {})
    return c if isinstance(c, dict) else {}


# ---------------------------------------------------------------- mechanical mode (2.1)
def image_seam():
    """Test hook PM_EMBED_AFTER_IMAGE=<file>: right after --apply-answers took its ONE answers image, create <file> and wait (at most
    20 s) for <file>.go, so a test can append to answers.jsonl exactly between the image and everything that must use it."""
    sig = os.environ.get("PM_EMBED_AFTER_IMAGE")
    if not sig:
        return
    with open(sig, "w"):
        pass
    end = time.monotonic() + 20.0
    while not os.path.exists(sig + ".go") and time.monotonic() < end:
        time.sleep(0.02)


def focus_confirmation(prev, snap, cmp, image):
    """14.3, evaluated INSIDE the refresh, under the publish lock, on its pinned generation (`prev`), its own snapshot and the ONE
    answers.jsonl image the collection used. -> (the reduced intent {accepted, ..., drift}, "") when every condition holds, else
    (None, reason):
    no uncommitted tail; the only key component that moved is answers_count; every complete line after the pinned `applied` is a
    well-formed F-set with the identity of the focus the last assessment served (K.confirmation_only, the predicate facts used).
    The staged prefix is verified by the collection itself (a rewritten file is an error there)."""
    lines, tail = image
    if prev.get("unverified"):
        return None, "the pinned generation is not verified"
    if tail:
        return None, "answers.jsonl has an uncommitted last line"
    if not cmp["moved"]:
        return None, "no new answer lines"
    if cmp["moved"] != ["answers_count"]:
        return None, "other facts moved: %s" % ", ".join(cmp["moved"])
    if not K.confirmation_only(prev["state"], lines, prev["applied"]):
        return None, "the new lines are not a plain confirmation of the focus"
    pending, _bad = K.parse_pending(lines[prev["applied"]:])
    it = K.intent_base(prev)
    K.apply_answers({}, pending, it)   # the same reducer as every other owner line (3.6: it also keeps the drift record)
    return K.reconcile_intent(it), ""


def embed_mechanical(root, clock, apply_answers=False):
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
            # D7: usage is re-collected when its OWN as-of time is over an hour old (not the map's: a refresh that kept stale
            # numbers must retry on the next one). Usage never decides whether the refresh happens: it gets what is left of
            # the budget minus a render margin, and a timeout keeps the previous numbers (marked stale).
            u0 = K.clean_usage(S0.get("usage")) if isinstance(S0.get("usage"), dict) else None
            ua = C.parse_iso(u0.get("at")) if u0 else None
            want_usage = u0 is None or ua is None or (C.now() - ua).total_seconds() >= 3600
            margin = max(USAGE_RENDER_MARGIN, total * 0.2) if total else 0.0
            # --apply-answers: ONE read of answers.jsonl serves the collection, the staged-prefix check, the confirmation test and
            # the tail flag, so the decision and the published state describe the same bytes
            image = K.answers_image(pm) if apply_answers else None
            if apply_answers:
                image_seam()
            snap = K.collect(root, prev, hd, cache, git_timeout=gt, want_usage=want_usage, usage_timeout=60.0,
                             usage_until=(clock.t0 + total - margin) if total else None, usage_prev=u0, answers_image=image,
                             evidence_held=True)   # this refresh holds the publish lock: its evidence pass runs inside it
        except K.GitCollectError as ex:
            raise EmbedError("git_error: %s" % ex)
        except K.AnswersUnreadable as ex:
            raise EmbedError(str(ex))
        except K.AnswersRewritten:
            raise EmbedError("answers rewritten")
        except K.BudgetOut:
            raise C.Deadline("deadline")
        clock.check()
        jk = copy.deepcopy(S0["judged_key"])
        cmp0 = K.compare_keys(jk, snap["key"], snap)
        for p in cmp0["adopt"]:   # a watched path hashed completely for the first time adopts that hash
            jk["watch_hashes"][p] = snap["key"]["watch_hashes"][p]
        if "evidence_lost" not in cmp0["moved"]:
            # 15.1: no loss the judged key is not already carrying. Whatever it carried verified again (the fresh set is empty), so the
            # refresh rebases the component; when the key HAS moved (a loss, or carried repairs still pending) it stays judged
            jk["evidence_lost"] = list(snap["key"]["evidence_lost"])
        cmp = K.compare_keys(jk, snap["key"], snap)
        notes, focus, image_lines = [], None, None
        if apply_answers:
            focus, why_not = focus_confirmation(prev, snap, cmp, image)
            if focus is None:   # the ordinary refresh below; the caller (facts) re-collects and stages the judgement
                notes.append("answers not applied: %s" % why_not)
            else:
                image_lines = image[0]
                ph = K.prefix_hash(image_lines, len(image_lines))
                jk["answers_count"], jk["intent_hash"] = snap["key"]["answers_count"], focus["accepted"]["hash"]   # the key now includes the lines
                snap = dict(snap, answers=dict(snap["answers"], applied=len(image_lines), applied_hash=ph, pending=[]))
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
            elif isinstance(T.get("usage"), dict):
                T["usage"] = K.clean_usage(T["usage"])   # numbers kept from an older build lose any free-text job label
            T["coverage"] = {"coverage": snap["status"]["coverage"], "covered": snap["status"]["covered"], "total": snap["status"]["total"]}
            replay = bool(prev.get("replay")) and focus is None   # an outstanding rebaseline keeps the map behind until a judgement
            T["stale"] = ({"judged_at": S0.get("judged_at"), "commits_since": snap["commits"]["count"],
                           "why": "answers replayed" + ("; " + cmp["why"] if cmp["why"] else "") if replay else cmp["why"]}
                          if (cmp["moved"] or replay) else None)
            T["template_hash"], T["embed_hash"], T["judged_key"] = th, eh, jk
            if focus is not None:   # the owner confirmed the focus the last assessment served: the record, the answers it consumed
                it = dict(T.get("intent") or {}, accepted=copy.deepcopy(focus["accepted"]))   # target stays as judged
                if isinstance(focus.get("drift"), dict):   # the same reducer kept the drift record (an F-set clears a revision request)
                    it["drift"] = copy.deepcopy(focus["drift"])
                T["intent"] = K.reconcile_intent(it)
                T["answers"] = dict(T["answers"], total=len(image_lines), applied=len(image_lines),
                                    applied_hash=snap["answers"]["applied_hash"])
            # a closed decision (answered / defaulted / overtaken) lives for one published generation, S0 was it: this refresh
            # drops it and retires its id exactly as the next judgement would. Newly answered decisions are not touched: an
            # answer not yet applied (answers.applied) stays pending in answers.jsonl for the next judgement.
            shown = [d["id"] for d in T["decisions"] if d.get("status") in VAL.CLOSED_ST]
            if shown:
                T["decisions"] = [d for d in T["decisions"] if d.get("status") not in VAL.CLOSED_ST]
                VAL.retire_decisions(T, shown)
            fresh = {r["path"]: r["release"] for r in snap["repos"] if isinstance(r.get("release"), dict)}
            for r_ in T["repos"]:   # tags and sync are facts, refreshed on every render; the judgement stays as it was
                if r_.get("path") in fresh:
                    r_["release"] = fresh[r_["path"]]
                    r_.pop("inaccessible", None)   # J1: the repository was read as git again
                else:
                    r_.pop("release", None)
            # 3.6: the completion evidence is a fact of THIS refresh's own pass: the view, the unverified marks (set for every known
            # loss, cleared only when the ref verified ok again) and, below, the assurance all follow the snapshot
            VAL.apply_evidence(T, snap["evidence"])
            # `since`, `fit` and `judged_seen` describe the JUDGED batch and stay as they were (live drift is `stale`, set above); the
            # assurance is recomputed from this refresh's own facts: stale, coverage, release, evidence and the decisions left open
            T["assurance"] = VAL.assurance(T)
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
        cache_merge(pm, cache, cur, genstr, clear_accept=focus is not None)
        return genstr, len(C.read_pinned(pm, genstr, "index.html") or b""), None, notes
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
    mech, deadline, pos, i, apply_a = False, None, [], 0, False
    try:
        while i < len(args):
            a = args[i]
            if a == "--mechanical":
                mech = True
            elif a == "--apply-answers":
                apply_a = True
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
        if mech and len(pos) > 1 or (not mech and len(pos) != 2) or (apply_a and not mech):
            raise ValueError
    except (ValueError, IndexError):
        print("PM_EMBED_ERROR usage: project-map-embed.sh ROOT inv-<id> [--deadline S] | ROOT --mechanical [--deadline S] [--apply-answers]")
        return 1
    clock = C.Clock(deadline)
    try:
        root = pos[0] if pos else default_root()
        if not root or not os.path.isabs(root) or not os.path.isdir(root):
            raise EmbedError("need an absolute project root")
        root = os.path.realpath(root).rstrip("/")
        if mech:
            genstr, size, stale, notes = embed_mechanical(root, clock, apply_a)
        else:
            genstr, size, stale, notes = embed_normal(root, pos[1], clock)
        print("PM_EMBED_OK gen %s %d" % (genstr, size))
        if stale:
            print("PM_EMBED_STALE %s" % stale["why"])
        for n in notes:
            print("PM_EMBED_NOTE %s" % n)
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
