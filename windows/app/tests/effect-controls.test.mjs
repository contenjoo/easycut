import test from "node:test";
import assert from "node:assert/strict";
import { normalizeFonts, filterFonts, initFontBrowser, loadInstalledFonts } from "../ui/font-browser.js";
import { effectGridHTML } from "../ui/effect-controls.js";
import { TRANSITIONS, TEXT_ANIMATIONS, VISUAL_FILTERS } from "../ui/effects.js";

globalThis.L = (text, ...args) => args.reduce((s, arg) => s.replace("{}", String(arg)), text);

const installed = normalizeFonts([
  { family: "Malgun Gothic", fontName: "Malgun Gothic", displayName: "Malgun Gothic" },
  { family: "NanumGothic", fontName: "NanumGothic", displayName: "Nanum Gothic" },
  { family: "NanumMyeongjo", fontName: "NanumMyeongjo", displayName: "Nanum Myeongjo" },
  { family: "Pretendard", fontName: "Pretendard", displayName: "Pretendard" },
  { family: "Arial", fontName: "Arial", displayName: "Arial" },
]);

test("font search accepts familiar Korean names without matching unrelated families", () => {
  assert.equal(filterFonts(installed, "  맑은 고딕  ")[0].fontName, "Malgun Gothic");
  assert.deepEqual(filterFonts(installed, "나눔").map((f) => f.family), ["NanumGothic", "NanumMyeongjo"]);
  assert.deepEqual(filterFonts(installed, "나눔 명조").map((f) => f.family), ["NanumMyeongjo"]);
  assert.equal(filterFonts(installed, "프리텐다드")[0].fontName, "Pretendard");
  assert.equal(filterFonts(installed, "ARIAL")[0].fontName, "Arial");
  assert.deepEqual(filterFonts(installed, "  "), installed);
  assert.deepEqual(filterFonts(installed, "missing-font-93e"), []);
});

test("catalog normalization keeps actual installed family names and excludes invalid duplicates", () => {
  const result = normalizeFonts([{ family: "Arial", fontName: "Arial Regular" }, { family: "arial" }, { family: "" }, {}, null]);
  assert.equal(result.length, 1);
  assert.equal(result[0].fontName, "Arial Regular");
  assert.equal(result[0].displayName, "Arial");
});

test("font command failure is explicit and a successful retry loads the real catalog", async () => {
  let calls = 0;
  initFontBrowser({ invoke: async () => { calls++; throw new Error("font service unavailable"); } });
  const failed = await loadInstalledFonts(true);
  assert.deepEqual(failed.fonts, []);
  assert.match(failed.error, /unavailable/);
  initFontBrowser({ invoke: async (command) => { calls++; assert.equal(command, "list_fonts"); return installed; } });
  const retried = await loadInstalledFonts(true);
  assert.equal(retried.error, null);
  assert.equal(retried.fonts.length, installed.length);
  assert.equal((await loadInstalledFonts()).fonts.length, installed.length);
  assert.equal(calls, 2, "successful catalog is reused between renders");
});

test("all effect families render named accessible choices with one selected card", () => {
  for (const [items, prefix] of [[TRANSITIONS, "transition"], [TEXT_ANIMATIONS, "text-effect"], [VISUAL_FILTERS, "visual-filter"]]) {
    const html = effectGridHTML(items, items[1].id, prefix);
    assert.equal((html.match(/<button /g) || []).length, items.length);
    assert.equal((html.match(/aria-pressed="true"/g) || []).length, 1);
    for (const item of items) assert.ok(html.includes(`data-testid="${prefix}-${item.id}"`));
  }
  const escaped = effectGridHTML([{ id: "custom", label: '<script>alert("x")</script>', icon: "○" }], "custom", "test");
  assert.ok(!escaped.includes("<script>"));
});
