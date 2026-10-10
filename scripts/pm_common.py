#!/usr/bin/env python3
"""pm_common: helpers shared by the project-map 3.2 scripts (facts, embed, collect, validate).

Stdlib only, Python 3.9+. Nothing here runs git (that is pm_git) or writes outside the paths it is given.
"""
import datetime as dt
import fcntl
import fnmatch
import hashlib
import hmac
import json
import os
import re
import secrets
import stat as _stat
import time

SCHEMA_STATE = "project-map-4"
SCHEMA_PLAN = "project-map-plan-1"
GEN_RE = re.compile(r"^gen-(\d{6})-([0-9a-f]{8})$")          # directory name
GENSTR_RE = re.compile(r"^(\d{6})-([0-9a-f]{8})$")           # <seq>-<id> as stored in files
INV_RE = re.compile(r"^inv-([0-9a-f]{8})$")
STABLE = ("index.html", "mobile.html", "brief.txt", "state.json")


class Busy(Exception):
    """Another process holds the publish lock."""


class Deadline(Exception):
    pass


# ---------------------------------------------------------------- time
def now():
    return dt.datetime.now().astimezone()


def iso(t=None, minute=False):
    t = t or now()
    return t.isoformat(timespec="minutes" if minute else "seconds")


_FRAC = re.compile(r"(\.\d+)")


def parse_iso(s):
    """ISO-8601 text -> aware datetime, or None. Accepts Z, any number of fractional digits, date-only, naive (local)."""
    if not isinstance(s, str) or not 8 <= len(s) <= 40:
        return None
    t = s.strip()
    if t.endswith(("Z", "z")):
        t = t[:-1] + "+00:00"
    t = _FRAC.sub(lambda m: (m.group(1) + "000000")[:7], t, count=1)
    try:
        d = dt.datetime.fromisoformat(t)
        return d.astimezone() if d.tzinfo is None else d.astimezone()
    except (ValueError, OverflowError, OSError):
        return None


class Clock(object):
    """Total wall budget. remaining() never negative; check() raises Deadline."""

    def __init__(self, total=None):
        self.t0 = time.monotonic()
        self.total = total

    def elapsed(self):
        return time.monotonic() - self.t0

    def remaining(self, cap=None):
        r = float("inf") if self.total is None else self.total - self.elapsed()
        if cap is not None:
            r = min(r, cap)
        return max(r, 0.0)

    def expired(self):
        return self.total is not None and self.elapsed() >= self.total

    def check(self):
        if self.expired():
            raise Deadline("deadline")


# ---------------------------------------------------------------- hashing / json
def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha12(b):
    return hashlib.sha256(b).hexdigest()[:12]


def _reject_const(x):
    raise ValueError("non-finite number %s" % x)


def loads(raw):
    """JSON text/bytes -> object; NaN/Infinity rejected; bytes must be UTF-8."""
    if isinstance(raw, (bytes, bytearray)):
        raw = bytes(raw).decode("utf-8")
    return json.loads(raw, parse_constant=_reject_const)


def load_json(path, default=None):
    try:
        with open(path, "rb") as fh:
            return loads(fh.read())
    except (OSError, ValueError):
        return default


def dumps(obj, indent=None, sort_keys=False):
    seps = (",", ":") if indent is None else (",", ": ")
    return json.dumps(obj, ensure_ascii=False, allow_nan=False, indent=indent, sort_keys=sort_keys, separators=seps)


def canon(obj):
    return dumps(obj, sort_keys=True)


def digest(obj):
    return sha12(canon(obj).encode("utf-8", "replace"))


# ---------------------------------------------------------------- bytes-aware strings
def blen(s):
    return len(s.encode("utf-8", "replace"))


def trim(s, n):
    """Cut to at most n bytes (UTF-8 boundary safe), '...' marker only when something was cut."""
    s = str(s)
    b = s.encode("utf-8", "replace")
    if len(b) <= n:
        return s
    return b[: max(n - 3, 0)].decode("utf-8", "ignore") + "..."


# ---------------------------------------------------------------- files
def fsync_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_file(path, data, mode=0o644, sync=True):
    """Plain (non-atomic) write used inside a not-yet-published directory; fsynced."""
    if isinstance(data, str):
        data = data.encode("utf-8", "replace")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            if sync:
                os.fsync(fh.fileno())
    except BaseException:
        raise


def atomic_write(path, data, mode=0o644):
    """tmp in the same directory + fsync + rename + directory fsync."""
    if isinstance(data, str):
        data = data.encode("utf-8", "replace")
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, ".%s.tmp.%d.%s" % (os.path.basename(path), os.getpid(), secrets.token_hex(3)))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.lexists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
    fsync_dir(d)


def symlink_replace(link, target):
    """Atomically make `link` a symlink to `target`, replacing whatever is there (a legacy regular file included)."""
    tmp = "%s.tmp" % link
    try:
        os.remove(tmp)
    except OSError:
        pass
    os.symlink(target, tmp)
    os.rename(tmp, link)


def under(path, base):
    rp, rb = os.path.realpath(path), os.path.realpath(base)
    return rp == rb or rp.startswith(rb.rstrip("/") + os.sep)


def home():
    return os.path.realpath(os.path.expanduser("~"))


def short_path(p):
    h = home()
    rp = os.path.realpath(p)
    if rp == h:
        return "~"
    return "~" + rp[len(h):] if rp.startswith(h + os.sep) else rp


# ---------------------------------------------------------------- lock
class PMLock(object):
    """fcntl.flock(LOCK_EX|LOCK_NB) on PM/.lock. The kernel drops it when the holder dies; no age-based stealing."""

    def __init__(self, pm):
        self.path = os.path.join(pm, ".lock")
        self.fd = None

    def acquire(self):
        if os.path.isdir(self.path) and not os.path.islink(self.path):   # 3.x used a lock directory
            try:
                os.rmdir(self.path)
            except OSError:
                raise Busy("legacy lock directory present")
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            os.close(fd)
            raise Busy("locked")
        self.fd = fd
        return self

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *a):
        self.release()


# ---------------------------------------------------------------- generations
def new_id8():
    return secrets.token_hex(4)


def gen_dir_name(genstr):
    return "gen-" + genstr


def current_gen(pm):
    """The generation string (<seq>-<id>) `current` points at, resolved ONCE; None when absent or malformed.
    macOS (APFS) can answer readlink with EINVAL for a moment while a symlink is being replaced by rename, so a
    link that exists but cannot be read yet is retried briefly before it counts as unreadable."""
    path = os.path.join(pm, "current")
    t = None
    for attempt in range(12):
        try:
            t = os.readlink(path)
            break
        except OSError:
            if not os.path.lexists(path):
                return None
            time.sleep(0.002 * (attempt + 1))
    if t is None:
        return None
    m = GEN_RE.match(t.rstrip("/"))
    return "%s-%s" % (m.group(1), m.group(2)) if m else None


def current_exists(pm):
    return os.path.lexists(os.path.join(pm, "current"))


def list_gen_dirs(pm):
    """All gen-* directory entries (complete or not, .tmp included) -> [(seq, name)]."""
    out = []
    try:
        names = os.listdir(pm)
    except OSError:
        return out
    for n in names:
        m = re.match(r"^gen-(\d{6})-[0-9a-f]{8}(\.tmp)?$", n)
        if m:
            out.append((int(m.group(1)), n))
    return sorted(out)


def read_manifest(gdir):
    m = load_json(os.path.join(gdir, "manifest.json"))
    return m if isinstance(m, dict) and isinstance(m.get("files"), dict) else None


def is_complete(gdir):
    m = read_manifest(gdir)
    if not m:
        return False
    for name, meta in m["files"].items():
        try:
            if os.path.getsize(os.path.join(gdir, name)) != meta.get("size"):
                return False
        except (OSError, AttributeError):
            return False
    return True


def gen_files(gdir):
    """Every regular file under gdir, relative, sorted (manifest.json excluded)."""
    out = []
    for dp, dn, fn in os.walk(gdir):
        dn.sort()
        for f in sorted(fn):
            rel = os.path.relpath(os.path.join(dp, f), gdir)
            if rel != "manifest.json":
                out.append(rel)
    return sorted(out)


def read_pinned(pm, genstr, name):
    """Bytes of a file inside an already-pinned generation, or None."""
    try:
        with open(os.path.join(pm, gen_dir_name(genstr), name), "rb") as fh:
            return fh.read()
    except OSError:
        return None


def line_count(path):
    n, last = 0, b""
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            n += chunk.count(b"\n")
            last = chunk[-1:]
    return n + (1 if last and last != b"\n" else 0)


# ---------------------------------------------------------------- signed generations (1.3 / 1.4)
_KEY = {"fresh": False}


def key_path():
    # ONE location for every caller. Hooks run with CLAUDE_PLUGIN_DATA set, but the skill's own Bash calls (facts,
    # embed) do not get it; a key chosen by that variable made hooks reject every map the skill published (3.3.0 fix).
    # The guard denies the map agent any read of this file.
    return os.path.join(os.path.expanduser("~"), ".claude", "agent-memory", "project-map", "key")


def get_key(create=True):
    """Per-user random HMAC key (mode 0600). Created once; _KEY['fresh'] is True when THIS process created it."""
    p = key_path()
    try:
        with open(p, "rb") as fh:
            k = fh.read()
        if len(k) >= 16:
            return k
    except OSError:
        pass
    if not create:
        return None
    os.makedirs(os.path.dirname(p), exist_ok=True)
    k = secrets.token_bytes(32)
    try:
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(k)
        _KEY["fresh"] = True
        return k
    except FileExistsError:
        with open(p, "rb") as fh:
            return fh.read()


def key_was_created():
    return _KEY["fresh"]


def usage_private_dir():
    """The plugin's private usage-scan directory (cache and last result, mode 0700). The guard denies the map agent any read of it."""
    return os.path.join(os.path.dirname(key_path()), "usage")


_LEGACY_USAGE = ("usage-cache.json", "usage-last.json")


def sweep_legacy_usage(pm):
    """One-time migration (3.3.0): the usage scan used to keep its cache and last result inside ROOT/.project-map, where the
    map agent can read them. Delete those files (and their temp files) if present; never follows a symlinked folder.
    -> number of files removed."""
    try:
        if not _stat.S_ISDIR(os.lstat(pm).st_mode):
            return 0
        names = os.listdir(pm)
    except OSError:
        return 0
    n = 0
    for name in names:
        if name in _LEGACY_USAGE or name.startswith(tuple("." + x + ".tmp." for x in _LEGACY_USAGE)):
            try:
                os.unlink(os.path.join(pm, name))
                n += 1
            except OSError:
                pass
    return n


def published_dir():
    return os.path.join(os.path.dirname(key_path()), "published")


def record_path(root):
    return os.path.join(published_dir(), sha256_bytes(os.path.realpath(root).encode("utf-8", "replace")))


def write_publish_record(root, genstr, gdir):
    """Embed notes every publish it makes: root, generation, and the sha256 of that generation's manifest.json."""
    try:
        os.makedirs(published_dir(), exist_ok=True)
        atomic_write(record_path(root), dumps({"root": os.path.realpath(root), "generation": genstr,
                                               "manifest_sha256": sha256_file(os.path.join(gdir, "manifest.json")), "at": iso()}))
    except OSError:
        pass


def adoptable(root, genstr, gdir):
    """A generation whose signature cannot be checked (key lost) may be re-signed ONLY when this machine's own record
    names it and the manifest is byte-identical to what was published, with every listed file intact."""
    rec = load_json(record_path(root))
    ld = legacy_data_dir()
    if rec is None and ld:   # the pre-3.3.0 record lived next to the per-DATA key
        rec = load_json(os.path.join(ld, "published", sha256_bytes(os.path.realpath(root).encode("utf-8", "replace"))))
    if not (isinstance(rec, dict) and rec.get("generation") == genstr and rec.get("root") == os.path.realpath(root)):
        return False
    m = read_manifest(gdir)
    try:
        if not m or rec.get("manifest_sha256") != sha256_file(os.path.join(gdir, "manifest.json")):
            return False
        for name, meta in m["files"].items():
            p = os.path.join(gdir, name)
            if os.path.getsize(p) != meta.get("size") or sha256_file(p) != meta.get("sha256"):
                return False
    except (OSError, AttributeError):
        return False
    return True


def sign_manifest(files, generation, base):
    return hmac.new(get_key(), canon({"files": files, "generation": generation, "base": base}).encode("utf-8", "replace"),
                    hashlib.sha256).hexdigest()


def _manifest_hmac(k, m):
    return hmac.new(k, canon({"files": m["files"], "generation": m.get("generation"), "base": m.get("base")}).encode("utf-8", "replace"),
                    hashlib.sha256).hexdigest()


def _files_intact(gdir, m):
    for name, meta in m["files"].items():
        try:
            p = os.path.join(gdir, name)
            if os.path.getsize(p) != meta.get("size") or sha256_file(p) != meta.get("sha256"):
                return False
        except (OSError, AttributeError):
            return False
    return True


def legacy_data_dir():
    """Before 3.3.0 the key lived in $CLAUDE_PLUGIN_DATA/key (hooks only). -> that directory when it is set, differs
    from the canonical key's directory and holds a key file; else None."""
    d = os.environ.get("CLAUDE_PLUGIN_DATA")
    if not d or not os.path.isabs(d):
        return None
    if os.path.realpath(d) == os.path.realpath(os.path.dirname(key_path())):
        return None
    kp = os.path.join(d, "key")
    return d if os.path.isfile(kp) and not os.path.islink(kp) else None


def _legacy_recover(gdir, m):
    """A generation signed by the pre-3.3.0 per-DATA key (CLAUDE_PLUGIN_DATA/key) is re-signed with the canonical key,
    but ONLY when that legacy key authenticates its manifest and every listed file is intact. Never adopts an unsigned
    or foreign map, never replaces an existing canonical key (get_key only creates when none exists)."""
    d = legacy_data_dir()
    if not d:
        return False
    try:
        with open(os.path.join(d, "key"), "rb") as fh:
            lk = fh.read()
    except OSError:
        return False
    if len(lk) < 16 or not hmac.compare_digest(_manifest_hmac(lk, m), m["hmac"]) or not _files_intact(gdir, m):
        return False
    try:
        m2 = dict(m, hmac=_manifest_hmac(get_key(), m))
        atomic_write(os.path.join(gdir, "manifest.json"), dumps(m2, indent=1))
    except OSError:
        return False
    _record_after_resign(gdir, m.get("generation"))
    return True


def _record_after_resign(gdir, manifest_gen):
    """The manifest changed bytes, so the publish record that names its sha256 must follow: write the canonical record of
    the OWNING root (<root>/.project-map/gen-<id>) with the final manifest hash, so a later loss of the canonical key
    can still adopt this generation. Only reached after the legacy key authenticated the manifest (never for an
    unauthenticated map). A record that names a DIFFERENT generation (a newer publish) is left alone."""
    try:
        g = os.path.realpath(gdir)
        pm = os.path.dirname(g)
        name = os.path.basename(g)
        if os.path.basename(pm) != ".project-map" or not name.startswith("gen-") or not GEN_RE.match(name):
            return
        genstr = name[4:]
        if manifest_gen != genstr:
            return
        root = os.path.dirname(pm)
        rec = load_json(record_path(root))
        if isinstance(rec, dict) and rec.get("generation") not in (None, genstr):
            return
        write_publish_record(root, genstr, g)
    except (OSError, ValueError):
        pass


def verify_generation(gdir):
    """True only when the manifest is signed by this user's key and every listed file matches its size and sha256.
    A generation signed by the legacy per-DATA key (see _legacy_recover) is re-signed once and then verifies."""
    m = read_manifest(gdir)
    if not m or not isinstance(m.get("hmac"), str) or not isinstance(m.get("files"), dict):
        return False
    k = get_key(create=False)
    if k and hmac.compare_digest(_manifest_hmac(k, m), m["hmac"]):
        return _files_intact(gdir, m)
    if _legacy_recover(gdir, m):
        return True
    return False


# ---------------------------------------------------------------- secret / unsafe text and paths
SECRET_RE = re.compile(
    r"AIza[0-9A-Za-z_-]{30,}|sk_(?:live|test)_\w{16,}|glpat-\w{16,}|npm_\w{30,}|hf_\w{30,}|[a-z][a-z0-9+.-]*://[^/\s:]+:[^@\s]+@"
    r"|(?:AKIA|ASIA)[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|github_pat_\w+|gh[opsu]_\w{20,}|xox[abprs]-[\w-]{10,}"
    r"|eyJ[\w-]{10,}\.[\w-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|Bearer\s+\S{16,}|(?i:password\s*[:=])"
    r"|(?i:(?:api[_-]?key|secret)\s*[:=]\s*\S{8,})")
BIDI = re.compile("[\u202a-\u202e\u2066-\u2069]")
CTRL = re.compile("[\x00-\x1f\x7f]")
INVISIBLE = re.compile("[\u200b-\u200f\u2060\ufeff\u2028\u2029\u0085]")
SECRET_NAMES = (".env*", "*.env", ".envrc", "*credential*", "*secret*", "*token*", "*password*", "*.pem", "*.key", "*.p12", "*.pfx",
                "*.tfstate", ".pgpass", "service-account*.json", "id_rsa*", "id_ed25519*", "*_history", ".netrc", ".npmrc",
                ".pypirc", ".claude.json", "settings*.json", "ssh_host_*", "known_hosts")
SECRET_DIRS = ("secrets", "credentials", ".kube", ".docker", ".gnupg", ".ssh", ".aws")   # directory components (casefolded)


def iter_strings(obj, path=""):
    if isinstance(obj, str):
        yield path or "$", obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            for r in iter_strings(v, path + "." + str(k) if path else str(k)):
                yield r
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            for r in iter_strings(v, "%s[%d]" % (path, i)):
                yield r


def unsafe_strings(obj, label):
    """Messages for every string under obj that looks like a secret, or holds control / bidi characters."""
    out = []
    for path, s in iter_strings(obj):
        if s is None:
            continue
        where = "%s%s" % (label, "" if path == "$" else "." + path)
        if CTRL.search(s):
            out.append("%s contains control characters" % where)
        elif BIDI.search(s):
            out.append("%s contains bidirectional override characters" % where)
        elif INVISIBLE.search(s):
            out.append("%s contains zero-width or line-separator characters" % where)
        elif SECRET_RE.search(s):
            out.append("%s looks like it contains a secret; remove it" % where)
    return out


_ESC_RE = re.compile("[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]")


def display_safe(s, n=None):
    """Safe display form of a name taken from git (tag, branch, upstream): control, bidi, zero-width and line-separator
    characters become visible \\uXXXX escapes, a secret-looking value becomes '[redacted]'. Ordinary Unicode and a
    literal % stay. Only for output: keep the raw name for any internal comparison or key (see ref_ident)."""
    s = str(s)
    if SECRET_RE.search(s):
        s = "[redacted]"
    s = _ESC_RE.sub(lambda m: "\\u%04x" % ord(m.group(0)), s)
    return trim(s, n) if n else s


def ref_ident(raw):
    """Key form of a raw name: the name itself when it is safe to show, else its display form + '#' + a hash of the
    raw bytes (two different hostile names never collide, and nothing hostile reaches state or pages)."""
    d = display_safe(raw)
    if d == raw:
        return raw
    return "%s#%s" % (d, sha256_bytes(str(raw).encode("utf-8", "surrogatepass"))[:8])


def tag_tid(raw):
    """Stable identity of a RAW tag name (16 hex chars of its sha256): the display form can collide ('[redacted]') or differ
    from the real name (escapes), the identity cannot."""
    return sha256_bytes(str(raw).encode("utf-8", "surrogatepass"))[:16]


def watch_problem(w):
    """Why a watch/repos entry is unusable (None when fine): never `.`, `.project-map`, `.git`, `..`, absolute,
    or anything the guard treats as secret."""
    if not isinstance(w, str) or not w or "\0" in w or "\n" in w:
        return "must be a non-empty path"
    if w.startswith(("/", ":", "-")) or w.startswith("~"):
        return "must be a relative path inside the project"
    parts = [x for x in w.split("/") if x not in ("", ".")]
    if not parts:
        return "must not be '.' (the whole project)"
    if ".." in parts:
        return "must be a relative path inside the project"
    for x in parts:
        c = x.casefold()
        if c in (".project-map", ".git"):
            return "must not contain a %s component" % x
        if c in SECRET_DIRS or any(fnmatch.fnmatchcase(c, pat) for pat in SECRET_NAMES):
            return "looks like a secret path (%s)" % x
    if ".config/gh" in "/".join(p.casefold() for p in parts):
        return "looks like a secret path (.config/gh)"
    return None


def secret_regex():
    """One grep -E (use -i) pattern for the secret path list: any path component equal to a secret directory or matching a
    secret basename pattern, plus .config/gh. The guard tests generate their expectations from this."""
    def conv(p):
        return "".join("[^/]*" if ch == "*" else re.escape(ch).replace("\\", "\\") for ch in p)
    alts = [re.escape(d) for d in SECRET_DIRS] + [conv(p) for p in SECRET_NAMES] + [r"\.config/gh"]
    return "(^|/)(" + "|".join(alts) + ")(/|$)"


if __name__ == "__main__":
    import sys as _sys
    if _sys.argv[1:] == ["--secret-regex"]:
        print(secret_regex())
    else:
        print("usage: pm_common.py --secret-regex", file=_sys.stderr)
        _sys.exit(2)
