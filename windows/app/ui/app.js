// EasyCut for Windows — 화면 로직 (상태, 명령, 패널)
import { Timeline } from "./timeline.js";
import { Player } from "./player.js";
import { initAI, focusAI, connectDialog, sendAI } from "./ai.js";
import { initShell, linkDialog, shortcutsDialog, confirmDiscard, modalBox, showModal, hideModal, ask } from "./shell.js";
import { initRecord, openRecordDialog, isRecording } from "./record.js";
import { initCaptions, renderCaptions as renderCaptionsTab, captionInspector, addCaption, deleteCaptions, generateCaptions, styleControls } from "./captions.js";
import { showMenu } from "./menu.js";
import { SPEEDS } from "./player.js";

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
  snapping: localStorage.getItem("snapping") !== "0",
  follow: localStorage.getItem("followPlayhead") !== "0",
  trackH: +(localStorage.getItem("trackHeight") || 54),
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
  /// 선택에 그룹 동료를 더한 집합
  groupMembers: (ids) => {
    const all = U.clips().map((x) => x.c);
    const gs = new Set(all.filter((c) => ids.has(c.id) && c.groupID).map((c) => c.groupID));
    if (!gs.size) return ids;
    return new Set([...ids, ...all.filter((c) => gs.has(c.groupID)).map((c) => c.id)]);
  },
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
  toast(L(String(e?.message ?? e)));
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
  el.querySelector(".m").textContent = L(message);
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
  reportUi();
}

export function onTime(t) {
  S.time = t;
  $("#clock").textContent = U.fmt(t);
  timeline?.playheadMoved();
  highlightWord();
  reportUi();
}

// AI가 재생헤드·선택·구간을 알 수 있게 백엔드에 알린다 (자주 바뀌므로 묶어서)
let uiTimer = null;
export function reportUi() {
  if (uiTimer) return;
  uiTimer = setTimeout(() => {
    uiTimer = null;
    invoke("ui_state", { state: { time: S.time, selection: [...S.sel], markIn: S.markIn, markOut: S.markOut, language: S.language } }).catch(() => {});
  }, 250);
}

// MARK: 미디어 탭

function renderMedia() {
  const el = $("#tab-media");
  const p = S.project;
  const kinds = { video: T("video"), audio: T("audio"), image: T("image") };
  el.innerHTML = `<div class="row"><button class="primary" id="m-import">${T("import")}</button><button id="m-link" title="Ctrl+Shift+I">🔗 ${L("링크로 가져오기")}</button><span class="hint">${p?.assets.length || 0}${T("items")}</span></div>`;
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
      d.oncontextmenu = (e) => { e.preventDefault(); mediaMenu(e.clientX, e.clientY, a); };
      grid.appendChild(d);
    }
    el.appendChild(grid);
  }
  $("#m-import").onclick = importPanel;
  $("#m-link").onclick = linkDialog;
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
  $("#t-cap").onclick = () => generateCaptions();
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

// MARK: 오른쪽 클릭 메뉴 (맥 TimelineView / Panels / TranscriptView 메뉴)

const speedItems = (cur, apply) => SPEEDS.map((s) => ({ label: `${s}x`, checked: Math.abs(cur - s) < 0.001, action: () => apply(s) }));

export function clipMenu(x, y, clip) {
  if (!S.sel.has(clip.id)) { S.sel = U.groupMembers(new Set([clip.id])); window.dispatchEvent(new Event("selection")); }
  const a = U.asset(clip.assetID);
  const many = S.sel.size >= 2;
  showMenu(x, y, [
    { label: L("재생헤드에서 분할"), key: "S", action: split },
    { label: L("복제"), key: "Ctrl+D", action: commands.duplicate },
    { label: L("복사"), key: "Ctrl+C", action: commands.copy },
    { sep: true },
    many && { label: L("그룹으로 묶기"), key: "Ctrl+G", action: commands.group },
    many && { label: L("하나로 합치기"), key: "Ctrl+J", action: commands.join },
    clip.groupID && { label: L("그룹 해제"), key: "Ctrl+Shift+G", action: commands.ungroup },
    (many || clip.groupID) && { sep: true },
    clip.kind === "media" && a?.kind !== "image" && { label: L("속도"), items: speedItems(clip.speed, (s) => run("set_speed", { ids: [...S.sel], speed: s })) },
    a?.hasAudio && { label: L(a.words ? "음성 다시 인식" : "음성 인식 (STT)"), action: () => transcribeAsset(a.id) },
    { sep: true },
    { label: L("삭제"), key: "Delete", action: () => deleteSelection(false) },
    { label: L("삭제 후 빈틈 메우기"), key: "Ctrl+Delete", action: () => deleteSelection(true) },
  ]);
}

export function captionMenu(x, y, c) {
  S.selCap = c.id;
  S.sel.clear();
  window.dispatchEvent(new Event("selection"));
  showMenu(x, y, [
    { label: L("자막 편집"), action: () => { switchTab("captions"); render(); } },
    { label: L("자막과 영상 함께 삭제"), action: () => deleteCaptions([c.id], true) },
    { label: L("자막만 삭제 (영상 유지)"), action: () => deleteCaptions([c.id], false) },
  ]);
}

export function emptyMenu(x, y, t) {
  showMenu(x, y, [
    { label: L("붙여넣기"), key: "Ctrl+V", action: () => { seek(t); commands.paste(); } },
    { sep: true },
    { label: L("여기에 텍스트 추가"), action: () => { seek(t); addText(); } },
    { label: L("여기에 자막 추가"), action: () => addCaption(t) },
    { label: L("모든 트랙 분할"), key: "Ctrl+Shift+T", action: () => { seek(t); commands.splitAll(); } },
    { sep: true },
    { label: L("트랙 추가"), action: commands.addTrack },
    { label: L("빈 트랙 정리"), action: commands.cleanTracks },
  ]);
}

function mediaMenu(x, y, a) {
  showMenu(x, y, [
    { label: L("타임라인에 추가"), action: () => run("add_to_timeline", { asset: a.id, time: null }) },
    { label: L("재생헤드 위치에 추가"), action: () => run("add_to_timeline", { asset: a.id, time: S.time }) },
    a.hasAudio && { label: L(a.words ? "음성 다시 인식" : "음성 인식 (STT)"), action: () => transcribeAsset(a.id) },
    { sep: true },
    { label: L("탐색기에서 보기"), action: () => invoke("reveal_file", { path: a.originalPath || a.path }) },
    { label: L("프로젝트에서 제거"), danger: true, action: () => run("remove_asset", { asset: a.id }) },
  ]);
}

/// 모델이 없으면 받을지 묻고, 한 미디어만 음성 인식
async function ensureWhisper() {
  const st = await invoke("whisper_status");
  if (!st.engine || !st.ffmpeg) { toast(T("engineMissing")); return false; }
  if (st.model) return true;
  const ok = await confirmModal(T("whisperTitle"), T("whisperHint"), T("download"));
  if (!ok) return false;
  try { await invoke("download_model"); return true; } catch (e) { showError(e); return false; }
}

async function transcribeAsset(id) {
  if (!(await ensureWhisper())) return;
  switchTab("transcript");
  await run("transcribe", { asset: id, language: S.language });
}

/// 녹화가 끝나면 바로 음성 인식 (모델이 있을 때만. 없으면 안내)
async function autoTranscribe(assetId) {
  const st = await invoke("whisper_status").catch(() => ({}));
  if (!st.engine || !st.model) return toast(L("음성 인식 모델을 받으면 대본으로 편집할 수 있습니다. [음성 인식]을 눌러 주세요."));
  switchTab("transcript");
  run("transcribe", { asset: assetId, language: S.language });
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
  renderCaptionsTab($("#tab-captions"));
}

// MARK: 오른쪽 인스펙터

function renderInspector() {
  const el = $("#inspector");
  const p = S.project;
  if (!p) return;
  const selected = U.clips().filter((x) => S.sel.has(x.c.id));
  const cap = !selected.length && S.selCap ? p.captions.find((c) => c.id === S.selCap) : null;
  if (cap) return captionInspector(el, cap);
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
  if (!(await confirmDiscard())) return;
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
    if (!path) return false;
  }
  if (await run("save_project", { path })) { toast(T("saved")); return true; }
  return false;
}

export function deleteSelection(ripple) {
  const r = U.markRange();
  if (r && S.sel.size === 0) {
    S.markIn = S.markOut = null;
    run("ripple_delete_range", { start: r[0], end: r[1] });
    toast(L("구간 삭제"));
    return;
  }
  if (!S.sel.size && S.selCap) return deleteCaptions([S.selCap]);
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

export function switchTab(name) {
  document.querySelectorAll(".tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === name));
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("on", t.id === "tab-" + name));
  if (name === "ai") setTimeout(focusAI, 0);
}

async function importSrt() {
  const f = await tauri.dialog.open({ filters: [{ name: "SRT", extensions: ["srt"] }] });
  if (f) run("import_srt", { path: f });
}

async function exportSrt() {
  const f = await tauri.dialog.save({ defaultPath: "captions.srt", filters: [{ name: "SRT", extensions: ["srt"] }] });
  if (f) { try { await invoke("export_srt", { path: f }); toast(T("saved")); } catch (e) { showError(e); } }
}

function syncToggles() {
  $("#snap-btn")?.classList.toggle("on", S.snapping);
  $("#follow-btn")?.classList.toggle("on", S.follow);
}

function setTrackH(h) {
  S.trackH = Math.max(34, Math.min(120, h));
  localStorage.setItem("trackHeight", String(S.trackH));
  timeline.refresh();
}

/// 이전 / 다음 편집점 (클립 경계, 구간 표시)
function jumpEdit(forward) {
  const pts = new Set([0, U.duration()]);
  for (const { c } of U.clips()) { pts.add(c.start); pts.add(U.clipEnd(c)); }
  if (S.markIn != null) pts.add(S.markIn);
  if (S.markOut != null) pts.add(S.markOut);
  const list = [...pts].sort((a, b) => a - b);
  const t = forward ? list.find((p) => p > S.time + 0.01) : [...list].reverse().find((p) => p < S.time - 0.01);
  if (t != null) seek(t);
}

function applySelect(v) {
  if (v?.select) {
    S.sel = new Set(v.select);
    window.dispatchEvent(new Event("selection"));
  }
  if (v?.message) toast(L(v.message));
}

const selIds = () => [...S.sel];

function setMark(which) {
  S.sel.clear();
  if (which === "in") { S.markIn = S.time; if (S.markOut != null && S.markOut < S.time) S.markOut = null; toast(L("시작 지점 (I) {}", U.fmt(S.time))); }
  else { S.markOut = S.time; if (S.markIn != null && S.markIn > S.time) S.markIn = null; toast(L("끝 지점 (O) {}", U.fmt(S.time))); }
  timeline.drawSoon();
  reportUi();
}

const commands = {
  import: importPanel,
  newProject: () => newProject(),
  open: () => openProject(),
  saveAs: () => saveProject(true),
  importSrt,
  exportSrt,
  link: linkDialog,
  undo: () => run("undo"),
  redo: () => run("redo"),
  split,
  deleteSel: () => deleteSelection(false),
  deselect: () => { S.sel.clear(); S.markIn = S.markOut = null; S.selWords.clear(); render(); reportUi(); },
  markIn: () => setMark("in"),
  markOut: () => setMark("out"),
  clearMarks: () => { S.markIn = S.markOut = null; timeline.drawSoon(); reportUi(); },
  faster: () => player.faster(),
  slower: () => player.slower(),
  stop: () => player.pause(),
  setRate: (r) => player.setRate(r),
  fillers: () => run("remove_fillers"),
  ai: () => switchTab("ai"),
  aiConnect: () => connectDialog(),
  shortcuts: shortcutsDialog,
  record: () => openRecordDialog(),
  duplicate: async () => { if (S.sel.size) applySelect(await run("duplicate_clips", { ids: selIds() })); },
  copy: async () => {
    if (!S.sel.size) return;
    const n = await invoke("copy_clips", { ids: selIds() });
    toast(L("{}개 클립 복사", n));
  },
  cut: async () => {
    if (!S.sel.size) return;
    await invoke("copy_clips", { ids: selIds() });
    deleteSelection(false);
  },
  paste: async () => applySelect(await run("paste_clips", { time: S.time })),
  selectAll: () => { S.sel = new Set(U.clips().map((x) => x.c.id)); window.dispatchEvent(new Event("selection")); },
  group: async () => {
    if (S.sel.size < 2) return toast(L("묶을 클립을 2개 이상 선택하세요 (빈 곳을 끌거나 Shift/Ctrl+클릭)"));
    applySelect(await run("group_clips", { ids: selIds(), on: true }));
    toast(L("{}개 클립을 그룹으로 묶었습니다 (Ctrl+Shift+G 해제)", S.sel.size));
  },
  ungroup: async () => {
    if (!U.clips().some((x) => S.sel.has(x.c.id) && x.c.groupID)) return toast(L("그룹으로 묶인 클립을 선택하세요"));
    await run("group_clips", { ids: selIds(), on: false });
    toast(L("그룹을 풀었습니다"));
  },
  join: async () => {
    if (S.sel.size < 2) return toast(L("합칠 클립을 2개 이상 선택하세요"));
    applySelect(await run("join_clips", { ids: selIds() }));
  },
  splitAll: () => { run("split", { time: S.time, ids: [] }); toast(L("분할")); },
  toggleSnap: () => {
    S.snapping = !S.snapping;
    localStorage.setItem("snapping", S.snapping ? "1" : "0");
    toast(L(S.snapping ? "스냅 켬" : "스냅 끔"));
    syncToggles();
  },
  toggleFollow: () => {
    S.follow = !S.follow;
    localStorage.setItem("followPlayhead", S.follow ? "1" : "0");
    toast(L(S.follow ? "재생헤드 따라가기 켬" : "재생헤드 따라가기 끔"));
    syncToggles();
  },
  trackBigger: () => setTrackH(S.trackH + 12),
  trackSmaller: () => setTrackH(S.trackH - 12),
  prevEdit: () => jumpEdit(false),
  nextEdit: () => jumpEdit(true),
  addTrack: () => run("tracks_edit", { action: "add" }),
  cleanTracks: () => run("tracks_edit", { action: "clean" }),
  delete: () => deleteSelection(true),
  text: addText,
  silence: silenceDialog,
  transcribe: transcribeAll,
  captions: () => generateCaptions(),
  addCaption: () => addCaption(),
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
  // 글자 키는 자판 배치·Alt 조합과 상관없이 물리 키로 (Ctrl+Alt+R이 다른 글자로 바뀌는 경우)
  const k = e.code.startsWith("Key") ? e.code.slice(3).toLowerCase() : e.code === "Slash" ? "/" : e.code === "Equal" ? "=" : e.code === "Minus" ? "-" : e.key.toLowerCase();
  if (ctrl) {
    if (e.shiftKey) {
      const shiftMap = { i: "link", r: "transcribe", c: "captions", x: "silence", s: "saveAs", z: "redo", t: "splitAll", g: "ungroup" };
      if (shiftMap[k] && commands[shiftMap[k]]) { e.preventDefault(); commands[shiftMap[k]](); }
      return;
    }
    if (e.altKey) {
      if (k === "r" && commands.record) { e.preventDefault(); commands.record(); }
      return;
    }
    const map = { z: "undo", y: "redo", s: "save", i: "import", e: "export", "=": "zoomIn", "+": "zoomIn", "-": "zoomOut", o: "open", n: "newProject",
      t: "split", "/": "shortcuts", d: "duplicate", a: "selectAll", c: "copy", x: "cut", v: "paste", g: "group", j: "join" };
    if (["1", "2", "3", "4"].includes(e.key)) { e.preventDefault(); return switchTab(["media", "transcript", "captions", "ai"][+e.key - 1]); }
    if (map[k] && commands[map[k]]) { e.preventDefault(); commands[map[k]](); }
    if (k === "backspace" || k === "delete") { e.preventDefault(); deleteSelection(true); }
    return;
  }
  // Alt+숫자: 속도 바로 고르기 (맥 ⌥0~9와 같은 표)
  if (e.altKey && /^Digit\d$/.test(e.code)) {
    const table = [20, 1, 2, 3, 4, 5, 8, 10, 12, 16];
    player.setRate(table[+e.code.slice(5)]);
    toast(L("재생 속도 {}", player.rate + "x"));
    e.preventDefault();
    return;
  }
  switch (e.code) {
    case "Space": e.preventDefault(); player.toggle(); return;
    case "ArrowLeft": e.preventDefault(); player.pause(); seek(S.time - (e.shiftKey ? 5 : 1)); return;
    case "ArrowRight": e.preventDefault(); player.pause(); seek(S.time + (e.shiftKey ? 5 : 1)); return;
    case "Home": seek(0); return;
    case "End": seek(U.duration()); return;
    case "Delete": case "Backspace":
      e.preventDefault();
      if (S.selWords.size && document.querySelector("#tab-transcript.on")) return deleteWords();
      return deleteSelection(false);
    case "Escape": commands.deselect(); return;
    case "KeyS": split(); return;
    case "KeyI": setMark("in"); return;
    case "KeyO": setMark("out"); return;
    case "KeyX": commands.clearMarks(); return;
    case "KeyZ": if (e.shiftKey) timeline.fit(); return;
    case "KeyT": addText(); return;
    case "KeyK": player.pause(); return;
    case "KeyL": player.faster(); return;
    case "KeyJ": player.slower(); return;
    case "Comma": player.pause(); seek(S.time - 1 / (S.project?.fps || 30)); return;
    case "Period": player.pause(); seek(S.time + 1 / (S.project?.fps || 30)); return;
    case "ArrowUp": e.preventDefault(); jumpEdit(false); return;
    case "ArrowDown": e.preventDefault(); jumpEdit(true); return;
    case "BracketRight": player.stepRate(true); toast(L("재생 속도 {}", player.rate + "x")); return;
    case "BracketLeft": player.stepRate(false); toast(L("재생 속도 {}", player.rate + "x")); return;
    case "Backslash": player.setRate(1); toast(L("1배속")); return;
    case "KeyN": commands.toggleSnap(); return;
    case "KeyC": if (commands.addCaption) commands.addCaption(); return;
  }
}

async function newProject() {
  if (!(await confirmDiscard())) return;
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
  window.addEventListener("selection", () => { renderInspector(); timeline.drawSoon(); reportUi(); });
  await listen("job", (e) => jobUpdate(e.payload));
  await listen("project", (e) => setState(e.payload));
  await listen("tauri://drag-drop", (e) => { const paths = e.payload?.paths; if (paths?.length) importFiles(paths); });
  // AI 도구가 화면 쪽 동작을 요청할 때 (재생헤드 이동, 재생 속도)
  await listen("ui-command", (e) => {
    const c = e.payload;
    if (c.action === "seek") seek(c.time);
    if (c.action === "speed") {
      player.setRate(c.speed);
      if (c.play === true && !player.playing) player.play();
      if (c.play === false) player.pause();
    }
  });
  initCaptions({ S, U, run, invoke, seek, toast, switchTab, render, commands, ask, captionMenu, selectionChanged: () => window.dispatchEvent(new Event("selection")) });
  setState(await invoke("get_state"));
  syncToggles();
  reportUi();
  const modal = { box: modalBox(), show: showModal, hide: hideModal };
  await initAI($("#tab-ai"), { toast, modal });
  initRecord({ toast, modal, autoTranscribe });
  const files = await invoke("startup_files");
  if (files.length) importFiles(files);
  await initShell({ S, U, run, toast, commands, switchTab, isBusyRecording: isRecording });
}

init();
