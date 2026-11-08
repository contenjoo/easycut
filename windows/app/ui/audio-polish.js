// 단어 강조 자막 · 배경음악 자동 줄이기 미리보기. 맥 AudioPolish/CaptionWords, Rust audio_polish와 같은 규칙.
export const DUCK_LEVEL = 0.25, DUCK_RAMP = 0.25, SPEECH_GAP = 0.8;
export const HIGHLIGHT = { r: 1, g: 0.84, b: 0.1, a: 1 };

const cache = new WeakMap();

function timelineWords(p) {
  const out = [];
  p.tracks.forEach((tr, ti) => {
    for (const c of tr.clips) {
      if (c.kind === "text") continue;
      const a = p.assets.find((x) => x.id === c.assetID);
      if (!a?.words) continue;
      for (const w of a.words) {
        const mid = (w.start + w.end) / 2;
        if (!(mid >= c.sourceIn && mid < c.sourceOut)) continue;
        const at = (s) => c.start + (s - c.sourceIn) / c.speed;
        out.push({ a, c, ti, start: at(Math.max(w.start, c.sourceIn)), end: at(Math.min(w.end, c.sourceOut)) });
      }
    }
  });
  return out.sort((x, y) => x.start - y.start);
}

export const isMusic = (a) => a?.kind === "audio" && !(a.words && a.words.length);

export function speechRanges(p) {
  const raw = timelineWords(p)
    .filter((w) => !p.tracks[w.ti].muted && !isMusic(w.a) && w.c.volume > 0.001)
    .map((w) => [w.start, Math.max(w.start, w.end)]);
  const out = [];
  for (const [s, e] of raw) {
    const last = out[out.length - 1];
    if (last && s - last[1] <= SPEECH_GAP) last[1] = Math.max(last[1], e);
    else out.push([s, e]);
  }
  return out;
}

export function duckFactor(t, speech) {
  let f = 1;
  for (const [a, b] of speech) {
    if (t < a - DUCK_RAMP) break;
    let g;
    if (t < a) g = (a - t) / DUCK_RAMP;
    else if (t <= b) g = 0;
    else if (t < b + DUCK_RAMP) g = (t - b) / DUCK_RAMP;
    else continue;
    f = Math.min(f, DUCK_LEVEL + (1 - DUCK_LEVEL) * g);
  }
  return f;
}

/** 공백으로 나눈 어절 [문자 시작, 문자 수] (코드 포인트 기준, Rust chars()와 같음) */
export function tokens(text) {
  const chars = Array.from(String(text ?? "").trim());
  const out = [];
  let start = -1;
  chars.forEach((ch, i) => {
    if (/\s/.test(ch)) { if (start >= 0) { out.push([start, i - start]); start = -1; } }
    else if (start < 0) start = i;
  });
  if (start >= 0) out.push([start, chars.length - start]);
  return out;
}

export function timings(text, start, end, words) {
  const toks = tokens(text);
  if (!toks.length) return [];
  if (words.length === toks.length) return toks.map(([s, l], i) => ({ s, l, start: Math.max(start, words[i]) }));
  const total = Math.max(1, toks.reduce((n, t) => n + Math.max(1, t[1]), 0));
  const dur = Math.max(0.01, end - start);
  let acc = 0;
  return toks.map(([s, l]) => { const t = start + (dur * acc) / total; acc += Math.max(1, l); return { s, l, start: t }; });
}

export function activeIndex(toks, t) {
  if (!toks.length) return -1;
  let idx = 0;
  toks.forEach((tok, i) => { if (tok.start <= t + 0.0001) idx = i; });
  return idx;
}

function data(p) {
  let d = cache.get(p);
  if (!d) {
    d = { speech: null, caps: new Map(), words: null };
    cache.set(p, d);
  }
  return d;
}

/** 지금 배경음악 배율 (자동 줄이기가 꺼져 있거나 음악이 아니면 1) */
export function previewDuck(p, a, t) {
  if (!p.autoDuck || !isMusic(a)) return 1;
  const d = data(p);
  if (!d.speech) d.speech = speechRanges(p);
  return duckFactor(t, d.speech);
}

/** 자막의 강조 어절 {s, l} 또는 null */
export function previewHighlight(p, cap, t) {
  if (!p.captionStyle?.wordHighlight) return null;
  const d = data(p);
  let toks = d.caps.get(cap.id);
  if (!toks) {
    if (!d.words) d.words = timelineWords(p);
    const inside = d.words.filter((w) => { const m = (w.start + w.end) / 2; return m >= cap.start && m < cap.end; }).map((w) => w.start);
    toks = timings(cap.text, cap.start, cap.end, inside);
    d.caps.set(cap.id, toks);
  }
  const i = activeIndex(toks, t);
  return i >= 0 ? toks[i] : null;
}
