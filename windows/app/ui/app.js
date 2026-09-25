// EasyCut for Windows — 화면 로직 (상태, 명령, 패널)
import { Timeline } from "./timeline.js";
import { Player } from "./player.js";
import { initAI, focusAI, connectDialog, sendAI } from "./ai.js";
import { initShell, linkDialog, shortcutsDialog, confirmDiscard, modalBox, showModal, hideModal, ask, buildMenu } from "./shell.js";
import { initRecord, openRecordDialog, isRecording } from "./record.js";
import { initCaptions, renderCaptions as renderCaptionsTab, captionInspector, addCaption, deleteCaptions, generateCaptions, styleControls } from "./captions.js";
import { showMenu } from "./menu.js";
import { startDrag } from "./drag.js";
import { initTranscript, renderTranscript as renderTranscriptTab, highlightWord, deleteWords, transcribeTimeline, transcribeAsset, silenceDialog, sttSettings, focusSearch, selectRange, fixSelectedWord, exportTxt } from "./transcript.js";
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
  volume: +(localStorage.getItem("previewVolume") ?? 1),
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
  // 내보내기는 내보내기 창에서 보여 준다
  if (id === "export" && !$("#modal").classList.contains("hidden")) return;
  if (!el) {
    el = document.createElement("div");
    el.className = "job";
    el.innerHTML = `<div class="m"></div><progress max="1"></progress><div class="row"><span class="hint eta"></span><span class="spacer"></span><button class="c">${T("cancel")}</button></div>`;
    el.querySelector(".c").onclick = () => invoke("cancel_job");
    $("#jobs").appendChild(el);
    jobs[id] = el;
    el._t0 = performance.now();
  }
  el.querySelector(".m").textContent = L(message);
  const pr = el.querySelector("progress");
  if (value > 0) pr.value = value; else pr.removeAttribute("value");
  // 남은 시간 (맥처럼)
  const eta = el.querySelector(".eta");
  if (value > 0.03 && value < 1) {
    const sec = (performance.now() - el._t0) / 1000;
    eta.textContent = `${Math.round(value * 100)}% · ` + L("남은 시간 약 {}", U.fmt(sec / value - sec).replace(/\.\d+$/, ""));
  } else eta.textContent = "";
}

// MARK: 상태 반영

// MARK: 칸 크기 조절 (왼쪽·오른쪽 패널 너비, 타임라인 높이) — 기억해 둔다

function initSplitters() {
  const root = document.documentElement;
  const get = (k, d) => +(localStorage.getItem("pane." + k) || d);
  const set = (k, v) => { root.style.setProperty(`--${k}`, v + "px"); localStorage.setItem("pane." + k, String(v)); };
  set("left-w", get("left-w", 330));
  set("right-w", get("right-w", 280));
  set("tl-h", get("tl-h", 290));
  document.querySelectorAll("[data-split]").forEach((h) => {
    h.onmousedown = (e) => {
      e.preventDefault();
      const kind = h.dataset.split;
      const sx = e.clientX, sy = e.clientY;
      const start = { left: get("left-w", 330), right: get("right-w", 280), timeline: get("tl-h", 290) }[kind];
      document.body.classList.add("resizing");
      const move = (ev) => {
        if (kind === "left") set("left-w", Math.max(240, Math.min(620, start + ev.clientX - sx)));
        if (kind === "right") set("right-w", Math.max(220, Math.min(520, start - (ev.clientX - sx))));
        if (kind === "timeline") set("tl-h", Math.max(150, Math.min(innerHeight - 260, start - (ev.clientY - sy))));
        timeline?.refresh();
        player?.refresh();
      };
      const up = () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); document.body.classList.remove("resizing"); };
      window.addEventListener("mousemove", move);
      window.addEventListener("mouseup", up);
    };
  });
}

// MARK: 미디어 그림 · 파형 (타임라인 클립과 미디어 칸에 그린다)

S.media = {};
let mediaQueue = Promise.resolve();
function loadMedia() {
  for (const a of S.project?.assets || []) {
    if (S.media[a.id] || S.missing?.includes(a.id)) continue;
    const m = (S.media[a.id] = { thumbs: [], peaks: null });
    mediaQueue = mediaQueue.then(async () => {
      try {
        const count = a.kind === "video" ? Math.max(2, Math.min(60, Math.round(a.duration / 4))) : 1;
        const list = a.kind === "audio" ? [] : await invoke("media_thumbs", { asset: a.id, count });
        m.thumbs = list.map(([t, path]) => { const img = new Image(); img.onload = () => { timeline?.drawSoon(); renderMediaThumb(a.id); }; img.src = tauri.core.convertFileSrc(path); return { t, img }; });
        if (a.hasAudio) { m.peaks = await invoke("media_peaks", { asset: a.id }); timeline?.drawSoon(); }
      } catch (_) {}
    });
  }
}

function renderMediaThumb(id) {
  const th = S.media[id]?.thumbs[Math.floor((S.media[id].thumbs.length - 1) / 3)];
  const el = document.querySelector(`.asset[data-id="${id}"] .thumb`);
  if (el && th?.img.complete) el.style.backgroundImage = `url("${th.img.src}")`;
}

export function setState(v) {
  S.project = v.project;
  S.missing = v.missing || [];
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
  loadMedia();
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
  $("#cc-btn")?.classList.toggle("on", !!S.project?.showCaptions);
  showTime();
}

/// 시계와 탐색 막대
function showTime() {
  $("#clock").textContent = U.fmt(S.time);
  const d = U.duration();
  const bar = $("#scrub-bar");
  if (bar && document.activeElement !== bar) bar.value = d > 0 ? S.time / d : 0;
}

export function seek(t) {
  S.time = Math.max(0, Math.min(t, U.duration()));
  player?.seek(S.time);
  timeline?.drawSoon();
  showTime();
  highlightWord();
  reportUi();
}

export function onTime(t) {
  S.time = t;
  showTime();
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
      const missing = S.missing.includes(a.id);
      d.dataset.id = a.id;
      d.innerHTML = `<div class="thumb ${a.kind}">${a.kind === "audio" ? "🎵" : ""}</div>
        <div class="k">${kinds[a.kind] || a.kind}${a.duration ? " · " + U.fmt(a.duration) : ""}${a.words ? " · 💬" : ""}</div><div class="n"></div>
        ${missing ? `<div class="miss">⚠ ${L("파일 없음")} <button class="mini relink">${L("다시 연결…")}</button></div>` : ""}
        <div class="row"><button class="add">＋</button><button class="rm">✕</button></div>`;
      if (missing) d.querySelector(".relink").onclick = async (e) => {
        e.stopPropagation();
        const f = await tauri.dialog.open({ title: a.name, filters: [{ name: a.name, extensions: [a.name.split(".").pop() || "*", "mp4", "mov", "mkv", "mp3", "wav", "m4a", "png", "jpg"] }] });
        if (f) run("relink_asset", { asset: a.id, path: f });
      };
      d.querySelector(".n").textContent = a.name;
      d.querySelector(".add").title = T("addToTimeline");
      d.querySelector(".rm").title = T("remove");
      d.querySelector(".add").onclick = () => run("add_to_timeline", { asset: a.id, time: null });
      d.querySelector(".rm").onclick = () => run("remove_asset", { asset: a.id });
      d.ondblclick = () => run("add_to_timeline", { asset: a.id, time: S.time });
      d.oncontextmenu = (e) => { e.preventDefault(); mediaMenu(e.clientX, e.clientY, a); };
      // 타임라인으로 끌어다 놓기
      d.onmousedown = (e) => {
        if (e.target.closest("button")) return;
        startDrag(e, {
          label: a.name,
          onDrop: (x, y) => {
            const at = timeline.pointAt(x, y);
            if (at) run("add_to_timeline", { asset: a.id, time: at.t, track: a.kind === "audio" && at.ti === 0 ? 2 : at.ti });
          },
        });
      };
      grid.appendChild(d);
    }
    el.appendChild(grid);
    for (const a of p.assets) renderMediaThumb(a.id);
  }
  $("#m-import").onclick = importPanel;
  $("#m-link").onclick = linkDialog;
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

/// 녹화가 끝나면 바로 음성 인식 (모델이 있을 때만. 없으면 안내)
async function autoTranscribe(assetId) {
  const st = await invoke("whisper_status").catch(() => ({}));
  if (!st.engine || !st.model) return toast(L("음성 인식 모델을 받으면 대본으로 편집할 수 있습니다. [음성 인식]을 눌러 주세요."));
  switchTab("transcript");
  run("transcribe", { asset: assetId, language: S.language });
}


// MARK: 대본 탭

function renderTranscript() {
  renderTranscriptTab($("#tab-transcript"));
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
  const pct = (v) => Math.round(v * 100) + "%";
  const slider = (key, label, min, max, step, val, fmt) =>
    `<div class="row"><label>${L(label)}</label><input type="range" data-k="${key}" min="${min}" max="${max}" step="${step}" value="${val}"/><span class="hint" data-v="${key}">${fmt(val)}</span></div>`;
  const speedGrid = (cur) => `<div class="speedgrid">${[0.5, 1, 1.5, 2, 3, 4, 8, 10, 16, 20].map((s) => `<button class="mini ${cur != null && Math.abs(cur - s) < 0.001 ? "primary" : ""}" data-speed="${s}">${s}x</button>`).join("")}</div>`;
  const wireSpeeds = (ids) => el.querySelectorAll("[data-speed]").forEach((b) => (b.onclick = () => run("set_speed", { ids, speed: +b.dataset.speed })));

  if (selected.length === 1) {
    const { c } = selected[0];
    const a = U.asset(c.assetID);
    const isText = c.kind === "text";
    const kind = isText ? "text" : a?.kind || "video";
    const icon = { text: "🔤", video: "🎬", audio: "🎵", image: "🖼" }[kind];
    const shape = c.shape || "none";
    const fmts = { volume: pct, scale: pct, opacity: pct, offsetX: (v) => (+v).toFixed(2), offsetY: (v) => (+v).toFixed(2), fadeIn: (v) => L("{}초", (+v).toFixed(1)), fadeOut: (v) => L("{}초", (+v).toFixed(1)) };
    el.innerHTML = `<div class="insp">
      <div class="ihead">${icon} <b>${esc(isText ? L("텍스트") : a?.name || L("클립"))}</b></div>
      <div class="hint">${L("시작 {} · 길이 {}", U.fmt(c.start), U.fmt(U.clipDur(c)))}${c.groupID ? " · 🔗 " + L("그룹") : ""}</div>
      ${isText ? `<h3>${L("내용")}</h3><textarea id="i-text" rows="3" style="width:100%"></textarea><div id="i-tstyle"></div>` : ""}
      ${kind === "video" || kind === "audio" ? `<h3>${L("속도 (최대 20배)")}</h3>
        <div class="row"><input type="range" id="i-speed" min="${Math.log(0.1)}" max="${Math.log(20)}" step="0.01" value="${Math.log(c.speed)}" style="flex:1"/><span class="hint" id="i-speed-v">${c.speed}x</span></div>
        ${speedGrid(c.speed)}` : ""}
      ${kind === "video" || kind === "audio" ? `<h3>${L("오디오")}</h3>${slider("volume", "볼륨", 0, 2, 0.01, c.volume, pct)}
        <div class="row"><button class="mini" id="i-mute">${L(c.volume === 0 ? "소리 켜기" : "음소거")}</button>
        ${a?.hasAudio ? `<button class="mini" id="i-stt">${L(a.words ? "다시 인식" : "음성 인식")}</button>` : ""}</div>` : ""}
      ${kind !== "audio" ? `<h3>${L("화면")}</h3>
        ${slider("scale", "크기", 0.1, 4, 0.01, c.scale, pct)}
        ${slider("offsetX", "가로 위치", -1, 1, 0.01, c.offsetX, fmts.offsetX)}
        ${slider("offsetY", "세로 위치", -1, 1, 0.01, c.offsetY, fmts.offsetY)}
        ${slider("opacity", "불투명도", 0, 1, 0.01, c.opacity, pct)}
        ${!isText ? `<div class="row"><label>${L("모양")}</label><div class="seg small">${[["none", "기본"], ["circle", "원"], ["rounded", "둥근 사각형"]].map(([v, t]) => `<button data-shape="${v}" class="${shape === v ? "on" : ""}">${L(t)}</button>`).join("")}</div></div>` : ""}
        <div class="row"><span class="hint">${L("화면 배치")}</span><button class="mini" data-layout="full">${L("전체")}</button><button class="mini" data-layout="br">PIP ↘</button><button class="mini" data-layout="bl">PIP ↙</button></div>` : ""}
      <h3>${L("전환 (페이드)")}</h3>
      ${slider("fadeIn", "페이드 인", 0, 3, 0.1, c.fadeIn, fmts.fadeIn)}
      ${slider("fadeOut", "페이드 아웃", 0, 3, 0.1, c.fadeOut, fmts.fadeOut)}
      <hr/><div class="row"><button class="mini" id="i-split">✂ ${L("분할")}</button><button class="mini" id="i-dup">⧉ ${L("복제")}</button><button class="mini danger-text" id="i-del">🗑 ${L("삭제")}</button></div>
    </div>`;
    const q = (s) => el.querySelector(s);
    if (isText) {
      q("#i-text").value = c.text;
      q("#i-text").onkeydown = (e) => e.stopPropagation();
      q("#i-text").onchange = () => run("update_clip", { id: c.id, props: { text: q("#i-text").value } });
      styleControls(q("#i-tstyle"), c.textStyle, (st) => run("update_clip", { id: c.id, props: { textStyle: st } }), true);
    }
    if (q("#i-speed")) {
      q("#i-speed").oninput = (e) => (q("#i-speed-v").textContent = (Math.round(Math.exp(+e.target.value) * 100) / 100) + "x");
      q("#i-speed").onchange = (e) => run("set_speed", { ids: [c.id], speed: Math.round(Math.exp(+e.target.value) * 100) / 100 });
      wireSpeeds([c.id]);
    }
    if (q("#i-mute")) q("#i-mute").onclick = () => run("update_clip", { id: c.id, props: { volume: c.volume === 0 ? 1 : 0 } });
    if (q("#i-stt")) q("#i-stt").onclick = () => transcribeAsset(a.id);
    el.querySelectorAll("[data-shape]").forEach((b) => (b.onclick = () => run("update_clip", { id: c.id, props: { shape: b.dataset.shape } })));
    el.querySelectorAll("[data-layout]").forEach((b) => (b.onclick = () => {
      const L0 = { full: { scale: 1, offsetX: 0, offsetY: 0 }, br: { scale: 0.3, offsetX: 0.33, offsetY: 0.32 }, bl: { scale: 0.3, offsetX: -0.33, offsetY: 0.32 } }[b.dataset.layout];
      run("update_clip", { id: c.id, props: L0 });
    }));
    q("#i-split").onclick = split;
    q("#i-dup").onclick = commands.duplicate;
    q("#i-del").onclick = () => deleteSelection(true);
    el.querySelectorAll("input[data-k]").forEach((inp) => {
      const k = inp.dataset.k;
      const out = el.querySelector(`[data-v="${k}"]`);
      inp.oninput = () => {
        c[k] = +inp.value; // 미리보기 즉시 반영
        out.textContent = fmts[k](+inp.value);
        player?.refresh();
      };
      inp.onchange = () => run("update_clip", { id: c.id, props: { [k]: +inp.value } });
    });
  } else if (selected.length > 1) {
    const ids = selected.map((x) => x.c.id);
    el.innerHTML = `<div class="insp"><div class="ihead">▦ <b>${L("{}개 클립 선택", selected.length)}</b></div>
      <h3>${L("속도 한꺼번에")}</h3>${speedGrid(null)}
      <div class="row"><button class="mini" id="i-group">🔗 ${L("그룹으로 묶기")}</button><button class="mini" id="i-join">${L("하나로 합치기")}</button></div>
      <div class="row"><button class="mini danger-text" id="i-del">🗑 ${L("삭제")}</button><button class="mini danger-text" id="i-rdel">⇤ ${L("삭제 후 당기기")}</button></div></div>`;
    wireSpeeds(ids);
    el.querySelector("#i-group").onclick = commands.group;
    el.querySelector("#i-join").onclick = commands.join;
    el.querySelector("#i-del").onclick = () => deleteSelection(false);
    el.querySelector("#i-rdel").onclick = () => deleteSelection(true);
  } else {
    const presets = [["1920×1080 (가로 FHD)", 1920, 1080], ["3840×2160 (가로 4K)", 3840, 2160], ["1280×720 (가로 HD)", 1280, 720], ["1080×1920 (세로 쇼츠/릴스)", 1080, 1920], ["1080×1080 (정사각형)", 1080, 1080], ["1080×1350 (4:5 피드)", 1080, 1350]];
    const cur = `${p.canvasWidth}x${p.canvasHeight}`;
    const has = presets.some(([, w, h]) => `${w}x${h}` === cur);
    const clipsN = U.clips().length;
    el.innerHTML = `<div class="insp"><div class="ihead">▭ <b>${L("프로젝트")}</b></div>
      <p class="hint">${L("클립을 선택하면 속도·볼륨·크기를 조절할 수 있습니다.")}</p>
      <h3>${L("화면 크기")}</h3><select id="i-canvas" style="width:100%">${has ? "" : `<option value="${cur}">${p.canvasWidth}×${p.canvasHeight} (${L("원본")})</option>`}
        ${presets.map(([t, w, h]) => `<option value="${w}x${h}">${L(t)}</option>`).join("")}</select>
      <h3>${L("프레임 레이트")}</h3><div class="seg small">${[24, 25, 30, 50, 60].map((f) => `<button data-fps="${f}" class="${Math.round(p.fps) === f ? "on" : ""}">${f}</button>`).join("")}</div>
      <div class="row"><label>${L("배경색")}</label><input type="color" id="i-bg" value="${hexColor(p.background)}"/></div>
      <hr/><h3>${L("요약")}</h3>
      <div class="hint">${L("전체 길이: {}", U.fmt(U.duration()))}<br>${L("클립: {}개 · 자막: {}개", clipsN, p.captions.length)}<br>${L("대본 단어: {}개", S.words.length)}</div>
      <hr/><h3>${L("빠른 작업")}</h3>
      <div class="quick"><button id="q-text">🔤 ${L("텍스트(제목) 추가")}</button><button id="q-cap">💬 ${L("자막 추가")}</button>
      <button id="q-png">📷 ${L("현재 장면 PNG 저장")}</button><button id="q-keys">⌨ ${L("단축키 보기")}</button></div></div>`;
    el.querySelector("#i-canvas").value = cur;
    el.querySelector("#i-canvas").onchange = (e) => {
      const [w, h] = e.target.value.split("x").map(Number);
      run("update_project", { props: { canvasWidth: w, canvasHeight: h } });
    };
    el.querySelectorAll("[data-fps]").forEach((b) => (b.onclick = () => run("update_project", { props: { fps: +b.dataset.fps } })));
    el.querySelector("#i-bg").onchange = (e) => {
      const v = e.target.value;
      run("update_project", { props: { background: { r: parseInt(v.slice(1, 3), 16) / 255, g: parseInt(v.slice(3, 5), 16) / 255, b: parseInt(v.slice(5, 7), 16) / 255, a: 1 } } });
    };
    el.querySelector("#q-text").onclick = addText;
    el.querySelector("#q-cap").onclick = () => addCaption();
    el.querySelector("#q-png").onclick = snapshot;
    el.querySelector("#q-keys").onclick = shortcutsDialog;
  }
}

// MARK: 명령

async function importPanel() {
  if (!tauri.dialog) return toast("dialog plugin missing");
  const files = await tauri.dialog.open({
    multiple: true,
    filters: [{ name: L("미디어"), extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "ts", "mts", "m2ts", "mpg", "mpeg", "3gp", "ogv", "vob",
      "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aif", "aiff", "wma", "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tif", "tiff"] }],
  });
  if (files?.length) importFiles(files);
}

function importFiles(paths, place = null) {
  const projects = paths.filter((p) => p.toLowerCase().endsWith(".easycut"));
  if (projects.length) return openProject(projects[0]);
  run("import_files", { paths, place });
}

async function openProject(path) {
  if (!(await confirmDiscard())) return;
  if (!path) {
    path = await tauri.dialog.open({ filters: [{ name: "EasyCut", extensions: ["easycut"] }] });
    if (!path) return;
  }
  S.sel.clear();
  if (await run("open_project", { path })) buildMenu();
}

async function saveProject(as = false) {
  let path = S.path;
  if (!path || as) {
    path = await tauri.dialog.save({ defaultPath: `${T("newProject")}.easycut`, filters: [{ name: "EasyCut", extensions: ["easycut"] }] });
    if (!path) return false;
  }
  if (await run("save_project", { path })) { toast(T("saved")); if (as || !S.path) buildMenu(); return true; }
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

/// 재생헤드에 텍스트(제목) 추가하고 골라 둔다 → 오른쪽에서 바로 글자·스타일 고치기 (맥과 같음)
async function addText() {
  applySelect(await run("add_text", { time: S.time, text: L("텍스트를 입력하세요") }));
  setTimeout(() => { const t = $("#i-text"); if (t) { t.focus(); t.select(); } }, 50);
}

// MARK: 내보내기 (맥 ExportSheet: 형식, 해상도, 자막 입히기, SRT, 진행률·남은 시간, 완료 창)

const EXPORT_FORMATS = [["mp4", "MP4 (H.264)", "mp4"], ["hevc", "MP4 (HEVC, 용량 작음)", "mp4"], ["prores", "MOV (ProRes, 고화질)", "mov"], ["m4a", "오디오만 (M4A)", "m4a"]];

async function exportDialog() {
  if (U.duration() <= 0) return toast(L("타임라인이 비어 있습니다."));
  const box = $("#modal-box");
  const pref = (k, d) => { try { const v = localStorage.getItem("export." + k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } };
  const setPref = (k, v) => { try { localStorage.setItem("export." + k, JSON.stringify(v)); } catch (_) {} };
  const o = { format: pref("format", "mp4"), res: pref("res", 1080), burn: pref("burn", true), srt: pref("srt", false) };
  const p = S.project;
  const draw = async () => {
    const [w, h] = await invoke("export_size", { height: o.res });
    const audio = o.format === "m4a";
    box.innerHTML = `<h2>${L("내보내기")}</h2>
      <div class="row"><label>${L("형식")}</label><select id="e-fmt">${EXPORT_FORMATS.map(([v, t]) => `<option value="${v}" ${o.format === v ? "selected" : ""}>${L(t)}</option>`).join("")}</select></div>
      ${audio ? "" : `<div class="row"><label>${L("해상도")}</label><select id="e-res">
        <option value="0">${L("프로젝트 크기 ({}×{})", p.canvasWidth, p.canvasHeight)}</option>
        ${[[2160, "2160p (4K)"], [1080, "1080p (FHD)"], [720, "720p (HD)"], [480, "480p"]].map(([v, t]) => `<option value="${v}">${t}</option>`).join("")}</select></div>
        <div class="row"><label></label><label class="hint" style="width:auto"><input type="checkbox" id="e-cap" ${o.burn ? "checked" : ""}/> ${L("자막을 영상에 입히기")}</label></div>`}
      <div class="row"><label></label><label class="hint" style="width:auto"><input type="checkbox" id="e-srt" ${o.srt ? "checked" : ""} ${p.captions.length ? "" : "disabled"}/> ${L("SRT 자막 파일도 함께 저장")}</label></div>
      <p class="hint">${audio ? L("길이 {}", U.fmt(U.duration())) : L("출력 {}×{} · 길이 {}", w, h, U.fmt(U.duration()))}</p>
      <div class="btns"><button id="e-cancel">${L("취소")}</button><button class="primary" id="e-go">${L("내보내기…")}</button></div>`;
    const q = (s) => box.querySelector(s);
    if (q("#e-res")) q("#e-res").value = String(o.res);
    q("#e-fmt").onchange = (e) => { o.format = e.target.value; setPref("format", o.format); draw(); };
    if (q("#e-res")) q("#e-res").onchange = (e) => { o.res = +e.target.value; setPref("res", o.res); draw(); };
    if (q("#e-cap")) q("#e-cap").onchange = (e) => { o.burn = e.target.checked; setPref("burn", o.burn); };
    q("#e-srt").onchange = (e) => { o.srt = e.target.checked; setPref("srt", o.srt); };
    q("#e-cancel").onclick = () => $("#modal").classList.add("hidden");
    q("#e-go").onclick = go;
  };
  const go = async () => {
    const [, label, ext] = EXPORT_FORMATS.find((f) => f[0] === o.format);
    const base = S.path ? S.path.split(/[\\/]/).pop().replace(/\.easycut$/, "") : L("새 프로젝트");
    const path = await tauri.dialog.save({ defaultPath: `${base} ${L("편집본")}.${ext}`, filters: [{ name: label, extensions: [ext] }] });
    if (!path) return;
    player.pause();
    const started = performance.now();
    box.innerHTML = `<h2>${L("내보내기")}</h2><progress id="e-pr" max="1" style="width:100%"></progress>
      <div class="row"><span id="e-pct" class="hint">0%</span><span id="e-eta" class="hint"></span><span class="spacer"></span><button id="e-stop">${L("취소")}</button></div>`;
    box.querySelector("#e-stop").onclick = () => invoke("cancel_job");
    const un = await listen("job", (e) => {
      if (e.payload.id !== "export") return;
      const v = e.payload.value;
      const pr = box.querySelector("#e-pr");
      if (!pr) return;
      pr.value = v;
      box.querySelector("#e-pct").textContent = Math.round(v * 100) + "%";
      if (v > 0.03 && v < 1) {
        const el = (performance.now() - started) / 1000;
        box.querySelector("#e-eta").textContent = " · " + L("남은 시간 약 {}", U.fmt(el / v - el).replace(/\.\d+$/, ""));
      }
    });
    try {
      await invoke("export_video", { path, height: o.res, burnCaptions: o.burn, format: o.format, alsoSrt: o.srt });
      box.innerHTML = `<h2>✅ ${L("내보내기 완료!")}</h2><p class="hint" style="word-break:break-all">${esc(path)}</p>
        <div class="btns"><button id="e-show">${L("탐색기에서 보기")}</button><button id="e-play">${L("재생")}</button><span class="spacer"></span><button class="primary" id="e-close">${L("닫기")}</button></div>`;
      box.querySelector("#e-show").onclick = () => invoke("reveal_file", { path });
      box.querySelector("#e-play").onclick = () => invoke("open_file", { path });
      box.querySelector("#e-close").onclick = () => $("#modal").classList.add("hidden");
    } catch (e) {
      const msg = L(String(e?.message ?? e));
      box.innerHTML = `<h2>${L("내보내기")}</h2><p class="hint" style="color:#ff7b7b;white-space:pre-line">${esc(msg)}</p>
        <div class="btns"><button class="primary" id="e-close">${L("닫기")}</button></div>`;
      box.querySelector("#e-close").onclick = () => $("#modal").classList.add("hidden");
    } finally {
      un();
    }
  };
  await draw();
  $("#modal").classList.remove("hidden");
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

/// 타임라인 도구 막대의 구간 표시 (맥 ContentView: 구간 시간 · 잘라내기 · 해제)
let lastRange = "";
export function rangeInfo() {
  const el = $("#range-info");
  if (!el) return;
  const r = U.markRange();
  const key = r ? `${r[0]}-${r[1]}` : S.markIn != null ? `in${S.markIn}` : "";
  if (key === lastRange) return;
  lastRange = key;
  if (r) {
    el.innerHTML = `<span class="rng">${U.fmt(r[0])} – ${U.fmt(r[1])} (${(r[1] - r[0]).toFixed(1)}s)</span>
      <button class="mini danger-text" id="rng-cut">✂ ${L("구간 잘라내기")}</button><button class="mini" id="rng-clear" title="X">✕</button>`;
    el.querySelector("#rng-cut").onclick = () => deleteSelection(true);
    el.querySelector("#rng-clear").onclick = commands.clearMarks;
  } else if (S.markIn != null) {
    el.innerHTML = `<span class="hint">${L("시작 {} · O로 끝 지점", U.fmt(S.markIn))}</span>`;
  } else {
    el.innerHTML = "";
  }
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

const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const hexColor = (c) => "#" + [c.r, c.g, c.b].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");

/// 재생헤드 위치 장면을 PNG로 (맥 '현재 장면 PNG로 저장')
async function snapshot() {
  const base = S.path ? S.path.split(/[\\/]/).pop().replace(/\.easycut$/, "") : "EasyCut";
  const path = await tauri.dialog.save({ defaultPath: `${base} ${U.fmt(S.time).replace(/[:.]/g, "-")}.png`, filters: [{ name: "PNG", extensions: ["png"] }] });
  if (!path) return;
  try { await invoke("snapshot_png", { path, time: S.time }); toast(L("장면을 저장했습니다")); } catch (e) { showError(e); }
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
  openPath: (p) => openProject(p),
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
  sttSettings,
  snapshot,
  exportTranscript: () => exportTxt(),
  findTranscript: focusSearch,
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
  prevFrame: () => { player.pause(); seek(S.time - 1 / (S.project?.fps || 30)); },
  nextFrame: () => { player.pause(); seek(S.time + 1 / (S.project?.fps || 30)); },
  toggleCaptions: () => run("update_project", { props: { showCaptions: !S.project.showCaptions } }),
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
  transcribe: transcribeTimeline,
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
      t: "split", "/": "shortcuts", f: "findTranscript", d: "duplicate", a: "selectAll", c: "copy", x: "cut", v: "paste", g: "group", j: "join" };
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
    case "Enter": case "NumpadEnter":
      if (S.selWords.size && document.querySelector("#tab-transcript.on")) { e.preventDefault(); fixSelectedWord(); }
      return;
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
  initSplitters();
  timeline = new Timeline($("#timeline"), $("#tl-scroll"));
  player = new Player($("#canvas"), $("#stage"));
  document.querySelectorAll("[data-cmd]").forEach((b) => (b.onclick = () => commands[b.dataset.cmd]?.()));
  document.querySelectorAll(".tabs button").forEach((b) => (b.onclick = () => switchTab(b.dataset.tab)));
  $("#rate").onchange = (e) => player.setRate(+e.target.value);
  $("#rate-slider").oninput = (e) => player.setRate(Math.round(Math.exp(+e.target.value) * 100) / 100);
  $("#scrub-bar").oninput = (e) => seek(+e.target.value * U.duration());
  $("#vol").value = S.volume;
  $("#vol").oninput = (e) => {
    S.volume = +e.target.value;
    localStorage.setItem("previewVolume", String(S.volume));
    $("#vol-ic").textContent = S.volume === 0 ? "🔇" : "🔊";
    player.update(false);
  };
  $("#vol-ic").textContent = S.volume === 0 ? "🔇" : "🔊";
  $("#zoom").oninput = (e) => timeline.setZoom(Math.pow(10, +e.target.value));
  window.addEventListener("keydown", onKey);
  window.addEventListener("selection", () => { renderInspector(); timeline.drawSoon(); reportUi(); });
  await listen("job", (e) => jobUpdate(e.payload));
  await listen("project", (e) => setState(e.payload));
  await listen("toast", (e) => toast(L(e.payload.text)));
  // 파일을 끌어다 놓기: 타임라인 위면 그 자리에, 아니면 미디어로 가져오기
  await listen("tauri://drag-drop", (e) => {
    const paths = e.payload?.paths;
    if (!paths?.length) return;
    const pos = e.payload.position;
    const at = pos ? timeline.pointAt(pos.x / devicePixelRatio, pos.y / devicePixelRatio) : null;
    importFiles(paths, at ? [at.ti, at.t] : null);
  });
  await listen("open-files", (e) => { if (e.payload?.length) importFiles(e.payload); });
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
  const modal = { box: modalBox(), show: showModal, hide: hideModal };
  initTranscript({ S, U, run, invoke, seek, toast, switchTab, ask, modal, player, timeline, generateCaptions, addCaption, render });
  initCaptions({ S, U, run, invoke, seek, toast, switchTab, render, commands, ask, captionMenu, selectionChanged: () => window.dispatchEvent(new Event("selection")) });
  setState(await invoke("get_state"));
  syncToggles();
  reportUi();
  await initAI($("#tab-ai"), { toast, modal });
  initRecord({ toast, modal, autoTranscribe });
  const files = await invoke("startup_files");
  if (files.length) importFiles(files);
  await initShell({ S, U, run, toast, commands, switchTab, isBusyRecording: isRecording });
}

init();
