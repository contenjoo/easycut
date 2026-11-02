import { TRANSITIONS, TEXT_ANIMATIONS, VISUAL_FILTERS } from "./effects.js";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const modes = new Map();
const icons = { none: "⊘", fade: "◐", slideLeft: "←", slideRight: "→", slideUp: "↑", slideDown: "↓", wipeLeft: "◧", wipeRight: "◨", wipeUp: "◩", wipeDown: "◪", zoom: "⤢", zoomIn: "⤢", zoomOut: "⤡", rotate: "⟳", rotateIn: "⟳", blur: "◌", blurIn: "◌", pixelate: "▦", iris: "◉", squeeze: "↕", scaleX: "↔", flip: "▱", slideDiagonal: "↖", pop: "✧", typewriter: "▤", bounce: "↥", float: "≋", shake: "∿", warm: "☼", cool: "❄", mono: "◐", sepia: "◍", vivid: "◈", soft: "☁", vintage: "▣", dramatic: "ϟ", noir: "☾" };
const short = { slideLeft: "왼쪽 슬라이드", slideRight: "오른쪽 슬라이드", wipeLeft: "왼쪽 와이프", wipeRight: "오른쪽 와이프" };

export function effectGridHTML(items, selected, prefix) {
  return `<div class="effect-grid" data-testid="${prefix}-gallery">${items.map((e) => `<button type="button" class="effect-card ${e.id === selected ? "selected" : ""}" data-effect="${esc(e.id)}" data-testid="${prefix}-${esc(e.id)}" aria-pressed="${e.id === selected}" title="${esc(L(e.label))}"><span class="effect-icon" aria-hidden="true">${esc(icons[e.id] || "✦")}</span><span class="effect-name">${esc(L(short[e.id] || e.label))}</span>${e.id === selected ? '<span class="effect-check" aria-hidden="true">✓</span>' : ""}</button>`).join("")}</div>`;
}

function durationHTML(value, intensity = false) {
  const label = intensity ? L("강도") : L("효과 시간");
  const display = intensity ? Math.round(value * 100) + "%" : L("{}초", Number(value).toFixed(1));
  return `<label class="effect-duration"><span>${label}</span><input type="range" data-effect-duration min="${intensity ? 0 : 0.1}" max="${intensity ? 1 : 3}" step="${intensity ? 0.01 : 0.1}" value="${value}"/><output>${display}</output></label>`;
}

function wireDuration(el, commit, intensity = false) {
  const slider = el.querySelector("[data-effect-duration]");
  if (!slider) return;
  slider.oninput = () => { el.querySelector(".effect-duration output").textContent = intensity ? Math.round(+slider.value * 100) + "%" : L("{}초", (+slider.value).toFixed(1)); };
  slider.onchange = () => commit(+slider.value);
}

function previewHTML(preview) { return preview ? `<button type="button" class="effect-play" data-testid="effect-preview-button"><span aria-hidden="true">▶</span> ${L("효과 재생")}</button>` : ""; }

export function renderTextEffects(el, { style, onChange, preview }) {
  const current = style.animation || "none", selected = TEXT_ANIMATIONS.find((e) => e.id === current);
  el.innerHTML = `<div class="effect-control-head"><h3>${L("텍스트 효과")}</h3><span>${esc(selected ? L(selected.label) : current)}</span></div>${current !== "none" ? durationHTML(style.animationDuration ?? 0.6) : ""}${previewHTML(preview)}${effectGridHTML(TEXT_ANIMATIONS, current, "text-effect")}<p class="hint effect-help">${L("각 텍스트와 자막이 시작할 때 적용됩니다. 짧은 구간에서는 효과 시간이 자동으로 줄어듭니다.")}</p>`;
  el.querySelectorAll("[data-effect]").forEach((b) => { b.onclick = () => onChange({ ...style, animation: b.dataset.effect === "none" ? null : b.dataset.effect }); });
  wireDuration(el, (value) => onChange({ ...style, animationDuration: value }));
  if (preview) el.querySelector(".effect-play").onclick = () => preview(false);
}

export function renderClipEffects(el, { clip, kind, onClip, preview }) {
  let state = modes.get(clip.id);
  if (!state) { state = { mode: kind === "text" ? "text" : "transition", edge: "transitionIn" }; modes.set(clip.id, state); }
  const choices = kind === "text" ? [["text", "텍스트"], ["transition", "전환"]] : [["transition", "전환"], ["filter", "필터"]];
  el.innerHTML = `<div class="inspector-segment" data-testid="effect-kind-picker">${choices.map(([id, label]) => `<button type="button" data-mode="${id}" class="${state.mode === id ? "on" : ""}" aria-pressed="${state.mode === id}">${L(label)}</button>`).join("")}</div><div class="effect-content"></div>`;
  el.querySelectorAll("[data-mode]").forEach((b) => { b.onclick = () => { state.mode = b.dataset.mode; renderClipEffects(el, { clip, kind, onClip, preview }); }; });
  const target = el.querySelector(".effect-content");
  if (state.mode === "text") return renderTextEffects(target, { style: clip.textStyle, onChange: (textStyle) => onClip({ textStyle }), preview });
  if (state.mode === "filter") {
    const current = clip.visualFilter || "none";
    target.innerHTML = `<div class="effect-control-head"><h3>${L("영상 필터")}</h3><span>${esc(L(VISUAL_FILTERS.find((f) => f.id === current)?.label || current))}</span></div>${current !== "none" ? durationHTML(clip.filterIntensity ?? 1, true) : ""}${previewHTML(preview)}${effectGridHTML(VISUAL_FILTERS, current, "visual-filter")}`;
    target.querySelectorAll("[data-effect]").forEach((b) => { b.onclick = () => onClip({ visualFilter: b.dataset.effect === "none" ? null : b.dataset.effect }); });
    wireDuration(target, (filterIntensity) => onClip({ filterIntensity }), true);
    if (preview) target.querySelector(".effect-play").onclick = () => preview(false);
    return;
  }
  const settings = clip[state.edge], current = settings?.effect || "none";
  target.innerHTML = `<div class="inspector-segment transition-edge" data-testid="transition-edge-picker">${[["transitionIn", "시작 효과"], ["transitionOut", "끝 효과"]].map(([id, label]) => `<button type="button" data-edge="${id}" class="${state.edge === id ? "on" : ""}" aria-pressed="${state.edge === id}">${L(label)}</button>`).join("")}</div><div class="effect-control-head"><h3>${L("전환 효과")}</h3><span>${esc(L(TRANSITIONS.find((f) => f.id === current)?.label || current))}</span></div>${current !== "none" ? durationHTML(settings?.duration ?? 0.5) : ""}${previewHTML(preview)}${effectGridHTML(TRANSITIONS, current, "transition")}<p class="hint effect-help">${L("클립의 시작과 끝에 적용됩니다. 짧은 클립에서는 각 효과가 길이의 절반을 넘지 않게 줄어듭니다.")}</p>`;
  target.querySelectorAll("[data-edge]").forEach((b) => { b.onclick = () => { state.edge = b.dataset.edge; renderClipEffects(el, { clip, kind, onClip, preview }); }; });
  target.querySelectorAll("[data-effect]").forEach((b) => { b.onclick = () => onClip({ [state.edge]: b.dataset.effect === "none" ? null : { effect: b.dataset.effect, duration: settings?.duration ?? 0.5 } }); });
  wireDuration(target, (duration) => onClip({ [state.edge]: { effect: current, duration } }));
  if (preview) target.querySelector(".effect-play").onclick = () => preview(state.edge === "transitionOut");
}
