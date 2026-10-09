// 개인정보 가리기 (맥과 같은 기능): 인스펙터 칸 + 미리보기 위 영역 그리기·옮기기·크기 조절
import { S, U, run, toast, seek, setState } from "./app.js";

const MANUAL = "직접 지정";
const pref = (k, d) => localStorage.getItem("privacy." + k) ?? d;
const setPref = (k, v) => localStorage.setItem("privacy." + k, v);
const STYLES = [["blur", "흐리게"], ["mosaic", "모자이크"], ["box", "검은 상자"]];
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

const srcTime = (c, t) => c.sourceIn + (t - c.start) * c.speed;
const tlTime = (c, s) => c.start + (s - c.sourceIn) / c.speed;
const active = (r, s) => s >= r.start - 1e-4 && s < r.end;
const uuid = () => crypto.randomUUID().toUpperCase();

export function setBlurs(c, list) {
  return run("set_blurs", { clip: c.id, blurs: list });
}

/// 인스펙터의 "가리기 (개인정보)" 칸
export function privacyHTML(c, a) {
  const list = c.blurs || [];
  const image = a.kind === "image";
  const style = pref("style", "blur");
  const rows = list.map((r) => {
    const sel = S.selBlur === r.id;
    const icon = r.label === "얼굴" ? "🙂" : r.label === MANUAL ? "⬚" : "🔎";
    const time = image ? "" : `<span class="hint">${U.fmt(tlTime(c, Math.max(r.start, c.sourceIn)))}~${U.fmt(tlTime(c, Math.min(r.end, c.sourceOut)))}</span>`;
    return `<div class="blurrow ${sel ? "on" : ""}" data-blur="${r.id}">
      <div class="row"><span>${icon}</span><span style="flex:1;min-width:0"><b>${esc(L(r.label))}</b>${r.text ? `<br><span class="hint">${esc(r.text)}</span>` : ""}</span>${time}
      <button class="mini" data-blurdel="${r.id}" title="${L("이 영역 지우기")}">✕</button></div>
      ${sel ? `<div class="seg small">${STYLES.map(([v, t]) => `<button data-blurstyle="${v}" class="${r.style === v ? "on" : ""}">${L(t)}</button>`).join("")}</div>
        ${image ? "" : `<div class="row"><button class="mini" data-blurtime="start">${L("시작=재생헤드")}</button><button class="mini" data-blurtime="end">${L("끝=재생헤드")}</button></div>`}` : ""}
    </div>`;
  }).join("");
  return `<h3>${L("가리기 (개인정보)")}</h3>
    <label class="row"><input type="checkbox" id="pv-pat" ${pref("patterns", "1") === "1" ? "checked" : ""}/> ${L("전화·주민·카드·계좌번호, 이메일")}</label>
    <label class="row"><input type="checkbox" id="pv-face" ${pref("faces", "0") === "1" ? "checked" : ""}/> ${L("얼굴")}</label>
    <input id="pv-keys" type="text" style="width:100%" placeholder="${L("이름·주소 등 가릴 글자 (쉼표로 구분)")}"/>
    <div class="row"><label>${L("방식")}</label><div class="seg small">${STYLES.map(([v, t]) => `<button data-pvstyle="${v}" class="${style === v ? "on" : ""}">${L(t)}</button>`).join("")}</div></div>
    <div class="row"><button class="mini primary" id="pv-scan" title="${L("화면 글자를 읽어(OCR) 개인정보가 보이는 자리와 시간을 찾습니다. 다시 찾으면 자동으로 찾은 영역은 새로 바뀌고, 직접 그린 영역은 남습니다.")}">🔎 ${L("자동으로 찾아 가리기")}</button>
      <button class="mini ${S.drawBlur ? "primary" : ""}" id="pv-draw" title="${L("미리보기 화면에서 끌어서 가릴 영역을 그립니다 (재생헤드부터 클립 끝까지)")}">⬚ ${L(S.drawBlur ? "그리기 취소" : "직접 그리기")}</button></div>
    ${list.length ? `${rows}<div class="row"><span class="hint">${L("{}곳 가림", list.length)}</span><span class="spacer"></span>
      <select id="pv-all"><option value="">${L("방식 모두 바꾸기")}</option>${STYLES.map(([v, t]) => `<option value="${v}">${L(t)}</option>`).join("")}</select>
      <button class="mini danger-text" id="pv-clear">${L("모두 지우기")}</button></div>
      <p class="hint">${L("미리보기를 멈춘 상태에서 영역을 끌어 옮기고, 오른쪽 아래 점으로 크기를 바꿉니다. 영역을 고르고 Delete로 지웁니다.")}</p>` : ""}`;
}

export function wirePrivacy(el, c, a, player) {
  const q = (s) => el.querySelector(s);
  if (!q("#pv-scan")) return;
  const list = c.blurs || [];
  q("#pv-keys").value = pref("keywords", "");
  q("#pv-keys").onkeydown = (e) => e.stopPropagation();
  q("#pv-keys").onchange = (e) => setPref("keywords", e.target.value);
  q("#pv-pat").onchange = (e) => setPref("patterns", e.target.checked ? "1" : "0");
  q("#pv-face").onchange = (e) => setPref("faces", e.target.checked ? "1" : "0");
  el.querySelectorAll("[data-pvstyle]").forEach((b) => (b.onclick = () => {
    setPref("style", b.dataset.pvstyle);
    el.querySelectorAll("[data-pvstyle]").forEach((x) => x.classList.toggle("on", x === b));
  }));
  q("#pv-scan").onclick = async () => {
    const keywords = q("#pv-keys").value.split(/[,\n]/).map((s) => s.trim()).filter(Boolean);
    const patterns = q("#pv-pat").checked, faces = q("#pv-face").checked;
    if (!patterns && !faces && !keywords.length) return toast(L("찾을 것을 하나 이상 고르세요"));
    player?.pause();
    q("#pv-scan").disabled = true;
    const v = await run("privacy_scan", { clip: c.id, patterns, faces, keywords, style: pref("style", "blur") });
    if (v?.state) {
      setState(v.state);
      toast(v.count ? L("{}곳을 가렸습니다 ({})", v.count, v.summary.split(", ").map((x) => x.replace(/^(.*) (\d+)$/, (_, k, n) => `${L(k)} ${n}`)).join(", ")) : L("가릴 개인정보를 찾지 못했습니다"));
    }
    if (q("#pv-scan")) q("#pv-scan").disabled = false;
  };
  q("#pv-draw").onclick = () => {
    if (S.time < c.start || S.time >= U.clipEnd(c)) seek(c.start + 0.001);
    player?.pause();
    S.drawBlur = !S.drawBlur;
    q("#pv-draw").classList.toggle("primary", S.drawBlur);
    q("#pv-draw").lastChild.textContent = " " + L(S.drawBlur ? "그리기 취소" : "직접 그리기");
    player?.refresh();
  };
  q("#pv-clear")?.addEventListener("click", () => { S.selBlur = null; setBlurs(c, []); });
  q("#pv-all")?.addEventListener("change", (e) => e.target.value && setBlurs(c, list.map((r) => ({ ...r, style: e.target.value }))));
  el.querySelectorAll("[data-blurdel]").forEach((b) => (b.onclick = (e) => {
    e.stopPropagation();
    if (S.selBlur === b.dataset.blurdel) S.selBlur = null;
    setBlurs(c, list.filter((r) => r.id !== b.dataset.blurdel));
  }));
  el.querySelectorAll("[data-blur]").forEach((row) => (row.onclick = (e) => {
    if (e.target.closest("button")) return;
    const r = list.find((x) => x.id === row.dataset.blur);
    S.selBlur = r.id;
    player?.pause();
    if (a.kind !== "image" && (!active(r, srcTime(c, S.time)) || S.time < c.start || S.time >= U.clipEnd(c))) {
      seek(Math.min(Math.max(tlTime(c, r.start), c.start), U.clipEnd(c) - 0.05) + 0.001);
    }
    window.dispatchEvent(new Event("selection"));
  }));
  el.querySelectorAll("[data-blurstyle]").forEach((b) => (b.onclick = () =>
    setBlurs(c, list.map((r) => (r.id === S.selBlur ? { ...r, style: b.dataset.blurstyle } : r)))));
  el.querySelectorAll("[data-blurtime]").forEach((b) => (b.onclick = () => {
    if (S.time < c.start || S.time > U.clipEnd(c)) return;
    const s = srcTime(c, S.time);
    setBlurs(c, list.map((r) => (r.id === S.selBlur ? { ...r, [b.dataset.blurtime]: s } : r)));
  }));
}

/// Delete 키: 고른 가리기 영역이 있으면 그것만 지운다
export function deleteSelectedBlur() {
  if (!S.selBlur || S.sel.size !== 1) return false;
  const x = U.findClip([...S.sel][0]);
  const list = x?.c.blurs || [];
  if (!list.some((r) => r.id === S.selBlur)) return false;
  const id = S.selBlur;
  S.selBlur = null;
  setBlurs(x.c, list.filter((r) => r.id !== id));
  return true;
}

/// Esc: 그리기·영역 고르기 취소
export function cancelBlurEdit() {
  if (!S.drawBlur && !S.selBlur) return false;
  S.drawBlur = false;
  S.selBlur = null;
  window.dispatchEvent(new Event("selection"));
  return true;
}

/// 클립 원본 화면 전체가 미리보기에서 차지하는 자리.
/// 원 모양 클립은 가운데 정사각형만 보이므로(_rect) 원본 전체로 넓혀 계산한다 (가리기 좌표는 원본 전체 기준)
function fullRect(c, a, rect) {
  if (c.shape !== "circle" || !a?.width || !a?.height) return rect;
  const k = rect.w / Math.min(a.width, a.height);
  const w = a.width * k, h = a.height * k;
  return { left: rect.left - (w - rect.w) / 2, top: rect.top - (h - rect.h) / 2, w, h };
}

/// 미리보기 위 가리기.
/// 효과(흐림·검은 상자)는 클립마다 그 클립 바로 위 층에 그려 위 트랙(얼굴 화면·텍스트)은 가리지 않는다.
/// 고치기(테두리·손잡이·그리기)는 맨 위 층에서 한다.
export class BlurLayer {
  constructor(box, player) {
    this.box = box;
    this.player = player;
    this.el = document.createElement("div");
    this.el.id = "blurfx";
    this.el.style.cssText = "position:absolute;inset:0;z-index:80;pointer-events:none";
    box.appendChild(this.el);
    this.fx = new Map(); // clip id → 효과 층
    this.sig = "";
    this.drag = null;
  }

  draw(act, t) {
    const editing = !this.player.playing && S.sel.size === 1 ? [...S.sel][0] : null;
    const clips = [];
    for (const { c, ti, tr, a } of act) {
      if (c.kind === "text" || !a || a.kind === "audio" || tr.hidden || !c.blurs?.length) continue;
      const el = this.player.els.get(c.id);
      const rect = el?._rect;
      if (!rect) continue;
      const s = srcTime(c, t);
      const regions = c.blurs.filter((r) => active(r, s));
      if (regions.length) clips.push({ c, ti, a, el, rect, full: fullRect(c, a, rect), regions, edit: c.id === editing });
    }
    let drawClip = null;
    if (S.drawBlur && editing) {
      const x = act.find((x) => x.c.id === editing && x.a && x.a.kind !== "audio");
      const rect = x && this.player.els.get(x.c.id)?._rect;
      if (rect) drawClip = { c: x.c, rect, full: fullRect(x.c, x.a, rect) };
    }
    const sig = JSON.stringify([clips.map((x) => [x.c.id, x.ti, x.regions, x.rect, x.edit, x.c.shape]), S.selBlur, drawClip?.c.id, this.player.cw, this.player.ch]);
    if (sig === this.sig || this.drag) return;
    this.sig = sig;

    // 효과 층: 클립 영상 바로 다음에 같은 z-index로 (모양대로 잘라서)
    const keep = new Set(clips.map((x) => x.c.id));
    for (const [id, node] of this.fx) if (!keep.has(id)) { node.remove(); this.fx.delete(id); }
    for (const { c, ti, el, rect, full, regions } of clips) {
      let node = this.fx.get(c.id);
      if (!node) {
        node = document.createElement("div");
        node.className = "blurclip";
        this.fx.set(c.id, node);
      }
      if (node.previousSibling !== el) el.after(node);
      node.style.cssText = `position:absolute;left:${rect.left}px;top:${rect.top}px;width:${rect.w}px;height:${rect.h}px;z-index:${1 + ti};pointer-events:none;overflow:hidden;` +
        `border-radius:${c.shape === "circle" ? "50%" : c.shape === "rounded" ? Math.min(rect.w, rect.h) * 0.08 + "px" : "0"}`;
      node.innerHTML = "";
      for (const r of regions) {
        const d = document.createElement("div");
        const w = r.w * full.w, h = r.h * full.h;
        d.style.cssText = `position:absolute;left:${full.left - rect.left + r.x * full.w}px;top:${full.top - rect.top + r.y * full.h}px;width:${w}px;height:${h}px`;
        // 미리보기는 근사: 흐리게·모자이크 모두 강하게 흐림 (내보내기는 맥과 같은 모자이크)
        const k = Math.max(6, Math.min(w, h) * (r.style === "mosaic" ? 0.5 : 0.35));
        if (r.style === "box") d.style.background = "#000";
        else d.style.backdropFilter = d.style.webkitBackdropFilter = `blur(${k}px)` + (r.style === "mosaic" ? " contrast(1.2)" : "");
        node.appendChild(d);
      }
    }

    // 고치기 층
    this.el.innerHTML = "";
    this.el.style.pointerEvents = drawClip ? "auto" : "none";
    this.el.style.cursor = drawClip ? "crosshair" : "";
    this.el.style.background = drawClip ? "rgba(0,0,0,.15)" : "";
    this.el.onpointerdown = drawClip ? (e) => this.startDraw(e, drawClip) : null;
    for (const x of clips) if (x.edit) for (const r of x.regions) this.el.appendChild(this.handleEl(x, r));
  }

  handleEl({ c, rect, full }, r) {
    const d = document.createElement("div");
    const px = { left: full.left + r.x * full.w, top: full.top + r.y * full.h, w: r.w * full.w, h: r.h * full.h };
    const sel = S.selBlur === r.id;
    d.style.cssText = `position:absolute;left:${px.left}px;top:${px.top}px;width:${px.w}px;height:${px.h}px;pointer-events:auto;cursor:move;` +
      `outline:${sel ? "2px solid var(--accent, #0a84ff)" : "1px dashed rgba(255,255,255,.85)"}`;
    d.title = r.text ? `${L(r.label)}: ${r.text}` : L(r.label);
    if (sel || px.w > 60) {
      const tag = document.createElement("span");
      tag.textContent = L(r.label);
      tag.style.cssText = `position:absolute;left:0;top:-16px;font-size:10px;font-weight:600;padding:0 4px;color:#fff;white-space:nowrap;background:${sel ? "var(--accent, #0a84ff)" : "rgba(0,0,0,.6)"}`;
      d.appendChild(tag);
    }
    d.onpointerdown = (e) => this.startMove(e, c, r, full, false, d);
    if (sel) {
      const h = document.createElement("div");
      h.style.cssText = "position:absolute;right:-5px;bottom:-5px;width:10px;height:10px;background:var(--accent, #0a84ff);cursor:nwse-resize";
      h.title = L("끌어서 크기 조절");
      h.onpointerdown = (e) => this.startMove(e, c, r, full, true, d);
      d.appendChild(h);
    }
    return d;
  }

  /// 끌기가 끝나거나 취소될 때 한 번 정리
  track(move, done) {
    const end = (ev) => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
      this.drag = null;
      this.sig = "";
      done(ev.type === "pointerup");
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
  }

  startMove(e, c, r, full, resize, target) {
    e.preventDefault();
    e.stopPropagation();
    // 고르는 순간 화면이 다시 그려지지 않게 먼저 끌기 상태로
    this.drag = true;
    if (S.selBlur !== r.id) {
      S.selBlur = r.id;
      window.dispatchEvent(new Event("selection"));
    }
    const x0 = e.clientX, y0 = e.clientY;
    const o = { ...r };
    let moved = false;
    this.track((ev) => {
      const dx = (ev.clientX - x0) / full.w, dy = (ev.clientY - y0) / full.h;
      if (Math.abs(ev.clientX - x0) + Math.abs(ev.clientY - y0) > 1) moved = true;
      if (resize) {
        r.w = Math.min(1 - r.x, Math.max(0.01, o.w + dx));
        r.h = Math.min(1 - r.y, Math.max(0.01, o.h + dy));
      } else {
        r.x = Math.min(1 - r.w, Math.max(0, o.x + dx));
        r.y = Math.min(1 - r.h, Math.max(0, o.y + dy));
      }
      Object.assign(target.style, { left: full.left + r.x * full.w + "px", top: full.top + r.y * full.h + "px", width: r.w * full.w + "px", height: r.h * full.h + "px" });
    }, (ok) => {
      // 다 옮긴 뒤 한 번만 기록 (되돌리기 한 번에 돌아온다). 취소되면 원래대로
      if (ok && moved) setBlurs(c, c.blurs.map((x) => (x.id === r.id ? { ...r } : x)));
      else { Object.assign(r, o); this.player.refresh(); }
    });
  }

  startDraw(e, { c, rect, full }) {
    e.preventDefault();
    const box = this.el.getBoundingClientRect();
    const p0 = { x: e.clientX - box.left, y: e.clientY - box.top };
    const ghost = document.createElement("div");
    ghost.style.cssText = "position:absolute;border:2px dashed var(--accent, #0a84ff);pointer-events:none";
    this.el.appendChild(ghost);
    this.drag = true;
    let p1 = p0;
    this.track((ev) => {
      p1 = { x: ev.clientX - box.left, y: ev.clientY - box.top };
      Object.assign(ghost.style, { left: Math.min(p0.x, p1.x) + "px", top: Math.min(p0.y, p1.y) + "px", width: Math.abs(p1.x - p0.x) + "px", height: Math.abs(p1.y - p0.y) + "px" });
    }, (ok) => {
      S.drawBlur = false;
      // 보이는 클립 화면 안으로 자른 뒤 원본 전체 비율로
      const x0 = Math.max(Math.min(p0.x, p1.x), rect.left), y0 = Math.max(Math.min(p0.y, p1.y), rect.top);
      const x1 = Math.min(Math.max(p0.x, p1.x), rect.left + rect.w), y1 = Math.min(Math.max(p0.y, p1.y), rect.top + rect.h);
      if (!ok || x1 - x0 < 4 || y1 - y0 < 4) { window.dispatchEvent(new Event("selection")); this.player.refresh(); return; }
      const a = U.asset(c.assetID);
      const image = a?.kind === "image";
      let s = srcTime(c, Math.min(Math.max(S.time, c.start), U.clipEnd(c)));
      if (s >= c.sourceOut - 0.05) s = c.sourceIn;
      const r = { id: uuid(), x: (x0 - full.left) / full.w, y: (y0 - full.top) / full.h, w: (x1 - x0) / full.w, h: (y1 - y0) / full.h,
        start: image ? 0 : s, end: image ? 1e6 : c.sourceOut, style: pref("style", "blur"), label: MANUAL };
      S.selBlur = r.id;
      setBlurs(c, [...(c.blurs || []), r]);
    });
  }
}
