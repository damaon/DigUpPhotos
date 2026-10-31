// The page `digup serve` shows: search, people and folders, in one file with nothing loaded from elsewhere (it works
// offline, and the page's Content-Security-Policy keeps it that way).
enum WebPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DigUp</title>
<style>
:root {
  --bg: #f6f5f2; --panel: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #e2e0dc; --accent: #2f6fde;
  --accent-text: #ffffff; --chip: #ecebe7; --shadow: 0 1px 2px rgba(0,0,0,.06), 0 4px 16px rgba(0,0,0,.06);
  --warn: #b25b00; --ok: #2e7d32;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161617; --panel: #1f1f21; --text: #f2f2f2; --muted: #9a9aa0; --line: #2e2e31; --accent: #5b8ff0;
    --chip: #2a2a2d; --shadow: 0 1px 2px rgba(0,0,0,.4), 0 4px 16px rgba(0,0,0,.3); --warn: #f0a24a; --ok: #6cc070;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, Ubuntu, sans-serif; }
button, input, select { font: inherit; color: inherit; }
header { position: sticky; top: 0; z-index: 5; background: color-mix(in srgb, var(--bg) 92%, transparent);
  backdrop-filter: blur(12px); border-bottom: 1px solid var(--line); }
.bar { max-width: 1280px; margin: 0 auto; padding: 12px 16px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
.logo { font-weight: 700; letter-spacing: -.02em; font-size: 18px; margin-right: 4px; }
.logo span { color: var(--accent); }
nav { display: flex; gap: 4px; }
nav button { border: 0; background: none; padding: 6px 12px; border-radius: 8px; cursor: pointer; color: var(--muted); }
nav button.on { background: var(--chip); color: var(--text); font-weight: 600; }
#q { flex: 1 1 320px; min-width: 0; padding: 10px 14px; border-radius: 10px; border: 1px solid var(--line);
  background: var(--panel); outline: none; font-size: 16px; }
#q:focus { border-color: var(--accent); }
.filters { max-width: 1280px; margin: 0 auto; padding: 0 16px 10px; display: flex; gap: 6px; flex-wrap: wrap; align-items: center; }
.chip { border: 1px solid var(--line); background: var(--panel); padding: 4px 10px; border-radius: 999px; cursor: pointer;
  font-size: 13px; color: var(--muted); }
.chip.on { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
.chip.person { color: var(--text); }
#when { width: 150px; padding: 4px 10px; border-radius: 999px; border: 1px solid var(--line); background: var(--panel); font-size: 13px; }
main { max-width: 1280px; margin: 0 auto; padding: 16px; }
.status { font-size: 13px; color: var(--muted); display: flex; gap: 8px; align-items: center; margin-left: auto; }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex: none; }
.dot.busy { background: var(--accent); animation: pulse 1.2s infinite; }
.dot.ok { background: var(--ok); } .dot.warn { background: var(--warn); }
@keyframes pulse { 50% { opacity: .35; } }
.notice { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; margin-bottom: 16px;
  box-shadow: var(--shadow); display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
.notice b { font-weight: 600; }
.btn { border: 1px solid var(--line); background: var(--panel); padding: 6px 12px; border-radius: 8px; cursor: pointer; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
.btn:disabled { opacity: .5; cursor: default; }
progress { width: 220px; height: 6px; accent-color: var(--accent); }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 12px; }
.card { background: var(--panel); border-radius: 10px; overflow: hidden; box-shadow: var(--shadow); cursor: pointer;
  display: flex; flex-direction: column; min-width: 0; }
.card .pic { aspect-ratio: 4 / 3; background: var(--chip); position: relative; overflow: hidden; }
.card .pic img { width: 100%; height: 100%; object-fit: cover; display: block; }
.card .badge { position: absolute; left: 6px; bottom: 6px; background: rgba(0,0,0,.65); color: #fff; font-size: 11px;
  padding: 1px 6px; border-radius: 4px; }
.card .meta { padding: 8px 10px; font-size: 12px; min-width: 0; }
.card .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 13px; }
.card .sub { color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.card .excerpt { color: var(--muted); display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden;
  margin-top: 4px; }
.card.doc .pic { display: flex; align-items: center; justify-content: center; font-size: 34px; color: var(--muted); }
.weak { opacity: .7; }
mark { background: color-mix(in srgb, var(--accent) 25%, transparent); color: inherit; border-radius: 3px; padding: 0 1px; }
.more { margin: 18px 0; text-align: center; }
.empty { color: var(--muted); padding: 48px 0; text-align: center; }
.people { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 16px; }
.person { text-align: center; cursor: pointer; }
.face { width: 110px; height: 110px; border-radius: 50%; overflow: hidden; position: relative; margin: 0 auto 8px;
  background: var(--chip); box-shadow: var(--shadow); }
.face img { position: absolute; max-width: none; }
.person .pname { font-weight: 600; font-size: 14px; }
.person .count { color: var(--muted); font-size: 12px; }
.head { display: flex; gap: 12px; align-items: center; margin-bottom: 16px; flex-wrap: wrap; }
.head h2 { margin: 0; font-size: 20px; }
.head input { padding: 6px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--panel); }
.folders { background: var(--panel); border-radius: 12px; box-shadow: var(--shadow); overflow: hidden; margin-bottom: 16px; }
.folder { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-top: 1px solid var(--line); }
.folder:first-child { border-top: 0; }
.folder .path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.folder .gone { color: var(--warn); font-size: 12px; }
.counts { display: flex; gap: 18px; flex-wrap: wrap; color: var(--muted); font-size: 13px; margin: 8px 0 16px; }
.counts b { color: var(--text); font-weight: 600; }
.overlay { position: fixed; inset: 0; background: rgba(0,0,0,.82); z-index: 20; display: none; flex-direction: column; }
.overlay.open { display: flex; }
.overlay .top { display: flex; gap: 8px; align-items: center; padding: 10px 14px; color: #eee; }
.overlay .title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
.overlay .top .btn { background: rgba(255,255,255,.12); border-color: transparent; color: #fff; }
.overlay .stage { flex: 1; min-height: 0; display: flex; align-items: center; justify-content: center; padding: 0 16px 16px; }
.overlay .stage img, .overlay .stage video { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 6px; }
.overlay .text { background: var(--panel); color: var(--text); max-width: 820px; width: 100%; max-height: 100%; overflow: auto;
  padding: 24px 28px; border-radius: 10px; white-space: pre-wrap; }
.overlay .info { color: #bbb; font-size: 13px; padding: 0 16px 12px; text-align: center; }
.browser { position: fixed; inset: 0; z-index: 30; background: rgba(0,0,0,.45); display: none; align-items: center; justify-content: center; padding: 16px; }
.browser.open { display: flex; }
.browser .box { background: var(--panel); border-radius: 12px; width: 560px; max-width: 100%; max-height: 80vh; display: flex;
  flex-direction: column; box-shadow: var(--shadow); }
.browser .where { padding: 12px 16px; border-bottom: 1px solid var(--line); font-weight: 600; overflow-wrap: anywhere; }
.browser .list { overflow: auto; flex: 1; }
.browser .item { padding: 8px 16px; cursor: pointer; border-top: 1px solid var(--line); }
.browser .item:hover { background: var(--chip); }
.browser .actions { padding: 12px 16px; display: flex; gap: 8px; justify-content: flex-end; border-top: 1px solid var(--line); }
.hidden { display: none !important; }
@media (max-width: 600px) {
  .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
  #q { flex-basis: 100%; order: 3; }
  .status { width: 100%; order: 4; margin-left: 0; }
  .people { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .face { width: 88px !important; height: 88px !important; }
}
html, body { overflow-x: hidden; }
</style>
</head>
<body>
<header>
  <div class="bar">
    <div class="logo">Dig<span>Up</span></div>
    <nav>
      <button data-tab="search" class="on">Search</button>
      <button data-tab="people">People</button>
      <button data-tab="folders">Folders</button>
    </nav>
    <input id="q" type="search" placeholder="Search by what it shows or says: “dog on the beach”, “invoice 2023”…" autofocus>
    <div class="status"><span class="dot" id="dot"></span><span id="statusText">…</span></div>
  </div>
  <div class="filters" id="filters">
    <button class="chip on" data-kind="">All</button>
    <button class="chip" data-kind="image">Photos</button>
    <button class="chip" data-kind="screenshot">Screenshots</button>
    <button class="chip" data-kind="video">Videos</button>
    <button class="chip" data-kind="pdf">PDFs</button>
    <button class="chip" data-kind="doc">Documents</button>
    <button class="chip" data-kind="audio">Sound</button>
    <input id="when" placeholder="When: 2023, july 2023…">
    <span id="personChips"></span>
  </div>
</header>
<main>
  <div id="notices"></div>
  <section id="tab-search"><div id="results"></div></section>
  <section id="tab-people" class="hidden"></section>
  <section id="tab-folders" class="hidden"></section>
</main>

<div class="overlay" id="viewer">
  <div class="top">
    <button class="btn" id="prev" title="Previous (←)">‹</button>
    <button class="btn" id="next" title="Next (→)">›</button>
    <div class="title" id="vTitle"></div>
    <button class="btn" id="vOpen">Open</button>
    <button class="btn" id="vReveal">Show in folder</button>
    <button class="btn" id="vClose" title="Close (Esc)">✕</button>
  </div>
  <div class="stage" id="vStage"></div>
  <div class="info" id="vInfo"></div>
</div>

<div class="browser" id="browser">
  <div class="box">
    <div class="where" id="bWhere"></div>
    <div class="list" id="bList"></div>
    <div class="actions">
      <button class="btn" id="bCancel">Cancel</button>
      <button class="btn primary" id="bChoose">Index this folder</button>
    </div>
  </div>
</div>

<script>
"use strict";
const $ = (s, el = document) => el.querySelector(s);
const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  for (const child of children) if (child != null) node.append(child);
  return node;
};
const api = async (path, body) => {
  const response = await fetch(path, body === undefined ? {} : {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || response.statusText);
  return data;
};
const thumb = (path, size, loc) => `/api/thumb?path=${encodeURIComponent(path)}&size=${size}` + (loc != null ? `&loc=${loc}` : "");
const fileURL = path => `/api/file?path=${encodeURIComponent(path)}`;
const clock = s => { s = Math.floor(s); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${x}` : `${m}:${x}`; };
// Excerpts mark the query's words «like this».
const marked = text => { const out = el("span"); text.split(/(«[^»]*»)/).forEach(part => out.append(
  part.startsWith("«") ? el("mark", { textContent: part.slice(1, -1) }) : part)); return out; };
// "2022:06:29 23:51:23" (EXIF) or "2022-06-29T23:51:23Z" as "29 Jun 2022, 23:51".
const taken = text => {
  const m = /^(\d{4})[:-](\d\d)[:-](\d\d)[ T](\d\d):(\d\d)/.exec(text || "");
  if (!m) return text;
  const date = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
  return date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" }) + ", " + `${m[4]}:${m[5]}`;
};
const icons = { pdf: "📄", doc: "📝", audio: "🎵", video: "🎬", image: "🖼", screenshot: "🖥" };
const kindNames = { image: "photos", screenshot: "screenshots", video: "videos", pdf: "PDFs", doc: "documents", audio: "sound" };

const state = { tab: "search", kind: "", people: [], peopleList: [], results: [], showWeak: false, status: null };

// Tabs
for (const button of document.querySelectorAll("nav button")) button.onclick = () => show(button.dataset.tab);
function show(tab) {
  state.tab = tab;
  for (const button of document.querySelectorAll("nav button")) button.classList.toggle("on", button.dataset.tab === tab);
  for (const name of ["search", "people", "folders"]) $(`#tab-${name}`).classList.toggle("hidden", name !== tab);
  $("#filters").classList.toggle("hidden", tab !== "search");
  if (tab === "people") renderPeople();
  if (tab === "folders") renderFolders();
  if (location.hash !== (tab === "search" ? "" : "#" + tab)) history.replaceState(null, "", location.pathname + location.search + (tab === "search" ? "" : "#" + tab));
}

// Search
let timer, asked = 0;
$("#q").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(search, 250); });
$("#q").addEventListener("keydown", e => { if (e.key === "Enter") { clearTimeout(timer); search(); } });
$("#when").addEventListener("change", search);
for (const chip of document.querySelectorAll("[data-kind]")) chip.onclick = () => {
  state.kind = chip.dataset.kind;
  for (const other of document.querySelectorAll("[data-kind]")) other.classList.toggle("on", other === chip);
  search();
};

async function search() {
  if (state.tab !== "search") show("search");
  const q = $("#q").value.trim(), when = $("#when").value.trim();
  const params = new URLSearchParams();
  if (q) params.set("q", q);
  if (when) params.set("when", when);
  if (state.kind) params.set("kind", state.kind);
  for (const id of state.people) params.append("person", id);
  const mine = ++asked;
  history.replaceState(null, "", q ? "?q=" + encodeURIComponent(q) : location.pathname);
  if (!q && !when && !state.people.length) { state.results = []; renderResults(); return; }
  $("#results").replaceChildren(el("div", { className: "empty", textContent: "Searching…" }));
  try {
    const data = await api("/api/search?" + params);
    if (mine !== asked) return;
    state.results = data.results; state.showWeak = false; state.when = data.when;
    renderResults();
  } catch (error) {
    if (mine === asked) $("#results").replaceChildren(el("div", { className: "empty", textContent: error.message }));
  }
}

function renderPersonChips() {
  const chips = state.people.map(id => {
    const person = state.peopleList.find(p => p.id === id);
    return el("button", { className: "chip on person", textContent: `${person ? person.displayName : "Person " + id} ✕`,
      onclick: () => { state.people = state.people.filter(x => x !== id); renderPersonChips(); search(); } });
  });
  $("#personChips").replaceChildren(...chips);
}

function card(hit, index) {
  const visual = ["image", "screenshot", "video", "pdf"].includes(hit.kind);
  let badge = null;
  if (hit.kind === "pdf" && hit.loc != null) badge = `p. ${hit.loc}`;
  if ((hit.kind === "video" || hit.kind === "audio") && hit.loc != null) badge = clock(hit.loc);
  const pic = visual
    ? el("div", { className: "pic" }, el("img", { loading: "lazy", src: thumb(hit.path, 360, hit.kind === "image" ? null : hit.loc),
        alt: "", onerror: e => { e.target.replaceWith(el("span", { textContent: icons[hit.kind] || "📁" })); } }))
    : el("div", { className: "pic" }, icons[hit.kind] || "📁");
  if (badge) pic.append(el("span", { className: "badge", textContent: badge }));
  const meta = el("div", { className: "meta" },
    el("div", { className: "name", textContent: hit.name, title: hit.path }),
    el("div", { className: "sub", textContent: hit.taken ? taken(hit.taken) : hit.folder, title: hit.folder }));
  if (hit.excerpt && hit.kind !== "image") meta.append(el("div", { className: "excerpt" }, marked(hit.excerpt)));
  return el("div", { className: "card" + (visual ? "" : " doc") + (hit.strong ? "" : " weak"), onclick: () => openViewer(index) }, pic, meta);
}

function renderResults() {
  const box = $("#results");
  const all = state.results;
  if (!all.length) {
    const q = $("#q").value.trim() || $("#when").value.trim() || state.people.length;
    box.replaceChildren(el("div", { className: "empty", textContent: q ? "Nothing close enough. Try other words, or fewer filters."
      : "Type what you remember: what's in the photo, a word from the document, a time." }));
    return;
  }
  const strong = all.filter(h => h.strong).length;
  const shown = state.showWeak ? all : all.slice(0, Math.max(strong, 1));
  const children = [];
  if (state.when) children.push(el("div", { className: "head" }, el("div", { className: "count", textContent: `Taken in ${state.when}` })));
  children.push(el("div", { className: "grid" }, ...shown.map((hit, i) => card(hit, i))));
  if (shown.length < all.length) children.push(el("div", { className: "more" },
    el("button", { className: "btn", textContent: `Show ${all.length - shown.length} weaker matches`,
      onclick: () => { state.showWeak = true; renderResults(); } })));
  box.replaceChildren(...children);
}

// Viewer
let viewing = -1;
function openViewer(index) {
  viewing = index;
  const hit = state.results[index];
  if (!hit) return;
  $("#viewer").classList.add("open");
  $("#vTitle").textContent = hit.name;
  const stage = $("#vStage");
  const info = [hit.folder];
  if (hit.taken) info.push(taken(hit.taken));
  if (hit.kind === "pdf" && hit.loc != null) info.push(`page ${hit.loc}`);
  if ((hit.kind === "video" || hit.kind === "audio") && hit.loc != null) info.push(`at ${clock(hit.loc)}`);
  $("#vInfo").textContent = info.join(" · ");
  if (hit.kind === "image" || hit.kind === "screenshot") {
    stage.replaceChildren(el("img", { src: thumb(hit.path, 1600), alt: hit.name }));
  } else if (hit.kind === "video" || hit.kind === "audio") {
    const media = el(hit.kind === "video" ? "video" : "audio", { controls: true, autoplay: true, src: fileURL(hit.path) + (hit.loc != null ? `#t=${hit.loc}` : "") });
    if (hit.kind === "video") media.poster = thumb(hit.path, 1280, hit.loc);
    stage.replaceChildren(media);
  } else if (hit.kind === "pdf") {
    stage.replaceChildren(el("img", { src: thumb(hit.path, 1600, hit.loc ?? 1), alt: hit.name }));
  } else {
    const text = el("div", { className: "text" }, marked(hit.excerpt || ""));
    stage.replaceChildren(text);
    api(`/api/text?segment=${hit.segmentID}`).then(d => { if (d.text) text.textContent = d.text; }).catch(() => {});
  }
}
function closeViewer() { $("#viewer").classList.remove("open"); $("#vStage").replaceChildren(); viewing = -1; }
$("#vClose").onclick = closeViewer;
$("#prev").onclick = () => viewing > 0 && openViewer(viewing - 1);
$("#next").onclick = () => viewing < state.results.length - 1 && openViewer(viewing + 1);
$("#vOpen").onclick = () => api("/api/open", { path: state.results[viewing].path }).catch(e => alert(e.message));
$("#vReveal").onclick = () => api("/api/open", { path: state.results[viewing].path, reveal: true }).catch(e => alert(e.message));
document.addEventListener("keydown", e => {
  if (viewing < 0) { if (e.key === "/" && document.activeElement !== $("#q")) { e.preventDefault(); $("#q").focus(); } return; }
  if (e.key === "Escape") closeViewer();
  if (e.key === "ArrowLeft") $("#prev").click();
  if (e.key === "ArrowRight") $("#next").click();
});

// People
async function loadPeople() {
  const data = await api("/api/people");
  state.peopleList = data.people;
  return data.people;
}

// A square around the face (Vision's box: normalized, origin bottom-left), kept inside the photo.
function faceCrop(person, size) {
  const box = el("div", { className: "face" });
  box.style.width = box.style.height = size + "px";
  if (!person.face) return box;
  const [x, y, w, h] = person.face.box;
  const img = el("img", { loading: "lazy", src: thumb(person.face.path, 640), alt: "" });
  img.onload = () => {
    const W = img.naturalWidth, H = img.naturalHeight;
    const side = Math.min(Math.max(w * W, h * H) * 1.7, W, H);
    const cx = Math.min(Math.max((x + w / 2) * W, side / 2), W - side / 2);
    const cy = Math.min(Math.max((1 - y - h / 2) * H, side / 2), H - side / 2);
    const scale = size / side;
    Object.assign(img.style, { width: W * scale + "px", height: H * scale + "px",
      left: -(cx - side / 2) * scale + "px", top: -(cy - side / 2) * scale + "px", visibility: "visible" });
  };
  img.style.visibility = "hidden";
  box.append(img);
  return box;
}

async function renderPeople(selected) {
  const tab = $("#tab-people");
  const people = await loadPeople().catch(e => { tab.replaceChildren(el("div", { className: "empty", textContent: e.message })); });
  if (!people) return;
  if (!people.length) {
    tab.replaceChildren(el("div", { className: "empty", textContent: "No people yet. They show up once photos with faces are indexed." }));
    return;
  }
  if (selected != null) return renderPerson(people.find(p => p.id === selected));
  const grid = el("div", { className: "people" }, ...people.map(person => el("div", { className: "person", onclick: () => renderPerson(person) },
    faceCrop(person, 110), el("div", { className: "pname", textContent: person.displayName }),
    el("div", { className: "count", textContent: `${person.photos} photo${person.photos === 1 ? "" : "s"}` }))));
  tab.replaceChildren(grid);
}

async function renderPerson(person) {
  if (!person) return renderPeople();
  const tab = $("#tab-people");
  const name = el("input", { value: person.name || "", placeholder: "Name" });
  const save = async () => { await api("/api/people/rename", { id: person.id, name: name.value }); person.name = name.value; };
  name.addEventListener("keydown", e => { if (e.key === "Enter") save().then(() => name.blur()); });
  name.addEventListener("change", save);
  const merge = el("select", {}, el("option", { value: "", textContent: "Same person as…" }),
    ...state.peopleList.filter(p => p.id !== person.id).map(p => el("option", { value: p.id, textContent: p.displayName })));
  merge.onchange = async () => {
    if (!merge.value) return;
    const other = state.peopleList.find(p => p.id === Number(merge.value));
    if (!confirm(`Put ${person.displayName} and ${other.displayName} together?`)) { merge.value = ""; return; }
    await api("/api/people/merge", { keeper: other.id, other: person.id });
    renderPeople(other.id);
  };
  const among = el("button", { className: "btn", textContent: "Search among their photos", onclick: () => {
    state.people = [person.id]; renderPersonChips(); show("search"); $("#q").focus(); search(); } });
  const head = el("div", { className: "head" }, el("button", { className: "btn", textContent: "‹ People", onclick: () => renderPeople() }),
    faceCrop(person, 56), name, merge, among);
  const box = el("div", { className: "empty", textContent: "Loading…" });
  tab.replaceChildren(head, box);
  const data = await api(`/api/photos?person=${person.id}&limit=1000`);
  state.results = data.results;
  box.replaceWith(el("div", { className: "grid" }, ...data.results.map((hit, i) => card(hit, i))));
}

// Folders
async function renderFolders() {
  const tab = $("#tab-folders");
  const data = await api("/api/folders");
  const list = el("div", { className: "folders" }, ...data.folders.map(folder => el("div", { className: "folder" },
    el("span", { className: "path", textContent: folder.display, title: folder.path }),
    folder.there ? null : el("span", { className: "gone", textContent: "not there now" }),
    el("button", { className: "btn", textContent: "Remove", onclick: async () => {
      if (!confirm(`Stop indexing ${folder.display}? What was found in it leaves the index.`)) return;
      await api("/api/folders", { folders: data.folders.map(f => f.path).filter(p => p !== folder.path) });
      renderFolders();
    } }))));
  if (!data.folders.length) list.append(el("div", { className: "folder" }, el("span", { className: "path", textContent: "No folders yet." })));
  const only = el("input", { type: "checkbox", checked: data.photosAndVideoOnly, onchange: async () => {
    await api("/api/folders", { folders: data.folders.map(f => f.path), photosAndVideoOnly: only.checked }); } });
  const counts = el("div", { className: "counts", id: "folderCounts" });
  tab.replaceChildren(
    el("div", { className: "head" }, el("h2", { textContent: "Folders DigUp looks through" }),
      el("button", { className: "btn primary", textContent: "Add folder…", onclick: () => browse(data.home, data.folders.map(f => f.path)) }),
      el("button", { className: "btn", textContent: "Look for changes now", onclick: () => api("/api/sync", {}) })),
    list,
    el("label", { className: "head" }, only, " Only photos and videos (skip screenshots, PDFs, documents and sound)"),
    counts);
  fillCounts(state.status);
}

function fillCounts(s) {
  const counts = $("#folderCounts");
  if (!counts || !s) return;
  const parts = Object.entries(s.files || {}).map(([kind, count]) =>
    el("span", {}, el("b", { textContent: count.toLocaleString() }), ` ${kindNames[kind] || kind}`));
  if (s.pending) parts.push(el("span", {}, el("b", { textContent: s.pending.toLocaleString() }), " still to read"));
  parts.push(el("span", { textContent: `Index: ${s.index}` }));
  counts.replaceChildren(...parts);
}

let browsing = null;
async function browse(path, current) {
  const data = await api("/api/browse?path=" + encodeURIComponent(path)).catch(e => { alert(e.message); });
  if (!data) return;
  browsing = { path: data.path, current };
  $("#browser").classList.add("open");
  $("#bWhere").textContent = data.display;
  const items = [];
  if (data.parent) items.push(el("div", { className: "item", textContent: "‹ Up", onclick: () => browse(data.parent, current) }));
  for (const name of data.folders) items.push(el("div", { className: "item", textContent: "📁 " + name,
    onclick: () => browse(data.path.replace(/[\\/]$/, "") + (data.path.includes("\\") ? "\\" : "/") + name, current) }));
  $("#bList").replaceChildren(...items);
}
$("#bCancel").onclick = () => $("#browser").classList.remove("open");
$("#bChoose").onclick = async () => {
  $("#browser").classList.remove("open");
  await api("/api/folders", { folders: [...browsing.current, browsing.path] }).catch(e => alert(e.message));
  renderFolders();
};

// Status
async function poll() {
  try {
    const s = await api("/api/status");
    state.status = s;
    const dot = $("#dot"), text = $("#statusText");
    const searchable = Object.values(s.files || {}).reduce((a, b) => a + b, 0);
    if (s.phase === "indexing" || s.phase === "reading long files") {
      dot.className = "dot busy";
      text.textContent = `${s.phase === "indexing" ? "Reading" : "Reading the rest of"} ${s.done.toLocaleString()} of ${s.total.toLocaleString()}` + (s.file ? ` · ${s.file}` : "");
    } else if (s.phase === "syncing") {
      dot.className = "dot busy"; text.textContent = "Looking through the folders…";
    } else if (!s.model.ready) {
      dot.className = "dot warn"; text.textContent = "Searching names only until the model is here";
    } else {
      dot.className = "dot ok"; text.textContent = `${searchable.toLocaleString()} files` + (s.pending ? ` · ${s.pending.toLocaleString()} to read` : "");
    }
    renderNotices(s);
    fillCounts(s);
  } catch (error) {
    $("#dot").className = "dot warn"; $("#statusText").textContent = "DigUp isn't running";
  }
  setTimeout(poll, state.status && state.status.phase === "idle" ? 4000 : 1500);
}

function renderNotices(s) {
  const notices = [];
  if (!s.model.ready) {
    const progress = s.model.downloading ? el("progress", { max: s.model.total, value: s.model.done }) : null;
    notices.push(el("div", { className: "notice" },
      el("div", {}, el("b", { textContent: "The model isn't here yet. " }),
        "DigUp needs it (865 MB, once) to search by meaning and to read photos, sound and video. Until then it finds files by name."),
      progress,
      s.model.downloading ? el("span", { textContent: `${Math.round(s.model.done / s.model.total * 100)}%` })
        : el("button", { className: "btn primary", textContent: "Download it", onclick: e => { e.target.disabled = true; api("/api/model/download", {}); } }),
      s.model.error ? el("span", { textContent: s.model.error }) : null));
  }
  if (state.status && s.phase === "no folders") {
    notices.push(el("div", { className: "notice" }, el("div", {}, el("b", { textContent: "Choose what to search. " }), "Add the folders with your photos and documents."),
      el("button", { className: "btn primary", textContent: "Add folder…", onclick: () => api("/api/folders").then(d => browse(d.home, d.folders.map(f => f.path))) })));
  }
  if (s.missing && s.missing.length) notices.push(el("div", { className: "notice" }, `Not there now (what was found in them stays): ${s.missing.join(", ")}`));
  if (s.error) notices.push(el("div", { className: "notice" }, el("b", { textContent: "Indexing stopped: " }), s.error));
  $("#notices").replaceChildren(...notices);
}

loadPeople().then(renderPersonChips).catch(() => {});
const start = new URLSearchParams(location.search).get("q");
if (location.hash.length > 1) show(location.hash.slice(1));
else if (start) { $("#q").value = start; search(); } else renderResults();
poll();
</script>
</body>
</html>
"""#
}
