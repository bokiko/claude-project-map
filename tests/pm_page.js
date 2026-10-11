#!/usr/bin/env node
// pm_page.js: run the page JavaScript of a published index.html against a tiny DOM shim and print what the page says.
//   node pm_page.js index.html [STATE_PATCH_JSON]   -> one JSON object on stdout
// STATE_PATCH_JSON (optional) is shallow-merged over the embedded state first (used to test wording without a publish).
// No browser needed. The shim keeps only what the template uses; it records every element created, so a test can prove
// that text from the repository never became markup (no <script>, no innerHTML).
'use strict';
const fs = require('fs'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const blob = /<script type="application\/json" id="state">([\s\S]*?)<\/script>/.exec(html)[1];
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
const js = scripts[scripts.length - 1][1];
const state = JSON.parse(blob);
if (process.argv[3]) Object.assign(state, JSON.parse(process.argv[3]));

const created = [];
class Text { constructor(t) { this.data = String(t); this.parent = null; } get textContent() { return this.data; } }
class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase(); this.children = []; this.parent = null; this.attrs = {}; this.dataset = {};
    this.className = ''; this.hidden = false; this.style = {}; this._text = null; this.tabIndex = 0; this.title = ''; this.type = ''; this.open = false;
  }
  get textContent() { return this._text !== null ? this._text : this.children.map(c => c.textContent).join(''); }
  set textContent(v) { this._text = String(v); this.children = []; }
  _adopt() { if (this._text !== null) { const t = new Text(this._text); t.parent = this; this.children = [t]; this._text = null; } }
  append(...xs) { this._adopt(); for (const x of xs) { const n = typeof x === 'string' ? new Text(x) : x; n.parent = this; this.children.push(n); } }
  replaceChildren(...xs) { this.children = []; this._text = null; this.append(...xs); }
  after(n) { const i = this.parent.children.indexOf(this); n.parent = this.parent; this.parent.children.splice(i + 1, 0, n); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  addEventListener() {}
  focus() {}
}
const root = new El('body'), byId = {};
function getElementById(id) {
  if (id === 'state') { const e = new El('script'); e.textContent = blob; return e; }
  if (!byId[id]) {
    const e = new El('x'); e.id = id; e.parent = root; root.children.push(e); byId[id] = e;
    const tag = new RegExp('<[a-z0-9]+[^>]*\\sid="' + id + '"[^>]*>').exec(html);
    e.hidden = !!(tag && /\shidden(\s|>|=)/.test(tag[0]));   // `hidden` declared in the markup
  }
  return byId[id];
}
const document = {
  title: '', getElementById, createTextNode: t => new Text(t), querySelectorAll: () => [],
  createElement: tag => { created.push(String(tag).toLowerCase()); return new El(tag); },
};
const ctx = { document, location: { search: '' }, URLSearchParams, console };
const src = js.replace(/let state=null;try\{state=JSON\.parse\(document\.getElementById\('state'\)\.textContent\);\}catch\(e\)\{\}/,
  'let state=__STATE__;');
if (src === js) { console.log(JSON.stringify({ error: 'template state line changed; update pm_page.js' })); process.exit(0); }
ctx.__STATE__ = state;
let err = null;
try { vm.runInNewContext(src, ctx); } catch (e) { err = String(e && e.message || e); }

function t(id) { return byId[id] ? byId[id].textContent : null; }
function flat(n) { return n.children.length > 1 ? n.children.map(x => x.textContent).join(' | ') : n.textContent; }
function blocks(el) {   // the visible blocks of a section: direct children, list items one by one, sub-parts joined by " | "
  const out = [];
  for (const c of el.children) {
    if (c.tagName === 'UL') for (const li of c.children) out.push(flat(li));
    else out.push(flat(c));
  }
  return out;
}
const since = getElementById('since');   // declared hidden in the markup; shown only when the script fills it
const snapRows = [];
const walk = n => { if (n.className === 'snapshot-row') snapRows.push(n.children.map(c => c.textContent)); (n.children || []).forEach(walk); };
walk(root);
console.log(JSON.stringify({
  error: err, pill: t('needs-pill'), count: t('decision-count'), note: t('decision-note'),
  sinceHidden: since ? since.hidden : null, since: since && !since.hidden ? blocks(since) : [],
  attention: since && !since.hidden ? since.children.filter(c => c.dataset && c.dataset.attention).map(c => c.dataset.attention) : [],
  stale: root.children.filter(c => c.className === 'stale').map(c => c.textContent),
  snapshot: snapRows, created: created, scripts: created.filter(x => x === 'script' || x === 'iframe').length,
  tagline: t('tagline'),
}));
