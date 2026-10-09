#!/usr/bin/env python3
"""pm_testlib.py: small helpers for tests/test_embed.sh (JSON edits, judgement builders, lock holder, reader).

  jud   PM INV full|update [CODE]   write STAGE/judgement.out.json (+ plan.out.json for full); CODE may edit J and P
  get   FILE EXPR                   print eval(EXPR) with d = the JSON in FILE
  mut   FILE CODE                   edit the JSON in FILE in place (d / J)
  legacy ROOT                       write a 3.x style map under ROOT/.project-map from tests/demo-judgement.json
  holder PM                         hold the publish lock until killed
  reader PM SECONDS                 read current/* repeatedly, print MIXED <n> when generations disagree
"""
import datetime as dt
import fcntl
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "demo-judgement.json")


def build(inv, kind):
    """Judgement + plan shaped like the demo-app fixture, in the 3.2 schema."""
    F = json.load(open(FIX))
    parts = []
    for p in F["parts"]:
        q = {"id": p["id"], "label": p["label"], "status": {"not_started": "unknown"}.get(p["status"], p["status"])}
        if p.get("line"):
            q["line"] = p["line"]
        if p.get("ref"):
            q["ref"] = p["ref"]
        if p["status"] == "stuck":
            q["blocked_by"] = p["blocked_by"][0]
        parts.append(q)
    decs = []
    for d in F["decisions"]:
        decs.append({"id": d["id"], "q": d["q"], "options": [{"id": o["id"], "label": o["label"]} for o in d["options"]],
                     "recommended": d["recommended"], "default": d["default"], "hard_rule": d["hard_rule"],
                     "deadline": d["deadline"], "ready": d["ready"]})
    decs[0]["deadline"] = (dt.datetime.now().astimezone() + dt.timedelta(days=1)).isoformat(timespec="seconds")
    J = {"generation": inv, "project": {"name": F["project"]["name"], "goal": F["project"]["goal"], "ledger": F["project"].get("ledger")},
         "run": {"type": "FULL" if kind == "full" else "UPDATE", "model": "test"},
         "headline": {"text": F["headline"]["text"], "tone": "watch"},
         "parts": parts, "current_phase": "P2",
         "eta": {"low": 2, "high": 4, "unit": "days", "basis": F["eta"]["basis"][:70], "confidence": "low"},
         "next_step": {"title": F["next_step"]["title"], "why": F["next_step"]["why"], "actor": "claude", "unblocks": ["qualification"]},
         "decisions": decs,
         "loops": [{"id": "L-01", "kind": "retry", "rounds": 2, "failed": 2, "note": "Full-model check"}],
         "risks": [{"id": "R-1", "text": F["risks"][0]["text"][:110], "severity": "high"}]}
    names = [m["label"] for m in F["milestone"]["list"]]
    crit = [{"id": "P2.c%d" % (i + 1), "text": c["text"][:78], "done": False} for i, c in enumerate(F["milestone"]["criteria"])]
    P = {"schema": "project-map-plan-1", "generation": inv, "origin": "proposed",
         "phases": [{"id": "P1", "label": names[0], "criteria": [{"id": "P1.c1", "text": "Weights load", "done": True, "ref": "file:PLAN.md:10"}]},
                    {"id": "P2", "label": names[1], "criteria": crit},
                    {"id": "P3", "label": names[2], "criteria": []}]}
    return J, P


def cmd_jud(pm, inv, kind, code=""):
    stage = os.path.join(pm, inv)
    J, P = build(inv, kind)
    if kind == "update":   # keep the carried plan's phase ids
        plan = json.load(open(os.path.join(stage, "plan.json")))
        ids = [p["id"] for p in plan["phases"]]
        J["current_phase"] = ids[min(1, len(ids) - 1)] if ids else "P1"
    else:
        J["current_phase"] = "P2"
    if kind != "full" and os.path.exists(os.path.join(stage, "plan.out.json")):
        os.remove(os.path.join(stage, "plan.out.json"))
    exec(code, {"J": J, "P": P, "json": json, "os": os, "dt": dt})
    json.dump(J, open(os.path.join(stage, "judgement.out.json"), "w"))
    if kind == "full":
        json.dump(P, open(os.path.join(stage, "plan.out.json"), "w"))


def cmd_get(path, expr):
    d = json.load(open(path))
    print(eval(expr, {"d": d, "json": json, "len": len, "sum": sum, "sorted": sorted, "set": set}))


def cmd_mut(path, code):
    d = json.load(open(path))
    exec(code, {"d": d, "J": d, "json": json, "os": os, "dt": dt})
    json.dump(d, open(path, "w"))


def cmd_legacy(root):
    """A 3.x map: regular files state.json, judgement.json, facts.json, index.html, mobile.html, brief.txt."""
    pm = os.path.join(root, ".project-map")
    os.makedirs(pm, exist_ok=True)
    J = json.load(open(FIX))
    json.dump(J, open(os.path.join(pm, "judgement.json"), "w"))
    S = {"schema": "project-map-3", "project": {"id": "p", "name": J["project"]["name"], "root": root, "ledger": J["project"].get("ledger")},
         "generated_at": "2026-10-06T10:00:00+03:00", "facts_at": "2026-10-06T10:00:00+03:00", "judgement_at": "2026-10-06T09:59:00+03:00",
         "headline": J["headline"], "parts": J["parts"], "milestone": J["milestone"], "next_step": J["next_step"],
         "decisions": [dict(d, status="open", raised_at="2026-10-06T10:00:00+03:00") for d in J["decisions"]],
         "retired_ids": ["old-part", "D-000"], "run": {"n": 4, "type": "FULL", "model": "x"}, "answers_applied": 0,
         "history": [], "facts": {"key": {"heads": {".": "abcdef012345"}}}}
    json.dump(S, open(os.path.join(pm, "state.json"), "w"))
    json.dump({"schema": "project-map-facts-1"}, open(os.path.join(pm, "facts.json"), "w"))
    for n, t in (("index.html", "<html>legacy</html>"), ("mobile.html", "<html>m</html>"), ("brief.txt", "legacy brief\n")):
        open(os.path.join(pm, n), "w").write(t)
    open(os.path.join(pm, "answers.jsonl"), "w").write(json.dumps({"id": "D-001", "answer": "A", "at": "2026-10-06T11:00:00+03:00", "by": "owner"}) + "\n")


def cmd_resign(gdir):
    """Recompute sizes, sha256 and the hmac of a generation after a test edited its files on purpose."""
    sys.path.insert(0, os.environ["PM_SCRIPTS"])
    import pm_common as C
    m = json.load(open(gdir + "/manifest.json"))
    for k in list(m["files"]):
        if not os.path.exists(gdir + "/" + k):
            del m["files"][k]
            continue
        data = open(gdir + "/" + k, "rb").read()
        m["files"][k] = {"size": len(data), "sha256": C.sha256_bytes(data)}
    m["hmac"] = C.sign_manifest(m["files"], m["generation"], m["base"])
    json.dump(m, open(gdir + "/manifest.json", "w"))


def cmd_holder(pm):
    fd = os.open(os.path.join(pm, ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    print("held", flush=True)
    while True:
        time.sleep(0.2)


def cmd_reader(pm, secs):
    end, bad, n = time.time() + float(secs), 0, 0
    while time.time() < end:
        try:
            g = None
            for _ in range(12):   # APFS: readlink can briefly fail with EINVAL while the link is replaced
                try:
                    g = os.readlink(os.path.join(pm, "current")).rstrip("/")
                    break
                except OSError:
                    time.sleep(0.002)
            if g is None:
                bad += 1
                continue
            d = os.path.join(pm, g)
            gen = g[4:]
            st = json.load(open(os.path.join(d, "state.json")))["generation"]
            html = open(os.path.join(d, "index.html"), encoding="utf-8").read()
            m = re.search(r'name="pm-generation" content="([^"]*)"', html)
            br = open(os.path.join(d, "brief.txt")).read().rstrip("\n").split("\n")[-1]
            n += 1
            if not (st == gen and m and m.group(1) == gen and br == "generation " + gen):
                bad += 1
        except FileNotFoundError:
            bad += 1
    print("MIXED %d of %d" % (bad, n))


if __name__ == "__main__":
    c = sys.argv[1]
    {"jud": cmd_jud, "get": cmd_get, "mut": cmd_mut, "legacy": cmd_legacy, "resign": cmd_resign, "holder": cmd_holder, "reader": cmd_reader}[c](*sys.argv[2:])
