# Page design spec (3.2): "H neat"

Approved by the owner; source draft H "Neat" (design drafts removed from the repo in 3.2.1), production file `scripts/project-map-template.html`
(template v6). Renders `state.json` schema `project-map-4`. The earlier 3.1 "Blend" spec is **superseded**; it is kept at the
end of this file for history only.

## Structure (one visible layer, top to bottom)
1. Header: eyebrow "Project map", top-right pill, project name (h1), tagline, one mono meta line.
   - Pill (3.4.0, INTERFACES 13.4): "Needs you" when a ready decision is open, "Nothing needs you" only when none is open and `state.assurance.ok`, else "No decision identified in the checked information". A stale map also shows "Assessment may be out of date · <why>" as its own line under the meta line. A state without `assurance` (before 3.4) keeps the earlier order: stale, "Needs you", "Nothing needs you".
   - Meta line (mono, the only text allowed below 13px): `~/folder` (identity.folder, or `…/` plus the last two components) · branch · date.
   - A "Coverage partial" notice appears under the meta line while coverage is partial.
2. "Since the previous assessment" section (3.4.0, only when `state.since` exists): card background, 1px border, 16px radius; eyebrow with the date, a count line, the attention row, up to three change rows, `not checked: ...`. Then four tiles: Progress (criteria shipped, bar, "n of m"), Phase (k/n and label), Needs you (count of ready decisions), Next step (accent tile, title only).
3. Work area: left, the phase list (keyboard-selectable buttons, `role=tab`, `aria-selected`, arrow keys / Home / End; the current phase is selected by default); right, the selected phase's criteria. The decision block shows only under the current phase: question, lettered options (A, B ...), then "Waits for your answer" for hard-rule decisions, "Default <letter> on <date>" otherwise.
4. "A little more context": disclosures in this order: Plan vs shipped (every criterion, status, evidence ref), Parts, Recent changes, Risks, History, Snapshot (headline, goal, folder, branch @ head, snapshot, assessment, generation, coverage, stale, working tree, next step, watched files), Usage. `?open=1` opens all.

## Type scale (px; desktop / under 700 wide)
h1 60 / 48; h2 28; h3 20; body 17; eyebrow and pill 13; tile label 13; stat 52 / 44; tile note 15 / 13; next-step title 24 / 20; phase name 17; phase state 13; phase count 15 / 13; criterion 17; option 17; answer hint 15; summary 17; table 15 / 13; mono evidence 13. Nothing below 13 except the mono meta line (11 / 10).

## Word limits
Project name 40 bytes; tagline one line (ellipsis); phase label 60; criterion 80; next-step title 80 (wraps on the tile); decision question 140, option label 60; headline 180 (shown in Snapshot).

## Tokens
Background #101011; card #19191b; line #303034; text #efeff0; soft #b7b7bd; muted #96969e; accent #dbb18c (next-step tile on #261e18 with #5a4331 border); selected phase #222225 with #717178 border. System font stack, mono for numbers and refs. Radii 14-22px. Focus ring 2px #d1d1d6.

## Rules that do not change
Embedding: `<script type="application/json" id="state">` placeholder, `<` escaped; all text through `textContent`; no network; `prefers-reduced-motion` removes motion; `<meta name="pm-generation">` stamp; `mobile.html` is generated from the same template. Screenshots: `docs/screenshot.png` (1440x900) and `docs/screenshot-mobile.png` (390 wide, no horizontal overflow). Both come from `docs/demo-state.json`, a fictional project called Lanternfish rendered through the real template.

---
# Superseded: 3.1 "Blend" spec (history)

> Superseded for the page layout by the v4 "Blend" design (2026-10-07): the draft files were removed from the repo in 3.2.1; the palette/typography notes below still inform it.

• Direction: a precision instrument—graphite surfaces, crisp typography and restrained luminous signals.
  Borrow the reference’s strong timeline and compact proportions.

  Five things holding the current page back

  1. The header gives commits, waiting counts and 915M tokens nearly equal weight to the project’s
     condition; it reads like a telemetry dump.

  2. The timeline, criteria chips and critical-path chips repeat the same journey across roughly 320px of
     vertical space.

  3. Large diagonal stripes make ordinary dependency waits look hazardous and visually dominate the active
     work.

  4. Nested panels, pill borders, dashed outlines and connector arcs compete; there is no consistent
     hierarchy of surfaces.

  5. The decision begins around y=675 and is cut off at 900px. Its narrow column forces verbose options to
     wrap while the upper page has ample space.

  Visual system

  • Background #090C12; panel #111620; raised surface #18202C; border #2B3545.
  • Text: primary #EDF2F7, secondary #B6C1D0, muted #8998AC; essential text must meet 4.5:1 contrast.
  • Four accents: cyan #69D9EF active; violet #B6A3FF current milestone; mint #79D9AD complete; amber
    #F2C879 owner attention.

  • Failure uses amber plus an explicit warning icon and label; dependency waits remain neutral. Colour
    always has a text equivalent.

  • Google Fonts: Space Grotesk for titles and prose; IBM Plex Mono for timestamps, IDs and small counts;
    system fallbacks, display=swap.

  • Project title 28/34px, −0.025em tracking; headline 20/28px; card titles 18/24px; body 14/21px.
  • Mono labels 11/16px, +0.08em tracking; numeric metadata 12/18px. Avoid uppercase sentences and mono
    paragraphs.

  • Matte surfaces with a faint top-edge highlight; 1px borders, 14px radii, minimal shadow. Active cards
    get one coloured edge.

  • No backdrop blur or grain. A static, very faint dot field may sit behind the timeline only; glow
    belongs exclusively to the current node.

  • Spacing rhythm: 4/8/12/16/24/32px; 24px card padding, 24px major gutters. Establish hierarchy through
    space before adding borders.

  • Load: one 240ms opacity reveal with at most 4px translation; timeline settles once over 450ms. No
    staggered procession.

  • Only the current-node halo may breathe, gently over 6s, and only for explicitly active work; label the
    snapshot time so animation cannot imply live telemetry.

  • Under prefers-reduced-motion, remove all animation, pulses, translation and transitions; retain the
    static hierarchy.

  Information order at 1440×900

  • Content width 1280px, centred with 80px side margins; start at y=32.
  • y=32–76: project identity left; updated time and owner-attention state right. Move commits and usage
    into details.

  • y=92–148: plain-language headline, at most two lines; tone indicated by a small signal beside it.
  • y=168–272: compact five-stop milestone track; current criterion count and estimate beneath its label.
    “Proposed” is a quiet track annotation.

  • y=296–620: action row—next step left, single open decision right, approximately 40/60 width; decision
    gets all 2–3 options and its consequence/default.

  • Keep decision options as compact labelled rows; preserve material costs, reversibility and readiness.
    The current decision says “Awaiting diagnosis,” rather than demanding a reply.

  • y=644 onward: parts overview left, up to three recent changes right. Dependency explanation appears
    once beside the affected part.

  • Below the fold: remaining criteria, risks, other decisions, trends, usage and evidence in native
    disclosure sections.

  • At 390px: 16px margins; headline → compact current/next milestone summary → decision → next step →
    parts → changes; full milestone track expands vertically.

  • Mobile options stack cost beneath label, use 44px disclosure targets, and wrap normally; critical
    facts never require hover or horizontal scrolling.

  Two quiet “wow” elements

  • Signal rail: thin inline SVG joining milestone nodes; completed segments mint, current endpoint
    violet, future segments neutral. One subtle load reveal; no endlessly travelling particles.

  • Precision beacon: current node with concentric rings, a tiny index and restrained halo. A progress arc
    appears only for counted criteria; unknown progress gets an unsegmented ring.

  Remove

  • Waiting-card hatching, decorative dependency arcs, duplicated critical-path chips, repeated “no
    estimate yet,” oversized remaining-count banner and redundant status pills.

  • Radio-like decision controls unless they actually submit an answer; use clearly labelled option rows.
    Remove empty trend panels and token totals from the first screen.

  VERDICT: Build a sparse graphite instrument panel with a luminous milestone rail and a wide action row
