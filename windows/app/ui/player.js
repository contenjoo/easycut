// 미리보기: 지금 시간에 걸린 클립마다 <video>/<audio>/<img>를 두고 한 시계에 맞춰 재생한다
import { S, U, onTime } from "./app.js";

const src = (path) => window.__TAURI__.core.convertFileSrc(path);
const RATES = [0.5, 1, 1.5, 2, 4, 8, 16];

export class Player {
  constructor(box, stage) {
    this.box = box;
    this.stage = stage;
    this.overlay = box.querySelector("#overlay");
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
    this.rate = r;
    document.querySelector("#rate").value = String(r);
    this.update(true);
  }

  faster() {
    if (!this.playing) { this.setRate(1); this.play(); return; }
    this.setRate(RATES.find((r) => r > this.rate) ?? 16);
  }

  slower() {
    this.setRate([...RATES].reverse().find((r) => r < this.rate) ?? 0.5);
  }

  /// 걸린 클립 요소를 만들고 위치·시간을 맞춘다. hard=true면 무조건 시간 맞춤
  update(hard, t = S.time) {
    const p = S.project;
    if (!p) return;
    const act = this.active(t);
    const keep = new Set(act.map((x) => x.c.id));
    for (const [id, el] of this.els) {
      if (!keep.has(id)) { el.pause?.(); el.remove(); this.els.delete(id); }
    }
    let cap = "";
    for (const { c, ti, tr, a } of act) {
      if (c.kind === "text") continue;
      if (!a) continue;
      let el = this.els.get(c.id);
      const visual = a.kind !== "audio" && !tr.hidden;
      if (!el) {
        el = document.createElement(a.kind === "image" ? "img" : a.kind === "audio" ? "audio" : "video");
        el.src = src(a.path);
        if (el.tagName !== "IMG") { el.preload = "auto"; el.playsInline = true; }
        el.style.position = "absolute";
        this.box.insertBefore(el, this.overlay);
        this.els.set(c.id, el);
      }
      el.style.display = visual || a.kind === "audio" ? "" : "none";
      el.style.zIndex = String(1 + ti);
      if (visual && a.width && a.height) this.place(el, c, a);
      if (el.tagName !== "IMG") {
        const want = c.sourceIn + (t - c.start) * c.speed;
        el.muted = tr.muted || c.volume <= 0.001;
        el.volume = Math.min(1, c.volume);
        const rate = Math.min(16, Math.max(0.0625, this.rate * c.speed));
        if (Math.abs(el.playbackRate - rate) > 0.001) el.playbackRate = rate;
        if (hard || Math.abs(el.currentTime - want) > 0.35 * Math.max(1, rate)) {
          try { el.currentTime = Math.max(0, want); } catch (_) {}
        }
        if (this.playing && el.paused) el.play().catch(() => {});
        if (!this.playing && !el.paused) el.pause();
      }
    }
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
    el.style.objectFit = shape === "circle" ? "cover" : "fill";
    el.style.borderRadius = shape === "circle" ? "50%" : shape === "rounded" ? "8%" : "0";
    el.style.border = shape === "circle" ? "2px solid rgba(255,255,255,.95)" : "none";
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
    d.style.color = col(st.textColor);
    d.style.background = col(st.backgroundColor);
    if (st.outline) d.style.webkitTextStroke = `${Math.max(1, st.fontSize * unit * 0.05)}px ${col(st.outlineColor)}`;
    d.style.top = posY * 100 + "%";
    d.style.left = 50 + offX * 100 + "%";
    return d;
  }
}
