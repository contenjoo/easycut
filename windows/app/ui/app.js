// EasyCut for Windows — 화면 로직 (상태, 명령, 패널)
import { Timeline } from "./timeline.js";
import { Player } from "./player.js";

const tauri = window.__TAURI__;
const invoke = (cmd, args) => tauri.core.invoke(cmd, args);
const listen = (ev, f) => tauri.event.listen(ev, f);
const $ = (s) => document.querySelector(s);

// MARK: 상태

export const S = {
  project: null,
  words: [],
  path: null,
  dirty: false,
  canUndo: false,
  canRedo: false,
  sel: new Set(),
  selWords: new Set(),
  time: 0,
  markIn: null,
  markOut: null,
  zoom: 40,
  silencePreview: [],
  language: localStorage.getItem("sttLanguage") || (window.LANG === "ko" ? "ko" : "en"),
};

export const U = {
  clipDur: (c) => Math.max(0, (c.sourceOut - c.sourceIn) / (c.speed || 1)),
  clipEnd: (c) => c.start + U.clipDur(c),
  asset: (id) => S.project?.assets.find((a) => a.id === id),
  duration: () => {
    const p = S.project;
    if (!p) return 0;
    let d = 0;
    for (const t of p.tracks) for (const c of t.clips) d = Math.max(d, U.clipEnd(c));
    for (const c of p.captions) d = Math.max(d, c.end);
    return d;
  },
  clips: () => S.project?.tracks.flatMap((t, ti) => t.clips.map((c) => ({ c, ti }))) ?? [],
  findClip: (id) => U.clips().find((x) => x.c.id === id),
  fmt: (t) => {
    t = Math.max(0, t || 0);
    const m = Math.floor(t / 60), s = Math.floor(t % 60), cs = Math.floor((t * 100) % 100);
    const h = Math.floor(m / 60);
    const mm = h ? String(m % 60).padStart(2, "0") : String(m).padStart(2, "0");
    return (h ? h + ":" : "") + `${mm}:${String(s).padStart(2, "0")}.${String(cs).padStart(2, "0")}`;
  },
  trackName: (n) => (window.LANG === "ko" ? n : n.replace(/^트랙 (\d+)$/, "Track $1")),
  markRange: () => (S.markIn != null && S.markOut != null && Math.abs(S.markOut - S.markIn) > 0.02
    ? [Math.min(S.markIn, S.markOut), Math.max(S.markIn, S.markOut)] : null),
};

let timeline, player;

// MARK: 알림 · 진행 상황

let toastTimer;
export function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.add("on");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("on"), 2600);
}

function showError(e) {
  toast(String(e?.message ?? e));
  console.error(e);
}

const jobs = {};
function jobUpdate({ id, value, message }) {
  let el = jobs[id];
  if (value >= 1 || !message) {
    el?.remove();
    delete jobs[id];
    return;
  }
  if (!el) {
    el = document.createElement("div");
    el.className = "job";
    el.innerHTML = `<div class="m"></div><progress max="1"></progress><div class="row"><button class="c">${T("cancel")}</button></div>`;
    el.querySelector(".c").onclick = () => invoke("cancel_job");
    $("#jobs").appendChild(el);
    jobs[id] = el;
  }
  el.querySelector(".m").textContent = message;
  const pr = el.querySelector("progress");
  if (value > 0) pr.value = value; else pr.removeAttribute("value");
}

// MARK: 상태 반영

export function setState(v) {
  S.project = v.project;
  S.words = v.words || [];
  S.path = v.path;
  S.dirty = v.dirty;
  S.canUndo = v.canUndo;
  S.canRedo = v.canRedo;
  const alive = new Set(U.clips().map((x) => x.c.id));
  S.sel = new Set([...S.sel].filter((id) => alive.has(id)));
  const wid = new Set(S.words.map((w) => w.id));
  S.selWords = new Set([...S.selWords].filter((id) => wid.has(id)));
  render();
}

export async function run(cmd, args) {
  try {
    const v = await invoke(cmd, args);
    if (v && v.project) setState(v);
    return v;
  } catch (e) {
    showError(e);
    return null;
  }
}

function render() {
  const name = S.path ? S.path.split(/[\\/]/).pop().replace(/\.easycut$/, "") : T("newProject");
  $("#title").textContent = name + (S.dirty ? " — " + T("edited") : "");
  document.title = `${name} — EasyCut`;
  $('[data-cmd="undo"]').disabled = !S.canUndo;
  $('[data-cmd="redo"]').disabled = !S.canRedo;
  $("#empty-hint").style.display = S.project?.assets.length ? "none" : "";
  renderMedia();
  renderTranscript();
  renderCaptions();
  renderInspector();
  timeline?.refresh();
  player?.refresh();
  $("#dur").textContent = U.fmt(U.duration());
}

export function seek(t) {
  S.time = Math.max(0, Math.min(t, U.duration()));
  player?.seek(S.time);
  timeline?.drawSoon();
  $("#clock").textContent = U.fmt(S.time);
  highlightWord();
}

export function onTime(t) {
  S.time = t;
  $("#clock").textContent = U.fmt(t);
  timeline?.playheadMoved();
  highlightWord();
}

// MARK: 미디어 탭

function renderMedia() {
  const el = $("#tab-media");
  const p = S.project;
  const kinds = { video: T("video"), audio: T("audio"), image: T("image") };
  el.innerHTML = `<div class="row"><button class="primary" id="m-import">${T("import")}</button><span class="hint">${p?.assets.length || 0}${T("items")}</span></div>`;
  if (!p?.assets.length) {
    el.innerHTML += `<p class="hint">${T("noMedia")}</p>`;
  } else {
    const grid = document.createElement("div");
    grid.className = "assets";
    for (const a of p.assets) {
      const d = document.createElement("div");
      d.className = "asset";
      d.title = a.path;
      d.innerHTML = `<div class="k">${kinds[a.kind] || a.kind}${a.duration ? " · " + U.fmt(a.duration) : ""}${a.words ? " · 💬" : ""}</div><div class="n"></div>
        <div class="row"><button class="add">＋</button><button class="rm">✕</button></div>`;
      d.querySelector(".n").textContent = a.name;
      d.querySelector(".add").title = T("addToTimeline");
      d.querySelector(".rm").title = T("remove");
      d.querySelector(".add").onclick = () => run("add_to_timeline", { asset: a.id, time: null });
      d.querySelector(".rm").onclick = () => run("remove_asset", { asset: a.id });
      d.ondblclick = () => run("add_to_timeline", { asset: a.id, time: S.time });
      grid.appendChild(d);
    }
    el.appendChild(grid);
  }
  $("#m-import").onclick = importPanel;
}

// MARK: 대본 탭

let wordDrag = null;
function renderTranscript() {
  const el = $("#tab-transcript");
  el.innerHTML = `
    <div class="row">
      <button class="primary" id="t-run">${T("transcribe")}</button>
      <select id="t-lang"><option value="ko">${T("korean")}</option><option value="en">${T("english")}</option><option value="auto">auto</option></select>
    </div>
    <div class="row">
      <button id="t-del" ${S.selWords.size ? "" : "disabled"}>${T("deleteSel")}${S.selWords.size ? ` (${S.selWords.size})` : ""}</button>
      <button id="t-fill">${T("fillers")}</button>
      <button id="t-cap">${T("makeCaptions")}</button>
    </div>
    <div id="transcript"></div>`;
  $("#t-lang").value = S.language;
  $("#t-lang").onchange = (e) => { S.language = e.target.value; localStorage.setItem("sttLanguage", S.language); };
  $("#t-run").onclick = transcribeAll;
  $("#t-del").onclick = deleteWords;
  $("#t-fill").onclick = () => run("remove_fillers");
  $("#t-cap").onclick = () => run("generate_captions");
  const box = $("#transcript");
  if (!S.words.length) {
    box.innerHTML = `<p class="hint" style="white-space:pre-line">${T("noTranscript")}</p>`;
    return;
  }
  const frag = document.createDocumentFragment();
  let lastLine = -99;
  S.words.forEach((w, i) => {
    // 3초 넘게 쉬면 새 줄
    if (i === 0 || w.start - S.words[i - 1].end > 1.2 || w.start - lastLine > 30) {
      if (i) frag.appendChild(document.createElement("br"));
      const t = document.createElement("span");
      t.className = "t";
      t.textContent = U.fmt(w.start).replace(/\.\d+$/, "");
      frag.appendChild(t);
      lastLine = w.start;
    }
    const s = document.createElement("span");
    s.className = "w" + (S.selWords.has(w.id) ? " sel" : "") + (w.filler ? " filler" : "");
    s.textContent = w.text;
    s.dataset.i = i;
    frag.appendChild(s);
    frag.appendChild(document.createTextNode(" "));
  });
  box.appendChild(frag);
  box.onmousedown = (e) => {
    const i = e.target.dataset?.i;
    if (i == null) return;
    const idx = +i;
    if (e.shiftKey && wordDrag?.anchor != null) {
      selectWordRange(wordDrag.anchor, idx);
    } else {
      wordDrag = { anchor: idx, active: true };
      selectWordRange(idx, idx);
      seek(S.words[idx].start);
    }
  };
  box.onmouseover = (e) => {
    const i = e.target.dataset?.i;
    if (i == null || !wordDrag?.active || !(e.buttons & 1)) return;
    selectWordRange(wordDrag.anchor, +i);
  };
  box.ondblclick = (e) => {
    const i = e.target.dataset?.i;
    if (i == null) return;
    const w = S.words[+i];
    const text = prompt(T("textContent"), w.text);
    if (text != null && text.trim()) run("update_word", { asset: w.asset, word: w.word, text: text.trim() });
  };
  window.addEventListener("mouseup", () => { if (wordDrag) wordDrag.active = false; }, { once: true });
  highlightWord();
}

function selectWordRange(a, b) {
  const [lo, hi] = [Math.min(a, b), Math.max(a, b)];
  S.selWords = new Set(S.words.slice(lo, hi + 1).map((w) => w.id));
  document.querySelectorAll("#transcript .w").forEach((el) => el.classList.toggle("sel", S.selWords.has(S.words[+el.dataset.i].id)));
  const btn = $("#t-del");
  if (btn) { btn.disabled = !S.selWords.size; btn.textContent = `${T("deleteSel")} (${S.selWords.size})`; }
}

let lastNow = -1;
function highlightWord() {
  if (!S.words.length) return;
  let lo = 0, hi = S.words.length - 1, found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const w = S.words[mid];
    if (S.time < w.start) hi = mid - 1;
    else if (S.time >= w.end) lo = mid + 1;
    else { found = mid; break; }
  }
  if (found === lastNow) return;
  document.querySelector(`#transcript .w[data-i="${lastNow}"]`)?.classList.remove("now");
  const el = document.querySelector(`#transcript .w[data-i="${found}"]`);
  el?.classList.add("now");
  lastNow = found;
}

async function deleteWords() {
  if (!S.selWords.size) return;
  const n = S.selWords.size;
  const ids = [...S.selWords];
  S.selWords.clear();
  await run("delete_words", { ids });
  toast(window.LANG === "ko" ? `${n}개 단어 삭제` : `Deleted ${n} words`);
}

async function transcribeAll() {
  const st = await invoke("whisper_status");
  if (!st.engine || !st.ffmpeg) return toast(T("engineMissing"));
  if (!st.model) {
    const ok = await confirmModal(T("whisperTitle"), T("whisperHint"), T("download"));
    if (!ok) return;
    try { await invoke("download_model"); } catch (e) { return showError(e); }
  }
  const used = new Set(S.project.tracks.flatMap((t) => t.clips.map((c) => c.assetID)).filter(Boolean));
  const targets = S.project.assets.filter((a) => used.has(a.id) && a.hasAudio);
  if (!targets.length) return toast(T("noAudio"));
  switchTab("transcript");
  for (const a of targets) {
    const v = await run("transcribe", { asset: a.id, language: S.language });
    if (!v) break;
  }
}

// MARK: 자막 탭

function renderCaptions() {
  const el = $("#tab-captions");
  const p = S.project;
  if (!p) return;
  const st = p.captionStyle;
  const hex = (c) => "#" + [c.r, c.g, c.b].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
  el.innerHTML = `
    <div class="row">
      <button class="primary" id="c-gen">${T("makeCaptions")}</button>
      <button id="c-imp">${T("importSrt")}</button><button id="c-exp">${T("exportSrt")}</button>
    </div>
    <div class="row"><label><input type="checkbox" id="c-show" ${p.showCaptions ? "checked" : ""}/> ${T("showCaptions")}</label></div>
    <h3>${T("captionStyle")}</h3>
    <div class="row"><label>${T("size")}</label><input type="range" id="c-size" min="20" max="120" value="${st.fontSize}"/></div>
    <div class="row"><label>${T("color")}</label><input type="color" id="c-color" value="${hex(st.textColor)}"/>
      <label>${T("background")}</label><input type="checkbox" id="c-bg" ${st.backgroundColor.a > 0.01 ? "checked" : ""}/>
      <label>${T("outline")}</label><input type="checkbox" id="c-ol" ${st.outline ? "checked" : ""}/></div>
    <div class="row"><label>${T("position")}</label><input type="range" id="c-pos" min="0.08" max="0.95" step="0.01" value="${st.positionY}"/></div>
    <div class="caplist"></div>`;
  $("#c-gen").onclick = () => run("generate_captions");
  $("#c-imp").onclick = async () => {
    const f = await tauri.dialog.open({ filters: [{ name: "SRT", extensions: ["srt"] }] });
    if (f) run("import_srt", { path: f });
  };
  $("#c-exp").onclick = async () => {
    const f = await tauri.dialog.save({ defaultPath: "captions.srt", filters: [{ name: "SRT", extensions: ["srt"] }] });
    if (f) { try { await invoke("export_srt", { path: f }); toast(T("saved")); } catch (e) { showError(e); } }
  };
  $("#c-show").onchange = (e) => run("update_project", { props: { showCaptions: e.target.checked } });
  const setStyle = (patch) => run("update_project", { props: { captionStyle: { ...st, ...patch } } });
  $("#c-size").onchange = (e) => setStyle({ fontSize: +e.target.value });
  $("#c-color").onchange = (e) => {
    const v = e.target.value;
    setStyle({ textColor: { r: parseInt(v.slice(1, 3), 16) / 255, g: parseInt(v.slice(3, 5), 16) / 255, b: parseInt(v.slice(5, 7), 16) / 255, a: 1 } });
  };
  $("#c-bg").onchange = (e) => setStyle({ backgroundColor: { r: 0, g: 0, b: 0, a: e.target.checked ? 0.6 : 0 } });
  $("#c-ol").onchange = (e) => setStyle({ outline: e.target.checked });
  $("#c-pos").onchange = (e) => setStyle({ positionY: +e.target.value });
  const list = el.querySelector(".caplist");
  if (!p.captions.length) {
    list.innerHTML = `<p class="hint">${T("noCaptions")}</p>`;
    return;
  }
  p.captions.forEach((c, i) => {
    const row = document.createElement("div");
    row.className = "c";
    row.innerHTML = `<div class="tm">${U.fmt(c.start)}<br>${U.fmt(c.end)}</div><textarea rows="1"></textarea><button title="${T("delete")}">✕</button>`;
    const ta = row.querySelector("textarea");
    ta.value = c.text;
    row.querySelector(".tm").onclick = () => seek(c.start);
    ta.onchange = () => {
      const caps = p.captions.map((x, k) => (k === i ? { ...x, text: ta.value } : x));
      run("update_project", { props: { captions: caps } });
    };
    row.querySelector("button").onclick = () => run("update_project", { props: { captions: p.captions.filter((_, k) => k !== i) } });
    list.appendChild(row);
  });
}

// MARK: 오른쪽 인스펙터

function renderInspector() {
  const el = $("#inspector");
  const p = S.project;
  if (!p) return;
  const selected = U.clips().filter((x) => S.sel.has(x.c.id));
  if (selected.length === 1) {
    const { c } = selected[0];
    const a = U.asset(c.assetID);
    const isText = c.kind === "text";
    const slider = (key, label, min, max, step, val, fmt) =>
      `<div class="row"><label>${label}</label><input type="range" data-k="${key}" min="${min}" max="${max}" step="${step}" value="${val}"/><span class="hint" data-v="${key}">${fmt(val)}</span></div>`;
    const pct = (v) => Math.round(v * 100) + "%";
    const n2 = (v) => (+v).toFixed(2);
    el.innerHTML = `<div style="padding:10px">
      <h3>${T("clip")}</h3><div class="hint" style="word-break:break-all">${isText ? T("text") : a?.name || ""}</div>
      <div class="hint">${U.fmt(c.start)} · ${U.fmt(U.clipDur(c))}</div>
      ${isText ? `<div class="row"><label>${T("textContent")}</label><textarea id="i-text" rows="2" style="flex:1"></textarea></div>` : ""}
      ${!isText && a?.kind !== "image" ? `<h3>${T("speed")}</h3><div class="row" id="i-speeds"></div>` : ""}
      ${!isText && a?.hasAudio ? slider("volume", T("volume"), 0, 2, 0.01, c.volume, pct) : ""}
      ${slider("scale", T("scale"), 0.1, 3, 0.01, c.scale, pct)}
      ${slider("offsetX", T("posX"), -1, 1, 0.01, c.offsetX, n2)}
      ${slider("offsetY", T("posY"), -1, 1, 0.01, c.offsetY, n2)}
      ${slider("opacity", T("opacity"), 0, 1, 0.01, c.opacity, pct)}
      ${slider("fadeIn", T("fadeIn"), 0, 3, 0.1, c.fadeIn, (v) => (+v).toFixed(1) + "s")}
      ${slider("fadeOut", T("fadeOut"), 0, 3, 0.1, c.fadeOut, (v) => (+v).toFixed(1) + "s")}
    </div>`;
    const speeds = el.querySelector("#i-speeds");
    if (speeds) {
      for (const s of [0.5, 1, 1.5, 2, 3, 4, 8, 16, 20]) {
        const b = document.createElement("button");
        b.textContent = s + "x";
        if (Math.abs(c.speed - s) < 0.001) b.classList.add("primary");
        b.onclick = () => run("set_speed", { ids: [c.id], speed: s });
        speeds.appendChild(b);
      }
    }
    const txt = el.querySelector("#i-text");
    if (txt) { txt.value = c.text; txt.onchange = () => run("update_clip", { id: c.id, props: { text: txt.value } }); }
    el.querySelectorAll("input[data-k]").forEach((inp) => {
      const k = inp.dataset.k;
      const out = el.querySelector(`[data-v="${k}"]`);
      inp.oninput = () => {
        c[k] = +inp.value; // 미리보기 즉시 반영
        out.textContent = k === "volume" || k === "scale" || k === "opacity" ? pct(+inp.value) : k.startsWith("fade") ? (+inp.value).toFixed(1) + "s" : n2(inp.value);
        player?.refresh();
      };
      inp.onchange = () => run("update_clip", { id: c.id, props: { [k]: +inp.value } });
    });
  } else if (selected.length > 1) {
    el.innerHTML = `<div style="padding:10px"><h3>${selected.length}${T("clipsSelected")}</h3><div class="row" id="i-speeds"></div>
      <div class="row"><button id="i-del">${T("delete")}</button></div></div>`;
    for (const s of [0.5, 1, 1.5, 2, 4, 8, 16]) {
      const b = document.createElement("button");
      b.textContent = s + "x";
      b.onclick = () => run("set_speed", { ids: [...S.sel], speed: s });
      el.querySelector("#i-speeds").appendChild(b);
    }
    el.querySelector("#i-del").onclick = () => deleteSelection(false);
  } else {
    const presets = [[1920, 1080], [3840, 2160], [1280, 720], [1080, 1920], [1080, 1080], [1080, 1350]];
    const cur = `${p.canvasWidth}x${p.canvasHeight}`;
    const has = presets.some(([w, h]) => `${w}x${h}` === cur);
    el.innerHTML = `<div style="padding:10px"><h3>${T("project")}</h3>
      <div class="row"><label>${T("canvas")}</label><select id="i-canvas">${has ? "" : `<option value="${cur}">${p.canvasWidth}×${p.canvasHeight}</option>`}
      ${presets.map(([w, h]) => `<option value="${w}x${h}">${w}×${h}</option>`).join("")}</select></div>
      <div class="row"><label>${T("fps")}</label><select id="i-fps">${[24, 25, 30, 50, 60].map((f) => `<option ${Math.round(p.fps) === f ? "selected" : ""}>${f}</option>`).join("")}</select></div>
      <p class="hint">${T("selectClipHint")}</p></div>`;
    el.querySelector("#i-canvas").value = cur;
    el.querySelector("#i-canvas").onchange = (e) => {
      const [w, h] = e.target.value.split("x").map(Number);
      run("update_project", { props: { canvasWidth: w, canvasHeight: h } });
    };
    el.querySelector("#i-fps").onchange = (e) => run("update_project", { props: { fps: +e.target.value } });
  }
}

// MARK: 명령

async function importPanel() {
  if (!tauri.dialog) return toast("dialog plugin missing");
  const files = await tauri.dialog.open({
    multiple: true,
    filters: [{ name: "Media", extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "mp3", "wav", "m4a", "aac", "flac", "png", "jpg", "jpeg", "gif", "bmp", "webp"] }],
  });
  if (files?.length) importFiles(files);
}

function importFiles(paths) {
  const projects = paths.filter((p) => p.toLowerCase().endsWith(".easycut"));
  if (projects.length) return openProject(projects[0]);
  run("import_files", { paths });
}

async function openProject(path) {
  if (S.dirty && !(await confirmModal("EasyCut", T("unsaved"), T("open")))) return;
  if (!path) {
    path = await tauri.dialog.open({ filters: [{ name: "EasyCut", extensions: ["easycut"] }] });
    if (!path) return;
  }
  S.sel.clear();
  await run("open_project", { path });
}

async function saveProject(as = false) {
  let path = S.path;
  if (!path || as) {
    path = await tauri.dialog.save({ defaultPath: `${T("newProject")}.easycut`, filters: [{ name: "EasyCut", extensions: ["easycut"] }] });
    if (!path) return;
  }
  if (await run("save_project", { path })) toast(T("saved"));
}

export function deleteSelection(ripple) {
  const r = U.markRange();
  if (r && S.sel.size === 0) {
    S.markIn = S.markOut = null;
    run("ripple_delete_range", { start: r[0], end: r[1] });
    return;
  }
  if (!S.sel.size) return;
  const ids = [...S.sel];
  S.sel.clear();
  run("delete_clips", { ids, ripple });
}

function split() {
  run("split", { time: S.time, ids: [...S.sel] });
}

async function addText() {
  const text = prompt(T("enterText"), window.LANG === "ko" ? "제목" : "Title");
  if (text) run("add_text", { time: S.time, text });
}

async function exportDialog() {
  const box = $("#modal-box");
  box.innerHTML = `<h2>${T("exportTitle")}</h2>
    <div class="row"><label>${T("resolution")}</label><select id="e-res"><option value="0">${T("original")}</option><option value="2160">4K</option><option value="1080" selected>1080p</option><option value="720">720p</option></select></div>
    <div class="row"><label><input type="checkbox" id="e-cap" checked/> ${T("burnCaptions")}</label></div>
    <div class="btns"><button id="e-cancel">${T("cancel")}</button><button class="primary" id="e-go">${T("export")}…</button></div>`;
  $("#modal").classList.remove("hidden");
  $("#e-cancel").onclick = () => $("#modal").classList.add("hidden");
  $("#e-go").onclick = async () => {
    const height = +$("#e-res").value;
    const burn = $("#e-cap").checked;
    $("#modal").classList.add("hidden");
    const base = S.path ? S.path.split(/[\\/]/).pop().replace(/\.easycut$/, "") : "EasyCut";
    const path = await tauri.dialog.save({ defaultPath: `${base}.mp4`, filters: [{ name: "MP4", extensions: ["mp4"] }] });
    if (!path) return;
    try {
      await invoke("export_video", { path, height, burnCaptions: burn });
      toast(T("exported"));
    } catch (e) { showError(e); }
  };
}

async function silenceDialog() {
  const box = $("#modal-box");
  box.innerHTML = `<h2>${T("silenceTitle")}</h2><p class="hint">${T("silenceHint")}</p>
    <div class="row"><label>${T("minSilence")}</label><input type="range" id="s-min" min="0.2" max="2" step="0.05" value="0.6"/><span class="hint" id="s-minv">0.60s</span></div>
    <div class="row"><label>${T("padding")}</label><input type="range" id="s-pad" min="0" max="0.5" step="0.01" value="0.12"/><span class="hint" id="s-padv">0.12s</span></div>
    <p class="hint" id="s-sum"></p>
    <div class="btns"><button id="s-cancel">${T("cancel")}</button><button id="s-prev">${T("preview")}</button><button class="danger" id="s-go">${T("cutSilences")}</button></div>`;
  $("#modal").classList.remove("hidden");
  const settings = () => ({ threshold: -40, minSilence: +$("#s-min").value, padding: +$("#s-pad").value });
  $("#s-min").oninput = (e) => ($("#s-minv").textContent = (+e.target.value).toFixed(2) + "s");
  $("#s-pad").oninput = (e) => ($("#s-padv").textContent = (+e.target.value).toFixed(2) + "s");
  const close = () => { S.silencePreview = []; timeline.drawSoon(); $("#modal").classList.add("hidden"); };
  $("#s-cancel").onclick = close;
  $("#s-prev").onclick = async () => {
    try {
      const r = await invoke("silence_ranges", { settings: settings(), auto: true, apply: false });
      S.silencePreview = r.ranges;
      timeline.drawSoon();
      $("#s-sum").textContent = r.ranges.length ? `${r.ranges.length} · −${r.removed.toFixed(1)}s` : T("noSilences");
    } catch (e) { showError(e); }
  };
  $("#s-go").onclick = async () => {
    try {
      const r = await invoke("silence_ranges", { settings: settings(), auto: true, apply: true });
      close();
      setState(await invoke("get_state"));
      toast(r.ranges.length ? `${r.ranges.length} · −${r.removed.toFixed(1)}s` : T("noSilences"));
    } catch (e) { showError(e); }
  };
  $("#s-prev").onclick();
}

function confirmModal(title, text, okLabel) {
  return new Promise((resolve) => {
    const box = $("#modal-box");
    box.innerHTML = `<h2></h2><p class="hint" style="white-space:pre-line"></p><div class="btns"><button id="q-no">${T("cancel")}</button><button class="primary" id="q-ok"></button></div>`;
    box.querySelector("h2").textContent = title;
    box.querySelector("p").textContent = text;
    box.querySelector("#q-ok").textContent = okLabel;
    $("#modal").classList.remove("hidden");
    const done = (v) => { $("#modal").classList.add("hidden"); resolve(v); };
    $("#q-no").onclick = () => done(false);
    $("#q-ok").onclick = () => done(true);
  });
}

function switchTab(name) {
  document.querySelectorAll(".tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === name));
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("on", t.id === "tab-" + name));
}

const commands = {
  import: importPanel,
  undo: () => run("undo"),
  redo: () => run("redo"),
  split,
  delete: () => deleteSelection(true),
  text: addText,
  silence: silenceDialog,
  transcribe: transcribeAll,
  captions: () => run("generate_captions"),
  save: () => saveProject(),
  export: exportDialog,
  play: () => player.toggle(),
  start: () => seek(0),
  end: () => seek(U.duration()),
  back5: () => seek(S.time - 5),
  fwd5: () => seek(S.time + 5),
  zoomIn: () => timeline.setZoom(S.zoom * 1.5),
  zoomOut: () => timeline.setZoom(S.zoom / 1.5),
  fit: () => timeline.fit(),
};

// MARK: 단축키

function onKey(e) {
  const tag = e.target.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
  const ctrl = e.ctrlKey || e.metaKey;
  const k = e.key.toLowerCase();
  if (ctrl) {
    const map = { z: e.shiftKey ? "redo" : "undo", y: "redo", s: "save", o: null, i: "import", e: "export", "=": "zoomIn", "-": "zoomOut" };
    if (k === "o") { e.preventDefault(); return openProject(); }
    if (k === "n") { e.preventDefault(); return newProject(); }
    if (k === "s" && e.shiftKey) { e.preventDefault(); return saveProject(true); }
    if (map[k]) { e.preventDefault(); commands[map[k]](); }
    if (k === "backspace" || k === "delete") { e.preventDefault(); deleteSelection(true); }
    return;
  }
  switch (e.code) {
    case "Space": e.preventDefault(); player.toggle(); return;
    case "ArrowLeft": e.preventDefault(); seek(S.time - (e.shiftKey ? 5 : 1)); return;
    case "ArrowRight": e.preventDefault(); seek(S.time + (e.shiftKey ? 5 : 1)); return;
    case "Home": seek(0); return;
    case "End": seek(U.duration()); return;
    case "Delete": case "Backspace":
      e.preventDefault();
      if (S.selWords.size && document.querySelector("#tab-transcript.on")) return deleteWords();
      return deleteSelection(false);
    case "Escape": S.sel.clear(); S.markIn = S.markOut = null; S.selWords.clear(); render(); return;
    case "KeyS": split(); return;
    case "KeyI": S.sel.clear(); S.markIn = S.time; timeline.drawSoon(); return;
    case "KeyO": S.sel.clear(); S.markOut = S.time; timeline.drawSoon(); return;
    case "KeyX": S.markIn = S.markOut = null; timeline.drawSoon(); return;
    case "KeyT": addText(); return;
    case "KeyK": player.pause(); return;
    case "KeyL": player.faster(); return;
    case "KeyJ": player.slower(); return;
    case "Comma": seek(S.time - 1 / (S.project?.fps || 30)); return;
    case "Period": seek(S.time + 1 / (S.project?.fps || 30)); return;
  }
}

async function newProject() {
  if (S.dirty && !(await confirmModal("EasyCut", T("unsaved"), T("newProj")))) return;
  S.sel.clear();
  run("new_project");
}

// MARK: 시작

async function init() {
  window.addEventListener("error", (e) => toast("JS: " + e.message));
  window.addEventListener("unhandledrejection", (e) => toast("JS: " + (e.reason?.message ?? e.reason)));
  applyI18n();
  timeline = new Timeline($("#timeline"), $("#tl-scroll"));
  player = new Player($("#canvas"), $("#stage"));
  document.querySelectorAll("[data-cmd]").forEach((b) => (b.onclick = () => commands[b.dataset.cmd]?.()));
  document.querySelectorAll(".tabs button").forEach((b) => (b.onclick = () => switchTab(b.dataset.tab)));
  $("#rate").onchange = (e) => player.setRate(+e.target.value);
  $("#zoom").oninput = (e) => timeline.setZoom(Math.pow(10, +e.target.value));
  window.addEventListener("keydown", onKey);
  window.addEventListener("selection", () => { renderInspector(); timeline.drawSoon(); });
  await listen("job", (e) => jobUpdate(e.payload));
  await listen("project", (e) => setState(e.payload));
  await listen("tauri://drag-drop", (e) => { const paths = e.payload?.paths; if (paths?.length) importFiles(paths); });
  setState(await invoke("get_state"));
  const files = await invoke("startup_files");
  if (files.length) importFiles(files);
}

init();
