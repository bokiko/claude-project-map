#!/usr/bin/env python3
"""project-map-usage.py - token/model usage collector for the project-map agent (incremental since 3.3.0).

Usage:  python3 project-map-usage.py <project-root> [--since ISO8601] [--max-jobs N] [--budget S] [--cache PATH|none]

Reads (session records are never modified; the result goes to stdout):
  Claude Code  ~/.claude/projects/**/<session>.jsonl and <session>/subagents/agent-*.jsonl
               assistant records: message.model + message.usage (input/output/cache tokens)
  Codex CLI    ~/.codex/sessions/**/rollout-*.jsonl
               event_msg/token_count (cumulative total_token_usage) + turn_context.model
Transcripts hold conversation text and other projects' paths. Nothing of that leaves this script except counters (see
"Output allowlist" below).

Attribution to the project (documented, approximate where noted):
  1. Claude: a record counts when the cwd it carries (or the last cwd seen in that file) is the
     project root or inside it. attribution = "cwd".
  1b. Claude subagent (.../<session>/subagents/agent-*.jsonl) with no cwd match of its own inherits
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

Output allowlist (3.3.0). stdout, the last-result file, and everything the callers copy from them (snapshot, pack, state,
page, brief) carry only: per-model totals, per-job rows (id, source, kind, label, model, family, attribution, msgs, first/last
time, token counts) and counts. A job label is the Claude session's ai-title ONLY when the session's cwd is the root itself
(attribution "cwd", a main session); every other label is generic ("Claude session <id8>", "Codex session <id8>"). User
messages, transcript paths, other projects' working directories and subagent descriptions are never output, and Codex user
text is not even kept in the cache. Every label passes pm_common.display_safe.

Incremental scan (3.3.0). A full scan reads and parses every transcript (1+ GB for a heavy user, 4-7 s), too slow for a
hook. The script keeps a per-root cache in the plugin's PRIVATE directory ~/.claude/agent-memory/project-map/usage/ (mode
0700; the guard denies the map agent any read of it), never inside the project:
  <sha256(realpath root)>-cache.json   per transcript path: size, mtime_ns, a fingerprint of the committed prefix, the
                     attribution state, the resumable parse state (Claude: message id -> last usage row; Codex: counters per
                     turn) and the finished job rows. Written only when something changed, atomically (random temp file in
                     the same folder, fsync, rename), mode 0600. Serialized size is capped at ~24 MB: completed results are
                     evicted first (their parse state; then whole entries, least recently seen first, which are FOLDED into a
                     compact record keyed by the hash of the path, with the size, mtime and file identity (device, inode, ctime_ns) they were read at
                     and the rest of the path digest, which is compared on reuse so a key collision can never substitute another
                     file's rows; a settled file excluded from this project folds too, with zero rows): the "folded"
                     bucket keeps their totals and job rows, so the aggregate is always folded + live entries and eviction never
                     throws work away; a folded file is reused while unchanged (size, mtime, identity, digest) and read again from byte 0 when any differs; only
                     when even the folded bucket does not fit are its oldest records dropped). The parse state of a file that is
                     still being scanned is never evicted; when the cap cannot be met the cache is not written and the run
                     reports scan.cache_partial. When compact records had to be dropped the run reports scan.cache_pressure true and scan.evicted_records N (convergence of budgeted runs needs the cap to hold the compact records plus the active state). The file also holds the scan cursor (per source, [phase, path] where the last
                     budgeted run stopped): the next run starts there, then reaches the files after it, then wraps around.
  <sha256>-last.json   the last COMPLETE result (small), so a run that runs out of budget can hand back the previous totals.
A transcript with the same size, mtime_ns and (device, inode, ctime_ns) is skipped (a rename-over that restores the mtime is another inode, an in-place rewrite that restores the mtime has another ctime, which user code cannot set: re-read). One that only grew is verified by fingerprinting the whole already-read
prefix (streaming, in fixed 1 MB blocks: a chained digest of the full blocks plus a plain hash of the last partial block) and only
the new bytes are parsed. The verification is RESUMABLE: after every block the verified position and the chain digest there are
saved, bound to the file's (device, inode, size, mtime_ns, ctime_ns) snapshot, so a run that runs out of budget leaves its progress and
the next run continues from it (any other state of the file starts over from byte 0; a rewrite is still found because the final
fingerprint must equal the committed one); a final line without newline is read tentatively every time
and never committed. Anything else (shrunk, same size with another mtime, prefix changed, attribution kind changed) is re-read
from byte 0. A file that changes while it is being read is dropped from this run (previous entry kept, run partial) unless it
only grew by appending (its committed prefix is hashed again to prove it). Deleted files drop out. Totals are exactly those
of a full scan: every file is processed by the same code whether it is new or resumed.
--budget S bounds the whole run (enumeration, cache load, every chunk, the final certification). When it runs out, the
progress so far is saved, and the output is the previous complete result with "partial": true (snapshot_for_state.partial,
as-of time = its "at"); with no previous result snapshot_for_state is null. Without --budget the scan always completes.
Output additions over 1.x: top-level "partial" (bool), "as_of" (only when partial) and "scan" (bytes_read, files, skipped,
incremental, full, reparsed, unstable, cache = off|cold|warm, cache_partial, cache_pressure, evicted_records, elapsed_s). Test hooks: PM_USAGE_SLOW=<seconds>
sleeps after every chunk read, PM_USAGE_CACHE_CAP=<bytes> lowers the cache cap, PM_USAGE_CHUNK=<bytes> lowers the chunk size, PM_USAGE_BLOCK=<bytes> the fingerprint block size, PM_USAGE_PKEY_LEN=<n> the folded-bucket key length (1 forces key collisions),
PM_USAGE_GATE=<dir> makes the first chunk wait (writes <dir>/reached, waits for <dir>/go; bounded 20 s).
The legacy ROOT/.project-map/usage-cache.json and usage-last.json (3.3.0 development builds) are deleted when found.
Stdlib only (plus the plugin's pm_common).
"""
import bisect, copy, hashlib, json, os, re, stat, sys, tempfile, time, datetime as dt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pm_common as C   # noqa: E402

MENTION_MIN = 25
HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude", "projects")
CODEX_DIR = os.path.join(HOME, ".codex", "sessions")
SKIP_CWD_FRAGMENT = "/.buzz"


def _env_int(name, default, lo):
    try:
        return max(lo, int(os.environ.get(name) or default))
    except ValueError:
        return default


CHUNK = _env_int("PM_USAGE_CHUNK", 8 * 1024 * 1024, 256)
BLK = _env_int("PM_USAGE_BLOCK", 1024 * 1024, 256)   # prefix fingerprint block size (part of the cache key)
CACHE_SCHEMA = "project-map-usage-cache-5"   # 5: file identity is (dev, inode, ctime_ns); folded records carry it + a path digest
LAST_SCHEMA = "project-map-usage-last-2"
PKEY_LEN = min(64, _env_int("PM_USAGE_PKEY_LEN", 24, 1))   # folded-bucket key length (test hook: 1 forces key collisions)
CACHE_CAP = 24 * 1024 * 1024
LAST_MAX = 8 * 1024 * 1024
ALLOW = 2           # snapshot_for_state["allow"]: the label allowlist version (older snapshots may carry free-text labels)
HIT, ANY, MEN, RM = 0, 1, 2, 3     # indexes into an entry's flag list


def _slow():
    try:
        return float(os.environ.get("PM_USAGE_SLOW") or 0)
    except ValueError:
        return 0.0


class Out(BaseException):
    """The time budget ran out (BaseException so no `except Exception` below can swallow it)."""


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
    """True when raw transcript bytes carry a "cwd" equal to root or inside it (not a sibling like root-2)."""
    return re.search(rb'"cwd":"' + re.escape(rootb) + rb'(?:"|/)', raw) is not None


def blank():
    return {"in": 0, "out": 0, "cache_read": 0, "cache_write": 0}


def add(a, b):
    for k in ("in", "out", "cache_read", "cache_write"):
        a[k] += b[k]


def total(d):
    return d["in"] + d["out"] + d["cache_read"] + d["cache_write"]


def read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


def loadline(line):
    """One JSONL line (bytes) -> object, or None for a blank/partial/invalid line."""
    try:
        return json.loads(line)
    except UnicodeDecodeError:
        try:
            return json.loads(line.decode("utf-8", "replace"))
        except Exception:
            return None
    except Exception:
        return None


def ident(s):
    """The snapshot of a file: (device, inode, size, mtime_ns, ctime_ns). ctime_ns is set by the kernel on every change of
    the content or the metadata and cannot be set from user space, so an in-place rewrite that keeps the inode and the size
    and restores the mtime (os.utime) still differs from the snapshot taken before it."""
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


class Chain(object):
    """Fingerprint of a committed prefix in fixed BLK-byte blocks: cd = sha256(cd + sha256(block)) after every full block, and
    the trailing partial block is a plain sha256 beside it. Because only whole blocks fold into cd, a verification that ran out
    of budget can resume at a block boundary from (position, cd) and still end with exactly the fingerprint of a straight pass."""
    def __init__(self, cd=b"", cp=0):
        self.cd, self.cp, self.bh, self.fill = cd, cp, hashlib.sha256(), 0

    def feed(self, data):
        mv, i = memoryview(data), 0
        while i < len(mv):
            n = min(len(mv) - i, BLK - self.fill)
            self.bh.update(mv[i:i + n])
            self.fill += n
            i += n
            if self.fill == BLK:
                self.cd = hashlib.sha256(self.cd + self.bh.digest()).digest()
                self.cp += BLK
                self.bh, self.fill = hashlib.sha256(), 0

    def fingerprint(self):
        return hashlib.sha256(self.cd + self.bh.digest() + b"%d" % (self.cp + self.fill)).hexdigest()


def phash(path):
    """The full SHA-256 hex digest of a path (the cache never needs the path back)."""
    return hashlib.sha256(path.encode("utf-8", "surrogateescape")).hexdigest()


def pkey(path):
    """The key of a path in the folded bucket: the first PKEY_LEN hex digits of its digest. The rest of the digest is stored in
    the record ("h") and compared on reuse, so two paths that share a key can never be handed each other's rows."""
    return phash(path)[:PKEY_LEN]


# ---------------------------------------------------------------- scan context
class Ctx(object):
    def __init__(self, root, since, deadline):
        self.root, self.rootb, self.since = root, root.encode(), since
        self.deadline, self.old, self.new = deadline, {}, {}
        self.folded = {}     # pkey(path) -> folded record of a completed file that was evicted from `old` (see fold_entry)
        self.cur = {"c": None, "x": None}   # scan cursor per source: [phase, path] where the last budgeted run stopped
        self.at = None       # (source, [phase, path]) being visited; becomes the cursor when the budget runs out
        self.seq = 1
        self.hits = {}       # claude non-subagent path -> its transcript is a cwd hit (for subagent inheritance)
        self.dirty = False
        self.poisoned = False
        self.mutated = False  # a transcript changed while it was read: this run's answer is partial
        self.slow = _slow()
        self.gate = os.environ.get("PM_USAGE_GATE") or None
        self.rm_pat = re.compile(r"ROOT:\s*" + re.escape(root) + r"(?![\w./-])")
        self.stats = {"bytes_read": 0, "files": 0, "skipped": 0, "incremental": 0, "full": 0, "reparsed": 0, "unstable": 0}

    def tick(self):
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise Out()

    def read(self, fd, pos, n):
        fd.seek(pos)
        b = fd.read(n)
        self.stats["bytes_read"] += len(b)
        return b

    def nap(self):
        if self.slow:
            time.sleep(self.slow)

    def pause(self):
        if self.gate:   # test hook: stop after the first chunk was read, until the test says go
            g, self.gate = self.gate, None
            try:
                with open(os.path.join(g, "reached"), "w"):
                    pass
                end = time.monotonic() + 20
                while not os.path.exists(os.path.join(g, "go")) and time.monotonic() < end:
                    time.sleep(0.01)
            except OSError:
                pass
        self.nap()


def walk(ctx, base, suffix=".jsonl"):
    n = 0
    for dp, _dn, fn in os.walk(base):
        ctx.tick()
        for f in fn:
            n += 1
            if not n & 255:
                ctx.tick()
            if f.endswith(suffix):
                yield os.path.join(dp, f)


def chunks(ctx, fd, start, upto):
    """Yield (position_after, bytes) pieces of [start, upto) that end on a line boundary. A final piece without a
    newline is NOT yielded (it is the tentative tail); the budget is checked before every read."""
    pos = start
    while pos < upto:
        ctx.tick()
        data = ctx.read(fd, pos, min(CHUNK, upto - pos))
        if not data:
            return
        end = pos + len(data)
        cut = data.rfind(b"\n")
        while cut < 0 and end < upto:   # one huge line: keep reading until it ends
            ctx.tick()
            more = ctx.read(fd, end, min(CHUNK, upto - end))
            if not more:
                break
            data += more
            end += len(more)
            cut = data.rfind(b"\n")
        if cut < 0:
            return
        data = data[:cut + 1]
        pos += len(data)
        ctx.pause()
        yield pos, data


def fresh_entry():
    return {"sz": 0, "mt": 0, "off": 0, "ph": None, "vf": None, "fl": [0, 0, 0, None], "sn": 0, "u": 1,
            "po": 0, "pk": None, "st": None, "md": None, "jb": [], "cnt": 0, "apx": 0, "ok": 0}


def verify_prefix(ctx, fd, e, snap):
    """The Chain of the first e["off"] bytes as the file has them now, or None when the file is shorter. RESUMABLE: every
    completed block saves e["vf"] = {sn: snapshot, vp: verified position (a block boundary), vd: chain digest there} and marks
    the cache dirty, so a run that is out of budget leaves its progress behind and the next one continues from it. The saved
    progress is used only when it was made against exactly this snapshot (device, inode, size, mtime_ns, ctime_ns); any other state of the
    file starts over from byte 0, so progress made on one version of the file is never combined with bytes of another. Chunks
    committed by the parse loop advance vf the same way (those bytes were read from this snapshot while the chain was built).
    The caller compares the returned fingerprint with e["ph"]."""
    off = e["off"]
    cp = off - off % BLK
    vf = e.get("vf")
    pos, cd = 0, b""
    if isinstance(vf, dict) and vf.get("sn") == list(snap) and isinstance(vf.get("vp"), int) and 0 <= vf["vp"] <= cp \
            and vf["vp"] % BLK == 0:
        pos, cd = vf["vp"], bytes.fromhex(vf["vd"])
    ch = Chain(cd, pos)
    while pos < cp:
        blk, p, end = hashlib.sha256(), pos, pos + BLK
        while p < end:
            ctx.tick()
            b = ctx.read(fd, p, min(CHUNK, end - p))
            if not b:
                return None
            blk.update(b)
            p += len(b)
        ch.cd = hashlib.sha256(ch.cd + blk.digest()).digest()
        ch.cp = pos = end
        e["vf"] = {"sn": list(snap), "vp": pos, "vd": ch.cd.hex()}
        ctx.dirty = True
        ctx.nap()
    p = cp
    while p < off:     # the trailing partial block (less than BLK bytes): read again on every resume
        ctx.tick()
        b = ctx.read(fd, p, min(CHUNK, off - p))
        if not b:
            return None
        ch.feed(b)
        p += len(b)
    return ch


# ---------------------------------------------------------------- flags (attribution evidence), per chunk
def first_user_marker(ctx, data):
    """1 / 0 when this chunk holds the first user record (does its content say `ROOT: <root>`), else None."""
    for line in data.split(b"\n"):
        d = loadline(line)
        if isinstance(d, dict) and d.get("type") == "user":
            try:
                return 1 if ctx.rm_pat.search(json.dumps((d.get("message") or {}).get("content"), ensure_ascii=False)) else 0
            except Exception:
                return 0
    return None


def flag_update(ctx, fl, data, is_sub):
    if not fl[HIT] and cwd_in(data, ctx.rootb):
        fl[HIT] = 1
    if not fl[ANY] and b'"cwd":"' in data:
        fl[ANY] = 1
    fl[MEN] += data.count(ctx.rootb)
    if is_sub and fl[RM] is None and not fl[HIT]:
        fl[RM] = first_user_marker(ctx, data)


def claude_mode(fl, is_sub, parent_hit):
    hit = bool(fl[HIT])
    inh = bool(is_sub and not hit and (parent_hit or fl[RM] == 1))
    men = 0 if fl[ANY] else fl[MEN]    # a transcript that names a cwd elsewhere is never attributed by mentions
    if not hit and not inh and men < MENTION_MIN:
        return None
    return "cwd" if hit else ("inherited" if inh else "mentions")


def codex_mode(fl):
    if fl[HIT]:
        return "cwd"
    men = 0 if fl[ANY] else fl[MEN]
    return "mentions" if men >= MENTION_MIN else None


# ---------------------------------------------------------------- Claude: parse state + job rows
def claude_state():
    return {"cc": None, "title": None, "seen": {}}


def claude_clone(st):
    return {"cc": st["cc"], "title": st["title"], "seen": dict(st["seen"])}


def claude_record(ctx, st, d, kind):
    if not isinstance(d, dict):
        return
    try:
        if d.get("cwd"):
            st["cc"] = d["cwd"]
        t = d.get("type")
        if t == "ai-title" and d.get("aiTitle"):
            st["title"] = d["aiTitle"]
        if t != "assistant":
            return
        msg = d.get("message") or {}
        u = msg.get("usage")
        model = msg.get("model")
        if not u or not model or not isinstance(model, str) or model.startswith("<"):
            return
        if kind == "cwd" and not under(d.get("cwd") or st["cc"], ctx.root):
            return
        ts = parse_ts(d.get("timestamp"))
        if ctx.since and ts and ts < ctx.since:
            return
        key = msg.get("id") or d.get("uuid") or ""
        st["seen"][key] = [model, int(u.get("input_tokens") or 0), int(u.get("output_tokens") or 0),
                           int(u.get("cache_read_input_tokens") or 0), int(u.get("cache_creation_input_tokens") or 0),
                           ts.isoformat() if ts else None]
    except Exception:    # one malformed record never poisons the file
        return


def claude_apply(ctx, st, data, kind):
    for line in data.split(b"\n"):
        if line.strip():
            claude_record(ctx, st, loadline(line), kind)


def short_id(s):
    return C.display_safe(str(s)[:8], 16)


def claude_jobs(path, st, mode, is_sub):
    if not st["seen"]:
        return []
    per_model = {}   # model -> [tok, n, (t0 epoch, t0 iso), (t1 epoch, t1 iso)]
    for model, i, o, cr, cw, tsiso in st["seen"].values():
        pm = per_model.setdefault(model, [blank(), 0, None, None])
        add(pm[0], {"in": i, "out": o, "cache_read": cr, "cache_write": cw})
        pm[1] += 1
        ts = parse_ts(tsiso)
        if ts:
            ep = ts.timestamp()
            if pm[2] is None or ep < pm[2][0]:
                pm[2] = (ep, tsiso)
            if pm[3] is None or ep > pm[3][0]:
                pm[3] = (ep, tsiso)
    sid = os.path.basename(path)[:-6]
    if is_sub:   # the label never comes from the subagent's meta file (a task description is conversation content)
        kind = "subagent"
        label = "Claude session " + short_id(os.path.basename(os.path.dirname(os.path.dirname(path))))
    else:
        kind = "main"
        title = st["title"] if mode == "cwd" else None   # the ai-title only for a session that ran in the root itself
        label = C.display_safe(title, 80) if title else "Claude session " + short_id(sid)
    jobs = []
    for model, (tok, n, t0, t1) in per_model.items():
        jobs.append({
            "id": "claude:" + sid, "source": "claude", "kind": kind, "label": label,
            "model": model, "family": family(model),
            "attribution": mode, "msgs": n,
            "first_at": t0[1] if t0 else None, "last_at": t1[1] if t1 else None,
            **tok, "total": total(tok),
        })
    return jobs


# ---------------------------------------------------------------- Codex: parse state + job rows
def codex_state(path):
    return {"sid": os.path.basename(path)[:-6], "model": None, "prev": None, "skip": False, "turn": "0", "turn_n": 0,
            "pt": {}}   # pt: json([turn, turn_n, model]) -> [tok, n, t0 [epoch, iso], t1 [epoch, iso]]


def codex_clone(st):
    return json.loads(json.dumps(st))


def codex_record(ctx, st, d):
    if not isinstance(d, dict):
        return
    try:
        t = d.get("type")
        p = d.get("payload") or {}
        if t == "session_meta":
            if SKIP_CWD_FRAGMENT in (p.get("cwd") or ""):
                st["skip"] = True
                return
            st["sid"] = p.get("id") or st["sid"]
        elif t == "turn_context":
            st["model"] = p.get("model") or st["model"]
            if p.get("turn_id") and p["turn_id"] != st["turn"]:
                st["turn"] = p["turn_id"]
                st["turn_n"] += 1
        elif t == "event_msg" and p.get("type") == "token_count":
            info = p.get("info") or {}
            cur = info.get("total_token_usage")
            if not cur:
                return
            cur = {k: int(cur.get(k) or 0) for k in
                   ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens")}
            prev = st["prev"]
            if prev is None or any(cur[k] < prev[k] for k in cur):
                delta = cur  # first event, or counter reset
            else:
                delta = {k: cur[k] - prev[k] for k in cur}
            st["prev"] = cur
            ts = parse_ts(d.get("timestamp"))
            if ctx.since and ts and ts < ctx.since:
                return
            cached = delta["cached_input_tokens"]
            row = {"in": max(delta["input_tokens"] - cached, 0), "out": delta["output_tokens"],
                   "cache_read": cached, "cache_write": delta["cache_write_input_tokens"]}
            key = json.dumps([st["turn"], st["turn_n"], st["model"] or "unknown"])
            pm = st["pt"].setdefault(key, [blank(), 0, None, None])
            add(pm[0], row)
            pm[1] += 1
            if ts:
                ep, iso = ts.timestamp(), ts.isoformat()
                if pm[2] is None or ep < pm[2][0]:
                    pm[2] = [ep, iso]
                if pm[3] is None or ep > pm[3][0]:
                    pm[3] = [ep, iso]
    except Exception:
        return


def codex_apply(ctx, st, data):
    for line in data.split(b"\n"):
        if st["skip"]:
            return
        if line.strip():
            codex_record(ctx, st, loadline(line))


def codex_jobs(st, mode):
    if st["skip"] or not st["pt"]:
        return [], 0
    jobs = []
    label = "Codex session " + short_id(st["sid"])
    for key, (tok, n, t0, t1) in st["pt"].items():
        tid, tn, m = json.loads(key)
        if total(tok) == 0:
            continue
        jobs.append({
            "id": "codex:%s:%s" % (st["sid"], str(tid)[:8]), "source": "codex", "kind": "turn",
            "label": label,
            "model": m, "family": m, "attribution": mode, "msgs": n,
            "first_at": t0[1] if t0 else None, "last_at": t1[1] if t1 else None,
            **tok, "total": total(tok),
        })
    return jobs, 1


# ---------------------------------------------------------------- one transcript
def visit(ctx, path, src, is_sub=False, parent_hit=False):
    """Bring the cache entry of `path` up to date -> (entry, cwd_hit) or (None, False) when unreadable.
    Raises Out when the budget runs out; every entry is left consistent at chunk boundaries. A cache entry that does
    not fit the code (damaged file, older layout) is thrown away and the transcript is read from byte 0."""
    ctx.stats["files"] += 1
    try:
        return visit_one(ctx, path, src, is_sub, parent_hit, True)
    except (KeyError, TypeError, ValueError, IndexError):
        ctx.old.pop(path, None)
        ctx.folded.pop(pkey(path), None)
        return visit_one(ctx, path, src, is_sub, parent_hit, False)


def settled(ctx, path, fd, s0, e):
    """True when the bytes this visit used are still the file: its identity (device, inode), size and mtime are unchanged, or
    it is the same file that only grew and its committed prefix hashes as it did while it was read (a live session being
    appended to). A rewrite, a truncation or a replacement by another file is not settled."""
    try:
        s1, s2 = os.stat(path), os.fstat(fd.fileno())
    except OSError:
        return False
    if ident(s1) == ident(s0) and ident(s2) == ident(s0):
        return True
    if (s1.st_dev, s1.st_ino) != (s0.st_dev, s0.st_ino) or (s2.st_dev, s2.st_ino) != (s0.st_dev, s0.st_ino):
        return False    # the path now names another file
    if e["off"] == 0:   # nothing was committed from it: a tentative tail is recomputed on every visit
        return True
    if s1.st_size < s0.st_size or s2.st_size < s0.st_size:
        return False
    h = verify_prefix(ctx, fd, e, ident(s2))
    return h is not None and h.fingerprint() == e["ph"]


def visit_one(ctx, path, src, is_sub, parent_hit, use_old):
    try:
        s = os.stat(path)
    except OSError:
        ctx.old.pop(path, None)
        return None, False
    size, mt = s.st_size, s.st_mtime_ns
    old = ctx.old.get(path) if use_old else None
    di = [s.st_dev, s.st_ino, s.st_ctime_ns]   # file identity of a completed entry: inode AND ctime (see ident)
    if old is None and ctx.folded:    # a completed file that was folded out of the cache: reused only while it is unchanged
        k = pkey(path)
        rec = ctx.folded.get(k)
        if isinstance(rec, dict) and rec.get("h") != phash(path)[len(k):]:
            rec = None    # the record of another path that shares the short key: not ours, left alone (that file is read again)
        elif rec is not None:
            ctx.folded.pop(k, None)
        if rec is not None and use_old and rec["z"] == size and rec["m"] == mt and rec.get("i") == di:
            old = unfold_entry(rec, ctx.seq)
            ctx.old[path] = old
    e = old
    fd = None
    prev = None

    def unstable():
        ctx.mutated = True
        ctx.stats["unstable"] += 1
        keep = prev if prev is not None else old   # `old` is untouched as long as no copy was taken
        if keep is not None:
            ctx.old[path] = keep
            return keep, bool(keep["fl"][HIT])
        ctx.old.pop(path, None)
        return None, False

    def opened():
        f = open(path, "rb")
        if ident(os.fstat(f.fileno())) != ident(s):   # replaced between the stat and the open
            f.close()
            return None
        return f

    try:
        try:
            if e is not None:
                e["sn"] = ctx.seq
            fast = bool(e) and e["sz"] == size and e["mt"] == mt and e["off"] == size and e.get("di") == di
            h = None
            if not fast:
                fd = opened()
                if fd is None:
                    return unstable()
                # same size and mtime but another (device, inode) is another file (rename-over with a restored mtime): re-read
                same = e is not None and e["sz"] == size and e["mt"] == mt and e.get("di") == di
                # same size with another mtime proves nothing about the middle: re-read; a shorter file than the committed prefix too
                cont = e is not None and size >= e["off"] and not (e["sz"] == size and not same)
                if cont and e["off"] > 0:
                    need = True
                    if same:   # nothing changed since the last visit: trust the prefix unless complete lines wait to be read
                        need = b"\n" in ctx.read(fd, e["off"], size - e["off"])
                    if need:   # resumable: a run that is out of budget saves how far it got (e["vf"], bound to this snapshot)
                        h = verify_prefix(ctx, fd, e, ident(s))
                        cont = h is not None and h.fingerprint() == e["ph"]
                elif cont:
                    h = Chain()
                prev = copy.deepcopy(old) if old is not None else None
                if cont:
                    ctx.stats["incremental"] += 1
                else:
                    e = fresh_entry()
                    h = Chain()
                    ctx.stats["full"] += 1
                ctx.old[path] = e
                e["sz"], e["mt"], e["ok"], e["u"], e["sn"], e["di"] = size, mt, 0, 1, ctx.seq, di
                ctx.dirty = True
                for pos, data in chunks(ctx, fd, e["off"], size):
                    if h is None:
                        h = verify_prefix(ctx, fd, e, ident(s))
                        if h is None:
                            return unstable()
                    flag_update(ctx, e["fl"], data, is_sub)
                    h.feed(data)
                    e["ph"], e["off"], e["ok"] = h.fingerprint(), pos, 0
                    e["vf"] = {"sn": list(ident(s)), "vp": h.cp, "vd": h.cd.hex()}   # these bytes were just read from this snapshot
            else:
                ctx.stats["skipped"] += 1
            fl = list(e["fl"])
            tail = b""
            if e["off"] < size:   # a last line without newline: read tentatively, never committed
                tail = ctx.read(fd, e["off"], size - e["off"])
                flag_update(ctx, fl, tail, is_sub)
            mode = claude_mode(fl, is_sub, parent_hit) if src == "claude" else codex_mode(fl)
            if mode is None:
                if fd is not None and not settled(ctx, path, fd, s, e):
                    return unstable()
                if e["st"] is not None or e["po"] or e["jb"] or e["md"] is not None:
                    ctx.dirty = True
                e.update(po=0, pk=None, st=None, md=None, jb=[], cnt=0, apx=0, ok=0 if tail else 1, u=0)
                return e, bool(fl[HIT])
            kind = "cwd" if (src == "claude" and mode == "cwd") else "all"
            if e["ok"] and e["md"] == mode and e["pk"] == kind and e["po"] == e["off"] and not tail:
                e["u"] = 0
                return e, bool(fl[HIT])
            ctx.dirty = True
            if prev is None and old is not None:
                prev = copy.deepcopy(old)
            if fd is None:
                fd = opened()
                if fd is None:
                    return unstable()
            if e["pk"] != kind or e["st"] is None or e["po"] > e["off"]:
                e["pk"], e["po"] = kind, 0
                e["st"] = claude_state() if src == "claude" else codex_state(path)
                ctx.stats["reparsed"] += 1   # parsed from byte 0 (new file, attribution kind changed, parse state evicted)
            e["ok"] = 0
            st = e["st"]
            if src == "codex" and st["skip"]:
                e["po"] = e["off"]
            else:
                for pos, data in chunks(ctx, fd, e["po"], e["off"]):
                    if src == "claude":
                        claude_apply(ctx, st, data, kind)
                    else:
                        codex_apply(ctx, st, data)
                    e["po"] = pos
                    if src == "codex" and st["skip"]:
                        e["po"] = e["off"]
                        break
            if src == "claude":
                view = st
                if tail:
                    view = claude_clone(st)
                    claude_record(ctx, view, loadline(tail), kind)
                jobs = claude_jobs(path, view, mode, is_sub)
                cnt = 1 if jobs else 0
            else:
                view = st
                if tail and not st["skip"]:
                    view = codex_clone(st)
                    codex_record(ctx, view, loadline(tail))
                jobs, cnt = codex_jobs(view, mode)
            if not settled(ctx, path, fd, s, e):   # the file was rewritten while it was read: nothing of it is trusted
                return unstable()
            e.update(md=mode, jb=jobs, cnt=cnt, apx=1 if (cnt and mode == "mentions") else 0, ok=0 if tail else 1, u=0)
            return e, bool(fl[HIT])
        except OSError:   # vanished or unreadable meanwhile
            ctx.old.pop(path, None)
            return None, False
    finally:
        if fd is not None:
            fd.close()


def parent_of(path):
    return os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(path))),
                        os.path.basename(os.path.dirname(os.path.dirname(path))) + ".jsonl")


def rotate(keys, cursor):
    """keys is sorted ascending ((phase, path) tuples). Start at the cursor (where the last budgeted run stopped), then the keys
    after it, then wrap to the ones before it. A cursor that no longer names a file starts at the next key after it."""
    try:
        cur = (int(cursor[0]), str(cursor[1]))
    except (TypeError, ValueError, IndexError, KeyError):
        return keys
    i = bisect.bisect_left(keys, cur)
    return keys[i:] + keys[:i]


def collect_claude(ctx):
    if not os.path.isdir(CLAUDE_DIR):
        return {"status": "unavailable", "reason": "no ~/.claude/projects"}, [], False
    paths = sorted(walk(ctx, CLAUDE_DIR))
    pset = set(paths)
    res = {}
    # sessions first (phase 0): a subagent's (phase 1) inheritance reads its parent session's cwd evidence
    keys = sorted((1 if "/subagents/" in p else 0, p) for p in paths)

    def parent_hit(parent):
        if parent in ctx.hits:
            return ctx.hits[parent]
        if parent in pset and "/subagents/" not in parent and parent not in res:   # rotated order: the parent is visited now
            res[parent], ctx.hits[parent] = visit(ctx, parent, "claude", False, False)
            return ctx.hits[parent]
        praw = read_bytes(parent)
        return praw is not None and cwd_in(praw, ctx.rootb)

    for phase, path in rotate(keys, ctx.cur.get("c")):
        ctx.at = ("c", [phase, path])
        ctx.tick()
        if path in res:
            continue
        is_sub = phase == 1
        ph = parent_hit(parent_of(path)) if is_sub else False
        e, hit = visit(ctx, path, "claude", is_sub, ph)
        res[path] = e
        if not is_sub:
            ctx.hits[path] = hit
    ctx.cur["c"], ctx.at = None, None
    jobs, attributed, approx, approx_n = [], 0, False, 0
    for path in paths:
        e = res.get(path)
        if e is None:
            continue
        ctx.new[path] = e
        if e["cnt"]:
            attributed += 1
            jobs += e["jb"]
            if e["apx"]:
                approx = True
                approx_n += 1
    st = {"status": "ok", "files_scanned": len(paths), "jobs_attributed": attributed}
    if approx_n:
        st["approximate_files"] = approx_n   # a count: which transcripts they are is not output
    return st, jobs, approx


def collect_codex(ctx):
    if not os.path.isdir(CODEX_DIR):
        return {"status": "unavailable", "reason": "no ~/.codex/sessions"}, [], False
    paths = sorted(walk(ctx, CODEX_DIR))
    res = {}
    for phase, path in rotate([(0, p) for p in paths], ctx.cur.get("x")):
        ctx.at = ("x", [phase, path])
        ctx.tick()
        e, _hit = visit(ctx, path, "codex")
        res[path] = e
    ctx.cur["x"], ctx.at = None, None
    jobs, attributed, approx = [], 0, False
    for path in paths:
        e = res.get(path)
        if e is None:
            continue
        ctx.new[path] = e
        if e["cnt"]:
            attributed += 1
            jobs += e["jb"]
            if e["apx"]:
                approx = True
    return {"status": "ok", "files_scanned": len(paths), "jobs_attributed": attributed}, jobs, approx


# ---------------------------------------------------------------- cache files (private directory)
def cache_key(root, since):
    return {"schema": CACHE_SCHEMA, "root": root, "since": since.isoformat() if since else None,
            "claude": CLAUDE_DIR, "codex": CODEX_DIR, "blk": BLK}


# A completed transcript that no longer fits the cache is not forgotten: it is folded into a compact record keyed by the hash of
# its path, with the size and mtime it was read at. Folded records stay in the cache (the "folded bucket"); the aggregate of a
# root is always folded bucket + live entries. An unchanged file is reused from its record without being opened; a changed one
# (size or mtime differs, or its attribution evidence now says something else) is read again from byte 0. The record has no
# prefix fingerprint or parse state, so a file that merely grew is re-read as well.
def foldable(e):
    if e.get("u") or e.get("ok") != 1 or e.get("off") != e.get("sz"):
        return False
    if e.get("md") is None:    # settled and excluded from this project: nothing was parsed (po 0), nothing to keep but the flags
        return not e.get("jb") and not e.get("cnt") and e.get("st") is None
    return e.get("po") == e.get("off")


def fold_entry(e, h):
    rows = [[j["id"], j["kind"], j["label"], j["model"], j["msgs"], j["first_at"], j["last_at"],
             j["in"], j["out"], j["cache_read"], j["cache_write"]] for j in e["jb"]]
    return {"z": e["sz"], "m": e["mt"], "i": e.get("di"), "h": h, "f": e["fl"], "k": e["pk"], "d": e["md"], "c": e["cnt"], "a": e["apx"],
            "s": e.get("sn", 0), "j": rows}


def unfold_entry(rec, seq):
    md = rec["d"]
    jobs = []
    for jid, kind, label, model, msgs, t0, t1, i, o, cr, cw in rec["j"]:
        codex = jid.startswith("codex:")
        jobs.append({"id": jid, "source": "codex" if codex else "claude", "kind": kind, "label": label, "model": model,
                     "family": model if codex else family(model), "attribution": md, "msgs": msgs,
                     "first_at": t0, "last_at": t1, "in": i, "out": o, "cache_read": cr, "cache_write": cw,
                     "total": i + o + cr + cw})
    return {"sz": rec["z"], "mt": rec["m"], "off": rec["z"], "ph": None, "vf": None, "fl": list(rec["f"]), "sn": seq, "u": 0, "di": rec["i"],
            "po": rec["z"] if md is not None else 0, "pk": rec["k"], "st": None, "md": md, "jb": jobs, "cnt": rec["c"], "apx": rec["a"], "ok": 1}


def cache_cap():
    return _env_int("PM_USAGE_CACHE_CAP", CACHE_CAP, 1)   # test hook: force the eviction


def private_paths(root):
    """(cache path, last path) in the plugin's private usage directory, or (None, None) when it cannot be made safe: it is
    created 0700 and must be a real directory (never a symlink) owned by this user."""
    d = C.usage_private_dir()
    try:
        os.makedirs(os.path.dirname(d), mode=0o700, exist_ok=True)
        try:
            os.mkdir(d, 0o700)
        except FileExistsError:
            pass
        s = os.lstat(d)
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid():
            return None, None
        if stat.S_IMODE(s.st_mode) != 0o700:
            os.chmod(d, 0o700)
    except OSError:
        return None, None
    h = hashlib.sha256(root.encode()).hexdigest()
    return os.path.join(d, h + "-cache.json"), os.path.join(d, h + "-last.json")


def load_json_file(path, limit):
    try:
        if os.path.getsize(path) > limit:
            return None
        with open(path, "r") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def load_cache(path, key, cap):
    """-> (live entries, folded bucket, scan cursor, warm, seq)"""
    d = load_json_file(path, cap) if path else None
    if d and d.get("key") == key and isinstance(d.get("files"), dict):
        seq = d.get("seq")
        folded = d.get("folded")
        cur = d.get("cur")
        cur = {"c": cur.get("c"), "x": cur.get("x")} if isinstance(cur, dict) else {"c": None, "x": None}
        return (d["files"], folded if isinstance(folded, dict) else {}, cur, True,
                (seq if isinstance(seq, int) and seq >= 0 else 0))
    return {}, {}, {"c": None, "x": None}, False, 0


def write_atomic(path, body):
    """Random, exclusively created temp file in the destination folder (never a predictable name, never a followed
    symlink), mode 0600, fsync, rename over the destination."""
    d, b = os.path.split(path)
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix="." + b + ".", suffix=".tmp", dir=d)
        try:
            os.fchmod(fd, 0o600)
            fh = os.fdopen(fd, "w")
        except BaseException:
            os.close(fd)
            raise
        with fh:
            fh.write(body)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = None
        return True
    except OSError:
        return False
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def tidy_temp(path):
    """Remove temp files of killed runs (older than an hour) next to the cache."""
    d, b = os.path.split(path)
    try:
        for n in os.listdir(d):
            p = os.path.join(d, n)
            if n.startswith("." + b + ".") and n.endswith(".tmp") and time.time() - os.lstat(p).st_mtime > 3600:
                os.unlink(p)
    except OSError:
        pass


def save_cache(path, key, files, seq, cap, folded=None, cur=None, info=None):
    """Write the cache within `cap` serialized bytes -> (written, evicted entries). Order of eviction: the parse state of
    completed files; then completed files entirely, least recently seen first (a file with nothing left to resume is FOLDED into
    `folded`, which keeps its totals and job rows; only a file with an unfinished tail is dropped); then, when even the folded
    bucket does not fit, its least recently seen records. An unfinished entry (a transcript still being scanned) is never
    evicted; when they alone exceed the cap nothing is written (the previous cache file stays) and the caller reports the cache
    as partial. `files` and `folded` are updated in place. `info`, when given, receives "evicted_records": how many compact
    (folded or foldable) records were dropped for good to meet the cap (cache pressure: those files are read again)."""
    folded = {} if folded is None else folded
    dropped = 0
    head = json.dumps({"key": key, "seq": seq, "cur": cur, "files": {}, "folded": {}}, separators=(",", ":"))

    def esize(k, v):
        return len(json.dumps(k)) + len(json.dumps(v, separators=(",", ":"))) + 2

    sizes = {p: esize(p, e) for p, e in files.items()}
    fsizes = {k: esize(k, r) for k, r in folded.items()}
    est = len(head) + sum(sizes.values()) + sum(fsizes.values())
    evicted = 0
    if est > cap:
        done = sorted((p for p, e in files.items() if not e.get("u")), key=lambda p: (files[p].get("sn", 0), -files[p].get("sz", 0), p))
        for p in done:
            if est <= cap:
                break
            if files[p].get("st") is not None:
                files[p]["st"] = None
                ns = esize(p, files[p])
                est -= sizes[p] - ns
                sizes[p] = ns
        fresh = set()
        for p in done:
            if est <= cap:
                break
            est -= sizes.pop(p)
            if foldable(files[p]):
                k = pkey(p)
                folded[k] = fold_entry(files[p], phash(p)[len(k):])
                fsizes[k] = esize(k, folded[k])
                est += fsizes[k]
                fresh.add(k)
            del files[p]
            evicted += 1
        for k in sorted(folded, key=lambda k: (folded[k].get("s", 0), k)):
            if est <= cap:
                break
            est -= fsizes.pop(k)
            del folded[k]
            dropped += 1
            if k not in fresh:
                evicted += 1
        if info is not None:
            info["evicted_records"] = dropped
        if est > cap:
            return False, evicted
    body = json.dumps({"key": key, "seq": seq, "cur": cur, "files": files, "folded": folded}, separators=(",", ":"))
    if len(body) > cap:
        return False, evicted
    ok = write_atomic(path, body)
    if ok:
        tidy_temp(path)
    return ok, evicted


# ---------------------------------------------------------------- aggregate (the output allowlist)
def agg(rows):
    t = blank()
    for r in rows:
        add(t, r)
    t["total"] = total(t)
    return t


def _s(v, n):
    return C.display_safe(str(v), n)


def _t(v):
    return v if (isinstance(v, str) and parse_ts(v)) else None


def _i(v):
    try:
        return max(int(v), 0)
    except (TypeError, ValueError):
        return 0


def safe_job(j):
    """The ONLY shape a job row has once it leaves the cache: counters, ids and display-safe short strings."""
    r = {"id": _s(j["id"], 80), "source": "codex" if j["source"] == "codex" else "claude", "kind": _s(j["kind"], 16),
         "label": _s(j["label"], 80), "model": _s(j["model"], 80), "family": _s(j["family"], 40),
         "attribution": _s(j["attribution"], 16), "msgs": _i(j["msgs"]),
         "first_at": _t(j["first_at"]), "last_at": _t(j["last_at"])}
    for k in ("in", "out", "cache_read", "cache_write"):
        r[k] = _i(j[k])
    r["total"] = r["in"] + r["out"] + r["cache_read"] + r["cache_write"]
    return r


def build_output(root, since, max_jobs, c_status, c_jobs, c_approx, x_status, x_jobs, x_approx):
    c_jobs = [safe_job(j) for j in c_jobs]
    x_jobs = [safe_job(j) for j in x_jobs]
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
        "at": now, "approximate": totals["approximate"], "allow": ALLOW,
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
    return {"schema": "project-map-usage-1", "root": root, "since": since.isoformat() if since else None,
            "generated_at": now, "sources": {"claude": c_status, "codex": x_status},
            "totals": totals, "per_model": per_model, "per_job_count": len(jobs),
            "per_job": top, "snapshot_for_state": snapshot, "partial": False}


def main(argv):
    t0 = time.monotonic()
    if len(argv) < 2 or not argv[1].startswith("/"):
        print(json.dumps({"error": "usage: project-map-usage.py <abs project root> [--since ISO] [--max-jobs N] [--budget S] [--cache PATH|none]"}))
        return 2
    root = os.path.realpath(argv[1]).rstrip("/")
    since, max_jobs, budget, cache_arg = None, 15, None, None
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
        elif argv[i] == "--budget" and i + 1 < len(argv):
            try:
                budget = float(argv[i + 1])
            except ValueError:
                budget = -1
            if not 0 < budget < 3600:
                print(json.dumps({"error": "bad --budget"}))
                return 2
            i += 2
        elif argv[i] == "--cache" and i + 1 < len(argv):
            cache_arg = argv[i + 1]
            i += 2
        else:
            print(json.dumps({"error": "unknown argument " + argv[i]}))
            return 2

    C.sweep_legacy_usage(os.path.join(root, ".project-map"))   # 3.3.0 migration: the cache used to live in ROOT
    if cache_arg == "none":
        cache_path = last_path = None
    elif cache_arg:
        cache_path, last_path = cache_arg, cache_arg + ".last"
    else:
        cache_path, last_path = private_paths(root)
    key = cache_key(root, since)
    cap = cache_cap()
    deadline = None if budget is None else t0 + max(budget * 0.8, budget - 0.3)   # the rest is for saving and printing
    hard = None if budget is None else t0 + budget
    ctx = Ctx(root, since, deadline)

    complete, loaded, warm, was_cur = True, False, False, None
    c_status = x_status = None
    try:
        if cache_path:
            ctx.old, ctx.folded, ctx.cur, warm, seq = load_cache(cache_path, key, cap)
            ctx.seq, loaded = seq + 1, True
            was_cur = dict(ctx.cur)
            ctx.tick()
        try:
            c_status, c_jobs, c_approx = collect_claude(ctx)
        except Exception as e:  # never crash the agent run
            c_status, c_jobs, c_approx = {"status": "unavailable", "reason": type(e).__name__}, [], False
            ctx.poisoned = True
        try:
            x_status, x_jobs, x_approx = collect_codex(ctx)
        except Exception as e:
            x_status, x_jobs, x_approx = {"status": "unavailable", "reason": type(e).__name__}, [], False
            ctx.poisoned = True
        ctx.tick()   # the last chunk may have used the whole budget: never certify a complete result past it
    except Out:
        complete = False
        if ctx.at:     # the next run starts where this one stopped, then reaches the files after it, then wraps around
            ctx.cur[ctx.at[0]] = ctx.at[1]
    if ctx.mutated:
        complete = False

    cache_partial = False
    pressure = {"evicted_records": 0}
    if cache_path and loaded and not ctx.poisoned:
        if complete:   # deleted files drop out (every present file was visited, so a folded record left over is a deleted file)
            gone = [p for p in ctx.old if p not in ctx.new]
            for p in gone:
                del ctx.old[p]
            ctx.dirty = ctx.dirty or bool(gone) or bool(ctx.folded)
            ctx.folded = {}
            ctx.cur = {"c": None, "x": None}
        if ctx.cur != was_cur:
            ctx.dirty = True
        if ctx.dirty or not warm:
            written, _ev = save_cache(cache_path, key, ctx.old, ctx.seq, cap, ctx.folded, ctx.cur, pressure)
            cache_partial = not written

    out = None
    if complete:
        out = build_output(root, since, max_jobs, c_status, c_jobs, c_approx, x_status, x_jobs, x_approx)
        if hard is not None and time.monotonic() >= hard:   # aggregation overran: not certified
            complete, out = False, None
    last_key = {"schema": LAST_SCHEMA, "root": root, "since": key["since"], "max_jobs": max_jobs,
                "claude": CLAUDE_DIR, "codex": CODEX_DIR}
    if complete:
        if last_path and not ctx.poisoned:
            write_atomic(last_path, json.dumps({"key": last_key, "out": out}, separators=(",", ":")))
    else:
        d = load_json_file(last_path, LAST_MAX) if last_path else None
        if d and d.get("key") == last_key and isinstance(d.get("out"), dict) and isinstance(d["out"].get("snapshot_for_state"), dict):
            out = d["out"]
            out["partial"] = True
            out["as_of"] = out.get("generated_at")
            out["snapshot_for_state"]["partial"] = True
        else:
            out = {"schema": "project-map-usage-1", "root": root, "since": key["since"], "generated_at": None,
                   "partial": True, "as_of": None, "snapshot_for_state": None}
    ctx.stats["cache"] = "off" if not cache_path else ("warm" if warm else "cold")
    if cache_partial:
        ctx.stats["cache_partial"] = True
    if cache_path:   # cache pressure: compact records had to be dropped to meet the cap, so convergence is not guaranteed
        ctx.stats["cache_pressure"] = pressure["evicted_records"] > 0
        ctx.stats["evicted_records"] = pressure["evicted_records"]
    ctx.stats["elapsed_s"] = round(time.monotonic() - t0, 3)
    if budget is not None:
        ctx.stats["budget_s"] = budget
    out["scan"] = ctx.stats
    print(json.dumps(out, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
