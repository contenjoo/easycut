// 대본 탭 · 음성 인식 설정 · 무음 컷 (맥 TranscriptView.swift / Sheets.swift STTSettingsSheet / SilenceSheet)
import { showMenu } from "./menu.js";

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
let X; // { S, U, run, invoke, seek, toast, switchTab, ask, modal, player, timeline, generateCaptions, addCaption, render }

export const LANGS = [["ko", "한국어"], ["en", "영어"], ["ja", "일본어"], ["zh", "중국어"], ["es", "스페인어"], ["fr", "프랑스어"], ["de", "독일어"], ["auto", "자동 감지"]];

export function initTranscript(ctx) {
  X = ctx;
}

// MARK: 음성 인식 실행

async function ensureWhisper() {
  const st = await X.invoke("stt_models");
  if (!st.engine) { X.toast(T("engineMissing")); return false; }
  if (st.models.find((m) => m.id === st.selected)?.installed) return true;
  const m = st.models.find((m) => m.id === st.selected);
  const ok = await X.ask(L("Whisper 음성 인식 모델"), L("처음 한 번 인식 모델({}MB)을 받아야 합니다. 받은 뒤에는 인터넷 없이 이 PC에서 처리됩니다.", Math.round(m?.sizeMB || 0)),
    [{ label: L("모델 고르기…"), value: "pick" }, { label: L("취소"), value: false }, { label: L("받기"), value: true, primary: true }]);
  if (ok === "pick") { sttSettings(); return false; }
  if (!ok) return false;
  try { await X.invoke("stt_download", { id: st.selected }); return true; } catch (e) { X.toast(L(String(e))); return false; }
}

/// 한 미디어만 인식
export async function transcribeAsset(id) {
  if (!(await ensureWhisper())) return;
  X.switchTab("transcript");
  const hadCaptions = X.S.project.captions.length > 0;
  const v = await X.run("transcribe", { asset: id, language: X.S.language });
  if (v) afterTranscribe(hadCaptions);
}

/// 타임라인의 미디어 인식. 이미 대본이 있으면 새 미디어만, 모두 있으면 다시 할지 묻는다
export async function transcribeTimeline() {
  const { S } = X;
  const used = new Set(S.project.tracks.flatMap((t) => t.clips.map((c) => c.assetID)).filter(Boolean));
  const all = S.project.assets.filter((a) => used.has(a.id) && a.hasAudio);
  if (!all.length) return X.toast(T("noAudio"));
  let targets = all.filter((a) => !a.words);
  if (!targets.length) {
    const again = await X.ask(L("음성을 다시 인식할까요?"), L("이미 대본이 있습니다. 다시 인식하면 대본을 고친 내용은 사라집니다."),
      [{ label: L("취소"), value: false }, { label: L("다시 인식"), value: true, primary: true }]);
    if (!again) return;
    targets = all;
  }
  if (!(await ensureWhisper())) return;
  X.switchTab("transcript");
  const hadCaptions = S.project.captions.length > 0;
  for (const a of targets) {
    const v = await X.run("transcribe", { asset: a.id, language: S.language });
    if (!v) return;
  }
  afterTranscribe(hadCaptions);
}

/// 처음 인식하면 자막도 바로 만든다 (맥과 같음)
function afterTranscribe(hadCaptions) {
  if (!hadCaptions && X.S.words.length) X.generateCaptions(false);
}

// MARK: 대본 탭

let drag = null;
let query = "";
let hits = [];
let hitAt = -1;

export function renderTranscript(el) {
  const { S, U } = X;
  const lang = LANGS.find((l) => l[0] === S.language)?.[1] || S.language;
  el.innerHTML = `
    <div class="row">
      <button class="primary" id="t-run" title="Ctrl+Shift+R">🎙 ${L("음성 인식")}</button>
      <button class="mini" id="t-set" title="${L("인식 언어·모델 설정")}">${L(lang)} · Whisper ⚙</button>
      <span class="spacer"></span>
      <input id="t-find" placeholder="🔍 ${L("대본 검색")} (Ctrl+F)" style="width:130px" value="${esc(query)}"/>
      <span class="hint" id="t-hits"></span>
    </div>
    <div id="transcript"></div>
    <div class="t-foot">
      <div class="hint" id="t-count"></div>
      <div class="row">
        <button id="t-del" disabled>✂ ${L("선택 삭제")}</button>
        <button id="t-sil">${L("무음 제거")}</button>
        <button id="t-fill">${L("군더더기")}</button>
      </div>
      <div class="row">
        <button id="t-cap" title="Ctrl+Shift+C">${L("자막 만들기")}</button>
        <button id="t-txt">TXT</button>
      </div>
    </div>`;
  const q = (s) => el.querySelector(s);
  q("#t-run").onclick = transcribeTimeline;
  q("#t-set").onclick = sttSettings;
  q("#t-del").onclick = deleteWords;
  q("#t-sil").onclick = silenceDialog;
  q("#t-fill").onclick = () => X.run("remove_fillers");
  q("#t-cap").onclick = () => X.generateCaptions();
  q("#t-txt").onclick = exportTxt;
  const find = q("#t-find");
  find.onkeydown = (e) => {
    e.stopPropagation();
    if (e.key === "Enter") { e.preventDefault(); jumpHit(e.shiftKey ? -1 : 1); }
    if (e.key === "Escape") { find.value = ""; search(""); find.blur(); }
  };
  find.oninput = () => search(find.value);
  const box = q("#transcript");
  if (!S.words.length) {
    box.innerHTML = `<div class="empty-note"><div style="font-size:30px">💬</div><b>${L("아직 대본이 없습니다")}</b>
      <p class="hint">${esc(L("영상을 타임라인에 올리고 [음성 인식]을 누르면\n말한 내용이 텍스트로 나타납니다.\n\n텍스트를 선택해 Delete를 누르면 그 부분이 영상에서 잘립니다.")).replace(/\n/g, "<br>")}</p></div>`;
    el.querySelector(".t-foot").style.display = "none";
    return;
  }
  const frag = document.createDocumentFragment();
  let lastLine = -99;
  S.words.forEach((w, i) => {
    // 쉬면 새 줄 (시각 표시는 누르면 그리로 이동)
    if (i === 0 || w.start - S.words[i - 1].end > 1.2 || w.start - lastLine > 30) {
      if (i) frag.appendChild(document.createElement("br"));
      const t = document.createElement("span");
      t.className = "t";
      t.textContent = U.fmt(w.start).replace(/\.\d+$/, "");
      t.dataset.seek = w.start;
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
    if (e.button !== 0) return;
    if (e.target.dataset?.seek) { X.seek(+e.target.dataset.seek); return; }
    const i = e.target.dataset?.i;
    if (i == null) return;
    const idx = +i;
    if (e.shiftKey && drag?.anchor != null) {
      selectRange(drag.anchor, idx);
    } else {
      drag = { anchor: idx, active: true };
      selectRange(idx, idx);
      X.seek(S.words[idx].start);
    }
  };
  box.onmouseover = (e) => {
    const i = e.target.dataset?.i;
    if (i == null || !drag?.active || !(e.buttons & 1)) return;
    selectRange(drag.anchor, +i);
  };
  box.ondblclick = (e) => { if (e.target.dataset?.i != null) fixWord(+e.target.dataset.i); };
  box.oncontextmenu = (e) => {
    e.preventDefault();
    const i = e.target.dataset?.i;
    if (i != null && !S.selWords.has(S.words[+i].id)) selectRange(+i, +i);
    wordMenu(e.clientX, e.clientY, i != null ? +i : null);
  };
  window.addEventListener("mouseup", () => { if (drag) drag.active = false; }, { once: true });
  updateCount();
  if (query) search(query, false);
  highlightWord(true);
}

function updateCount() {
  const el = document.querySelector("#t-count");
  const n = X.S.selWords.size;
  if (el) el.textContent = n ? L("{}개 단어 선택됨", n) : L("단어 {}개 · 클릭=이동, 드래그=선택", X.S.words.length);
  const btn = document.querySelector("#t-del");
  if (btn) { btn.disabled = !n; btn.textContent = `✂ ${L("선택 삭제")}${n ? ` (${n})` : ""}`; }
}

export function selectRange(a, b) {
  const { S } = X;
  const [lo, hi] = [Math.min(a, b), Math.max(a, b)];
  S.selWords = new Set(S.words.slice(lo, hi + 1).map((w) => w.id));
  document.querySelectorAll("#transcript .w").forEach((el) => el.classList.toggle("sel", S.selWords.has(S.words[+el.dataset.i].id)));
  updateCount();
}

export async function deleteWords() {
  const { S } = X;
  if (!S.selWords.size) return;
  const n = S.selWords.size;
  const ids = [...S.selWords];
  S.selWords.clear();
  await X.run("delete_words", { ids });
  X.toast(L("{}개 단어 삭제", n));
}

/// 단어 고치기. 비우면 그 단어를 영상에서 잘라낸다 (맥과 같음)
async function fixWord(i) {
  const w = X.S.words[i];
  const text = prompt(L("단어 고치기 (비우면 삭제)"), w.text);
  if (text == null) return;
  if (!text.trim()) { X.S.selWords = new Set([w.id]); return deleteWords(); }
  X.run("update_word", { asset: w.asset, word: w.word, text: text.trim() });
}

/// Enter: 선택한 첫 단어 고치기
export function fixSelectedWord() {
  const i = X.S.words.findIndex((w) => X.S.selWords.has(w.id));
  if (i >= 0) fixWord(i);
}

function wordMenu(x, y, i) {
  const { S } = X;
  const n = S.selWords.size;
  const sel = S.words.filter((w) => S.selWords.has(w.id));
  showMenu(x, y, [
    { label: n ? L("선택한 {}개 단어를 영상에서 잘라내기", n) : L("단어를 선택하세요"), key: "Delete", disabled: !n, action: deleteWords },
    { label: L("단어 고치기"), key: "Enter", disabled: i == null, action: () => fixWord(i) },
    { label: L("여기서 재생"), disabled: i == null, action: () => { X.seek(S.words[i].start); X.player.play(); } },
    { label: L("선택 구간을 자막으로 추가"), disabled: !n, action: async () => {
      await X.run("add_caption", { time: sel[0].start, end: sel[sel.length - 1].end, text: sel.map((w) => w.text).join(" ") });
      X.toast(L("자막을 추가했습니다"));
    } },
    { sep: true },
    { label: L("무음 제거…"), action: silenceDialog },
    { label: L("군더더기 말 제거"), action: () => X.run("remove_fillers") },
  ]);
}

// 대본 검색 (띄어쓰기 무시)
function search(q, jump = true) {
  query = q;
  const { S } = X;
  document.querySelectorAll("#transcript .w.hit").forEach((el) => el.classList.remove("hit", "cur"));
  hits = [];
  hitAt = -1;
  const needle = q.replace(/\s+/g, "").toLowerCase();
  const out = document.querySelector("#t-hits");
  if (!needle) { if (out) out.textContent = ""; return; }
  const norm = S.words.map((w) => w.text.replace(/\s+/g, "").toLowerCase());
  for (let st = 0; st < norm.length; st++) {
    let acc = "", en = st;
    while (en < norm.length && acc.length < needle.length) { acc += norm[en]; en++; }
    if (acc.startsWith(needle) || (acc.includes(needle) && en - st === 1)) hits.push([st, en - 1]);
  }
  for (const [a, b] of hits) for (let i = a; i <= b; i++) document.querySelector(`#transcript .w[data-i="${i}"]`)?.classList.add("hit");
  if (out) out.textContent = hits.length ? `${hits.length}` : L("없음");
  if (jump && hits.length) jumpHit(1);
}

function jumpHit(dir) {
  if (!hits.length) return;
  document.querySelectorAll("#transcript .w.cur").forEach((el) => el.classList.remove("cur"));
  hitAt = (hitAt + dir + hits.length) % hits.length;
  const [a, b] = hits[hitAt];
  for (let i = a; i <= b; i++) document.querySelector(`#transcript .w[data-i="${i}"]`)?.classList.add("cur");
  document.querySelector(`#transcript .w[data-i="${a}"]`)?.scrollIntoView({ block: "center" });
  selectRange(a, b);
  X.seek(X.S.words[a].start);
  const out = document.querySelector("#t-hits");
  if (out) out.textContent = `${hitAt + 1}/${hits.length}`;
}

export function focusSearch() {
  X.switchTab("transcript");
  setTimeout(() => document.querySelector("#t-find")?.focus(), 0);
}

let lastNow = -1;
/// 재생 위치의 단어 강조. 재생 중이면 보이게 스크롤
export function highlightWord(force) {
  const { S } = X;
  if (!S.words.length) return;
  let lo = 0, hi = S.words.length - 1, found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const w = S.words[mid];
    if (S.time < w.start) hi = mid - 1;
    else if (S.time >= w.end) lo = mid + 1;
    else { found = mid; break; }
  }
  if (found === lastNow && !force) return;
  document.querySelector(`#transcript .w[data-i="${lastNow}"]`)?.classList.remove("now");
  const el = document.querySelector(`#transcript .w[data-i="${found}"]`);
  el?.classList.add("now");
  lastNow = found;
  if (el && X.player?.playing && !drag?.active) {
    const box = document.querySelector("#tab-transcript");
    const r = el.getBoundingClientRect(), b = box.getBoundingClientRect();
    if (r.top < b.top + 40 || r.bottom > b.bottom - 120) el.scrollIntoView({ block: "center" });
  }
}

export async function exportTxt() {
  const base = X.S.path ? X.S.path.split(/[\\/]/).pop().replace(/\.easycut$/, "") : L("대본");
  const f = await window.__TAURI__.dialog.save({ defaultPath: `${base}.txt`, filters: [{ name: "TXT", extensions: ["txt"] }] });
  if (!f) return;
  try { await X.invoke("export_transcript", { path: f }); X.toast(T("saved")); } catch (e) { X.toast(L(String(e))); }
}

// MARK: 음성 인식 설정 (언어, 모델)

export async function sttSettings() {
  const { S } = X;
  const box = X.modal.box;
  let st = await X.invoke("stt_models");
  const draw = () => {
    box.innerHTML = `<h2>${L("음성 인식(STT) 설정")}</h2>
      <div class="row"><label>${L("언어")}</label><select id="st-lang">${LANGS.map(([v, n]) => `<option value="${v}" ${S.language === v ? "selected" : ""}>${L(n)}</option>`).join("")}</select></div>
      <p class="hint">${st.engine ? "✅ " + L("Whisper 엔진 내장됨") : "⚠ " + L("Whisper 엔진을 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")}</p>
      <h3>${L("모델")}</h3>
      ${st.models.map((m) => `<div class="row model-row"><label style="width:auto;flex:1"><input type="radio" name="st-m" value="${m.id}" ${st.selected === m.id ? "checked" : ""}/> ${esc(L(m.label))}
          <span class="hint"> · ${Math.round(m.sizeMB)}MB</span></label>
        ${m.installed ? `<span class="ok">✔ ${L("설치됨")}</span>` : `<button class="mini" data-dl="${m.id}">${L("내려받기")}</button>`}</div>`).join("")}
      <p class="hint">${L("CPU만 있는 PC에서는 Small이 빠르고, Large v3 Turbo가 가장 정확합니다.")}</p>
      <div class="btns"><button id="st-folder">${L("모델 폴더 열기")}</button><span class="spacer"></span><button class="primary" id="st-close">${L("완료")}</button></div>`;
    box.querySelector("#st-lang").onchange = (e) => { S.language = e.target.value; localStorage.setItem("sttLanguage", S.language); X.render(); };
    box.querySelectorAll('input[name="st-m"]').forEach((r) => (r.onchange = async () => { st = await X.invoke("stt_select", { id: r.value }); draw(); }));
    box.querySelectorAll("[data-dl]").forEach((b) => (b.onclick = async () => {
      b.disabled = true;
      b.textContent = L("받는 중…");
      try { st = await X.invoke("stt_download", { id: b.dataset.dl }); } catch (e) { X.toast(L(String(e))); }
      draw();
    }));
    box.querySelector("#st-folder").onclick = () => X.invoke("open_file", { path: st.folder });
    box.querySelector("#st-close").onclick = X.modal.hide;
  };
  draw();
  X.modal.show();
}

// MARK: 무음 컷 (잘릴 곳을 타임라인에 미리 보여주고 한 번에 적용)

const pref = (k, d) => { try { const v = localStorage.getItem("silence." + k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } };
const setPref = (k, v) => { try { localStorage.setItem("silence." + k, JSON.stringify(v)); } catch (_) {} };

export async function silenceDialog() {
  const { S, U } = X;
  const hasTranscript = S.words.length > 0;
  const o = {
    mode: hasTranscript ? pref("mode", "audio") : "audio",
    threshold: pref("threshold", -40),
    auto: pref("auto", true),
    minGap: pref("minGap", 0.6),
    keep: pref("keep", 0.12),
  };
  let result = null, analyzing = true, timer = null;
  const box = X.modal.box;
  const close = () => { S.silencePreview = []; X.timeline.drawSoon(); X.modal.hide(); };
  const draw = () => {
    const dur = U.duration();
    const total = result?.removed || 0;
    box.innerHTML = `<h2>✂ ${L("무음 컷")} ${analyzing ? `<span class="spin"></span> <span class="hint">${L("소리 분석 중…")}</span>` : ""}</h2>
      <p class="hint">${L("말이 없는 부분을 찾아 한 번에 잘라냅니다. 잘릴 곳은 타임라인에 빨간색으로 표시됩니다.")}</p>
      <div class="seg"><button data-mode="audio" class="${o.mode === "audio" ? "on" : ""}">${L("소리 크기로 (음성 인식 불필요)")}</button>
        <button data-mode="transcript" class="${o.mode === "transcript" ? "on" : ""}" ${hasTranscript ? "" : "disabled"}>${L("대본 기준 (말 사이 공백)")}</button></div>
      ${o.mode === "audio" ? `<div class="row"><label style="width:100px">${L("기준 음량")}</label><input type="range" id="s-th" min="-65" max="-15" step="1" value="${o.threshold}"/>
        <span class="hint" style="width:50px">${Math.round(o.threshold)} dB</span><label class="hint" style="width:auto"><input type="checkbox" id="s-auto" ${o.auto ? "checked" : ""}/> ${L("자동")}</label></div>
        <p class="hint">${L("이 음량보다 작은 소리는 무음으로 봅니다. 잡음이 많으면 오른쪽(크게)으로, 작은 말소리까지 잘리면 왼쪽으로.")}</p>` : ""}
      <div class="row"><label style="width:100px">${L("최소 무음 길이")}</label><input type="range" id="s-min" min="0.2" max="3" step="0.1" value="${o.minGap}"/><span class="hint" style="width:50px">${L("{}초", o.minGap.toFixed(1))}</span></div>
      <div class="row"><label style="width:100px">${L("앞뒤 여유")}</label><input type="range" id="s-pad" min="0" max="0.6" step="0.02" value="${o.keep}"/><span class="hint" style="width:50px">${L("{}초", o.keep.toFixed(2))}</span></div>
      <div class="row"><span class="hint">${L("빠른 설정")}</span><button class="mini" data-p="1,0.2">${L("자연스럽게")}</button><button class="mini" data-p="0.6,0.12">${L("보통")}</button><button class="mini" data-p="0.3,0.05">${L("빠른 템포")}</button></div>
      <div class="sumbox"></div>
      <div class="btns"><button id="s-cancel">${L("취소")}</button><button class="danger" id="s-go" ${!result?.ranges.length || analyzing ? "disabled" : ""}>${L("무음 잘라내기")}</button></div>`;
    const q = (s) => box.querySelector(s);
    showResult();
    box.querySelectorAll("[data-mode]").forEach((b) => (b.onclick = () => { o.mode = b.dataset.mode; setPref("mode", o.mode); draw(); recompute(); }));
    const label = (inp, text) => (inp.nextElementSibling.textContent = text);
    if (q("#s-th")) {
      q("#s-th").oninput = (e) => { o.threshold = +e.target.value; o.auto = false; q("#s-auto").checked = false; label(e.target, `${o.threshold} dB`); setPref("threshold", o.threshold); setPref("auto", false); soon(); };
      q("#s-auto").onchange = (e) => { o.auto = e.target.checked; setPref("auto", o.auto); recompute(); };
    }
    q("#s-min").oninput = (e) => { o.minGap = +e.target.value; label(e.target, L("{}초", o.minGap.toFixed(1))); setPref("minGap", o.minGap); soon(); };
    q("#s-pad").oninput = (e) => { o.keep = +e.target.value; label(e.target, L("{}초", o.keep.toFixed(2))); setPref("keep", o.keep); soon(); };
    box.querySelectorAll("[data-p]").forEach((b) => (b.onclick = () => {
      const [g, k] = b.dataset.p.split(",").map(Number);
      o.minGap = g; o.keep = k; setPref("minGap", g); setPref("keep", k); draw(); recompute();
    }));
    q("#s-cancel").onclick = close;
    q("#s-go").onclick = async () => {
      try {
        const r = await X.invoke("silence_ranges", { settings: settings(), auto: false, apply: true, mode: o.mode });
        close();
        X.toast(r.ranges.length ? L("무음 {}곳 · {}초 삭제", r.ranges.length, r.removed.toFixed(1)) : L("잘라낼 무음이 없습니다"));
      } catch (e) { X.toast(L(String(e))); }
    };
  };
  /// 결과 요약만 바꾼다 (끄는 중인 슬라이더를 다시 만들지 않게)
  function showResult() {
    const dur = U.duration();
    const total = result?.removed || 0;
    const sum = box.querySelector(".sumbox");
    if (!sum) return;
    sum.innerHTML = `<b class="${result?.ranges.length ? "red" : ""}">${result ? (result.ranges.length ? L("{}곳 · {}초 삭제", result.ranges.length, total.toFixed(1)) : L("잘라낼 무음이 없습니다")) : "…"}</b>
      <div class="hint">${U.fmt(dur)} → ${U.fmt(Math.max(0, dur - total))}  (${dur > 0 ? Math.round((total / dur) * 100) : 0}% ${L("단축")})</div>`;
    const go = box.querySelector("#s-go");
    if (go) go.disabled = !result?.ranges.length || analyzing;
    const th = box.querySelector("#s-th");
    if (th && o.auto) { th.value = o.threshold; th.nextElementSibling.textContent = `${Math.round(o.threshold)} dB`; }
    const h2 = box.querySelector("h2");
    if (h2 && !analyzing) h2.querySelectorAll(".spin, .hint").forEach((x) => x.remove());
  }
  const settings = () => ({ threshold: o.threshold, minSilence: o.minGap, padding: o.keep });
  const soon = () => { clearTimeout(timer); timer = setTimeout(recompute, 180); };
  async function recompute() {
    try {
      const r = await X.invoke("silence_ranges", { settings: settings(), auto: o.mode === "audio" && o.auto, apply: false, mode: o.mode });
      if (o.mode === "audio" && o.auto) o.threshold = Math.round(r.threshold);
      result = r;
      analyzing = false;
      S.silencePreview = r.ranges;
      X.timeline.drawSoon();
    } catch (e) {
      analyzing = false;
      X.toast(L(String(e)));
    }
    showResult();
  }
  draw();
  X.modal.show();
  recompute();
}
