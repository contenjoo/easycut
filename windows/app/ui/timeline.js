// 타임라인 (캔버스): 눈금자 · 자막 줄 · 트랙 · 클립 · 재생헤드
import { S, U, seek, run, toast } from "./app.js";

const HEADER = 110, RULER = 24, CAPH = 26, TRACKH = 54, EDGE = 7;
const COLORS = { video: "#4a6fb5", audio: "#3f8f6a", image: "#9a6b3c", text: "#7b4fb3" };

export class Timeline {
  constructor(canvas, scroller) {
    this.cv = canvas;
    this.sc = scroller;
    this.ctx = canvas.getContext("2d");
    this.drag = null;
    this.pending = false;
    canvas.addEventListener("mousedown", (e) => this.down(e));
    window.addEventListener("mousemove", (e) => this.move(e));
    window.addEventListener("mouseup", (e) => this.up(e));
    canvas.addEventListener("dblclick", (e) => this.dbl(e));
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
  rowY(ti) { return RULER + CAPH + (S.project.tracks.length - 1 - ti) * TRACKH; }
  trackAt(y) {
    const rel = y - RULER - CAPH;
    if (rel < 0) return null;
    const row = Math.floor(rel / TRACKH);
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
    const h = Math.max(this.sc.clientHeight, RULER + CAPH + S.project.tracks.length * TRACKH + TRACKH);
    const dpr = window.devicePixelRatio || 1;
    // 너무 큰 캔버스는 보이는 부분만 그린다
    const vw = Math.min(w, 16000);
    if (this.cv.width !== vw * dpr || this.cv.height !== h * dpr) {
      this.cv.width = vw * dpr;
      this.cv.height = h * dpr;
      this.cv.style.width = w + "px";
      this.cv.style.height = h + "px";
    }
    this.fullW = w;
    this.drawSoon();
  }

  drawSoon() {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => { this.pending = false; this.draw(); });
  }

  playheadMoved() {
    // 재생 중엔 재생헤드를 따라 스크롤
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
      ctx.fillRect(x0, y, W, TRACKH);
      ctx.fillStyle = "#2c2e33";
      ctx.fillRect(x0, y + TRACKH - 1, W, 1);
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
    for (const c of p.captions) {
      const cx = this.x(c.start), cw = Math.max(2, (c.end - c.start) * S.zoom);
      if (cx > x1 || cx + cw < x0) continue;
      ctx.fillStyle = "#8d5bd1";
      this.round(cx, RULER + 4, cw, CAPH - 8, 4);
      ctx.fill();
      this.label(c.text, cx + 4, RULER + 17, cw - 8, "#fff");
    }

    // 클립
    p.tracks.forEach((tr, ti0) => {
      for (const c0 of tr.clips) {
        const { c, ti } = this.displayed(c0, ti0);
        const cx = this.x(c.start), cw = Math.max(2, U.clipDur(c) * S.zoom);
        if (cx > x1 || cx + cw < x0) continue;
        const y = this.rowY(ti) + 3, h = TRACKH - 6;
        const a = U.asset(c.assetID);
        const kind = c.kind === "text" ? "text" : a?.kind || "video";
        ctx.globalAlpha = tr.hidden ? 0.4 : 1;
        ctx.fillStyle = COLORS[kind];
        this.round(cx, y, cw, h, 5);
        ctx.fill();
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
        this.label(name, Math.max(cx + 5, Math.min(x0 + HEADER + 5, cx + cw - 60)), y + 12, cw - 10, "#fff");
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
      ctx.fillRect(this.x(this.insertAt) - 1.5, this.rowY(0) - 2, 3, TRACKH + 4);
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
      ctx.fillText(U.trackName(tr.name), x0 + 10, y + 20);
      ctx.fillStyle = tr.muted ? "#ff6b6b" : "#9a9ca3";
      ctx.fillText(tr.muted ? "🔇" : "🔊", x0 + 10, y + 42);
      ctx.fillStyle = tr.hidden ? "#ff6b6b" : "#9a9ca3";
      ctx.fillText(tr.hidden ? "🚫" : "👁", x0 + 34, y + 42);
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
    if (py < y + 3 || py > y + TRACKH - 3) return null;
    const t = this.t(px);
    const c = S.project.tracks[ti].clips.find((c) => t >= c.start && t <= U.clipEnd(c));
    if (!c) return null;
    const xs = this.x(c.start), xe = this.x(U.clipEnd(c));
    const z = Math.min(EDGE, (xe - xs) / 3);
    return { c, ti, edge: px - xs < z ? -1 : xe - px < z ? 1 : 0 };
  }

  snap(t, exclude) {
    const cands = [0, S.time];
    for (const { c } of U.clips()) if (c.id !== exclude && !S.sel.has(c.id)) cands.push(c.start, U.clipEnd(c));
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
    // 구간이 있을 때 다른 곳을 누르면 푼다 (재생헤드 잡기는 예외)
    const onHead = y < RULER && Math.abs(x - this.x(S.time)) <= 8;
    if (U.markRange() && !onHead) { S.markIn = S.markOut = null; }
    if (y < RULER) {
      if (onHead) this.drag = { type: "scrub" };
      else this.drag = { type: "range", from: this.snap(this.t(Math.max(x, sl + HEADER))), sx: x };
      seek(this.t(Math.max(x, sl + HEADER)));
      return;
    }
    if (x - sl < HEADER) {
      const ti = this.trackAt(y);
      if (ti != null) {
        const lx = x - sl;
        const tr = S.project.tracks[ti];
        if (lx < 30) run("update_track", { index: ti, muted: !tr.muted, hidden: tr.hidden });
        else if (lx < 56) run("update_track", { index: ti, muted: tr.muted, hidden: !tr.hidden });
      }
      return;
    }
    if (y < RULER + CAPH) {
      seek(this.t(x));
      return;
    }
    const h = this.hit(x, y);
    if (h) {
      if (e.ctrlKey || e.metaKey) {
        S.sel.has(h.c.id) ? S.sel.delete(h.c.id) : S.sel.add(h.c.id);
      } else if (e.shiftKey) {
        S.sel.add(h.c.id);
      } else if (!S.sel.has(h.c.id)) {
        S.sel = new Set([h.c.id]);
      }
      if (h.edge) {
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
        const cy0 = this.rowY(ti) + 3, cy1 = cy0 + TRACKH - 6;
        for (const c of tr.clips) {
          const cx0 = this.x(c.start), cx1 = this.x(U.clipEnd(c));
          if (cx1 >= rx0 && cx0 <= rx1 && cy1 >= ry0 && cy0 <= ry1) sel.add(c.id);
        }
      });
      S.sel = sel;
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
    const h = this.hit(x, y);
    if (h) seek(h.c.start);
  }
}
