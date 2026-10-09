#!/usr/bin/env python3
"""pm_git: hardened git execution core for project-map (INTERFACES-3.2 section 7).

Every git call made by facts, embed, the hooks and pm-git.sh goes through run().
Hardening: configured helpers never execute (fsmonitor, hooks, pager, external
diff, ssh command are all overridden on the command line), every GIT_* variable
of the caller is dropped, and only an allowlisted subcommand/flag grammar is
accepted. Stdlib only, Python 3.9+.

Public API: run, collection_failure, toplevel, env_for_git, argv_prefix, GitArgError.
CLI (used by pm-git.sh only): pm_git.py --agent ROOT <sub> [args]
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

__all__ = ["GitArgError", "run", "collection_failure", "toplevel", "env_for_git", "argv_prefix"]

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
    _tail_paths(a, i)


def _v_ls_files(a):
    _tail_paths(a, 2 if a[:2] == ("-s", "-z") else 0)

def _v_rev_parse(a):
    if a in (("--show-toplevel",), ("--abbrev-ref", "HEAD"), ("HEAD",)):
        return
    if len(a) != 1 or not re.fullmatch(r"(?:%s)\^\{commit\}" % SHA_RE, a[0]):
        _bad("rev-parse: not allowed")


def _v_rev_list(a):
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


def _v_branch(a):
    if a not in (("--show-current",), ("--list",)):
        _bad("branch: not allowed")


VALIDATORS = {
    "status": _v_status, "log": _v_log, "ls-files": _v_ls_files, "rev-parse": _v_rev_parse,
    "rev-list": _v_rev_list, "merge-base": _v_merge_base, "cat-file": _v_cat_file,
    "diff": _v_diff, "branch": _v_branch, "tag": lambda a: a == ("--list",) or _bad("tag: only --list"),
}
# Subcommands where a specific non-zero rc is the documented answer, not a failure.
ANSWER_RC = {"cat-file": 1, "merge-base": 1}


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
