#!/usr/bin/env python3
"""pm_render: index.html, mobile.html and brief.txt from a state.json dict (INTERFACES-3.2 sections 1, 6.6)."""
import re

import pm_common as C
import pm_validate as VAL

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


FOLDER_MAX = 60


def _fit_folder(folder):
    """13.6 / P14: a ~-shortened path (or a short one) stays as it is up to 60 bytes; anything else becomes `…/<last two
    components>` (never cut mid-component), cut to 60 bytes at a character boundary with `…`. A 200-byte folder can therefore
    never push line 1 out of the brief."""
    if (folder.startswith("~") or folder.count("/") <= 2) and C.blen(folder) <= FOLDER_MAX:
        return folder
    out = "\u2026/" + "/".join(folder.rstrip("/").split("/")[-2:])
    if C.blen(out) <= FOLDER_MAX:
        return out
    return out.encode("utf-8")[: FOLDER_MAX - 3].decode("utf-8", "ignore") + "\u2026"


def _qualifier(S):
    """The first reason the assessment is incomplete, for line 2 (13.4 case c only). A behind map already says why on that line,
    so its own reason is not repeated."""
    for w in (S.get("assurance") or VAL.assurance(S)).get("why") or []:
        if not w.startswith("assessment behind"):
            return C.trim(w, 40)
    return ""


def _line2(S):
    """as of <snapshot minute> · assessed <judged minute> · current | behind: <stale.why <=60> [· <qualifier <=40>]. Never dropped."""
    st = S.get("stale") or {}
    l2 = "as of %s · assessed %s · " % ((S["identity"].get("snapshot_at") or "")[:16], (S.get("judged_at") or "")[:16])
    l2 += "behind: %s" % C.trim(st.get("why", ""), 60) if st else "current"
    q = _qualifier(S) if VAL.needs_text(S) == VAL.NEEDS_TEXT["c"] else ""   # the qualifier is the brief's form of case (c), 13.4
    return l2 + (" \u00b7 " + q if q else "")


def brief(S):
    """<= 1000 bytes including the final newline, whole lines only, in the fixed display order of 13.6. When the lines do not
    fit they are dropped by priority: tokens, git, the change lines (last first), the since line, attention, overtaken,
    stale / coverage (3.5 and 3.6 add their lines to this order); then the decisions collapse into `+N more decisions`.
    Lines 1-3, 6 and the generation trailer are never dropped; line 2 is never cut mid-field (each field has its own cap)."""
    gen = S["generation"]
    trailer = "generation %s" % gen
    phases = S["phases"]
    k = next((i + 1 for i, p in enumerate(phases) if p["id"] == S["focus"]["phase"]), 0)
    idn = S["identity"]
    l1 = "%s · %s · phase %d/%d %s · %s" % (idn["name"], _fit_folder(idn["folder"]), k, len(phases),
                                                          S["focus"].get("label", ""), S["headline"]["tone"])
    l2 = _line2(S)
    l3 = S["headline"]["text"]
    st = S.get("stale") or {}
    need = [d for d in S["decisions"] if d["status"] in ("open", "overdue") and d.get("ready", True) is not False]
    dl = []
    for d in need:
        by = ", by %s" % d["deadline"][:10] if d.get("deadline") else ""
        dl.append((d["id"], "%s needs you: %s (default %s%s)" % (d["id"], d["q"], d["default"], by)))
    ns = S["next_step"]
    l6 = "next: %s (%s)" % (ns["title"], ns["actor"])
    sn = S.get("since") if isinstance(S.get("since"), dict) else None
    l5, l7, l8 = "", "", []
    if sn:
        att = sn.get("attention") or {}
        if att and not (att.get("kind") == "decision" and att.get("id") in {i for i, _ in dl}):   # the D line already says it
            l5 = "attention: %s \u00b7 %s" % (att.get("text", ""), att.get("why", ""))
        n_at = (((sn.get("from") or {}).get("assessed_at")) or "")[:16]
        l7 = "since %s: %d commits \u00b7 %d uncommitted \u00b7 %d changes" % (
            n_at or "the previous assessment", sn.get("commits") or 0, sn.get("dirty") or 0, len(sn.get("changes") or []))
        if isinstance(sn.get("listed"), int) and sn["listed"] < (sn.get("commits") or 0):
            l7 += " \u00b7 %d of %d shown" % (sn["listed"], sn["commits"])
        for c in (sn.get("changes") or [])[:3]:
            l8.append("- %s \u00b7 %s" % (c.get("text", ""), "landed, not checked" if c.get("state") == "landed" else "uncommitted"))
    ov = ["%s overtaken by events: %s (%s)" % (d["id"], C.trim(d.get("overtaken_why", ""), 120), C.trim(d.get("overtaken_ref", ""), 80))
          for d in S["decisions"] if d["status"] == "overtaken"]   # information for one generation, never "needs you"
    rl = ""
    r0 = next((r for r in S.get("repos") or [] if isinstance(r, dict)), None)
    if r0 and isinstance(r0.get("release"), dict) and r0["release"].get("line"):
        rl = "git: " + C.trim(r0["release"]["line"], 200)   # local evidence only; see release_line in pm_collect
    stale_l = ["stale: %s" % C.trim(st.get("why", ""), 100)] if st else []
    cv = S.get("coverage") or {}
    if cv.get("coverage") == "partial":
        stale_l.append("coverage partial %d/%d" % (cv.get("covered", 0), cv.get("total", 0)))
    tl = ""
    tot = ((S.get("usage") or {}).get("totals") or {})
    if tot.get("all") is not None:
        tl = "tokens %s (claude %s, codex %s)" % (human(tot.get("all")), human(tot.get("claude")), human(tot.get("codex")))
        if (S.get("usage") or {}).get("stale"):   # the last scan could not finish in time: say which run the numbers are from
            tl += " · usage as of %s" % (str((S["usage"]).get("at") or "")[:16].replace("T", " ") or "an earlier run")

    # sections in display order; each droppable group is a list so its lines can go one by one, last first
    sec = {"d": [t for _i, t in dl], "5": [l5] if l5 else [], "7": [l7] if l7 else [], "8": l8, "9": ov, "10": [rl] if rl else [],
           "11": stale_l, "12": [tl] if tl else []}
    order = ["d", "5", "6", "7", "8", "9", "10", "11", "12"]

    def render(more=0):
        out = [l1, l2, l3]
        for key in order:
            if key == "6":
                out.append(l6)
            else:
                out += sec[key]
            if key == "d" and more:
                out.append("+%d more decisions" % more)
        return out + [trailer]

    def size(lines):
        return sum(C.blen(x) + 1 for x in lines)

    for key in ("12", "10", "8", "7", "5", "9", "11"):   # drop order of 13.6 (6b and 11b join in 3.5 / 3.6)
        while size(render()) > BRIEF_MAX and sec[key]:
            sec[key].pop()
    if size(render()) > BRIEF_MAX and sec["d"]:   # the existing `+N more decisions` collapsing
        total = len(sec["d"])
        while sec["d"] and size(render(total - len(sec["d"]))) > BRIEF_MAX:
            sec["d"].pop()
        out = render(total - len(sec["d"]))
    else:
        out = render()
    for drop in (l6, l3):   # last resort for hand-made oversized states: whole lines only, line 2 and the trailer stay
        if size(out) > BRIEF_MAX and drop in out:
            out.remove(drop)
    return "\n".join(out) + "\n"
