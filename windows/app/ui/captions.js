// 자막 탭과 자막 인스펙터 (맥 Panels.swift CaptionsPanel / CaptionRow / TextStyleControls)
import { startDrag } from "./drag.js";

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

export const FONTS = ["Malgun Gothic", "Gulim", "Dotum", "Batang", "Gungsuh", "NanumGothic", "NanumMyeongjo", "NanumBarunGothic", "NanumSquare", "Noto Sans KR", "Pretendard", "Segoe UI", "Arial"];

export const hex = (c) => "#" + [c.r, c.g, c.b].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
export const rgba = (h, a = 1) => ({ r: parseInt(h.slice(1, 3), 16) / 255, g: parseInt(h.slice(3, 5), 16) / 255, b: parseInt(h.slice(5, 7), 16) / 255, a });
const WHITE = { r: 1, g: 1, b: 1, a: 1 }, BLACK = { r: 0, g: 0, b: 0, a: 1 }, YELLOW = { r: 1, g: 0.84, b: 0.04, a: 1 };
const CAPTION_BG = { r: 0, g: 0, b: 0, a: 0.6 }, CLEAR = { r: 0, g: 0, b: 0, a: 0 };

let X; // { S, U, run, invoke, seek, toast, switchTab }

export function initCaptions(ctx) {
  X = ctx;
  if (X.S.capCutsVideo == null) X.S.capCutsVideo = localStorage.getItem("captionCutsVideo") !== "0";
}

export const sortedCaptions = () => [...(X.S.project?.captions || [])].sort((a, b) => a.start - b.start);

export async function deleteCaptions(ids, withVideo = X.S.capCutsVideo) {
  const v = await X.run("delete_captions", { ids, withVideo });
  if (v?.message) X.toast(L(v.message));
  if (ids.includes(X.S.selCap)) X.S.selCap = null;
}

export async function addCaption(time = X.S.time) {
  const v = await X.run("add_caption", { time });
  if (v?.caption) { X.S.selCap = v.caption; X.switchTab("captions"); X.render(); }
}

export async function generateCaptions(confirmFirst = true) {
  const p = X.S.project;
  if (!X.S.words.length) return X.toast(L("대본이 없습니다. 먼저 음성 인식을 실행하세요."));
  if (confirmFirst && p.captions.length) {
    const ok = await X.ask(L("기존 자막을 대본으로 다시 만들까요?"), L("직접 수정한 자막 내용은 사라집니다."),
      [{ label: L("취소"), value: false }, { label: L("다시 만들기"), value: true, primary: true }]);
    if (!ok) return;
  }
  const v = await X.run("generate_captions");
  if (v) X.toast(L("자막 {}개 생성", v.project.captions.length));
}

/// 글자 스타일 편집 (자막 전체 스타일, 텍스트 클립). 바뀌면 onChange(새 스타일)
export function styleControls(el, style, onChange, showPosition) {
  const fonts = FONTS.includes(style.fontName) || !style.fontName ? FONTS : [style.fontName, ...FONTS];
  el.innerHTML = `
    <div class="row"><label>${L("크기")}</label><input type="range" data-s="fontSize" min="16" max="200" value="${style.fontSize}"/><span class="hint" data-v="fontSize">${Math.round(style.fontSize)}</span></div>
    <div class="row"><label>${L("글꼴")}</label><select data-s="fontName"><option value="">${L("기본 (맑은 고딕)")}</option>${fonts.map((f) => `<option ${f === style.fontName ? "selected" : ""}>${esc(f)}</option>`).join("")}</select></div>
    <div class="row"><label></label><label class="hint"><input type="checkbox" data-s="bold" ${style.bold ? "checked" : ""}/> ${L("굵게")}</label>
      <label class="hint"><input type="checkbox" data-s="outline" ${style.outline ? "checked" : ""}/> ${L("외곽선")}</label></div>
    <div class="row"><label>${L("글자")}</label><input type="color" data-c="textColor" value="${hex(style.textColor)}"/>
      <label style="width:auto">${L("배경")}</label><input type="color" data-c="backgroundColor" value="${hex(style.backgroundColor)}"/>
      <input type="range" data-s="bgAlpha" min="0" max="1" step="0.05" value="${style.backgroundColor.a}" title="${L("배경 투명도")}" style="max-width:70px"/>
      ${style.outline ? `<label style="width:auto">${L("외곽선")}</label><input type="color" data-c="outlineColor" value="${hex(style.outlineColor)}"/>` : ""}</div>
    ${showPosition ? `<div class="row"><label>${L("위치")}</label><input type="range" data-s="positionY" min="0.05" max="0.95" step="0.01" value="${style.positionY}"/><span class="hint" data-v="positionY">${L(style.positionY > 0.66 ? "아래" : style.positionY < 0.33 ? "위" : "가운데")}</span></div>` : ""}
    <div class="row"><span class="hint">${L("빠른 스타일")}</span>
      <button class="mini" data-q="basic">${L("기본")}</button><button class="mini" data-q="yellow">${L("노랑")}</button><button class="mini" data-q="white">${L("흰+외곽")}</button></div>`;
  const commit = (patch) => onChange({ ...style, ...patch });
  el.querySelectorAll("[data-s]").forEach((inp) => {
    const k = inp.dataset.s;
    if (inp.type === "range") {
      inp.oninput = () => {
        const out = el.querySelector(`[data-v="${k}"]`);
        if (out) out.textContent = k === "positionY" ? L(+inp.value > 0.66 ? "아래" : +inp.value < 0.33 ? "위" : "가운데") : Math.round(+inp.value);
      };
      inp.onchange = () => commit(k === "bgAlpha" ? { backgroundColor: { ...style.backgroundColor, a: +inp.value } } : { [k]: +inp.value });
    } else if (inp.type === "checkbox") inp.onchange = () => commit({ [k]: inp.checked });
    else inp.onchange = () => commit({ [k]: inp.value });
  });
  el.querySelectorAll("[data-c]").forEach((inp) => {
    const k = inp.dataset.c;
    inp.onchange = () => {
      const a = k === "backgroundColor" ? (style.backgroundColor.a > 0.01 ? style.backgroundColor.a : 0.6) : 1;
      commit({ [k]: rgba(inp.value, a), ...(k === "outlineColor" ? { outline: true } : {}) });
    };
  });
  el.querySelectorAll("[data-q]").forEach((b) => (b.onclick = () => {
    const q = b.dataset.q;
    if (q === "basic") commit({ textColor: WHITE, backgroundColor: CAPTION_BG, outline: false });
    if (q === "yellow") commit({ textColor: YELLOW, backgroundColor: CLEAR, outline: true, outlineColor: BLACK });
    if (q === "white") commit({ textColor: WHITE, backgroundColor: CLEAR, outline: true, outlineColor: BLACK });
  }));
}

// MARK: 자막 탭

export function renderCaptions(el) {
  const { S, U, run } = X;
  const p = S.project;
  if (!p) return;
  const caps = sortedCaptions();
  el.innerHTML = `
    <div class="row">
      <button class="primary" id="c-gen" title="Ctrl+Shift+C">🪄 ${L("대본→자막")}</button>
      <button id="c-add" title="${L("재생헤드 위치에 자막 추가")} (C)">＋</button>
      <button id="c-imp">${L("SRT 가져오기…")}</button><button id="c-exp">${L("SRT 내보내기…")}</button>
      <span class="spacer"></span><span class="hint">${L("{}개", caps.length)}</span>
    </div>
    <div class="row"><label class="hint" style="width:auto" title="${L("켜면 자막 한 줄을 지울 때 그 말이 나오는 영상 구간도 잘려 나갑니다. 목록에서 줄을 끌어 순서를 바꾸면 영상도 함께 옮겨집니다.")}">
      <input type="checkbox" id="c-cut" ${S.capCutsVideo ? "checked" : ""}/> ${L("자막을 지우면 영상도 함께 삭제")}</label>
      <label class="hint" style="width:auto"><input type="checkbox" id="c-show" ${p.showCaptions ? "checked" : ""}/> ${L("자막 표시")}</label>
      ${caps.length ? `<button class="mini danger-text" id="c-clear">${L("자막 모두 삭제")}</button>` : ""}</div>
    <div class="caplist"></div>
    <details class="capstyle" ${localStorage.getItem("capStyleOpen") === "0" ? "" : "open"}><summary>${L("자막 스타일")}</summary><div id="c-style"></div></details>`;
  const q = (s) => el.querySelector(s);
  q("#c-gen").onclick = () => generateCaptions();
  q("#c-add").onclick = () => addCaption();
  q("#c-imp").onclick = X.commands.importSrt;
  q("#c-exp").onclick = X.commands.exportSrt;
  q("#c-cut").onchange = (e) => { S.capCutsVideo = e.target.checked; localStorage.setItem("captionCutsVideo", S.capCutsVideo ? "1" : "0"); renderCaptions(el); };
  q("#c-show").onchange = (e) => run("update_project", { props: { showCaptions: e.target.checked } });
  if (q("#c-clear")) q("#c-clear").onclick = async () => {
    const ok = await X.ask(L("자막 모두 삭제"), L("자막 {}개를 모두 지울까요? (영상은 그대로)", caps.length), [{ label: L("취소"), value: false }, { label: L("삭제"), value: true, danger: true }]);
    if (ok) run("clear_captions");
  };
  el.querySelector("details.capstyle").ontoggle = (e) => localStorage.setItem("capStyleOpen", e.target.open ? "1" : "0");
  styleControls(q("#c-style"), p.captionStyle, (st) => run("update_project", { props: { captionStyle: st } }), true);

  const list = q(".caplist");
  if (!caps.length) {
    list.innerHTML = `<div class="empty-note"><div style="font-size:30px">💬</div><b>${L("자막이 없습니다")}</b><p class="hint">${L("음성 인식 후 [대본→자막]을 누르거나\n+ 로 직접 추가하세요.").replace("\n", "<br>")}</p></div>`;
    return;
  }
  caps.forEach((c, i) => {
    const row = document.createElement("div");
    row.className = "c" + (S.selCap === c.id ? " sel" : "");
    row.dataset.id = c.id;
    row.innerHTML = `<div class="grip" title="${L("끌어서 순서 바꾸기 (영상도 함께 옮겨집니다)")}">⋮⋮</div><div class="tm" title="${L("여기로 이동")}">${U.fmt(c.start)}<br><span class="hint">${U.fmt(c.end)}</span></div><textarea rows="1"></textarea>
      <button class="del" title="${L(S.capCutsVideo ? "자막과 그 구간 영상 삭제" : "자막만 삭제")}">${S.capCutsVideo ? "✂" : "✕"}</button>`;
    const ta = row.querySelector("textarea");
    ta.value = c.text;
    ta.onfocus = () => { if (S.selCap !== c.id) { S.selCap = c.id; S.sel.clear(); markSelected(list); X.selectionChanged(); } };
    const commit = () => { if (ta.value !== c.text) run("update_caption", { id: c.id, text: ta.value }); };
    ta.onchange = commit;
    ta.onkeydown = (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); ta.blur(); } e.stopPropagation(); };
    row.querySelector(".tm").onclick = () => { X.seek(c.start); S.selCap = c.id; S.sel.clear(); markSelected(list); X.selectionChanged(); };
    row.querySelector(".del").onclick = () => deleteCaptions([c.id]);
    row.oncontextmenu = (e) => { e.preventDefault(); X.captionMenu(e.clientX, e.clientY, c); };
    // 끌어서 순서 바꾸기 → 영상 구간도 함께 이동
    row.querySelector(".grip").onmousedown = (e) => {
      e.preventDefault();
      let to = null;
      const rows = [...list.querySelectorAll(".c")];
      const target = (y) => {
        rows.forEach((r) => r.classList.remove("drop", "drop-top"));
        for (let k = 0; k < rows.length; k++) {
          const r = rows[k].getBoundingClientRect();
          if (y < r.top + r.height / 2) { rows[k].classList.add("drop-top"); return k; }
        }
        rows[rows.length - 1]?.classList.add("drop");
        return rows.length;
      };
      startDrag(e, {
        label: c.text.slice(0, 24),
        onMove: (x, y) => (to = target(y)),
        onDrop: () => {
          rows.forEach((r) => r.classList.remove("drop", "drop-top"));
          if (to != null && to !== i && to !== i + 1) {
            run("move_caption", { from: i, to });
            X.toast(L("순서를 바꿨습니다"));
          }
        },
        onCancel: () => rows.forEach((r) => r.classList.remove("drop", "drop-top")),
      });
    };
    list.appendChild(row);
  });
  // 선택한 자막이 보이게
  list.querySelector(".c.sel")?.scrollIntoView({ block: "nearest" });
}

function markSelected(list) {
  list.querySelectorAll(".c").forEach((r) => r.classList.toggle("sel", r.dataset.id === X.S.selCap));
}

// MARK: 자막 인스펙터 (오른쪽)

export function captionInspector(el, c) {
  const { S, U, run } = X;
  const dur = U.duration();
  el.innerHTML = `<div style="padding:10px">
    <h3>${L("자막")}</h3>
    <textarea id="ci-text" rows="3" style="width:100%"></textarea>
    <div class="row"><label>${L("시작")}</label><input type="range" id="ci-s" min="0" max="${Math.max(dur, c.end)}" step="0.01" value="${c.start}"/><span class="hint" id="ci-sv">${U.fmt(c.start)}</span></div>
    <div class="row"><label>${L("끝")}</label><input type="range" id="ci-e" min="0" max="${Math.max(dur, c.end) + 5}" step="0.01" value="${c.end}"/><span class="hint" id="ci-ev">${U.fmt(c.end)}</span></div>
    <div class="row"><button id="ci-sp">${L("시작을 재생헤드로")}</button><button id="ci-ep">${L("끝을 재생헤드로")}</button></div>
    <div class="row"><button id="ci-dv">✂ ${L("자막과 영상 함께 삭제")}</button></div>
    <div class="row"><button id="ci-d">✕ ${L("자막만 삭제 (영상 유지)")}</button></div>
  </div>`;
  const q = (s) => el.querySelector(s);
  q("#ci-text").value = c.text;
  q("#ci-text").onchange = (e) => run("update_caption", { id: c.id, text: e.target.value });
  q("#ci-text").onkeydown = (e) => e.stopPropagation();
  q("#ci-s").oninput = (e) => (q("#ci-sv").textContent = U.fmt(+e.target.value));
  q("#ci-e").oninput = (e) => (q("#ci-ev").textContent = U.fmt(+e.target.value));
  q("#ci-s").onchange = (e) => run("update_caption", { id: c.id, start: +e.target.value });
  q("#ci-e").onchange = (e) => run("update_caption", { id: c.id, end: +e.target.value });
  q("#ci-sp").onclick = () => run("update_caption", { id: c.id, start: S.time });
  q("#ci-ep").onclick = () => run("update_caption", { id: c.id, end: S.time });
  q("#ci-dv").onclick = () => deleteCaptions([c.id], true);
  q("#ci-d").onclick = () => deleteCaptions([c.id], false);
}
