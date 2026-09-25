// 미리보기: 지금 시간에 걸린 클립마다 <video>/<audio>/<img>를 두고 한 시계에 맞춰 재생한다
import { S, U, onTime } from "./app.js";

const src = (path) => window.__TAURI__.core.convertFileSrc(path);
// 맥 앱과 같은 속도 단계. 16배를 넘으면 영상 요소는 16배로 돌리고 시계만 더 빨리 가며 따라잡는다
export const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 10, 12, 16, 20];
const SHUTTLE = [1, 2, 4, 8, 16, 20];

export class Player {
  constructor(box, stage) {
    this.box = box;
    this.stage = stage;
    this.overlay = box.querySelector("#overlay");
    // 마우스 클릭 강조 (노란 원이 퍼졌다 사라짐, 0.7초)
    this.fx = document.createElement("canvas");
    this.fx.id = "clickfx";
    this.fx.style.cssText = "position:absolute;inset:0;pointer-events:none;z-index:90";
    box.appendChild(this.fx);
    box.querySelector("#video").remove();
    box.querySelector("#still").remove();
    this.els = new Map(); // clip id → element
    this.playing = false;
    this.rate = 1;
    this.last = 0;
    new ResizeObserver(() => this.layout()).observe(stage);
  }

  // 캔버스 비율에 맞춰 미리보기 크기
  layout() {
    const p = S.project;
    if (!p) return;
    const sw = this.stage.clientWidth - 16, sh = this.stage.clientHeight - 16;
    const k = Math.min(sw / p.canvasWidth, sh / p.canvasHeight);
    this.cw = Math.max(10, p.canvasWidth * k);
    this.ch = Math.max(10, p.canvasHeight * k);
    this.box.style.width = this.cw + "px";
    this.box.style.height = this.ch + "px";
    this.update(false);
  }

  refresh() {
    this.layout();
  }

  active(t) {
    const out = [];
    S.project?.tracks.forEach((tr, ti) => {
      for (const c of tr.clips) {
        if (t >= c.start - 1e-4 && t < U.clipEnd(c)) out.push({ c, ti, tr, a: U.asset(c.assetID) });
      }
    });
    return out;
  }

  /// 트랙마다 곧 시작할 다음 클립 (재생 중 미리 불러 둔다)
  upcoming(t) {
    const out = [];
    const ahead = 1.5 * Math.max(1, this.rate);
    S.project?.tracks.forEach((tr, ti) => {
      let next = null;
      for (const c of tr.clips) {
        if (c.start > t && c.start - t < ahead && (!next || c.start < next.start)) next = c;
      }
      if (next) out.push({ c: next, ti, tr, a: U.asset(next.assetID) });
    });
    return out;
  }

  seek(t) {
    this.update(true, t);
  }

  toggle() {
    this.playing ? this.pause() : this.play();
  }

  play() {
    if (!S.project) return;
    if (S.time >= U.duration() - 0.05) S.time = 0;
    this.playing = true;
    this.last = performance.now();
    document.querySelector("#playBtn").textContent = "❚❚";
    this.update(true);
    const tick = (now) => {
      if (!this.playing) return;
      const dt = (now - this.last) / 1000;
      this.last = now;
      let t = S.time + dt * this.rate;
      if (t >= U.duration()) { t = U.duration(); this.pause(); }
      onTime(t);
      this.update(false);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  pause() {
    this.playing = false;
    document.querySelector("#playBtn").textContent = "▶";
    for (const el of this.els.values()) if (el.pause) el.pause();
  }

  setRate(r) {
    this.rate = Math.min(20, Math.max(0.25, r));
    const sel = document.querySelector("#rate");
    if (![...sel.options].some((o) => +o.value === this.rate)) sel.add(new Option(`${this.rate}x`, String(this.rate)));
    sel.value = String(this.rate);
    const sl = document.querySelector("#rate-slider");
    if (sl && document.activeElement !== sl) sl.value = Math.log(this.rate);
    // 1배속이 아니면 미리보기에 표시
    const badge = document.querySelector("#speed-badge");
    if (badge) { badge.textContent = this.rate === 1 ? "" : L("{} 재생", this.rate + "x"); badge.style.display = this.rate === 1 ? "none" : ""; }
    this.update(true);
  }

  /// L: 멈춰 있으면 1배속 재생, 재생 중이면 2·4·8·16·20배
  faster() {
    if (!this.playing) { this.setRate(1); this.play(); return; }
    this.setRate(SHUTTLE.find((r) => r > this.rate + 0.01) ?? 20);
  }

  /// J: 한 단계 느리게 (멈춰 있으면 재생)
  slower() {
    this.setRate([...SHUTTLE].reverse().find((r) => r < this.rate - 0.01) ?? 0.5);
    if (!this.playing) this.play();
  }

  /// ] / [ : 속도 한 단계
  stepRate(up) {
    this.setRate(up ? SPEEDS.find((r) => r > this.rate + 0.01) ?? 20 : [...SPEEDS].reverse().find((r) => r < this.rate - 0.01) ?? 0.25);
  }

  element(c, a) {
    let el = this.els.get(c.id);
    if (!el) {
      el = document.createElement(a.kind === "image" ? "img" : a.kind === "audio" ? "audio" : "video");
      el.src = src(a.path);
      if (el.tagName !== "IMG") { el.preload = "auto"; el.playsInline = true; }
      el.style.position = "absolute";
      this.box.insertBefore(el, this.overlay);
      this.els.set(c.id, el);
    }
    return el;
  }

  /// 걸린 클립 요소를 만들고 위치·시간을 맞춘다. hard=true면 무조건 시간 맞춤
  update(hard, t = S.time) {
    const p = S.project;
    if (!p) return;
    const act = this.active(t);
    // 무음 컷처럼 클립이 촘촘히 이어지면 경계마다 새 <video>가 처음부터 불러와 검은 화면이 깜박인다.
    // 재생 중엔 다음 클립 요소를 미리 만들어 첫 프레임까지 준비해 둔다
    const soon = this.playing ? this.upcoming(t).filter((x) => x.c.kind !== "text" && x.a && x.a.kind !== "image") : [];
    const keep = new Set([...act, ...soon].map((x) => x.c.id));
    for (const [id, el] of this.els) {
      if (!keep.has(id)) {
        el.pause?.();
        el.remove();
        if (el.tagName !== "IMG") { el.removeAttribute("src"); el.load(); }
        this.els.delete(id);
      }
    }
    for (const { c, ti, a } of soon) {
      if (act.some((x) => x.c.id === c.id)) continue;
      const el = this.element(c, a);
      el.muted = true;
      if (!el.paused) el.pause();
      el.style.zIndex = String(1 + ti);
      el.style.opacity = "0";
      if (Math.abs(el.currentTime - c.sourceIn) > 0.05) {
        try { el.currentTime = c.sourceIn; } catch (_) {}
      }
    }
    for (const { c, ti, tr, a } of act) {
      if (c.kind === "text") continue;
      if (!a) continue;
      const el = this.element(c, a);
      const visual = a.kind !== "audio" && !tr.hidden;
      el.style.display = visual || a.kind === "audio" ? "" : "none";
      el.style.zIndex = String(1 + ti);
      el.style.opacity = "";
      if (visual && a.width && a.height) this.place(el, c, a);
      if (el.tagName !== "IMG") {
        const want = c.sourceIn + (t - c.start) * c.speed;
        const vol = c.volume * (S.volume ?? 1);
        el.muted = tr.muted || vol <= 0.001;
        el.volume = Math.min(1, vol);
        const rate = Math.min(16, Math.max(0.0625, this.rate * c.speed));
        if (Math.abs(el.playbackRate - rate) > 0.001) el.playbackRate = rate;
        if (hard || Math.abs(el.currentTime - want) > 0.35 * Math.max(1, rate)) {
          try { el.currentTime = Math.max(0, want); } catch (_) {}
        }
        if (this.playing && el.paused) el.play().catch(() => {});
        if (!this.playing && !el.paused) el.pause();
      }
    }
    this.drawClicks(act, t);
    // 텍스트 클립 + 자막
    this.overlay.innerHTML = "";
    const unit = this.ch / 1080;
    for (const { c, tr } of act) {
      if (c.kind !== "text" || tr.hidden) continue;
      this.overlay.appendChild(this.textEl(c.text, c.textStyle, unit * c.scale, c.textStyle.positionY + c.offsetY, c.offsetX));
    }
    if (p.showCaptions) {
      const cap = p.captions.find((c) => t >= c.start && t < c.end);
      if (cap) this.overlay.appendChild(this.textEl(cap.text, p.captionStyle, unit, p.captionStyle.positionY, 0));
    }
  }

  drawClicks(act, t) {
    const fx = this.fx;
    const dpr = window.devicePixelRatio || 1;
    if (fx.width !== Math.round(this.cw * dpr) || fx.height !== Math.round(this.ch * dpr)) {
      fx.width = Math.round(this.cw * dpr);
      fx.height = Math.round(this.ch * dpr);
    }
    const g = fx.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, this.cw, this.ch);
    for (const { c, tr, a } of act) {
      if (!c.showClicks || !a?.clicks?.length || tr.hidden) continue;
      const el = this.els.get(c.id);
      const r = el?._rect;
      if (!r) continue;
      const s = c.sourceIn + (t - c.start) * c.speed;
      for (const m of a.clicks) {
        if (s < m.t || s - m.t > 0.7) continue;
        const p = (s - m.t) / 0.7;
        const rad = (0.02 + 0.03 * p) * Math.min(r.w, r.h);
        const cx = r.left + m.x * r.w, cy = r.top + m.y * r.h;
        const grad = g.createRadialGradient(cx, cy, rad * 0.55, cx, cy, rad);
        grad.addColorStop(0, `rgba(255,214,26,${0.65 * (1 - p)})`);
        grad.addColorStop(1, "rgba(255,214,26,0)");
        g.fillStyle = grad;
        g.beginPath();
        g.arc(cx, cy, rad, 0, Math.PI * 2);
        g.fill();
        // 안쪽도 같은 색으로 채운다 (맥은 가운데가 차 있는 원판)
        g.fillStyle = `rgba(255,214,26,${0.65 * (1 - p)})`;
        g.beginPath();
        g.arc(cx, cy, rad * 0.55, 0, Math.PI * 2);
        g.fill();
      }
    }
  }

  place(el, c, a) {
    const shape = c.shape;
    let aw = a.width, ah = a.height;
    if (shape === "circle") aw = ah = Math.min(a.width, a.height);
    const fit = Math.min(this.cw / aw, this.ch / ah) * c.scale;
    const w = aw * fit, h = ah * fit;
    el.style.width = w + "px";
    el.style.height = h + "px";
    el.style.left = (this.cw - w) / 2 + c.offsetX * this.cw + "px";
    el.style.top = (this.ch - h) / 2 + c.offsetY * this.ch + "px";
    el._rect = { left: (this.cw - w) / 2 + c.offsetX * this.cw, top: (this.ch - h) / 2 + c.offsetY * this.ch, w, h };
    el.style.objectFit = shape === "circle" ? "cover" : "fill";
    // 맥·내보내기와 같게: 원은 흰 테두리(지름의 1.8%), 둥근 사각형은 짧은 변의 8%
    el.style.borderRadius = shape === "circle" ? "50%" : shape === "rounded" ? `${Math.min(w, h) * 0.08}px` : "0";
    el.style.border = shape === "circle" ? `${Math.max(1.5, w * 0.018)}px solid rgba(255,255,255,.95)` : "none";
    el.style.boxSizing = "border-box";
    const fi = c.fadeIn > 0 ? Math.min(1, (S.time - c.start) / c.fadeIn) : 1;
    const fo = c.fadeOut > 0 ? Math.min(1, (U.clipEnd(c) - S.time) / c.fadeOut) : 1;
    el.style.opacity = String(Math.max(0, c.opacity * fi * fo));
  }

  textEl(text, st, unit, posY, offX) {
    const d = document.createElement("div");
    d.className = "cap";
    d.textContent = text;
    const col = (c) => `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a})`;
    d.style.fontSize = st.fontSize * unit + "px";
    d.style.fontWeight = st.bold ? "700" : "400";
    // 맥에서 만든 프로젝트의 맥 전용 글꼴은 기본 글꼴로 (내보내기와 같게)
    const f = (st.fontName || "").trim();
    d.style.fontFamily = !f || f.startsWith("AppleSDGothic") || f.startsWith("Apple SD") || f.startsWith(".") || f.includes("-") ? '"Malgun Gothic", sans-serif' : `"${f}", "Malgun Gothic", sans-serif`;
    d.style.color = col(st.textColor);
    d.style.background = col(st.backgroundColor);
    if (st.outline) d.style.webkitTextStroke = `${Math.max(1, st.fontSize * unit * 0.05)}px ${col(st.outlineColor)}`;
    d.style.top = posY * 100 + "%";
    d.style.left = 50 + offX * 100 + "%";
    return d;
  }
}
