import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const { TRANSITIONS, TEXT_ANIMATIONS, VISUAL_FILTERS, transitionState, textMotionState, textProgress,
  clampedTransitionDuration, visualFilterCSS, graphemes, visibleCharacters, revealTextParts, legacyFade, fontFamilyCSS } =
  await import("data:text/javascript;base64," + Buffer.from(await readFile(new URL("../ui/effects.js", import.meta.url), "utf8")).toString("base64"));

const rect = { left: 40, top: 30, w: 200, h: 100 }, canvas = { w: 320, h: 180 };
const cssOnly = (state) => [state.opacity, state.transform, state.clipPath, state.filter, state.pixelSize];
const unchanged = [1, "", "", "", 1];

test("Windows fixture, Rust and JS effect catalogs match; local Mac enums match when present", async () => {
  const fixture = JSON.parse(await readFile(new URL("./fixtures/effect-catalog.json", import.meta.url), "utf8"));
  const rust = await readFile(new URL("../../crates/easycut-core/src/effects.rs", import.meta.url), "utf8");
  let swift;
  try { swift = await readFile(new URL("../../../Sources/EasyCut/Model/ClipEffects.swift", import.meta.url), "utf8"); }
  catch (error) { if (error.code !== "ENOENT") throw error; } // Windows 전용 배포에는 macOS 소스가 없다.
  for (const [name, rustName, key, catalog, count] of [
    ["ClipTransition", "TRANSITIONS", "transitions", TRANSITIONS, 19],
    ["TextAnimation", "TEXT_ANIMATIONS", "textAnimations", TEXT_ANIMATIONS, 16],
    ["VisualFilter", "VISUAL_FILTERS", "visualFilters", VISUAL_FILTERS, 10],
  ]) {
    const rustBody = rust.match(new RegExp(`pub const ${rustName}:[^=]*=\\s*&\\[(.*?)\\];`, "s"));
    assert(rustBody, rustName + " Rust catalog exists");
    const rustIDs = [...rustBody[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
    assert.equal(catalog.length, count);
    assert.equal(fixture[key].length, count);
    assert.deepEqual(catalog.map((entry) => entry.id), fixture[key]);
    assert.deepEqual(rustIDs, fixture[key]);
    assert.equal(new Set(catalog.map((entry) => entry.id)).size, count);
    assert(catalog.every((entry) => entry.label && entry.icon && entry.category));
    if (swift) {
      const body = swift.split(`enum ${name}:`)[1].split("    var id:")[0];
      const ids = [...body.matchAll(/^    case (.+)$/gm)].flatMap((match) => match[1].split(",").map((id) => id.trim()));
      assert.deepEqual(ids, fixture[key], name + " local Mac catalog");
    }
  }
});

test("all transitions change the early frame, hide the exact boundary and restore the settled frame", () => {
  for (const { id } of TRANSITIONS.filter((entry) => entry.id !== "none")) {
    for (const entering of [true, false]) {
      const settings = { effect: id, duration: 0.5 };
      const early = transitionState(settings, 0.1, 2, entering, rect, canvas);
      assert.notDeepEqual(cssOnly(early), unchanged, id);
      assert.equal(transitionState(settings, 0, 2, entering, rect, canvas).opacity, 0, id);
      assert.deepEqual(cssOnly(transitionState(settings, 1, 2, entering, rect, canvas)), unchanged, id);
      assert(!/NaN|Infinity/.test(JSON.stringify(early)), id);
      assert(early.opacity >= 0 && early.opacity <= 1, id);
    }
  }
});

test("transition direction and elapsed time follow the clip boundary in canvas coordinates", () => {
  const state = (id, entering) => transitionState({ effect: id, duration: 0.5 }, 0.1, 2, entering, rect, canvas);
  assert.match(state("slideLeft", true).transform, /translateX\([\d.]+px\)/);
  assert.match(state("slideLeft", false).transform, /translateX\(-[\d.]+px\)/);
  assert.match(state("slideUp", true).transform, /translateY\([\d.]+px\)/);
  assert.match(state("slideUp", false).transform, /translateY\(-[\d.]+px\)/);
  assert.notEqual(state("wipeLeft", true).clipPath, state("wipeLeft", false).clipPath);
  assert.notEqual(state("wipeUp", true).clipPath, state("wipeUp", false).clipPath);
  assert.equal(state("fade", true).opacity, 0.2);
  assert(state("pixelate", true).pixelSize > 1);
  assert.match(state("iris", true).clipPath, /^circle\(/);
});

test("short or invalid transitions never overlap or produce nonfinite CSS", () => {
  assert.equal(clampedTransitionDuration({ effect: "fade", duration: 3 }, 0.2), 0.1);
  for (const settings of [null, { effect: "none", duration: 1 }, { effect: "future-effect", duration: 1 }, { effect: "fade", duration: NaN }, { effect: "fade", duration: -1 }]) {
    assert.deepEqual(cssOnly(transitionState(settings, 0, 2, true, rect, canvas)), unchanged);
  }
  assert.deepEqual(cssOnly(transitionState({ effect: "fade", duration: 1 }, NaN, 2, true, rect, canvas)), unchanged);
});

test("all text entrance effects settle exactly, with local time resetting for each caption", () => {
  for (const { id } of TEXT_ANIMATIONS.filter((entry) => entry.id !== "none")) {
    const style = { animation: id, animationDuration: 0.6 };
    const early = textMotionState(style, 0.02, 2, rect, canvas);
    if (id !== "typewriter") assert.notDeepEqual(cssOnly(early), unchanged, id);
    assert.deepEqual(cssOnly(textMotionState(style, 1, 2, rect, canvas)), unchanged, id);
    assert(!/NaN|Infinity/.test(JSON.stringify(early)), id);
    const first = textMotionState(style, 0.1 - 0, 1, rect, canvas), second = textMotionState(style, 1.6 - 1.5, 1, rect, canvas);
    assert(Math.abs(first.opacity - second.opacity) < 1e-12, id);
    assert.deepEqual(cssOnly(first).slice(1), cssOnly(second).slice(1), id);
  }
  assert.equal(textProgress({ animationDuration: 5 }, 0.1, 0.2), 1);
  assert.equal(textProgress({ animationDuration: 0 }, 0, 2), 1);
});

test("typewriter keeps Korean clusters, joined emoji and full multiline layout text", () => {
  const text = "한👩‍🏫글 🇰🇷\n다음 줄";
  assert.deepEqual(graphemes("한👩‍🏫글🇰🇷á"), ["한", "👩‍🏫", "글", "🇰🇷", "á"]);
  assert.equal(visibleCharacters("한👩‍🏫글", 0), 0);
  assert.equal(visibleCharacters("한👩‍🏫글", 1), 3);
  for (const progress of [0, 0.1, 0.3, 0.7, 1]) {
    const parts = revealTextParts(text, progress);
    assert.equal(parts.visible + parts.hidden, text);
    assert.equal(graphemes(parts.visible).length, parts.count);
  }
});

test("all visual looks have a finite CSS filter and zero intensity preserves the original", () => {
  for (const { id } of VISUAL_FILTERS.filter((entry) => entry.id !== "none")) {
    assert(visualFilterCSS(id), id);
    assert.equal(visualFilterCSS(id, 0), "", id);
    assert.equal(visualFilterCSS(id, -1), "", id);
    assert.equal(visualFilterCSS(id, 2), visualFilterCSS(id, 1), id);
    assert.equal(visualFilterCSS(id, NaN), visualFilterCSS(id, 1), id);
    assert(!/NaN|Infinity/.test(visualFilterCSS(id, 0.4)), id);
  }
  assert.equal(visualFilterCSS("none"), "");
  assert.equal(visualFilterCSS("future-filter"), "");
});

test("legacy fades remain multiplicative and audio windows clamp to half a clip", () => {
  const clip = { start: 2, sourceIn: 0, sourceOut: 2, speed: 1, fadeIn: 1, fadeOut: 1 };
  assert.equal(legacyFade(clip, 2), 0);
  assert.equal(legacyFade(clip, 2.5), 0.5);
  assert.equal(legacyFade(clip, 3), 1);
  assert.equal(legacyFade(clip, 3.5), 0.5);
  assert.equal(legacyFade({ ...clip, fadeIn: 8 }, 2.5, true), 0.5);
});

test("font families preserve hyphens and quote arbitrary names as a single CSS family", () => {
  assert.match(fontFamilyCSS("Noto-Sans-KR"), /^"Noto-Sans-KR",/);
  assert.match(fontFamilyCSS('A"; color:red; /*'), /^"A\\"; color:red; \/\*",/);
  assert(!fontFamilyCSS("line\nbreak").includes("\n"));
  assert.equal(fontFamilyCSS(""), fontFamilyCSS(".AppleSystemUIFont"));
});

// 최소 DOM으로 실제 Player·BlurLayer 연결과 RAF 취소 경계를 검사한다.
class Element {
  constructor(tag = "div") { this.tagName = tag.toUpperCase(); this.children = []; this.style = {}; this.dataset = {}; this.offsetWidth = 160; this.offsetHeight = 40; this.paused = true; this.currentTime = 0; }
  appendChild(child) { child.remove(); this.children.push(child); child.parentNode = this; return child; }
  append(...children) { children.forEach((child) => this.appendChild(child)); }
  insertBefore(child, before) { child.remove(); const at = this.children.indexOf(before); this.children.splice(at < 0 ? this.children.length : at, 0, child); child.parentNode = this; }
  remove() { if (this.parentNode) { const at = this.parentNode.children.indexOf(this); if (at >= 0) this.parentNode.children.splice(at, 1); this.parentNode = null; } }
  after(child) { const parent = this.parentNode; child.remove(); parent.children.splice(parent.children.indexOf(this) + 1, 0, child); child.parentNode = parent; }
  get previousSibling() { return this.parentNode?.children[this.parentNode.children.indexOf(this) - 1] ?? null; }
  set innerHTML(_) { for (const child of this.children) child.parentNode = null; this.children = []; }
  querySelector(selector) { return this.children.find((child) => "#" + child.id === selector) ?? null; }
  pause() { this.paused = true; }
  play() { this.paused = false; return Promise.resolve(); }
  load() {}
  removeAttribute(name) { delete this[name]; }
}
const S = { project: null, time: 0, sel: new Set(), volume: 1 };
const U = {
  clipDur: (clip) => (clip.sourceOut - clip.sourceIn) / clip.speed,
  clipEnd: (clip) => clip.start + U.clipDur(clip),
  asset: (id) => S.project.assets.find((asset) => asset.id === id),
  duration: () => Math.max(0, ...S.project.tracks.flatMap((track) => track.clips.map(U.clipEnd))),
};
const playButton = new Element("button"), frames = [];
globalThis.document = { createElement: (tag) => new Element(tag), querySelector: () => playButton };
globalThis.window = { __TAURI__: { core: { convertFileSrc: (path) => path } }, devicePixelRatio: 1 };
globalThis.ResizeObserver = class { observe() {} };
globalThis.requestAnimationFrame = (callback) => { frames.push(callback); return frames.length; };
globalThis.__easycutPreviewTest = { S, U, onTime: (time) => { S.time = time; }, transitionState, textMotionState, textProgress, revealTextParts, graphemes, visualFilterCSS, legacyFade, fontFamilyCSS };
const moduleFrom = async (file, prefix) => {
  const source = (await readFile(new URL(file, import.meta.url), "utf8")).replace(/^import .*;\r?$/gm, "");
  return import("data:text/javascript;base64," + Buffer.from(prefix + "\n" + source).toString("base64"));
};
const { BlurLayer } = await moduleFrom("../ui/privacy.js", "const {S,U}=globalThis.__easycutPreviewTest;");
globalThis.__easycutPreviewTest.BlurLayer = BlurLayer;
const { Player } = await moduleFrom("../ui/player.js", "const {S,U,onTime,BlurLayer,transitionState,textMotionState,textProgress,revealTextParts,graphemes,visualFilterCSS,legacyFade,fontFamilyCSS}=globalThis.__easycutPreviewTest;");
function playerFixture() {
  const box = new Element(), stage = new Element();
  for (const id of ["overlay", "video", "still"]) { const el = new Element(); el.id = id; box.appendChild(el); }
  const player = new Player(box, stage); player.cw = 320; player.ch = 180;
  return player;
}
const style = { fontSize: 54, bold: true, fontName: "Noto-Sans-KR", positionY: 0.5,
  textColor: { r: 1, g: 1, b: 1, a: 1 }, backgroundColor: { r: 0, g: 0, b: 0, a: 0 }, outline: false };
const clip = (id, patch = {}) => ({ id, kind: "media", assetID: "image", start: 0, sourceIn: 0, sourceOut: 2, speed: 1,
  volume: 1, opacity: 1, scale: 1, offsetX: 0, offsetY: 0, fadeIn: 0, fadeOut: 0, textStyle: style, ...patch });

test("media and privacy masks share one transformed wrapper while text retains its track order", () => {
  const text = clip("text", { kind: "text", text: "아래 텍스트", opacity: 0.7, transitionIn: { effect: "fade", duration: 0.5 } });
  const media = clip("media", { transitionIn: { effect: "slideLeft", duration: 0.5 }, visualFilter: "mono", blurs: [
    { x: 0.1, y: 0.1, w: 0.2, h: 0.2, start: 0, end: 2, style: "box" },
  ] });
  S.project = { tracks: [{ clips: [text] }, { clips: [media] }], assets: [{ id: "image", kind: "image", path: "/fixture.png", width: 320, height: 180 }], showCaptions: false };
  const player = playerFixture(); player.update(false, 0.1);
  const layer = player.layers.get("media"), mask = player.blur.fx.get("media");
  assert.equal(mask.parentNode, layer.content);
  assert.equal(player.els.get("media").parentNode, layer.content);
  assert.match(layer.entrance.style.transform, /translateX/);
  assert.match(layer.content.style.filter, /grayscale/);
  assert(+player.layers.get("text").root.style.zIndex < +layer.root.style.zIndex);
  assert.equal(player.layers.get("text").root.style.opacity, "0.7");
  assert.equal(player.layers.get("text").entrance.style.opacity, "0.2");
  assert.equal(player.layers.get("text").content.style.filter, "");
});

test("pause then immediate replay discards the old RAF clock instead of running two timelines", () => {
  S.project = { tracks: [{ clips: [clip("clock")] }], assets: [], showCaptions: false }; S.time = 0;
  frames.length = 0;
  const player = playerFixture(); player.update = () => {};
  player.play(); const oldFrame = frames.shift();
  player.pause(); player.play();
  assert.equal(frames.length, 1);
  oldFrame(player.last + 100);
  assert.equal(S.time, 0);
  assert.equal(frames.length, 1);
  frames.shift()(player.last + 100);
  assert(Math.abs(S.time - 0.1) < 0.0001);
  assert.equal(frames.length, 1);
  player.pause();
});

test("pixelation never resamples a raw frame with active privacy, including trim and speed timing", () => {
  const draws = [];
  const previous = Element.prototype.getContext;
  Element.prototype.getContext = function () {
    return { clearRect() {}, drawImage: (source) => draws.push(source) };
  };
  try {
    const player = playerFixture();
    const asset = { kind: "image", path: "/privacy.png", width: 320, height: 180 };
    const c = clip("protected", { sourceIn: 1, sourceOut: 5, speed: 2 });
    const el = player.element(c, asset), layer = player.layers.get(c.id);
    el._rect = { left: 0, top: 0, w: 320, h: 180 };
    layer.raster = new Element("canvas");
    layer.content.appendChild(layer.raster);
    S.time = 1.5; // 시간 이동 중 아직 이전 전역 시간이 남아 있는 상황도 재현한다.
    for (const style of ["blur", "mosaic", "box"]) {
      c.blurs = [{ x: 0.2, y: 0.2, w: 0.1, h: 0.1, start: 1.5, end: 2.5, style }];
      el.style.visibility = "hidden";
      layer.raster.style.display = "";
      player.pixelateMedia(layer, el, c, asset, 12, 0.5); // 원본 2초: 보호 구간 안
      assert.equal(draws.length, 0, style + " must not sample the private raw frame");
      assert.equal(el.style.visibility, "", style + " keeps the existing masked media visible");
      assert.equal(layer.raster.style.display, "none", style + " clears a raster from an earlier frame");
    }
    player.pixelateMedia(layer, el, c, asset, 12, 1.5); // 원본 4초: 보호 구간 밖
    assert.equal(draws[0], el, "unprotected intervals still produce the requested pixel effect");
    assert.equal(draws.length, 2);
    assert.equal(el.style.visibility, "hidden");
  } finally {
    if (previous) Element.prototype.getContext = previous;
    else delete Element.prototype.getContext;
  }
});
