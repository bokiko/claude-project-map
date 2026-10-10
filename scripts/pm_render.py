#!/usr/bin/env python3
"""pm_render: index.html, mobile.html and brief.txt from a state.json dict (INTERFACES-3.2 sections 1, 6.6)."""
import re

import pm_common as C

PLACEHOLDER = "/*__PM_STATE__*/null"
META = '<meta name="pm-generation" content="">'
BRIEF_MAX = 1000


class RenderError(Exception):
    pass


def render_html(S, tpl_path):
    blob = C.dumps(S)
    for ch, esc in (("&", "\\u0026"), ("<", "\\u003c"), (">", "\\u003e"), (" ", "\\u2028"), (" ", "\\u2029")):
        blob = blob.replace(ch, esc)   # valid JSON escapes: "</script" and "<!--" cannot survive inside the page
    try:
        with open(tpl_path, encoding="utf-8") as fh:
            html = fh.read()
    except OSError as ex:
        raise RenderError("template unreadable: %s" % ex)
    if PLACEHOLDER not in html or META not in html:
        raise RenderError("template placeholder missing")
    html = html.replace(META, '<meta name="pm-generation" content="%s">' % S["generation"], 1)
    html = html.replace(PLACEHOLDER, blob, 1)
    title = re.sub(r"[<>&\"]", "", (S["identity"]["name"] or "Project") + " - project map")
    return re.sub(r"<title>.*?</title>", lambda m: "<title>" + title + "</title>", html, count=1)


def render_mobile(S):
    return ('<!doctype html><meta charset="utf-8"><meta name="pm-generation" content="%s"><title>mobile check</title>'
            '<body style="margin:0;background:#101011"><iframe src="index.html" style="width:390px;height:2400px;border:0;display:block"></iframe>'
            % S["generation"])


def human(n):
    return "n/a" if n is None else ("%.1fB" % (n / 1e9) if n >= 1e9 else "%.0fM" % (n / 1e6) if n >= 1e6 else "%.0fk" % (n / 1e3))


def _fit_folder(folder):
    """~-shortened paths stay as they are; others keep the LAST two components after '…/' (never cut mid-component)."""
    if folder.startswith("~") or folder.count("/") <= 2:
        return folder
    return "\u2026/" + "/".join(folder.rstrip("/").split("/")[-2:])


def brief(S):
    """<= 1000 bytes including the final newline. Lines are added in priority order, whole or not at all;
    the generation trailer is always present and last."""
    gen = S["generation"]
    trailer = "generation %s" % gen
    phases = S["phases"]
    k = next((i + 1 for i, p in enumerate(phases) if p["id"] == S["focus"]["phase"]), 0)
    idn = S["identity"]
    l1 = "%s · %s · phase %d/%d %s · %s" % (idn["name"], _fit_folder(idn["folder"]), k, len(phases),
                                                          S["focus"].get("label", ""), S["headline"]["tone"])
    st = S.get("stale") or {}
    at = (S.get("judged_at") or "")[:16]
    if st and st.get("commits_since"):
        l2 = "assessment %s · %d commits since" % (at, st["commits_since"])
    elif st:
        l2 = "assessment %s · behind: %s" % (at, C.trim(st.get("why", ""), 60))
    else:
        l2 = "assessment %s · current" % at
    lines = [l1, l2, S["headline"]["text"]]
    need = [d for d in S["decisions"] if d["status"] in ("open", "overdue") and d.get("ready", True) is not False]
    dl = []
    for d in need:
        by = ", by %s" % d["deadline"][:10] if d.get("deadline") else ""
        dl.append("%s needs you: %s (default %s%s)" % (d["id"], d["q"], d["default"], by))
    ov_lines = ["%s overtaken by events: %s (%s)" % (d["id"], C.trim(d.get("overtaken_why", ""), 120), C.trim(d.get("overtaken_ref", ""), 80))
                for d in S["decisions"] if d["status"] == "overtaken"]   # information for one generation, never "needs you"
    tail = []
    ns = S["next_step"]
    tail.append("next: %s (%s)" % (ns["title"], ns["actor"]))
    if st:
        tail.append("stale: %s" % C.trim(st.get("why", ""), 100))
    cv = S.get("coverage") or {}
    if cv.get("coverage") == "partial":
        tail.append("coverage partial %d/%d" % (cv.get("covered", 0), cv.get("total", 0)))
    tot = ((S.get("usage") or {}).get("totals") or {})
    if tot.get("all") is not None:
        uline = "tokens %s (claude %s, codex %s)" % (human(tot.get("all")), human(tot.get("claude")), human(tot.get("codex")))
        if (S.get("usage") or {}).get("stale"):   # the last scan could not finish in time: say which run the numbers are from
            uline += " · usage as of %s" % (str((S["usage"]).get("at") or "")[:16].replace("T", " ") or "an earlier run")
        tail.append(uline)

    rl = ""
    r0 = next((r for r in S.get("repos") or [] if isinstance(r, dict)), None)
    if r0 and isinstance(r0.get("release"), dict) and r0["release"].get("line"):
        rl = "git: " + C.trim(r0["release"]["line"], 200)   # local evidence only; see release_line in pm_collect
    out, used = [], C.blen(trailer) + 1
    for ln in lines:
        if used + C.blen(ln) + 1 <= BRIEF_MAX:
            out.append(ln)
            used += C.blen(ln) + 1
    rel_at = len(out)
    shown = 0
    for i, ln in enumerate(dl):
        left_after = len(dl) - i - 1
        reserve = C.blen("+%d more decisions" % (left_after or 1)) + 1 if left_after else 0
        if used + C.blen(ln) + 1 + reserve <= BRIEF_MAX:
            out.append(ln)
            used += C.blen(ln) + 1
            shown += 1
        else:
            break
    if shown < len(dl):
        more = "+%d more decisions" % (len(dl) - shown)
        out.append(more)
        used += C.blen(more) + 1
    dec_end = len(out)

    def place_extras():
        # overtaken lines sit with the decisions block, ranking just below the next step; then the release line
        nonlocal used, dec_end, rl
        for ln in ov_lines:
            if used + C.blen(ln) + 1 <= BRIEF_MAX:
                out.insert(dec_end, ln)
                dec_end += 1
                used += C.blen(ln) + 1
        if rl and used + C.blen(rl) + 1 <= BRIEF_MAX:
            out.insert(rel_at, rl)
            dec_end += 1
            used += C.blen(rl) + 1
            rl = ""

    # the release line ranks below the decisions and the next step, above stale/coverage/tokens
    for i, ln in enumerate(tail):
        if i == 1:
            place_extras()
        if used + C.blen(ln) + 1 <= BRIEF_MAX:
            out.append(ln)
            used += C.blen(ln) + 1
    if len(tail) == 1:
        place_extras()
    out.append(trailer)
    return "\n".join(out) + "\n"
