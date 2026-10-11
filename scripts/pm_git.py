#!/usr/bin/env python3
"""pm_git: hardened git execution core for project-map (INTERFACES-3.2 section 7).

Every git call made by facts, embed, the hooks and pm-git.sh goes through run().
Hardening: configured helpers never execute (fsmonitor, hooks, pager, external
diff, ssh command are all overridden on the command line), every GIT_* variable
of the caller is dropped, and only an allowlisted subcommand/flag grammar is
accepted. Stdlib only, Python 3.9+.

Release-fact tuples (3.3.0): for-each-ref, symbolic-ref and a few extra rev-parse/rev-list forms are accepted as
exact tuples only (see _v_for_each_ref and friends); they are script-internal and never reachable from pm-git.sh.

Public API: tag_name_problem, tag_name_git_ok, run, stream_lines, collection_failure, toplevel, env_for_git, argv_prefix, GitArgError.
CLI (used by pm-git.sh only): pm_git.py --agent ROOT <sub> [args]
"""
from __future__ import annotations

import os
import stat as stat_mod
import re
import subprocess
import time as _time
import sys

__all__ = ["tag_name_problem", "tag_name_git_ok", "GitArgError", "run", "stream_lines", "collection_failure", "toplevel", "env_for_git", "argv_prefix"]

# -c overrides, in order (section 7.1). They beat repo-local config.
SAFE_CONFIG = (
    "core.fsmonitor=false",
    "core.hooksPath=/dev/null",
    "core.pager=cat",
    "diff.external=",
    "core.sshCommand=false",
)
SHA_RE = r"[0-9a-f]{7,40}|HEAD"
LOG_INTERNAL = "--format=%x1e%H%x1f%ct%x1f%s"  # facts/embed record format
LOG_AGENT = "--format=%h %ad %s"               # agent format, needs --date=short
MAX_LOG_N = 200


class GitArgError(ValueError):
    """Raised for any call outside the internal grammar (nothing is executed)."""


def _bad(msg):
    raise GitArgError(msg)


def _is_str(x):
    return isinstance(x, str) and "\0" not in x


def _sha(x):
    if not _is_str(x) or not re.fullmatch(SHA_RE, x):
        _bad("bad revision: %r" % (x,))


def _relpath(p):
    # no "..", not option-like, not absolute; ":" is refused too (git pathspec magic)
    if (not _is_str(p) or not p or "\n" in p or p[0] in "-/:"
            or ".." in p.split("/")):
        _bad("bad relpath: %r" % (p,))


def _tail_paths(a, i):
    """a[i:] must be empty or `-- <relpath>...` (at least one path)."""
    if i >= len(a):
        return
    if a[i] != "--" or len(a) == i + 1:
        _bad("expected -- <relpath>...")
    for p in a[i + 1:]:
        _relpath(p)


def _v_status(a):
    if a not in (("--porcelain=v1", "-z", "--untracked-files=all"), ("--porcelain=v1",)):
        _bad("status: flags not allowed")


def _v_log(a):
    if not a or a[0] not in (LOG_INTERNAL, LOG_AGENT):
        _bad("log: format not allowed")
    i = 1
    if a[0] == LOG_AGENT:
        if a[1:2] != ("--date=short",):
            _bad("log: agent format needs --date=short")
        i = 2
    n = a[i + 1] if len(a) > i + 1 else ""
    if a[i:i + 1] != ("-n",) or not re.fullmatch(r"[0-9]{1,3}", n) or not 1 <= int(n) <= MAX_LOG_N:
        _bad("log: -n 1..%d required" % MAX_LOG_N)
    i += 2
    if i < len(a) and a[i].startswith("--since="):
        if not re.fullmatch(r"--since=[0-9][0-9A-Za-z:+.\- ]{0,39}", a[i]):
            _bad("log: bad --since")
        i += 1
    if i < len(a) and a[0] == LOG_INTERNAL and re.fullmatch(r"[0-9a-f]{7,40}\.\.HEAD", a[i]):   # 3.6.2: internal P..HEAD only
        i += 1
    _tail_paths(a, i)


def _v_ls_files(a):
    _tail_paths(a, 2 if a[:2] == ("-s", "-z") else 0)

REL_HEX40 = r"[0-9a-f]{40}"   # full SHA-1 object ids only; SHA-256 repositories are reported as unknown
TAG_FMT = "--format=%(refname)%00%(objecttype)%00%(objectname)%00%(*objecttype)%00%(*objectname)"
UP_FMT = "--format=%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)"
_REF_BAD = re.compile(r"[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//")


REF_TYPE_FMT = "--format=%(refname)%00%(objecttype)%00%(objectname)"


def _lit_ref_ok(r, prefixes):
    """A literal ref under one of prefixes: git ref grammar, no wildcard or control characters, no option-like forms."""
    if not _is_str(r) or len(r) > 255 or not any(r.startswith(p) and len(r) > len(p) for p in prefixes):
        return False
    if _REF_BAD.search(r) or r.endswith(("/", ".", ".lock")):
        return False
    return all(c and not c.startswith(".") and not c.endswith(".lock") for c in r.split("/"))


def branch_ref_ok(r):
    """A literal refs/heads/<branch>."""
    return _lit_ref_ok(r, ("refs/heads/",))


def upstream_ref_ok(r):
    """The literal ref a branch's upstream config resolves to: refs/remotes/... or refs/heads/..."""
    return _lit_ref_ok(r, ("refs/remotes/", "refs/heads/"))


def _v_rev_parse(a):
    if a in (("--show-toplevel",), ("--abbrev-ref", "HEAD"), ("HEAD",), ("--is-shallow-repository",),
             ("--verify", "--end-of-options", "HEAD^{commit}")):
        return
    if len(a) == 3 and a[:2] == ("--verify", "--end-of-options") and a[2].endswith("^{commit}") \
            and upstream_ref_ok(a[2][:-len("^{commit}")]):
        return   # the literal configured upstream ref, never an arbitrary revision
    if len(a) != 1 or not re.fullmatch(r"(?:%s)\^\{commit\}" % SHA_RE, a[0]):
        _bad("rev-parse: not allowed")


def _v_symbolic_ref(a):
    if a != ("--quiet", "HEAD"):
        _bad("symbolic-ref: only --quiet HEAD")


def _v_for_each_ref(a):
    if len(a) == 4 and a[0] == "--sort=refname" and a[1] == TAG_FMT and a[3] == "refs/tags" \
            and re.fullmatch(r"--points-at=%s" % REL_HEX40, a[2]):
        return
    if a == ("--sort=refname", "--sort=-creatordate", "--count=5", TAG_FMT, "refs/tags"):
        return
    if len(a) == 2 and a[0] == UP_FMT and branch_ref_ok(a[1]):
        return
    if len(a) == 2 and a[0] == REF_TYPE_FMT and upstream_ref_ok(a[1]):   # existence + type of ONE literal ref
        return
    _bad("for-each-ref: not allowed")


def _v_rev_list(a):
    if len(a) == 3 and a[:2] == ("--left-right", "--count") \
            and re.fullmatch(r"%s\.\.\.%s" % (REL_HEX40, REL_HEX40), a[2]):
        return
    if len(a) != 2 or a[0] != "--count" or not _is_str(a[1]):
        _bad("rev-list: only --count A..B")
    parts = a[1].split("..")
    if len(parts) != 2:
        _bad("rev-list: need A..B")
    _sha(parts[0]), _sha(parts[1])


def _v_merge_base(a):
    if len(a) != 3 or a[0] != "--is-ancestor":
        _bad("merge-base: only --is-ancestor A B")
    _sha(a[1]), _sha(a[2])


def _v_cat_file(a):
    if len(a) != 2 or a[0] not in ("-e", "-t"):
        _bad("cat-file: only -e|-t <sha>")
    _sha(a[1])


def _v_diff(a):
    if len(a) < 5 or a[:3] != ("--stat", "--no-ext-diff", "--no-textconv"):
        _bad("diff: only --stat --no-ext-diff --no-textconv A B")
    _sha(a[3]), _sha(a[4])
    _tail_paths(a, 5)


TAG_REF_PREFIX = "refs/tags/"


def _v_check_ref_format(a):
    """Exactly `check-ref-format refs/tags/<name>` (script-internal: raise-time legality of a future tag name). The fixed
    prefix means the argument can never be an option; the name is bounded and carries no NUL."""
    if len(a) != 1 or not _is_str(a[0]) or not a[0].startswith(TAG_REF_PREFIX) or not 1 <= len(a[0]) - len(TAG_REF_PREFIX) <= 200:
        _bad("check-ref-format: only refs/tags/<name>")


_TAG_BAD_CHARS = re.compile(r"[\x00-\x20\x7f~^:?*\[\\]")


def tag_name_problem(name):
    """None when `name` is a legal single tag name, else a short reason. The rules of `git check-ref-format
    refs/tags/<name>` (no component starting with '.' or ending in '.lock', no '..', no control character, space or one of
    ~ ^ : ? * [ \\, no '@{', no trailing '.' or '/', no '//'), plus the lone '@' that git refuses as a refname."""
    if not isinstance(name, str) or not name:
        return "empty"
    if name == "@":
        return "a lone @"
    if _TAG_BAD_CHARS.search(name):
        return "a space, control character or one of ~ ^ : ? * [ \\"
    if ".." in name:
        return "contains .."
    if "@{" in name:
        return "contains @{"
    if name.endswith("."):
        return "ends with ."
    if name.startswith("/") or name.endswith("/") or "//" in name:
        return "empty path component"
    for c in name.split("/"):
        if c.startswith("."):
            return "a component starts with ."
        if c.endswith(".lock"):
            return "a component ends with .lock"
    return None


def tag_name_git_ok(repo, name):
    """True/False from the real `git check-ref-format refs/tags/<name>` run in repo; None when git cannot say (missing,
    timeout, repo unusable)."""
    try:
        rc, _out = run(repo, "check-ref-format", TAG_REF_PREFIX + name, timeout=10.0)
    except GitArgError:
        return False
    return True if rc == 0 else False if rc == 1 else None


def _v_branch(a):
    if a not in (("--show-current",), ("--list",)):
        _bad("branch: not allowed")


VALIDATORS = {
    "status": _v_status, "log": _v_log, "ls-files": _v_ls_files, "rev-parse": _v_rev_parse,
    "rev-list": _v_rev_list, "merge-base": _v_merge_base, "cat-file": _v_cat_file,
    "diff": _v_diff, "branch": _v_branch, "symbolic-ref": _v_symbolic_ref, "for-each-ref": _v_for_each_ref,
    "check-ref-format": _v_check_ref_format, "tag": lambda a: a == ("--list",) or _bad("tag: only --list"),
}
# Subcommands where a specific non-zero rc is the documented answer, not a failure.
ANSWER_RC = {"cat-file": 1, "merge-base": 1}
# symbolic-ref --quiet HEAD, rc 1 = detached HEAD: the release collector reads that rc itself (run() returns it);
# it is deliberately NOT an ANSWER_RC entry, so nothing else can mistake a failure for it.


def env_for_git():
    """Caller env without any GIT_* variable, plus the pinned safe ones (7.1)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0",
               GIT_EXTERNAL_DIFF="", GIT_PAGER="cat")
    return env


def argv_prefix(repo):
    """`git -C repo --no-optional-locks -c ...` (7.1)."""
    if not _is_str(repo) or not repo:
        _bad("bad repo path")
    out = ["git", "-C", repo, "--no-optional-locks"]
    for c in SAFE_CONFIG:
        out += ["-c", c]
    return out


def run(repo, sub, *args, timeout=20.0):
    """Run a validated git command. Returns (rc, stdout_text); (124, "") on timeout.

    Raises GitArgError for anything outside the internal grammar. A missing git
    binary returns (127, ""). stderr is discarded; stdin is closed.
    """
    check = VALIDATORS.get(sub) if isinstance(sub, str) else None
    if check is None:
        _bad("subcommand not allowed: %r" % (sub,))
    if not all(isinstance(x, str) for x in args):
        _bad("arguments must be strings")
    check(tuple(args))
    argv = argv_prefix(repo) + [sub] + list(args)
    try:
        p = subprocess.run(argv, env=env_for_git(), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError:
        return 127, ""
    return p.returncode, p.stdout.decode("utf-8", errors="replace")


def _fixed(repo, args, timeout):
    """A constant internal git command (never agent input) with the same hardened prefix and environment. -> (rc, out)."""
    try:
        p = subprocess.run(argv_prefix(repo) + list(args), env=env_for_git(), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return 124, ""
    return p.returncode, p.stdout.decode("utf-8", errors="replace")


def _exclude_pattern(rel, name):
    """The anchored, escaped exclude line for <rel>/<name>/ (rel "" = the worktree top)."""
    p = (rel + "/" if rel else "") + name
    esc = "".join("\\" + ch if ch in "*?[\\" else ch for ch in p)
    return "/" + esc + "/"


def ensure_local_exclude(root, name=".project-map", timeout=5.0, deadline=None):
    """3.6.2 (INTERFACES 17.5): keep ROOT/<name>/ out of commits WITHOUT touching a tracked file. When ROOT is inside a Git work
    tree whose `check-ignore` does not already ignore the folder, ONE anchored, escaped line ("/<rel>/<name>/") is appended to the
    repository's local exclude file <common dir>/info/exclude (shared by linked worktrees). Boundaries: the common dir is resolved by
    the hardened git and opened as a directory; `info` is opened (or created) RELATIVE to that descriptor with O_NOFOLLOW, and
    `exclude` relative to the `info` descriptor with O_APPEND|O_CREAT|O_NOFOLLOW, then fstat-checked (regular, one link); a link
    anywhere on that path is refused; append-only (no read-replace, so a concurrent writer loses nothing; a duplicate line is
    harmless). Never untracks or edits .gitignore. Never
    raises. -> (status, why): ("added"|"ignored"|"skip"|"not_ignored", why) -- "not_ignored" when the folder is still not ignored
    (a negation rule, a refused or failed step, tracked map files, a query that did not answer); "skip" only for what git confirms is
    not a work tree (a plain folder: rc 128; a bare repository or the inside of .git: "false"); "deferred" when the caller's
    `deadline` (absolute time.monotonic()) leaves no time: the next publication tries again."""
    import time as _t

    def q(args):   # one bounded query; None when the deadline has passed
        left = timeout if deadline is None else min(timeout, deadline - _t.monotonic())
        if left <= 0.05:
            return None
        return _fixed(root, args, left)
    try:
        r = q(["rev-parse", "--is-inside-work-tree"])
        if r is None:
            return "deferred", "out of time; the next publication checks again"
        rc, out = r
        if rc == 0 and out.strip() == "false":   # git answered: a bare repository or the inside of .git
            return "skip", ""
        if rc != 0:   # J3: a fatal answer is a plain folder only when no .git entry exists here or above (git's own discovery)
            return ("skip", "") if not _git_entry_above(root) else ("not_ignored", "git could not read this repository's metadata")
        if out.strip() != "true":
            return "not_ignored", "git did not answer whether this is a work tree"
        r = q(["ls-files", "-z", "--", name])
        if r is None:
            return "deferred", "out of time; the next publication checks again"
        if r[0] != 0:
            return "not_ignored", "git could not tell whether the map files are tracked"
        if r[1].strip("\0"):
            return "not_ignored", "map files are tracked by git (untrack them yourself: git rm -r --cached %s)" % name
        r = q(["check-ignore", "-q", name])
        if r is None:
            return "deferred", "out of time; the next publication checks again"
        if r[0] == 0:
            return "ignored", ""
        if r[0] != 1:   # 1 = not ignored; anything else did not answer
            return "not_ignored", "git could not check the ignore rules"
        r1, r2 = q(["rev-parse", "--show-toplevel"]), q(["rev-parse", "--git-common-dir"])
        if r1 is None or r2 is None:
            return "deferred", "out of time; the next publication checks again"
        (rc, top), (rc2, common) = r1, r2
        top, common = top.strip(), common.strip()
        if rc != 0 or rc2 != 0 or not top or not common or "\n" in top or "\n" in common:
            return "not_ignored", "the repository's metadata folder could not be resolved"
        if os.path.realpath(top) == os.path.realpath(os.path.expanduser("~")):   # a repository of the home folder: never touched
            return "skip", ""
        common = os.path.realpath(common if os.path.isabs(common) else os.path.join(root, common))
        rel = os.path.relpath(os.path.realpath(root), os.path.realpath(top))
        if rel == ".":
            rel = ""
        if rel.startswith(".."):
            return "not_ignored", "the map folder is outside the work tree"
        # Every step below works relative to an OPEN directory descriptor with O_NOFOLLOW, so swapping a component for a link
        # between the checks and the write cannot redirect it (the common directory itself was resolved by realpath first).
        D = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        cfd = os.open(common, D)
        try:
            try:
                ifd = os.open("info", D, dir_fd=cfd)
            except FileNotFoundError:
                os.mkdir("info", 0o755, dir_fd=cfd)
                ifd = os.open("info", D, dir_fd=cfd)
            try:
                fd = os.open("exclude", os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o644, dir_fd=ifd)
                try:
                    st = os.fstat(fd)
                    if not stat_mod.S_ISREG(st.st_mode) or st.st_nlink != 1:
                        return "not_ignored", "info/exclude is not a plain file"
                    lead = b""
                    if st.st_size:
                        rfd = os.open("exclude", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0), dir_fd=ifd)
                        try:
                            if (os.fstat(rfd).st_ino, os.fstat(rfd).st_dev) != (st.st_ino, st.st_dev):
                                return "not_ignored", "info/exclude changed while it was opened"
                            os.lseek(rfd, -1, os.SEEK_END)
                            lead = b"" if os.read(rfd, 1) == b"\n" else b"\n"
                        finally:
                            os.close(rfd)
                    os.write(fd, lead + _exclude_pattern(rel, name).encode("utf-8") + b"\n")
                finally:
                    os.close(fd)
            finally:
                os.close(ifd)
        finally:
            os.close(cfd)
        r = q(["check-ignore", "-q", name])
        if r is None or r[0] not in (0, 1):
            return "not_ignored", "the exclude line was added but git could not confirm it applies"
        if r[0] != 0:
            return "not_ignored", "a rule in .gitignore re-includes it"
        return "added", ""
    except Exception as ex:   # noqa: BLE001 - a convenience: never fails a publication
        return "not_ignored", "the local exclude file could not be written (%s)" % type(ex).__name__


def object_info(repo, sha, timeout=5.0):
    """3.6.2 (INTERFACES 17.3): what <sha> names, from ONE completed `git cat-file --batch-check` (the id on stdin, never argv).
    -> ("commit", full_oid) | ("other", full_oid) | ("missing", None) | ("ambiguous", None) | ("unknown", None). Only git's own
    documented "missing" answer from a query that completed is absence; a fatal error, a timeout, malformed output, an
    unreadable or corrupt object store are "unknown". Raises GitArgError for a malformed id."""
    if not _is_str(sha) or not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        _bad("bad object id: %r" % (sha,))
    try:
        p = subprocess.run(argv_prefix(repo) + ["cat-file", "--batch-check"], input=(sha + "\n").encode(), env=env_for_git(),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return "unknown", None
    if p.returncode != 0:
        return "unknown", None
    line = p.stdout.decode("utf-8", "replace").strip()
    parts = line.split()
    if parts == [sha, "missing"]:
        return "missing", None
    if parts == [sha, "ambiguous"]:
        return "ambiguous", None
    if len(parts) == 3 and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", parts[0]) and parts[0].startswith(sha) and parts[2].isdigit():
        return ("commit" if parts[1] == "commit" else "other"), parts[0]
    return "unknown", None


def _git_entry_above(path):
    """True when a `.git` entry (directory or file) exists in PATH or any parent: git's own discovery would find a repository."""
    p = os.path.realpath(path)
    while True:
        if os.path.lexists(os.path.join(p, ".git")):
            return True
        q = os.path.dirname(p)
        if q == p:
            return False
        p = q


def _left(timeout, deadline):
    """J4: the allowance for the NEXT git call: the per-call timeout, cut to what is left before the absolute deadline."""
    if deadline is None:
        return timeout
    return min(timeout, deadline - _time.monotonic())


def is_shallow(repo, timeout=5.0):
    """True | False | None (no answer): a shallow clone's history stops at a boundary, so a negative ancestry answer is not proof."""
    rc, out = _fixed(repo, ["rev-parse", "--is-shallow-repository"], timeout)
    return {"true": True, "false": False}.get(out.strip()) if rc == 0 else None


def commit_reach(repo, sha, timeout=5.0, deadline=None):
    """3.6.2 (INTERFACES 17.3): is commit <sha> part of the CHECKED-OUT history of this repository? -> ("ok", oid) (an ancestor
    of HEAD) | ("unreachable", oid) (the object exists but HEAD does not reach it: a reset, rebase or force-push dropped it, or it
    lives only on another branch, tag or a backup ref: none of these is evidence for the current checkout) | ("absent", None) (git
    answered "missing", or the id names no commit) | ("unknown", None) (any failed, ambiguous or timed-out query)."""
    t = _left(timeout, deadline)   # J4: every call gets only what is left before `deadline`; none is started after it
    if t <= 0.05:
        return "unknown", None
    kind, oid = object_info(repo, sha, t)
    if kind in ("missing", "other"):
        return "absent", None
    if kind != "commit":
        return "unknown", None
    t = _left(timeout, deadline)
    if t <= 0.05:
        return "unknown", None
    rc, _ = run(repo, "merge-base", "--is-ancestor", oid, "HEAD", timeout=t)
    if rc == 0:
        return "ok", oid
    t = _left(timeout, deadline)
    if rc == 1 and t > 0.05 and is_shallow(repo, t) is False:   # a shallow clone's negative answer proves nothing (I1)
        return "unreachable", oid
    return "unknown", None


def collection_failure(sub, rc):
    """True when rc is a collection failure; False for 0 and documented answers."""
    return rc != 0 and ANSWER_RC.get(sub) != rc


def toplevel(path, timeout=3.0):
    """Absolute repo toplevel of path, or None (not a repo, error, timeout)."""
    try:
        rc, out = run(path, "rev-parse", "--show-toplevel", timeout=timeout)
    except GitArgError:
        return None
    line = out.strip()
    return line if rc == 0 and line else None


# ---- agent mode (pm-git.sh, section 7.2) --------------------------------------------------

def _agent_call(sub, rest):
    """Map the agent grammar to one internal call; return (sub, args) or raise."""
    if sub == "status" and not rest:
        return "status", ("--porcelain=v1",)
    if sub == "log":
        n = "20"
        if rest:
            if len(rest) != 2 or rest[0] != "-n" or not re.fullmatch(r"[0-9]{1,3}", rest[1]) \
                    or not 1 <= int(rest[1]) <= 60:
                _bad("log: only -n 1..60")
            n = str(int(rest[1]))
        return "log", (LOG_AGENT, "--date=short", "-n", n)
    if sub == "rev-parse" and not rest:
        return "rev-parse", ("HEAD",)
    if sub in ("branch", "tag") and not rest:
        return sub, ("--list",)
    if sub == "ls-files" and len(rest) <= 1:
        return "ls-files", (("--", rest[0]) if rest else ())
    _bad("not allowed")


def _agent(argv):
    if len(argv) < 2 or not os.path.isabs(argv[0]) or re.search(r"\s", argv[0]) \
            or not os.path.isdir(argv[0]):
        _bad("bad root")
    sub, args = _agent_call(argv[1], tuple(argv[2:]))
    rc, out = run(argv[0], sub, *args)
    sys.stdout.buffer.write(out.encode("utf-8", errors="replace"))
    return rc


def main(argv):
    if len(argv) >= 2 and argv[0] == "--agent":
        try:
            return _agent(argv[1:])
        except GitArgError:
            pass
    sys.stderr.write("pm-git: not allowed\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))



def stream_lines(repo, sub, *args, timeout=20.0, max_rows=None, on_row=None):
    """Validated git call whose stdout is consumed line by line through on_row(line) without being held in memory.
    Stops (and kills git) after max_rows rows. -> (rc, truncated): rc 124 on timeout, 127 when git is missing; a
    truncated read reports rc 0 and truncated True."""
    import threading
    check = VALIDATORS.get(sub) if isinstance(sub, str) else None
    if check is None:
        _bad("subcommand not allowed: %r" % (sub,))
    if not all(isinstance(x, str) for x in args):
        _bad("arguments must be strings")
    check(tuple(args))
    argv = argv_prefix(repo) + [sub] + list(args)
    try:
        p = subprocess.Popen(argv, env=env_for_git(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    except OSError:
        return 127, False
    timed = {"out": False}

    def kill():
        timed["out"] = True
        try:
            p.kill()
        except OSError:
            pass
    timer = threading.Timer(timeout, kill)
    timer.start()
    n, trunc = 0, False
    try:
        for raw in p.stdout:
            n += 1
            if max_rows is not None and n > max_rows:
                trunc = True
                p.kill()
                break
            if on_row:
                on_row(raw.decode("utf-8", errors="replace").rstrip("\n"))
    finally:
        timer.cancel()
        try:
            p.stdout.close()
        except OSError:
            pass
        p.wait()
    if timed["out"]:
        return 124, False
    return (0 if trunc else p.returncode), trunc
