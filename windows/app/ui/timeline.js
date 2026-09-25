// 타임라인 (캔버스): 눈금자 · 자막 줄 · 트랙 · 클립 · 재생헤드
import { S, U, seek, run, toast, clipMenu, captionMenu, emptyMenu, switchTab } from "./app.js";

const HEADER = 110, RULER = 24, CAPH = 26, EDGE = 7;
/// 트랙 높이 (맥처럼 조절 가능)
const th = () => S.trackH || 54;
const COLORS = { video: "#4a6fb5", audio: "#3f8f6a", image: "#9a6b3c", text: "#7b4fb3" };

export class Timeline {
  constructor(canvas, scroller) {
    this.cv = canvas;
    this.sc = scroller;
    this.ctx = canvas.getContext("2d");
    this.drag = null;
    this.pending = false;
    // 스크롤 폭은 이 빈 칸이 정한다. 캔버스 CSS 폭을 실제 픽셀 폭과 같게 두어야 글자가 가로로 늘어나지 않는다
    this.spacer = document.createElement("div");
    this.spacer.style.cssText = "position:absolute;left:0;top:0;height:1px;pointer-events:none";
    scroller.appendChild(this.spacer);
    canvas.addEventListener("mousedown", (e) => this.down(e));
    window.addEventListener("mousemove", (e) => this.move(e));
    window.addEventListener("mouseup", (e) => this.up(e));
    canvas.addEventListener("dblclick", (e) => this.dbl(e));
    canvas.addEventListener("contextmenu", (e) => this.context(e));
    scroller.addEventListener("scroll", () => this.drawSoon());
    scroller.addEventListener("wheel", (e) => {
      if (!(e.ctrlKey || e.metaKey)) return;
      e.preventDefault();
      this.setZoom(S.zoom * (1 - e.deltaY * 0.002), e);
    }, { passive: false });
    new ResizeObserver(() => this.refresh()).observe(scroller);
  }

  // 좌표
  x(t) { return HEADER + t * S.zoom; }
  t(x) { return Math.max(0, (x - HEADER) / S.zoom); }
  rowY(ti) { return RULER + CAPH + (S.project.tracks.length - 1 - ti) * th(); }
  trackAt(y) {
    const rel = y - RULER - CAPH;
    if (rel < 0) return null;
    const row = Math.floor(rel / th());
    const ti = S.project.tracks.length - 1 - row;
    return ti >= 0 && ti < S.project.tracks.length ? ti : null;
  }

  setZoom(z, e) {
    const old = S.zoom;
    S.zoom = Math.min(800, Math.max(0.2, z));
    document.querySelector("#zoom").value = Math.log10(S.zoom);
    // 재생헤드(또는 마우스) 위치를 유지
    const anchorT = e ? this.t(e.offsetX) : S.time;
    const screenX = (e ? e.offsetX : this.x(S.time)) - this.sc.scrollLeft;
    this.refresh();
    this.sc.scrollLeft = Math.max(0, HEADER + anchorT * S.zoom - screenX);
    if (old !== S.zoom) this.drawSoon();
  }

  fit() {
    const w = this.sc.clientWidth - HEADER - 30;
    this.setZoom(w / Math.max(5, U.duration()));
    this.sc.scrollLeft = 0;
  }

  refresh() {
    if (!S.project) return;
    const w = Math.max(this.sc.clientWidth, this.x(U.duration() + 30) + 200);
    const h = Math.max(this.sc.clientHeight, RULER + CAPH + S.project.tracks.length * th() + th());
    const dpr = window.devicePixelRatio || 1;
    // 너무 큰 캔버스는 보이는 폭만큼만 만들어 스크롤 위치로 옮겨 그린다
    // (옮긴 캔버스가 내용 끝을 넘으면 스크롤 폭이 계속 늘어나므로 화면 폭을 넘지 않게)
    const vw = w > 16000 ? this.sc.clientWidth : w;
    if (this.cv.width !== Math.round(vw * dpr) || this.cv.height !== Math.round(h * dpr)) {
      this.cv.width = Math.round(vw * dpr);
      this.cv.height = Math.round(h * dpr);
    }
    this.cv.style.width = vw + "px";
    this.cv.style.height = h + "px";
    this.spacer.style.width = w + "px";
    this.fullW = w;
    this.drawSoon();
  }

  drawSoon() {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => { this.pending = false; this.draw(); });
  }

  playheadMoved() {
    // 재생 중엔 재생헤드를 따라 스크롤 (끌 수 있음)
    if (S.follow === false) return this.drawSoon();
    const px = this.x(S.time);
    const vis0 = this.sc.scrollLeft, vis1 = vis0 + this.sc.clientWidth;
    if (px > vis1 - 40 || px < vis0 + HEADER) this.sc.scrollLeft = Math.max(0, px - HEADER - 40);
    this.drawSoon();
  }

  draw() {
    const p = S.project;
    if (!p) return;
    const ctx = this.ctx, dpr = window.devicePixelRatio || 1;
    const sl = this.sc.scrollLeft, st = this.sc.scrollTop;
    const W = this.sc.clientWidth, H = this.cv.height / dpr;
    // 캔버스가 너무 넓으면 스크롤 위치만큼 옮겨서 그림
    const shift = this.fullW > 16000 ? sl : 0;
    this.cv.style.transform = shift ? `translateX(${shift}px)` : "";
    ctx.setTransform(dpr, 0, 0, dpr, -shift * dpr, 0);
    const x0 = sl, x1 = sl + W;
    ctx.fillStyle = "#1e1f23";
    ctx.fillRect(x0, 0, W, H);

    // 트랙 줄
    p.tracks.forEach((tr, ti) => {
      const y = this.rowY(ti);
      ctx.fillStyle = ti % 2 ? "#212226" : "#1c1d21";
      ctx.fillRect(x0, y, W, th());
      ctx.fillStyle = "#2c2e33";
      ctx.fillRect(x0, y + th() - 1, W, 1);
    });
    ctx.fillStyle = "#26222e";
    ctx.fillRect(x0, RULER, W, CAPH);

    // 구간
    const r = U.markRange();
    if (r || S.markIn != null) {
      const a = r ? r[0] : S.markIn, b = r ? r[1] : S.markIn;
      ctx.fillStyle = "rgba(80,140,255,0.18)";
      ctx.fillRect(this.x(a), RULER, Math.max(2, (b - a) * S.zoom), H);
    }

    // 자막
    ctx.font = "11px -apple-system, 'Segoe UI', 'Malgun Gothic', sans-serif";
    for (const c0 of p.captions) {
      const c = this.displayedCaption(c0);
      const cx = this.x(c.start), cw = Math.max(2, (c.end - c.start) * S.zoom);
      if (cx > x1 || cx + cw < x0) continue;
      ctx.fillStyle = S.selCap === c.id ? "#a97be8" : "#8d5bd1";
      this.round(cx, RULER + 4, cw, CAPH - 8, 4);
      ctx.fill();
      if (S.selCap === c.id) {
        ctx.strokeStyle = "#fff";
        ctx.lineWidth = 1.5;
        this.round(cx + 0.5, RULER + 4.5, cw - 1, CAPH - 9, 4);
        ctx.stroke();
      }
      this.label(c.text, cx + 4, RULER + 17, cw - 8, "#fff");
    }

    // 클립
    p.tracks.forEach((tr, ti0) => {
      for (const c0 of tr.clips) {
        const { c, ti } = this.displayed(c0, ti0);
        const cx = this.x(c.start), cw = Math.max(2, U.clipDur(c) * S.zoom);
        if (cx > x1 || cx + cw < x0) continue;
        const y = this.rowY(ti) + 3, h = th() - 6;
        const a = U.asset(c.assetID);
        const kind = c.kind === "text" ? "text" : a?.kind || "video";
        ctx.globalAlpha = tr.hidden ? 0.4 : 1;
        ctx.fillStyle = COLORS[kind];
        this.round(cx, y, cw, h, 5);
        ctx.fill();
        this.media(c, a, kind, cx, y, cw, h, x0, x1);
        ctx.globalAlpha = 1;
        // 대본이 있으면 단어 자리 표시
        if (a?.words && kind !== "text") {
          ctx.fillStyle = "rgba(255,255,255,0.22)";
          for (const w of a.words) {
            if (w.end < c.sourceIn || w.start > c.sourceOut) continue;
            const wx = cx + (Math.max(w.start, c.sourceIn) - c.sourceIn) / c.speed * S.zoom;
            const ww = Math.max(1, (Math.min(w.end, c.sourceOut) - Math.max(w.start, c.sourceIn)) / c.speed * S.zoom);
            if (wx > x1 || wx + ww < x0) continue;
            ctx.fillRect(wx, y + 20, ww, h - 26);
          }
        }
        ctx.fillStyle = "rgba(0,0,0,0.25)";
        ctx.fillRect(cx, y, cw, 16);
        let name = c.kind === "text" ? "T  " + c.text : a?.name || "?";
        if (Math.abs(c.speed - 1) > 0.001) name = `⏩${c.speed}x  ` + name;
        if (a?.words) name = "💬 " + name;
        if (c.groupID) name = "🔗 " + name;
        this.label(name, Math.max(cx + 5, Math.min(x0 + HEADER + 5, cx + cw - 60)), y + 12, cw - 10, "#fff");
        // 그룹 표시: 아래쪽 청록 띠
        if (c.groupID) {
          ctx.fillStyle = "#2bb3a3";
          ctx.fillRect(cx + 2, y + h - 4, cw - 4, 3);
        }
        if (S.sel.has(c.id)) {
          ctx.strokeStyle = "#fff";
          ctx.lineWidth = 2;
          this.round(cx + 1, y + 1, cw - 2, h - 2, 5);
          ctx.stroke();
          ctx.fillStyle = "#ffd34d";
          ctx.fillRect(cx, y + 12, 4, h - 24);
          ctx.fillRect(cx + cw - 4, y + 12, 4, h - 24);
        }
      }
    });

    // 무음 컷 미리보기
    for (const [a, b] of S.silencePreview) {
      const rx = this.x(a), rw = Math.max(1, (b - a) * S.zoom);
      if (rx > x1 || rx + rw < x0) continue;
      ctx.fillStyle = "rgba(255,70,70,0.28)";
      ctx.fillRect(rx, RULER, rw, H);
      ctx.fillStyle = "rgba(255,70,70,0.85)";
      ctx.fillRect(rx, RULER, rw, 3);
    }

    // 끼워 넣기 위치
    if (this.insertAt != null) {
      ctx.fillStyle = "#ffd34d";
      ctx.fillRect(this.x(this.insertAt) - 1.5, this.rowY(0) - 2, 3, th() + 4);
    }
    if (this.drag?.type === "marquee" && this.drag.moved) {
      const { sx, sy, cx, cy } = this.drag;
      ctx.fillStyle = "rgba(59,130,246,0.15)";
      ctx.fillRect(Math.min(sx, cx), Math.min(sy, cy), Math.abs(cx - sx), Math.abs(cy - sy));
      ctx.strokeStyle = "#3b82f6";
      ctx.lineWidth = 1;
      ctx.strokeRect(Math.min(sx, cx), Math.min(sy, cy), Math.abs(cx - sx), Math.abs(cy - sy));
    }

    this.ruler(x0, W);
    this.headers(x0, st, H);
    // 재생헤드
    const px = this.x(S.time);
    ctx.fillStyle = "#ff4d4d";
    ctx.fillRect(px - 0.5, 0, 2, H);
    ctx.beginPath();
    ctx.moveTo(px - 6, RULER - 10); ctx.lineTo(px + 7, RULER - 10); ctx.lineTo(px + 0.5, RULER); ctx.closePath(); ctx.fill();
  }

  /// 클립 안에 장면 그림(영상·사진)과 파형(소리)을 그린다
  media(c, a, kind, cx, y, cw, h, x0, x1) {
    const m = a && S.media?.[a.id];
    if (!m || kind === "text") return;
    const ctx = this.ctx;
    ctx.save();
    this.round(cx, y, cw, h, 5);
    ctx.clip();
    const body = y + 16, bh = h - 16;
    const thumbs = m.thumbs.filter((t) => t.img.complete && t.img.naturalWidth);
    if (thumbs.length && bh > 10) {
      const tw = Math.max(20, (bh * thumbs[0].img.naturalWidth) / thumbs[0].img.naturalHeight);
      const start = Math.max(cx, x0 - ((x0 - cx) % tw));
      for (let tx = start; tx < Math.min(cx + cw, x1); tx += tw) {
        const src = kind === "image" ? 0 : c.sourceIn + ((tx - cx + tw / 2) / S.zoom) * c.speed;
        let best = thumbs[0];
        for (const t of thumbs) if (Math.abs(t.t - src) < Math.abs(best.t - src)) best = t;
        ctx.globalAlpha = 0.55;
        ctx.drawImage(best.img, tx, body, tw, bh);
      }
      ctx.globalAlpha = 1;
    }
    if (m.peaks?.length && a.hasAudio) {
      // 아래쪽 절반에 파형 (50ms 단위)
      const base = y + h - 2, amp = kind === "audio" ? bh - 4 : bh * 0.45;
      ctx.fillStyle = kind === "audio" ? "rgba(255,255,255,0.55)" : "rgba(255,255,255,0.35)";
      const px0 = Math.max(cx, x0), px1 = Math.min(cx + cw, x1);
      for (let px = px0; px < px1; px += 2) {
        const s0 = c.sourceIn + ((px - cx) / S.zoom) * c.speed, s1 = c.sourceIn + ((px + 2 - cx) / S.zoom) * c.speed;
        let v = 0;
        for (let i = Math.floor(s0 / 0.05); i <= Math.floor(s1 / 0.05) && i < m.peaks.length; i++) v = Math.max(v, m.peaks[i] || 0);
        const hh = Math.max(1, Math.sqrt(v) * amp);
        ctx.fillRect(px, base - hh, 1.5, hh);
      }
    }
    ctx.restore();
  }

  ruler(x0, W) {
    const ctx = this.ctx;
    ctx.fillStyle = "#2a2b30";
    ctx.fillRect(x0, 0, W, RULER);
    const steps = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600];
    const major = steps.find((s) => s * S.zoom >= 80) || 3600;
    const t0 = Math.floor(this.t(x0) / major) * major;
    ctx.fillStyle = "#9a9ca3";
    ctx.font = "10px -apple-system, 'Segoe UI', sans-serif";
    for (let t = t0; this.x(t) < x0 + W; t += major) {
      const x = this.x(t);
      ctx.fillRect(x, RULER - 8, 1, 8);
      ctx.fillText(U.fmt(t).replace(/\.00$/, ""), x + 3, 11);
      for (let k = 1; k < 5; k++) ctx.fillRect(x + (major * S.zoom * k) / 5, RULER - 4, 1, 4);
    }
  }

  headers(x0, st, H) {
    const ctx = this.ctx, p = S.project;
    ctx.fillStyle = "#26272b";
    ctx.fillRect(x0, 0, HEADER, H);
    ctx.fillStyle = "#3a3c42";
    ctx.fillRect(x0 + HEADER - 1, 0, 1, H);
    ctx.font = "600 11px -apple-system, 'Segoe UI', 'Malgun Gothic', sans-serif";
    ctx.fillStyle = "#e8e8ea";
    ctx.fillText(T("captionsRow"), x0 + 10, RULER + 17);
    p.tracks.forEach((tr, ti) => {
      const y = this.rowY(ti);
      ctx.fillStyle = "#e8e8ea";
      // 트랙이 낮으면 이름과 아이콘을 한 줄에
      const compact = th() < 52;
      const iy = compact ? y + th() / 2 + 5 : y + 42;
      ctx.fillText(U.trackName(tr.name), x0 + 10, compact ? iy : y + 20);
      ctx.fillStyle = tr.muted ? "#ff6b6b" : "#9a9ca3";
      ctx.fillText(tr.muted ? "🔇" : "🔊", x0 + (compact ? 56 : 10), iy);
      ctx.fillStyle = tr.hidden ? "#ff6b6b" : "#9a9ca3";
      ctx.fillText(tr.hidden ? "🚫" : "👁", x0 + (compact ? 80 : 34), iy);
    });
    ctx.fillStyle = "#2a2b30";
    ctx.fillRect(x0, 0, HEADER, RULER);
    ctx.fillStyle = "#ff4d4d";
    ctx.font = "600 11px -apple-system, 'Segoe UI', sans-serif";
    ctx.fillText(U.fmt(S.time), x0 + 8, 16);
  }

  label(text, x, y, maxW, color) {
    if (maxW < 12) return;
    const ctx = this.ctx;
    ctx.fillStyle = color;
    let s = text;
    if (ctx.measureText(s).width > maxW) {
      while (s.length > 1 && ctx.measureText(s + "…").width > maxW) s = s.slice(0, -1);
      s += "…";
    }
    ctx.fillText(s, x, y);
  }

  round(x, y, w, h, r) {
    const ctx = this.ctx;
    r = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h);
  }

  // 끌고 있는 클립은 옮겨질 자리에 그린다
  displayed(c, ti) {
    const d = this.drag;
    if (d?.type === "move" && (S.sel.has(c.id) || d.id === c.id) && (d.dt || d.dTrack)) {
      return { c: { ...c, start: Math.max(0, c.start + d.dt) }, ti: Math.max(0, Math.min(S.project.tracks.length - 1, ti + d.dTrack)) };
    }
    if (d?.type === "trim" && d.id === c.id && d.dt) {
      const k = { ...c };
      if (d.left) {
        const ns = Math.max(0, c.start + d.dt);
        k.sourceIn = c.sourceIn + (ns - c.start) * c.speed;
        k.start = ns;
      } else {
        k.sourceOut = c.sourceOut + d.dt * c.speed;
      }
      return { c: k, ti };
    }
    return { c, ti };
  }

  hit(px, py) {
    const ti = this.trackAt(py);
    if (ti == null) return null;
    const y = this.rowY(ti);
    if (py < y + 3 || py > y + th() - 3) return null;
    const t = this.t(px);
    const c = S.project.tracks[ti].clips.find((c) => t >= c.start && t <= U.clipEnd(c));
    if (!c) return null;
    const xs = this.x(c.start), xe = this.x(U.clipEnd(c));
    const z = Math.min(EDGE, (xe - xs) / 3);
    return { c, ti, edge: px - xs < z ? -1 : xe - px < z ? 1 : 0 };
  }

  snap(t, exclude) {
    if (S.snapping === false) return t;
    const cands = [0, S.time];
    for (const { c } of U.clips()) if (c.id !== exclude && !S.sel.has(c.id)) cands.push(c.start, U.clipEnd(c));
    if (S.markIn != null) cands.push(S.markIn);
    if (S.markOut != null) cands.push(S.markOut);
    const tol = 8 / S.zoom;
    let best = t, d = tol;
    for (const v of cands) if (Math.abs(v - t) < d) { d = Math.abs(v - t); best = v; }
    return best;
  }

  pos(e) {
    const r = this.cv.getBoundingClientRect();
    const shift = this.fullW > 16000 ? this.sc.scrollLeft : 0;
    return { x: e.clientX - r.left + shift, y: e.clientY - r.top };
  }

  down(e) {
    if (!S.project || e.button !== 0) return;
    const { x, y } = this.pos(e);
    const sl = this.sc.scrollLeft;
    // 구간이 있을 때 다른 곳을 누르면 푼다 (모르고 Delete 눌러 지워지는 일 방지)
    if (U.markRange()) { S.markIn = S.markOut = null; }
    // 눈금자: 끌면 언제나 구간 선택, Alt를 누른 채 끌면 재생헤드만 이동
    if (y < RULER) {
      const tx = this.t(Math.max(x, sl + HEADER));
      this.drag = e.altKey ? { type: "scrub" } : { type: "range", from: this.snap(tx), sx: x };
      seek(tx);
      return;
    }
    if (x - sl < HEADER) {
      const ti = this.trackAt(y);
      if (ti != null) {
        const lx = x - sl;
        const tr = S.project.tracks[ti];
        const [m0, h0] = th() < 52 ? [52, 76] : [6, 30];
        if (lx >= m0 && lx < m0 + 24) run("update_track", { index: ti, muted: !tr.muted, hidden: tr.hidden });
        else if (lx >= h0 && lx < h0 + 24) run("update_track", { index: ti, muted: tr.muted, hidden: !tr.hidden });
      }
      return;
    }
    // 자막 줄: 누르면 선택, 끌면 이동, 가장자리를 끌면 길이 조절. 빈 곳은 재생헤드 이동 + 구간 선택
    if (y < RULER + CAPH) {
      const ch = this.captionHit(x, y);
      if (ch) {
        S.sel.clear();
        S.selCap = ch.c.id;
        this.drag = { type: ch.edge ? "capTrim" : "capMove", id: ch.c.id, left: ch.edge < 0, sx: x, dt: 0 };
        window.dispatchEvent(new Event("selection"));
      } else {
        S.selCap = null;
        const tx = this.t(x);
        seek(tx);
        this.drag = { type: "range", from: this.snap(tx), sx: x };
        window.dispatchEvent(new Event("selection"));
      }
      this.drawSoon();
      return;
    }
    S.selCap = null;
    const h = this.hit(x, y);
    if (h) {
      if (e.ctrlKey || e.metaKey) {
        S.sel.has(h.c.id) ? S.sel.delete(h.c.id) : S.sel.add(h.c.id);
      } else if (e.shiftKey) {
        S.sel.add(h.c.id);
      } else if (!S.sel.has(h.c.id)) {
        S.sel = new Set([h.c.id]);
      }
      // 그룹이면 동료 클립도 함께 선택
      S.sel = U.groupMembers(S.sel);
      if (h.edge && !h.c.groupID) {
        S.sel = new Set([h.c.id]);
        this.drag = { type: "trim", id: h.c.id, left: h.edge < 0, dt: 0 };
      } else {
        this.drag = { type: "move", id: h.c.id, grab: this.t(x) - h.c.start, orig: h.c.start, ti: h.ti, dt: 0, dTrack: 0, alt: e.altKey };
      }
      window.dispatchEvent(new Event("selection"));
      this.drawSoon();
      return;
    }
    // 빈 곳: 선택 해제 + 이동, 끌면 여러 클립 선택
    const additive = e.shiftKey || e.ctrlKey || e.metaKey;
    this.drag = { type: "marquee", sx: x, sy: y, cx: x, cy: y, base: additive ? new Set(S.sel) : new Set(), moved: false };
    if (!additive) S.sel.clear();
    window.dispatchEvent(new Event("selection"));
    seek(this.t(x));
  }

  move(e) {
    const d = this.drag;
    if (!d) return;
    const { x, y } = this.pos(e);
    if (d.type === "scrub") { seek(this.t(Math.max(x, this.sc.scrollLeft + HEADER))); return; }
    if (d.type === "range") {
      if (Math.abs(x - d.sx) < 4) return;
      const to = this.snap(this.t(Math.max(x, this.sc.scrollLeft + HEADER)));
      S.sel.clear();
      S.markIn = Math.min(d.from, to);
      S.markOut = Math.max(d.from, to);
      seek(to);
      return;
    }
    if (d.type === "capMove" || d.type === "capTrim") {
      const c = S.project.captions.find((k) => k.id === d.id);
      if (!c) return;
      if (d.type === "capMove") {
        const ns = this.snap(Math.max(0, c.start + (x - d.sx) / S.zoom));
        d.dt = ns - c.start;
      } else {
        const tt = this.snap(this.t(x));
        d.dt = tt - (d.left ? c.start : c.end);
      }
      this.drawSoon();
      return;
    }
    if (d.type === "move") {
      const f = U.findClip(d.id);
      if (!f) return;
      let ns = Math.max(0, this.t(x) - d.grab);
      const s1 = this.snap(ns, d.id);
      if (s1 !== ns) ns = s1;
      else {
        const e1 = this.snap(ns + U.clipDur(f.c), d.id);
        if (e1 !== ns + U.clipDur(f.c)) ns = e1 - U.clipDur(f.c);
      }
      const tt = this.trackAt(y);
      d.dt = ns - d.orig;
      d.dTrack = (tt == null ? d.ti : tt) - d.ti;
      d.alt = e.altKey;
      d.pointer = this.t(x);
      // 트랙 1에서 한 클립을 끌면 끼워 넣기(순서 바꾸기)
      this.insertAt = null;
      if (d.ti === 0 && d.dTrack === 0 && !d.alt && S.sel.size <= 1) {
        const others = S.project.tracks[0].clips.filter((c) => c.id !== d.id);
        const under = others.find((c) => d.pointer >= c.start && d.pointer < U.clipEnd(c));
        if (under) this.insertAt = d.pointer < (under.start + U.clipEnd(under)) / 2 ? under.start : U.clipEnd(under);
        else if (others.length) {
          const bounds = [0, ...others.flatMap((c) => [c.start, U.clipEnd(c)])];
          this.insertAt = bounds.reduce((a, b) => (Math.abs(b - d.pointer) < Math.abs(a - d.pointer) ? b : a));
        }
        if (this.insertAt != null && this.insertAt >= f.c.start - 1e-4 && this.insertAt <= U.clipEnd(f.c) + 1e-4) this.insertAt = null;
      }
      this.drawSoon();
      return;
    }
    if (d.type === "trim") {
      const f = U.findClip(d.id);
      if (!f) return;
      const tt = this.snap(this.t(x), d.id);
      d.dt = tt - (d.left ? f.c.start : U.clipEnd(f.c));
      this.drawSoon();
      return;
    }
    if (d.type === "marquee") {
      d.cx = x; d.cy = y;
      if (Math.abs(x - d.sx) > 4 || Math.abs(y - d.sy) > 4) d.moved = true;
      if (!d.moved) return;
      const sel = new Set(d.base);
      const rx0 = Math.min(d.sx, x), rx1 = Math.max(d.sx, x), ry0 = Math.min(d.sy, y), ry1 = Math.max(d.sy, y);
      S.project.tracks.forEach((tr, ti) => {
        const cy0 = this.rowY(ti) + 3, cy1 = cy0 + th() - 6;
        for (const c of tr.clips) {
          const cx0 = this.x(c.start), cx1 = this.x(U.clipEnd(c));
          if (cx1 >= rx0 && cx0 <= rx1 && cy1 >= ry0 && cy0 <= ry1) sel.add(c.id);
        }
      });
      S.sel = U.groupMembers(sel);
      window.dispatchEvent(new Event("selection"));
      this.drawSoon();
    }
  }

  up() {
    const d = this.drag;
    this.drag = null;
    const ins = this.insertAt;
    this.insertAt = null;
    if (!d) return;
    if ((d.type === "capMove" || d.type === "capTrim") && Math.abs(d.dt) > 1e-3) {
      const c = S.project.captions.find((k) => k.id === d.id);
      if (c) {
        if (d.type === "capMove") run("update_caption", { id: c.id, start: Math.max(0, c.start + d.dt), end: Math.max(0, c.start + d.dt) + (c.end - c.start) });
        else if (d.left) run("update_caption", { id: c.id, start: Math.min(c.end - 0.1, Math.max(0, c.start + d.dt)) });
        else run("update_caption", { id: c.id, end: Math.max(c.start + 0.1, c.end + d.dt) });
      }
    }
    if (d.type === "range" && U.markRange()) {
      const r = U.markRange();
      toast(`${T("range")} ${U.fmt(r[0])} – ${U.fmt(r[1])} · ${T("rangeHint")}`);
    }
    if (d.type === "move" && (Math.abs(d.dt) > 1e-4 || d.dTrack)) {
      if (ins != null) {
        run("reorder_clip", { id: d.id, pointer: d.pointer });
        toast(T("reordered"));
      } else {
        const ids = S.sel.has(d.id) ? [...S.sel] : [d.id];
        const moves = ids.map((id) => U.findClip(id)).filter(Boolean)
          .sort((a, b) => a.c.start - b.c.start)
          .map(({ c, ti }) => [c.id, Math.max(0, Math.min(S.project.tracks.length - 1 + 1, ti + d.dTrack)), Math.max(0, c.start + d.dt)]);
        run("move_clips", { moves });
      }
    }
    if (d.type === "trim" && Math.abs(d.dt) > 1e-4) {
      const f = U.findClip(d.id);
      if (f) run("trim_clip", { id: d.id, left: d.left, time: (d.left ? f.c.start : U.clipEnd(f.c)) + d.dt });
    }
    this.drawSoon();
  }

  dbl(e) {
    const { x, y } = this.pos(e);
    const ch = y >= RULER && y < RULER + CAPH ? this.captionHit(x, y) : null;
    if (ch) {
      S.selCap = ch.c.id;
      seek(ch.c.start);
      switchTab("captions");
      window.dispatchEvent(new Event("selection"));
      return;
    }
    const h = this.hit(x, y);
    if (h) seek(h.c.start);
  }

  /// 오른쪽 클릭: 클립 / 자막 / 빈 곳 메뉴
  context(e) {
    e.preventDefault();
    if (!S.project) return;
    const { x, y } = this.pos(e);
    if (x - this.sc.scrollLeft < HEADER || y < RULER) return;
    if (y < RULER + CAPH) {
      const ch = this.captionHit(x, y);
      if (ch) return captionMenu(e.clientX, e.clientY, ch.c);
      return emptyMenu(e.clientX, e.clientY, this.t(x));
    }
    const h = this.hit(x, y);
    if (h) return clipMenu(e.clientX, e.clientY, h.c);
    emptyMenu(e.clientX, e.clientY, this.t(x));
  }

  /// 화면 좌표 → 타임라인 (시간, 트랙). 타임라인 밖이면 null
  pointAt(clientX, clientY) {
    const r = this.sc.getBoundingClientRect();
    if (clientX < r.left || clientX > r.right || clientY < r.top || clientY > r.bottom) return null;
    const { x, y } = this.pos({ clientX, clientY });
    if (x - this.sc.scrollLeft < HEADER) return null;
    const ti = this.trackAt(y);
    return { t: this.snap(this.t(x)), ti: ti ?? 0 };
  }

  /// 자막 줄에서 누른 자막 (edge: -1 왼쪽 끝, 1 오른쪽 끝, 0 가운데)
  captionHit(px, py) {
    if (py < RULER + 3 || py > RULER + CAPH - 3) return null;
    const t = this.t(px);
    const c = S.project.captions.find((c) => t >= c.start && t <= c.end);
    if (!c) return null;
    const xs = this.x(c.start), xe = this.x(c.end);
    const z = Math.min(EDGE, (xe - xs) / 3);
    return { c, edge: px - xs < z ? -1 : xe - px < z ? 1 : 0 };
  }

  /// 끌고 있는 자막은 옮겨질 자리에 그린다
  displayedCaption(c) {
    const d = this.drag;
    if (!d || d.id !== c.id || !d.dt) return c;
    if (d.type === "capMove") return { ...c, start: c.start + d.dt, end: c.end + d.dt };
    if (d.type === "capTrim") return d.left ? { ...c, start: Math.min(c.end - 0.1, c.start + d.dt) } : { ...c, end: Math.max(c.start + 0.1, c.end + d.dt) };
    return c;
  }
}
