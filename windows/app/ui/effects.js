// 미리보기·효과 갤러리가 공유하는 목록과 시간 계산. DOM 없이도 검사할 수 있다.
const item = (id, label, icon, category) => Object.freeze({ id, label, icon, category });
export const TRANSITIONS = Object.freeze([
  item("none", "없음", "○", "기본"), item("fade", "페이드", "◐", "기본"),
  item("slideLeft", "왼쪽으로 슬라이드", "←", "이동"), item("slideRight", "오른쪽으로 슬라이드", "→", "이동"),
  item("slideUp", "위로 슬라이드", "↑", "이동"), item("slideDown", "아래로 슬라이드", "↓", "이동"),
  item("wipeLeft", "왼쪽으로 와이프", "◧", "열기"), item("wipeRight", "오른쪽으로 와이프", "◨", "열기"),
  item("zoom", "확대·축소", "↗", "변형"), item("wipeUp", "위로 와이프", "⊥", "열기"),
  item("wipeDown", "아래로 와이프", "⊤", "열기"), item("zoomOut", "멀어지기", "↙", "변형"),
  item("rotate", "회전", "↻", "변형"), item("blur", "흐림 전환", "◌", "분위기"),
  item("pixelate", "픽셀 전환", "▦", "분위기"), item("iris", "원형 열기", "◉", "열기"),
  item("squeeze", "접었다 펼치기", "↕", "변형"), item("flip", "카드 뒤집기", "▱", "변형"),
  item("slideDiagonal", "대각선 이동", "↖", "이동"),
]);
export const TEXT_ANIMATIONS = Object.freeze([
  item("none", "없음", "○", "기본"), item("fade", "서서히 나타나기", "◐", "기본"),
  item("slideUp", "아래에서 올라오기", "↑", "이동"), item("slideDown", "위에서 내려오기", "↓", "이동"),
  item("pop", "팝업", "✧", "변형"), item("typewriter", "타이핑", "Aa", "기본"),
  item("bounce", "통통 튀기", "↕", "이동"), item("zoomIn", "작게 시작하기", "↗", "변형"),
  item("zoomOut", "크게 시작하기", "↙", "변형"), item("rotateIn", "돌아 나타나기", "↻", "변형"),
  item("blurIn", "선명해지기", "◌", "분위기"), item("wipeRight", "오른쪽으로 나타나기", "→|", "열기"),
  item("wipeUp", "위로 나타나기", "↑|", "열기"), item("scaleX", "가로로 펼치기", "↔", "변형"),
  item("float", "떠오르기", "≈", "이동"), item("shake", "살짝 흔들기", "∿", "이동"),
]);
export const VISUAL_FILTERS = Object.freeze([
  item("none", "원본", "○", "기본"), item("warm", "따뜻하게", "☀", "색감"),
  item("cool", "시원하게", "❄", "색감"), item("mono", "흑백", "◐", "필름"),
  item("sepia", "세피아", "◒", "필름"), item("vivid", "선명하게", "◈", "색감"),
  item("soft", "부드럽게", "☁", "분위기"), item("vintage", "빈티지", "▣", "필름"),
  item("dramatic", "드라마틱", "ϟ", "분위기"), item("noir", "느와르", "☾", "필름"),
]);
const transitionIDs = new Set(TRANSITIONS.map((entry) => entry.id));

const finite = (value, fallback = 0) => Number.isFinite(value) ? value : fallback;
const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));
const n = (value) => String(Math.round(finite(value) * 100000) / 100000);
const px = (value) => n(value) + "px";
const identity = (progress = 1) => ({ opacity: 1, transform: "", clipPath: "", filter: "", pixelSize: 1, progress });
const dimensions = (rect = {}, canvas = {}) => ({
  x: finite(rect.left ?? rect.x), y: finite(rect.top ?? rect.y),
  w: Math.max(0, finite(rect.w ?? rect.width)), h: Math.max(0, finite(rect.h ?? rect.height)),
  cw: Math.max(0, finite(canvas.w ?? canvas.width)), ch: Math.max(0, finite(canvas.h ?? canvas.height)),
});
const inset = (x, y, w, h, cw, ch) => `inset(${px(y)} ${px(cw - x - w)} ${px(ch - y - h)} ${px(x)})`;

export function clampedTransitionDuration(settings, duration) {
  if (!settings || !transitionIDs.has(settings.effect) || settings.effect === "none" || !Number.isFinite(settings.duration) || !Number.isFinite(duration)) return 0;
  return Math.min(Math.max(0, settings.duration), Math.max(0, duration) / 2);
}

export function textProgress(style = {}, elapsed, duration) {
  if (!Number.isFinite(elapsed) || !Number.isFinite(duration) || duration <= 0) return 1;
  const requested = style.animationDuration ?? 0.6;
  if (!Number.isFinite(requested) || requested <= 0) return 1;
  return clamp(elapsed / Math.min(requested, duration / 2));
}

export function transitionState(settings, elapsed, duration, entering, rect, canvas) {
  const window = clampedTransitionDuration(settings, duration);
  if (!window || !Number.isFinite(elapsed)) return identity();
  const p = clamp(elapsed / window), out = identity(p);
  if (p >= 1) return out;
  if (p <= 0) return { ...out, opacity: 0 };
  const { x, y, w, h, cw, ch } = dimensions(rect, canvas);
  const ease = 1 - (1 - p) ** 3, remain = 1 - ease;
  switch (settings.effect) {
    case "fade": out.opacity = p; break;
    case "slideLeft": out.transform = `translateX(${px((entering ? Math.max(0, cw - x) : -Math.max(0, x + w)) * remain)})`; break;
    case "slideRight": out.transform = `translateX(${px((entering ? -Math.max(0, x + w) : Math.max(0, cw - x)) * remain)})`; break;
    case "slideUp": out.transform = `translateY(${px((entering ? Math.max(0, ch - y) : -Math.max(0, y + h)) * remain)})`; break;
    case "slideDown": out.transform = `translateY(${px((entering ? -Math.max(0, y + h) : Math.max(0, ch - y)) * remain)})`; break;
    case "wipeLeft": case "wipeRight": {
      const fromRight = (settings.effect === "wipeLeft") === entering;
      out.clipPath = inset(fromRight ? x + w * (1 - p) : x, y, w * p, h, cw, ch); break;
    }
    case "wipeUp": case "wipeDown": {
      const fromBottom = (settings.effect === "wipeUp") === entering;
      out.clipPath = inset(x, fromBottom ? y + h * (1 - p) : y, w, h * p, cw, ch); break;
    }
    case "zoom": out.transform = `scale(${n(entering ? 0.65 + 0.35 * ease : 1 + 0.35 * remain)})`; out.opacity = p; break;
    case "zoomOut": out.transform = `scale(${n(entering ? 1 + 0.5 * remain : 0.5 + 0.5 * ease)})`; out.opacity = p; break;
    case "rotate": out.transform = `rotate(${n((entering ? 1 : -1) * 90 * remain)}deg)`; out.opacity = p; break;
    case "blur": out.filter = `blur(${px(Math.min(w, h) * 0.08 * remain)})`; out.opacity = p; break;
    case "pixelate": out.pixelSize = Math.max(1, Math.min(w, h) * 0.14 * remain); out.opacity = p; break;
    case "iris": out.clipPath = `circle(${px(Math.hypot(w, h) / 2 * p)} at ${px(x + w / 2)} ${px(y + h / 2)})`; break;
    case "squeeze": out.transform = `scaleY(${n(Math.max(0.001, ease))})`; out.opacity = p; break;
    case "flip": out.transform = `perspective(${px(Math.max(1, w, h) * 3)}) rotateY(${n((entering ? -1 : 1) * 90 * remain)}deg)`; break;
    case "slideDiagonal": out.transform = `translate(${px((entering ? Math.max(0, cw - x) : -Math.max(0, x + w)) * remain)},${px((entering ? Math.max(0, ch - y) : -Math.max(0, y + h)) * remain)})`; break;
    default: return identity();
  }
  return out;
}

export function textMotionState(style = {}, elapsed, duration, rect, canvas) {
  const p = textProgress(style, elapsed, duration), out = identity(p);
  if (p >= 1) return out;
  const { x, y, w, h, cw, ch } = dimensions(rect, canvas);
  const ease = 1 - (1 - p) ** 3;
  switch (style.animation) {
    case "fade": out.opacity = p; break;
    case "slideUp": case "slideDown": out.opacity = p; out.transform = `translateY(${px((style.animation === "slideUp" ? 1 : -1) * Math.max(h * 0.6, ch * 0.055) * (1 - ease))})`; break;
    case "pop": { const v = p - 1; out.transform = `scale(${n(Math.max(0.001, 1 + 2.70158 * v ** 3 + 1.70158 * v ** 2))})`; out.opacity = Math.min(1, p * 4); break; }
    case "bounce": out.transform = `translateY(${px(-Math.abs(Math.sin(p * Math.PI * 3)) * (1 - p) * h * 0.7)})`; out.opacity = p; break;
    case "zoomIn": out.transform = `scale(${n(0.35 + 0.65 * ease)})`; out.opacity = p; break;
    case "zoomOut": out.transform = `scale(${n(1 + 0.6 * (1 - ease))})`; out.opacity = p; break;
    case "rotateIn": out.transform = `rotate(${n(36 * (1 - ease))}deg)`; out.opacity = p; break;
    case "blurIn": out.filter = `blur(${px(Math.min(w, h) * 0.18 * (1 - ease))})`; out.opacity = p; break;
    case "wipeRight": out.clipPath = inset(x, y, w * p, h, cw, ch); break;
    case "wipeUp": out.clipPath = inset(x, y + h * (1 - p), w, h * p, cw, ch); break;
    case "scaleX": out.transform = `scaleX(${n(0.05 + 0.95 * ease)})`; out.opacity = p; break;
    case "float": out.transform = `translateY(${px(ch * 0.09 * (1 - ease) - Math.sin(p * Math.PI * 2) * (1 - p) * h * 0.12)})`; out.opacity = p; break;
    case "shake": out.transform = `translateX(${px(Math.sin(p * Math.PI * 8) * (1 - p) * h * 0.2)})`; out.opacity = p; break;
    default: break;
  }
  return out;
}

// WebView2의 표준 CSS 필터로 같은 색감 계열을 표시한다. 저장·내보내기는 원래 필터 ID를 사용한다.
export function visualFilterCSS(kind, intensity = 1) {
  const s = Number.isFinite(intensity) ? clamp(intensity) : 1;
  if (!s) return "";
  switch (kind) {
    case "warm": return `sepia(${n(0.28 * s)}) saturate(${n(1 + 0.2 * s)}) hue-rotate(${n(-10 * s)}deg) brightness(${n(1 + 0.025 * s)})`;
    case "cool": return `sepia(${n(0.12 * s)}) hue-rotate(${n(165 * s)}deg) saturate(${n(1 + 0.1 * s)})`;
    case "mono": return `grayscale(${n(s)})`;
    case "sepia": return `sepia(${n(0.9 * s)})`;
    case "vivid": return `saturate(${n(1 + 0.45 * s)}) brightness(${n(1 + 0.01 * s)}) contrast(${n(1 + 0.12 * s)})`;
    case "soft": return `blur(${n(1.2 * s)}px) saturate(${n(1 - 0.08 * s)}) brightness(${n(1 + 0.025 * s)}) contrast(${n(1 - 0.06 * s)})`;
    case "vintage": return `sepia(${n(0.4 * s)}) saturate(${n(1 - 0.2 * s)}) brightness(${n(1 + 0.02 * s)}) contrast(${n(1 - 0.05 * s)})`;
    case "dramatic": return `saturate(${n(1 - 0.28 * s)}) brightness(${n(1 - 0.025 * s)}) contrast(${n(1 + 0.35 * s)})`;
    case "noir": return `grayscale(${n(s)}) contrast(${n(1 + 0.45 * s)}) brightness(${n(1 - 0.06 * s)})`;
    default: return "";
  }
}

let segmenter;
export function graphemes(text) {
  const value = String(text ?? "");
  if (typeof Intl.Segmenter === "function") {
    segmenter ??= new Intl.Segmenter("ko", { granularity: "grapheme" });
    return Array.from(segmenter.segment(value), (entry) => entry.segment);
  }
  const out = [];
  for (const point of value) {
    const previous = out.at(-1) || "";
    if (out.length && (/\p{Mark}|[\uFE0E\uFE0F\u200D]|\p{Emoji_Modifier}/u.test(point) || previous.endsWith("\u200D")
        || (/\p{Regional_Indicator}/u.test(point) && /^\p{Regional_Indicator}$/u.test(previous)))) out[out.length - 1] += point;
    else out.push(point);
  }
  return out;
}
export function visibleCharacters(text, progress) {
  return Math.floor(graphemes(String(text ?? "").trim()).length * (Number.isFinite(progress) ? clamp(progress) : 1));
}
export function revealTextParts(text, progress) {
  const parts = graphemes(String(text ?? "").trim()), count = visibleCharacters(text, progress);
  return { visible: parts.slice(0, count).join(""), hidden: parts.slice(count).join(""), count };
}
export function legacyFade(clip, time, audio = false) {
  const duration = Math.max(0, finite((clip.sourceOut - clip.sourceIn) / (clip.speed || 1)));
  const fi = Math.min(Math.max(0, finite(clip.fadeIn)), audio ? duration / 2 : Infinity);
  const fo = Math.min(Math.max(0, finite(clip.fadeOut)), audio ? duration / 2 : Infinity);
  return (fi ? clamp((time - clip.start) / fi) : 1) * (fo ? clamp((clip.start + duration - time) / fo) : 1);
}
export function fontFamilyCSS(fontName) {
  const name = String(fontName ?? "").trim().replace(/\0/g, "");
  const fallback = '"Malgun Gothic", "Segoe UI", sans-serif';
  if (!name || name.startsWith(".")) return fallback;
  const quoted = name.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\a ").replace(/\r/g, "\\d ").replace(/\f/g, "\\c ");
  return `"${quoted}", ${fallback}`;
}
