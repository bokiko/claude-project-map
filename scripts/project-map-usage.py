#!/usr/bin/env python3
"""project-map-usage.py - read-only token/model usage collector for the project-map agent.

Usage:  python3 project-map-usage.py <project-root> [--since ISO8601] [--max-jobs N]

Reads (never writes; output goes to stdout only):
  Claude Code  ~/.claude/projects/**/<session>.jsonl and <session>/subagents/agent-*.jsonl
               assistant records: message.model + message.usage (input/output/cache tokens)
  Codex CLI    ~/.codex/sessions/**/rollout-*.jsonl
               event_msg/token_count (cumulative total_token_usage) + turn_context.model

Attribution to the project (documented, approximate where noted):
  1. Claude: a record counts when the cwd it carries (or the last cwd seen in that file) is the
     project root or inside it. attribution = "cwd".
  1b. Claude subagent (…/<session>/subagents/agent-*.jsonl) with no cwd match of its own inherits
     the project when its parent session transcript is a cwd hit, or its first user message
     contains `ROOT: <root>`. attribution = "inherited" (all records counted, not approximate).
  2. Claude fallback: a transcript with no cwd match but >= MENTION_MIN mentions of the root
     path counts whole. attribution = "mentions" (totals.approximate = true).
  3. Codex: session_meta/turn_context cwd inside the root ("cwd"), else >= MENTION_MIN mentions
     of the root path ("mentions"). Sessions under ~/.buzz are never read (Buzz is hands-off).
Missing source dir / unreadable data -> status "unavailable" and null totals, never 0.

Tokens per row: in (fresh input), out, cache_read, cache_write, total = sum of the four.
Codex: in = input_tokens - cached_input_tokens; out = output_tokens (reasoning included);
cache_read = cached_input_tokens; cache_write = cache_write_input_tokens.
Stdlib only.
"""
import json, os, re, sys, datetime as dt
from collections import defaultdict

MENTION_MIN = 25
HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude", "projects")
CODEX_DIR = os.path.join(HOME, ".codex", "sessions")
SKIP_CWD_FRAGMENT = "/.buzz"


def parse_ts(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def family(model):
    m = (model or "").lower()
    for f in ("opus", "fable", "sonnet", "haiku"):
        if f in m:
            return f
    return "other"


def under(cwd, root):
    return bool(cwd) and (cwd == root or cwd.startswith(root + "/"))


def cwd_in(raw, rootb):
    """True when a raw transcript carries a "cwd" equal to root or inside it (not a sibling like root-2)."""
    return re.search(rb'"cwd":"' + re.escape(rootb) + rb'(?:"|/)', raw) is not None


def blank():
    return {"in": 0, "out": 0, "cache_read": 0, "cache_write": 0}


def add(a, b):
    for k in ("in", "out", "cache_read", "cache_write"):
        a[k] += b[k]


def total(d):
    return d["in"] + d["out"] + d["cache_read"] + d["cache_write"]


def iter_jsonl(path):
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                try:
                    yield json.loads(line)
                except Exception:
                    continue  # partial last line of a live transcript
    except OSError:
        return


def walk(base, suffix=".jsonl"):
    for dp, _dn, fn in os.walk(base):
        for f in fn:
            if f.endswith(suffix):
                yield os.path.join(dp, f)


def read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


# ---------------------------------------------------------------- Claude
def subagent_inherits(path, root, rootb):
    """True when a subagent transcript belongs to root without a cwd hit of its own:
    its parent session transcript is a cwd hit, or its first user message says `ROOT: <root>`."""
    parent = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(path))),
                          os.path.basename(os.path.dirname(os.path.dirname(path))) + ".jsonl")
    praw = read_bytes(parent)
    if praw is not None and cwd_in(praw, rootb):
        return True
    pat = re.compile(r"ROOT:\s*" + re.escape(root) + r"(?![\w./-])")
    for d in iter_jsonl(path):
        if d.get("type") == "user":
            return bool(pat.search(json.dumps((d.get("message") or {}).get("content"), ensure_ascii=False)))
    return False


def collect_claude(root, since):
    if not os.path.isdir(CLAUDE_DIR):
        return {"status": "unavailable", "reason": "no ~/.claude/projects"}, [], False
    rootb = root.encode()
    jobs, scanned, attributed, approx = [], 0, 0, False
    approx_files = []
    for path in walk(CLAUDE_DIR):
        scanned += 1
        raw = read_bytes(path)
        if raw is None:
            continue
        cwd_hit = cwd_in(raw, rootb)
        is_sub = "/subagents/" in path
        inherited = None
        if is_sub and not cwd_hit:
            inherited = subagent_inherits(path, root, rootb)
        mentions = raw.count(rootb)
        if b'"cwd":"' in raw:   # a transcript that names a cwd elsewhere is never attributed by mentions
            mentions = 0
        if not cwd_hit and not inherited and mentions < MENTION_MIN:
            continue
        attribution = "cwd" if cwd_hit else ("inherited" if inherited else "mentions")
        meta = {}
        if is_sub:
            try:
                with open(path[:-6] + ".meta.json") as fh:
                    meta = json.load(fh)
            except Exception:
                meta = {}
        cur_cwd = None
        title = None
        seen = {}  # message id -> (model, usage, ts) last record wins
        for d in iter_jsonl(path):
            if d.get("cwd"):
                cur_cwd = d["cwd"]
            if d.get("type") == "ai-title" and d.get("aiTitle"):
                title = d["aiTitle"]
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            u = msg.get("usage")
            model = msg.get("model")
            if not u or not model or model.startswith("<"):
                continue
            if attribution == "cwd" and not under(d.get("cwd") or cur_cwd, root):
                continue
            ts = parse_ts(d.get("timestamp"))
            if since and ts and ts < since:
                continue
            key = msg.get("id") or d.get("uuid")
            seen[key] = (model, u, ts)
        if not seen:
            continue
        per_model = defaultdict(lambda: [blank(), 0, None, None])
        for model, u, ts in seen.values():
            row = {
                "in": int(u.get("input_tokens") or 0),
                "out": int(u.get("output_tokens") or 0),
                "cache_read": int(u.get("cache_read_input_tokens") or 0),
                "cache_write": int(u.get("cache_creation_input_tokens") or 0),
            }
            pm = per_model[model]
            add(pm[0], row)
            pm[1] += 1
            if ts:
                pm[2] = min(pm[2], ts) if pm[2] else ts
                pm[3] = max(pm[3], ts) if pm[3] else ts
        sid = os.path.basename(path)[:-6]
        if is_sub:
            kind = "subagent"
            label = meta.get("description") or meta.get("agentType") or sid
            agent_type = meta.get("agentType")
            jid = "claude:" + sid
        else:
            kind = "main"
            label = title or "Claude session " + sid[:8]
            agent_type = None
            jid = "claude:" + sid
        if attribution == "mentions":
            approx = True
            approx_files.append(os.path.relpath(path, CLAUDE_DIR))
        attributed += 1
        for model, (tok, n, t0, t1) in per_model.items():
            jobs.append({
                "id": jid, "source": "claude", "kind": kind, "label": label[:80],
                "agent_type": agent_type, "model": model, "family": family(model),
                "attribution": attribution, "msgs": n,
                "first_at": t0.isoformat() if t0 else None, "last_at": t1.isoformat() if t1 else None,
                **tok, "total": total(tok),
            })
    st = {"status": "ok", "files_scanned": scanned, "jobs_attributed": attributed}
    if approx_files:
        st["approximate_files"] = approx_files[:5]
        st["approximate_files_total"] = len(approx_files)
    return st, jobs, approx


# ---------------------------------------------------------------- Codex
def collect_codex(root, since):
    if not os.path.isdir(CODEX_DIR):
        return {"status": "unavailable", "reason": "no ~/.codex/sessions"}, [], False
    rootb = root.encode()
    jobs, scanned, attributed, approx = [], 0, 0, False
    for path in walk(CODEX_DIR):
        scanned += 1
        raw = read_bytes(path)
        if raw is None:
            continue
        mentions = 0 if b'"cwd":"' in raw else raw.count(rootb)
        cwd_hit = cwd_in(raw, rootb)
        if not cwd_hit and mentions < MENTION_MIN:
            continue
        attribution = "cwd" if cwd_hit else "mentions"
        sid = os.path.basename(path)[:-6]
        model, prev, skip, turn = None, None, False, "0"
        turn_n, labels = 0, {}
        per_turn = {}  # (turn, model) -> [tok, n, t0, t1]
        for d in iter_jsonl(path):
            t = d.get("type")
            p = d.get("payload") or {}
            if t == "session_meta":
                if SKIP_CWD_FRAGMENT in (p.get("cwd") or ""):
                    skip = True
                    break
                sid = p.get("id") or sid
            elif t == "turn_context":
                model = p.get("model") or model
                if p.get("turn_id") and p["turn_id"] != turn:
                    turn = p["turn_id"]
                    turn_n += 1
            elif t == "response_item" and p.get("type") == "message" and p.get("role") == "user" and turn not in labels:
                c = p.get("content")
                txt = ""
                if isinstance(c, list):
                    txt = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                elif isinstance(c, str):
                    txt = c
                txt = re.sub(r"\s+", " ", txt).strip()
                if txt and not txt.startswith(("<", "#")):
                    labels[turn] = txt[:70]
            elif t == "event_msg" and p.get("type") == "token_count":
                info = p.get("info") or {}
                cur = info.get("total_token_usage")
                if not cur:
                    continue
                cur = {k: int(cur.get(k) or 0) for k in
                       ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens")}
                if prev is None or any(cur[k] < prev[k] for k in cur):
                    delta = cur  # first event, or counter reset
                else:
                    delta = {k: cur[k] - prev[k] for k in cur}
                prev = cur
                ts = parse_ts(d.get("timestamp"))
                if since and ts and ts < since:
                    continue
                cached = delta["cached_input_tokens"]
                row = {"in": max(delta["input_tokens"] - cached, 0), "out": delta["output_tokens"],
                       "cache_read": cached, "cache_write": delta["cache_write_input_tokens"]}
                pm = per_turn.setdefault((turn, turn_n, model or "unknown"), [blank(), 0, None, None])
                add(pm[0], row)
                pm[1] += 1
                if ts:
                    pm[2] = min(pm[2], ts) if pm[2] else ts
                    pm[3] = max(pm[3], ts) if pm[3] else ts
        if skip or not per_turn:
            continue
        if attribution == "mentions":
            approx = True
        attributed += 1
        for (tid, tn, m), (tok, n, t0, t1) in per_turn.items():
            if total(tok) == 0:
                continue
            jobs.append({
                "id": "codex:%s:%s" % (sid, tid[:8]), "source": "codex", "kind": "turn",
                "label": labels.get(tid) or "Codex round %d" % tn, "agent_type": None,
                "model": m, "family": m, "attribution": attribution, "msgs": n, "session": sid,
                "first_at": t0.isoformat() if t0 else None, "last_at": t1.isoformat() if t1 else None,
                **tok, "total": total(tok),
            })
    return {"status": "ok", "files_scanned": scanned, "jobs_attributed": attributed}, jobs, approx


# ---------------------------------------------------------------- aggregate
def agg(rows):
    t = blank()
    for r in rows:
        add(t, r)
    t["total"] = total(t)
    return t


def main(argv):
    if len(argv) < 2 or not argv[1].startswith("/"):
        print(json.dumps({"error": "usage: project-map-usage.py <abs project root> [--since ISO] [--max-jobs N]"}))
        return 2
    root = os.path.realpath(argv[1]).rstrip("/")
    since, max_jobs = None, 15
    i = 2
    while i < len(argv):
        if argv[i] == "--since" and i + 1 < len(argv):
            since = parse_ts(argv[i + 1])
            if since is None:
                print(json.dumps({"error": "bad --since"}))
                return 2
            if since.tzinfo is None:
                since = since.replace(tzinfo=dt.timezone.utc)
            i += 2
        elif argv[i] == "--max-jobs" and i + 1 < len(argv) and argv[i + 1].isdigit():
            max_jobs = int(argv[i + 1])
            i += 2
        else:
            print(json.dumps({"error": "unknown argument " + argv[i]}))
            return 2

    try:
        c_status, c_jobs, c_approx = collect_claude(root, since)
    except Exception as e:  # never crash the agent run
        c_status, c_jobs, c_approx = {"status": "unavailable", "reason": type(e).__name__}, [], False
    try:
        x_status, x_jobs, x_approx = collect_codex(root, since)
    except Exception as e:
        x_status, x_jobs, x_approx = {"status": "unavailable", "reason": type(e).__name__}, [], False

    jobs = c_jobs + x_jobs
    jobs.sort(key=lambda j: j["last_at"] or "", reverse=True)

    per_model = {}
    for j in jobs:
        pm = per_model.setdefault(j["model"], {"group": j["source"], "family": j["family"], **blank(), "total": 0, "jobs": set()})
        add(pm, j)
        pm["total"] += j["total"]
        pm["jobs"].add(j["id"])
    for pm in per_model.values():
        pm["jobs"] = len(pm["jobs"])

    def group_total(src):
        status = c_status if src == "claude" else x_status
        if status["status"] != "ok":
            return None
        rows = [j for j in jobs if j["source"] == src]
        t = agg(rows)
        t["jobs"] = len({j["id"] for j in rows})
        return t

    by_family = {}
    for j in c_jobs:
        by_family.setdefault(j["family"], blank())
        add(by_family[j["family"]], j)
    for f in by_family.values():
        f["total"] = total(f)

    totals = {"claude": group_total("claude"), "codex": group_total("codex"),
              "by_claude_family": by_family if c_status["status"] == "ok" else None}
    ok = [t for t in (totals["claude"], totals["codex"]) if t]
    totals["all"] = ({"total": sum(t["total"] for t in ok), "jobs": sum(t["jobs"] for t in ok)} if ok else None)
    totals["approximate"] = bool(c_approx or x_approx)

    now = dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")
    top = sorted(jobs, key=lambda j: j["total"], reverse=True)[:max_jobs]
    top.sort(key=lambda j: j["last_at"] or "", reverse=True)
    snapshot = {
        "at": now, "approximate": totals["approximate"],
        "sources": {"claude": c_status["status"], "codex": x_status["status"]},
        "totals": {"claude": totals["claude"] and totals["claude"]["total"],
                   "codex": totals["codex"] and totals["codex"]["total"],
                   "all": totals["all"] and totals["all"]["total"],
                   "jobs": totals["all"] and totals["all"]["jobs"]},
        "by_model": [{"model": m, "group": v["group"], "family": v["family"], "total": v["total"], "jobs": v["jobs"]}
                     for m, v in sorted(per_model.items(), key=lambda kv: -kv[1]["total"])],
        "jobs": [{"label": j["label"], "model": j["model"], "source": j["source"], "in": j["in"], "out": j["out"],
                  "cache": j["cache_read"] + j["cache_write"], "at": (j["last_at"] or "")[:10]} for j in top],
        "jobs_omitted": max(len(jobs) - len(top), 0),
    }
    out = {"schema": "project-map-usage-1", "root": root, "since": since.isoformat() if since else None,
           "generated_at": now, "sources": {"claude": c_status, "codex": x_status},
           "totals": totals, "per_model": per_model, "per_job_count": len(jobs),
           "per_job": top, "snapshot_for_state": snapshot}
    print(json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
