// 미리보기: 지금 시간에 걸린 클립마다 <video>/<audio>/<img>를 두고 한 시계에 맞춰 재생한다
import { S, U, onTime } from "./app.js";
import { BlurLayer } from "./privacy.js";
import { transitionState, textMotionState, textProgress, revealTextParts, graphemes, visualFilterCSS, legacyFade, fontFamilyCSS } from "./effects.js";

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
    this.fx.style.cssText = "display:none;position:absolute;inset:0;pointer-events:none";
    box.appendChild(this.fx);
    // 개인정보 가리기 영역
    this.blur = new BlurLayer(box, this);
    box.querySelector("#video").remove();
    box.querySelector("#still").remove();
    this.els = new Map(); // clip id → element
    this.layers = new Map(); // 원본·가리기·클릭 표시가 함께 움직이는 트랙별 효과 층
    this.playing = false;
    this.rate = 1;
    this.last = 0;
    this.playGeneration = 0;
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
    this.box.style.background = this.color(p.background);
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
    if (!S.project || this.playing || U.duration() <= 0) return;
    if (S.time >= U.duration() - 0.05) S.time = 0;
    this.playing = true;
    const generation = ++this.playGeneration;
    this.last = performance.now();
    document.querySelector("#playBtn").textContent = "❚❚";
    this.update(true);
    const tick = (now) => {
      if (!this.playing || generation !== this.playGeneration) return;
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
    this.playGeneration++;
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
      if (el.tagName !== "IMG") { el.preload = "auto"; el.playsInline = true; }
      el.style.position = "absolute";
      this.layer(c.id).content.appendChild(el);
      this.els.set(c.id, el);
    }
    if (el._assetPath !== a.path) { el.src = src(a.path); el._assetPath = a.path; }
    return el;
  }

  layer(id) {
    let layer = this.layers.get(id);
    if (layer) return layer;
    const part = () => {
      const el = document.createElement("div");
      el.style.cssText = "position:absolute;inset:0;pointer-events:none";
      return el;
    };
    layer = { root: part(), exit: part(), entrance: part(), motion: part(), content: part() };
    layer.root.dataset.clip = id;
    layer.root.className = "preview-clip-layer";
    layer.root.appendChild(layer.exit);
    layer.exit.appendChild(layer.entrance);
    layer.entrance.appendChild(layer.motion);
    layer.motion.appendChild(layer.content);
    this.box.insertBefore(layer.root, this.overlay);
    this.layers.set(id, layer);
    return layer;
  }

  motionStyle(el, state, rect) {
    el.style.transformOrigin = `${rect.left + rect.w / 2}px ${rect.top + rect.h / 2}px`;
    el.style.transform = state.transform;
    el.style.opacity = String(state.opacity);
    el.style.clipPath = state.clipPath;
    el.style.filter = state.filter;
  }

  clipMotion(layer, c, rect, time, text = false) {
    const canvas = { w: this.cw, h: this.ch }, duration = U.clipDur(c);
    const entrance = transitionState(c.transitionIn, time - c.start, duration, true, rect, canvas);
    const exit = transitionState(c.transitionOut, U.clipEnd(c) - time, duration, false, rect, canvas);
    this.motionStyle(layer.entrance, entrance, rect);
    this.motionStyle(layer.exit, exit, rect);
    this.motionStyle(layer.motion, text ? textMotionState(c.textStyle, time - c.start, duration, rect, canvas)
      : { transform: "", opacity: 1, clipPath: "", filter: "" }, rect);
    layer.root.style.opacity = String(Math.max(0, (c.opacity ?? 1) * legacyFade(c, time)));
    layer.content.style.filter = text ? "" : visualFilterCSS(c.visualFilter, c.filterIntensity ?? 1);
    return Math.max(entrance.pixelSize, exit.pixelSize);
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
    for (const [id, layer] of this.layers) if (!keep.has(id)) { layer.root.remove(); this.layers.delete(id); }
    for (const { c, ti, a } of soon) {
      if (act.some((x) => x.c.id === c.id)) continue;
      const el = this.element(c, a);
      const layer = this.layer(c.id);
      el.muted = true;
      if (!el.paused) el.pause();
      layer.root.style.zIndex = String(1 + ti);
      layer.root.style.opacity = "0";
      if (Math.abs(el.currentTime - c.sourceIn) > 0.05) {
        try { el.currentTime = c.sourceIn; } catch (_) {}
      }
    }
    for (const { c, ti, tr, a } of act) {
      const layer = this.layer(c.id);
      layer.root.style.zIndex = String(1 + ti);
      if (c.kind === "text") {
        const oldMedia = this.els.get(c.id);
        if (oldMedia) { oldMedia.pause?.(); oldMedia.remove(); this.els.delete(c.id); }
        layer.root.style.display = tr.hidden ? "none" : "";
        if (!tr.hidden) {
          const unit = Math.min(this.cw, this.ch) / 1080;
          const d = this.clipText(layer, c.text, c.textStyle, unit * c.scale, c.textStyle.positionY + c.offsetY, c.offsetX, t - c.start, U.clipDur(c));
          const pixelSize = this.clipMotion(layer, c, d._rect, t, true);
          this.pixelateText(layer, d, c.textStyle, pixelSize);
        }
        continue;
      }
      if (!a) continue;
      if (layer.text) { layer.text.remove(); layer.text = null; layer.textSignature = null; }
      const el = this.element(c, a);
      const visual = a.kind !== "audio" && !tr.hidden;
      layer.root.style.display = visual || a.kind === "audio" ? "" : "none";
      el.style.display = a.kind === "audio" ? "none" : "";
      el.style.zIndex = "0";
      el.style.opacity = "";
      if (visual && a.width && a.height) {
        this.place(el, c, a);
        const pixelSize = this.clipMotion(layer, c, el._rect, t);
        this.pixelateMedia(layer, el, c, a, pixelSize, t);
      }
      if (el.tagName !== "IMG") {
        const want = c.sourceIn + (t - c.start) * c.speed;
        const vol = c.volume * (S.volume ?? 1) * legacyFade(c, t, true);
        el.muted = tr.muted || vol <= 0.001;
        el.volume = Math.max(0, Math.min(1, vol));
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
    this.blur.draw(act, t);
    // 자막은 모든 트랙 위, 텍스트 클립은 원래 트랙 순서에 놓는다.
    this.overlay.innerHTML = "";
    const unit = Math.min(this.cw, this.ch) / 1080;
    this.overlay.style.zIndex = String(Math.max(100, p.tracks.length + 20));
    if (p.showCaptions) {
      const cap = p.captions.find((c) => t >= c.start && t < c.end);
      if (cap) {
        const wrapper = document.createElement("div");
        wrapper.style.cssText = "position:absolute;inset:0;pointer-events:none";
        const d = this.textEl(cap.text, p.captionStyle, unit, p.captionStyle.positionY, 0);
        wrapper.appendChild(d);
        this.overlay.appendChild(wrapper);
        this.reveal(d, cap.text, p.captionStyle, t - cap.start, cap.end - cap.start);
        const rect = this.textRect(d, p.captionStyle.positionY, 0, true);
        this.motionStyle(wrapper, textMotionState(p.captionStyle, t - cap.start, cap.end - cap.start, rect, { w: this.cw, h: this.ch }), rect);
      }
    }
  }

  drawClicks(act, t) {
    const dpr = window.devicePixelRatio || 1;
    for (const { c, tr, a } of act) {
      const layer = this.layers.get(c.id);
      if (!layer) continue;
      if (!c.showClicks || !a?.clicks?.length || tr.hidden) { if (layer.clicks) layer.clicks.style.display = "none"; continue; }
      const el = this.els.get(c.id);
      const r = el?._rect;
      if (!r) continue;
      const fx = layer.clicks ??= document.createElement("canvas");
      if (!fx.parentNode) {
        fx.style.cssText = "position:absolute;inset:0;width:100%;height:100%;pointer-events:none;z-index:50";
        layer.content.appendChild(fx);
      }
      fx.style.display = "";
      if (fx.width !== Math.round(this.cw * dpr) || fx.height !== Math.round(this.ch * dpr)) {
        fx.width = Math.round(this.cw * dpr);
        fx.height = Math.round(this.ch * dpr);
      }
      const g = fx.getContext("2d");
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, this.cw, this.ch);
      g.save();
      g.beginPath();
      if (c.shape === "circle") g.arc(r.left + r.w / 2, r.top + r.h / 2, Math.min(r.w, r.h) / 2, 0, Math.PI * 2);
      else g.roundRect(r.left, r.top, r.w, r.h, c.shape === "rounded" ? Math.min(r.w, r.h) * 0.08 : 0);
      g.clip();
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
      g.restore();
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
  }

  color(c) {
    return c ? `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a})` : "#000";
  }

  textEl(text, st, unit, posY, offX) {
    const d = document.createElement("div");
    d.className = "cap";
    d.style.cssText = "position:absolute;transform:translate(-50%,-50%);text-align:center;white-space:pre-wrap;padding:.2em .45em;border-radius:.25em;max-width:90%;line-height:1.25";
    d._visible = document.createElement("span");
    d._hidden = document.createElement("span");
    d._hidden.style.visibility = "hidden";
    d.append(d._visible, d._hidden);
    d._visible.textContent = String(text ?? "").trim();
    d.style.fontSize = st.fontSize * unit + "px";
    d.style.fontWeight = st.bold ? "700" : "400";
    d.style.fontFamily = fontFamilyCSS(st.fontName);
    d.style.color = this.color(st.textColor);
    d.style.background = this.color(st.backgroundColor);
    if (st.outline) d.style.webkitTextStroke = `${Math.max(1, st.fontSize * unit * 0.05)}px ${this.color(st.outlineColor)}`;
    d.style.top = posY * 100 + "%";
    d.style.left = 50 + offX * 100 + "%";
    return d;
  }

  reveal(d, text, style, elapsed, duration) {
    const parts = style.animation === "typewriter" ? revealTextParts(text, textProgress(style, elapsed, duration))
      : { visible: String(text ?? "").trim(), hidden: "" };
    if (d._visible.textContent !== parts.visible) d._visible.textContent = parts.visible;
    if (d._hidden.textContent !== parts.hidden) d._hidden.textContent = parts.hidden;
  }

  textRect(d, posY, offX, caption = false) {
    const w = d.offsetWidth, h = d.offsetHeight;
    const left = (this.cw - w) / 2 + offX * this.cw;
    let top = posY * this.ch - h / 2;
    if (caption) { top = Math.max(4, Math.min(top, this.ch - h - 4)); d.style.top = top + h / 2 + "px"; }
    return d._rect = { left, top, w, h };
  }

  clipText(layer, text, style, unit, posY, offX, elapsed, duration) {
    const signature = JSON.stringify([text, style, unit, posY, offX]);
    if (layer.textSignature !== signature) {
      layer.text?.remove();
      layer.text = this.textEl(text, style, unit, posY, offX);
      layer.content.appendChild(layer.text);
      layer.textSignature = signature;
    }
    this.reveal(layer.text, text, style, elapsed, duration);
    this.textRect(layer.text, posY, offX);
    return layer.text;
  }

  rasterCanvas(layer, rect) {
    const canvas = layer.raster ??= document.createElement("canvas");
    if (!canvas.parentNode) layer.content.appendChild(canvas);
    canvas.style.cssText = `position:absolute;left:${rect.left}px;top:${rect.top}px;width:${rect.w}px;height:${rect.h}px;pointer-events:none;z-index:0`;
    const w = Math.max(1, Math.ceil(rect.w)), h = Math.max(1, Math.ceil(rect.h));
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    return canvas;
  }

  pixelateMedia(layer, el, c, a, cell, time = S.time) {
    el.style.visibility = "";
    const sourceTime = c.sourceIn + (time - c.start) * c.speed;
    const protectedSource = c.blurs?.some((region) => !Number.isFinite(sourceTime)
      || sourceTime >= region.start - 1e-4 && sourceTime < region.end);
    // 원본을 먼저 작게 샘플링하면 가린 픽셀이 큰 셀로 번져 가리기 영역 밖에 나타날 수 있다.
    // 보호 구간에서는 기존 가리기 층을 그대로 사용하고 원본의 픽셀화 샘플링을 생략한다.
    if (cell <= 1.01 || protectedSource) { if (layer.raster) layer.raster.style.display = "none"; return; }
    const rect = el._rect, canvas = this.rasterCanvas(layer, rect);
    const tiny = layer.tiny ??= document.createElement("canvas");
    tiny.width = Math.max(1, Math.ceil(rect.w / cell));
    tiny.height = Math.max(1, Math.ceil(rect.h / cell));
    try {
      const g = tiny.getContext("2d");
      g.clearRect(0, 0, tiny.width, tiny.height);
      if (c.shape === "circle") {
        const side = Math.min(a.width, a.height);
        g.drawImage(el, (a.width - side) / 2, (a.height - side) / 2, side, side, 0, 0, tiny.width, tiny.height);
      } else g.drawImage(el, 0, 0, tiny.width, tiny.height);
      const output = canvas.getContext("2d");
      output.clearRect(0, 0, canvas.width, canvas.height);
      output.imageSmoothingEnabled = false;
      output.drawImage(tiny, 0, 0, canvas.width, canvas.height);
      canvas.style.borderRadius = el.style.borderRadius;
      canvas.style.border = el.style.border;
      canvas.style.boxSizing = "border-box";
      el.style.visibility = "hidden";
    } catch (_) {
      // 아직 디코딩 중이면 기본 영상·가리기 층을 그대로 유지하고 다음 프레임에 다시 시도한다.
      canvas.style.display = "none";
    }
  }

  pixelateText(layer, d, style, cell) {
    d.style.visibility = "";
    if (cell <= 1.01) { if (layer.raster) layer.raster.style.display = "none"; return; }
    const rect = d._rect;
    const canvas = this.rasterCanvas(layer, rect);
    const full = layer.textRaster ??= document.createElement("canvas");
    full.width = canvas.width; full.height = canvas.height;
    const g = full.getContext("2d"), fontSize = parseFloat(d.style.fontSize), padX = fontSize * 0.45, padY = fontSize * 0.2;
    g.fillStyle = this.color(style.backgroundColor);
    g.beginPath(); g.roundRect(0, 0, full.width, full.height, fontSize * 0.25); g.fill();
    g.font = `${style.bold ? "700" : "400"} ${fontSize}px ${fontFamilyCSS(style.fontName)}`;
    g.textBaseline = "alphabetic";
    const allText = d._visible.textContent + d._hidden.textContent;
    const lines = [];
    const paragraphs = allText.split("\n");
    paragraphs.forEach((paragraph, paragraphIndex) => {
      let line = "";
      for (const char of graphemes(paragraph)) {
        if (line && g.measureText(line + char).width > Math.max(1, rect.w - padX * 2)) { lines.push({ text: line, newline: false }); line = ""; }
        line += char;
      }
      lines.push({ text: line, newline: paragraphIndex < paragraphs.length - 1 });
    });
    let remaining = graphemes(d._visible.textContent).length;
    lines.forEach((line, index) => {
      const parts = graphemes(line.text), visible = parts.slice(0, Math.max(0, remaining)).join("");
      remaining -= parts.length + (line.newline ? 1 : 0);
      const x = (rect.w - g.measureText(line.text).width) / 2, y = padY + fontSize + index * fontSize * 1.25;
      if (style.outline) { g.strokeStyle = this.color(style.outlineColor); g.lineWidth = Math.max(1, fontSize * 0.1); g.strokeText(visible, x, y); }
      g.fillStyle = this.color(style.textColor); g.fillText(visible, x, y);
    });
    const tiny = layer.tiny ??= document.createElement("canvas");
    tiny.width = Math.max(1, Math.ceil(rect.w / cell)); tiny.height = Math.max(1, Math.ceil(rect.h / cell));
    tiny.getContext("2d").drawImage(full, 0, 0, tiny.width, tiny.height);
    const output = canvas.getContext("2d");
    output.clearRect(0, 0, canvas.width, canvas.height); output.imageSmoothingEnabled = false;
    output.drawImage(tiny, 0, 0, canvas.width, canvas.height);
    d.style.visibility = "hidden";
  }
}
