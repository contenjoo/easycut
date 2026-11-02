// Headless regression against the real editor HTML/CSS/JS with an offline,
// explicitly mocked Tauri backend. This is not native Windows/Tauri evidence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
let playwright;
try { playwright = require('playwright-core'); }
catch (error) {
  const fallback = process.env.EASYCUT_PLAYWRIGHT_MODULE_DIR || '/private/tmp/easycut-windows-studio-tests/node_modules/playwright-core';
  if (!fs.existsSync(fallback)) throw error;
  playwright = require(fallback);
}

const uiRoot = path.resolve(__dirname, '../ui');
const evidence = path.resolve(process.env.EASYCUT_STUDIO_EVIDENCE || path.join(__dirname, '../../../output/windows-studio-20261102'));
const IMAGE_ID = 'fixture-image', TEXT_ID = 'fixture-title', CAPTION_ID = 'fixture-caption';
const white = { r: 1, g: 1, b: 1, a: 1 }, black = { r: 0, g: 0, b: 0, a: 1 };
const style = { fontSize: 80, fontName: '', bold: true, textColor: white, backgroundColor: { ...black, a: 0 }, outline: true, outlineColor: black, positionY: 0.45 };
const baseClip = { start: 0, sourceIn: 0, sourceOut: 3, speed: 1, volume: 1, opacity: 1, scale: 1, offsetX: 0, offsetY: 0, fadeIn: 0, fadeOut: 0, text: '', textStyle: style };
const fixtureProject = {
  version: 1, assets: [{ id: 'fixture-art', path: '/__fixture__/scene.svg', name: '오프라인 검사 이미지.svg', kind: 'image', duration: 3, width: 1280, height: 720, hasAudio: false }],
  tracks: [{ id: 'track-image', name: '트랙 1', hidden: false, muted: false, clips: [{ ...baseClip, id: IMAGE_ID, kind: 'media', assetID: 'fixture-art' }] },
    { id: 'track-title', name: '트랙 2', hidden: false, muted: false, clips: [{ ...baseClip, id: TEXT_ID, kind: 'text', text: '전환과 텍스트 효과' }] },
    { id: 'track-empty', name: '트랙 3', hidden: false, muted: false, clips: [] }],
  captions: [{ id: CAPTION_ID, start: 0.25, end: 2.75, text: '한글 자막 입력 검사' }],
  captionStyle: { ...style, fontSize: 54, positionY: 0.86, backgroundColor: { ...black, a: 0.6 } },
  canvasWidth: 1280, canvasHeight: 720, fps: 30, showCaptions: true, background: black,
};
const fixtureFonts = [
  { family: 'Malgun Gothic', fontName: 'Malgun Gothic', displayName: 'Malgun Gothic' },
  { family: 'NanumGothic', fontName: 'NanumGothic', displayName: 'Nanum Gothic' },
  { family: 'NanumMyeongjo', fontName: 'NanumMyeongjo', displayName: 'Nanum Myeongjo' },
  { family: 'Pretendard', fontName: 'Pretendard', displayName: 'Pretendard' },
  { family: 'Arial', fontName: 'Arial', displayName: 'Arial' },
];

function installFixtureBackend({ project: initial, fonts, failFonts }) {
  const copy = (v) => JSON.parse(JSON.stringify(v));
  let project = copy(initial), undo = [], redo = [], fontFailure = failFonts;
  const calls = [], listeners = new Map();
  const agents = { claude: { state: 'ready' }, codex: { state: 'ready' }, hasKey: false, hasGeminiKey: false, claudeInstalled: true, codexInstalled: true };
  const state = () => ({ project: copy(project), words: [], missing: [], path: null, dirty: undo.length > 0, canUndo: undo.length > 0, canRedo: redo.length > 0 });
  const edit = (f) => { undo.push(copy(project)); redo = []; f(); return state(); };
  window.__studioMock = { calls, snapshot: state, setFontFailure: (value) => { fontFailure = value; } };
  window.__TAURI__ = {
    core: {
      convertFileSrc: (file) => new URL(file, location.origin).href,
      invoke: async (command, args = {}) => {
        calls.push({ command, args: copy(args) });
        switch (command) {
          case 'get_state': return state();
          case 'update_clip': return edit(() => {
            const clip = project.tracks.flatMap((t) => t.clips).find((c) => c.id === args.id);
            if (!clip) throw new Error('Missing fixture clip');
            Object.assign(clip, copy(args.props));
          });
          case 'update_project': return edit(() => Object.assign(project, copy(args.props)));
          case 'update_caption': return edit(() => {
            const caption = project.captions.find((c) => c.id === args.id);
            for (const key of ['text', 'start', 'end']) if (args[key] != null) caption[key] = args[key];
          });
          case 'add_text': {
            const id = 'added-text-' + calls.length;
            const result = edit(() => project.tracks[1].clips.push({ ...copy(initial.tracks[1].clips[0]), id, start: args.time || 0, text: args.text }));
            return { ...result, select: [id] };
          }
          case 'undo': if (undo.length) { redo.push(copy(project)); project = undo.pop(); } return state();
          case 'redo': if (redo.length) { undo.push(copy(project)); project = redo.pop(); } return state();
          case 'list_fonts': if (fontFailure) throw new Error('fixture font command failed'); return copy(fonts);
          case 'media_thumbs': return [[0, '/__fixture__/scene.svg']];
          case 'media_peaks': return [];
          case 'get_prefs': return { recent: [], autosave: false };
          case 'ai_settings': return { settings: { backend: 'api', model: '', effort: '', showThinking: false }, models: [] };
          case 'ai_agents': case 'ai_refresh_agents': return copy(agents);
          case 'generation_state': return {};
          case 'generation_capabilities': return { providers: {}, skills: [], runtime: {} };
          case 'startup_files': return [];
          case 'recovery_check': case 'check_update': return null;
          case 'ui_state': case 'set_pref': return null;
          default: throw new Error('Unsupported offline fixture command: ' + command);
        }
      },
    },
    event: { listen: async (name, fn) => { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); return () => {}; } },
    dialog: { open: async () => null, save: async () => null },
  };
  localStorage.setItem('uiLang', 'ko');
  localStorage.removeItem('pane.left-w'); localStorage.removeItem('pane.right-w'); localStorage.removeItem('pane.tl-h');
}

const imageSVG = '<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><defs><linearGradient id="g"><stop stop-color="#243448"/><stop offset="1" stop-color="#576e86"/></linearGradient></defs><rect width="1280" height="720" fill="url(#g)"/><circle cx="1000" cy="160" r="180" fill="#e9b277" opacity=".7"/><path d="M0 600L320 250L680 650L1000 350L1280 690V720H0" fill="#123c45" opacity=".8"/></svg>';

async function serveUI() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/__fixture__/scene.svg') { res.writeHead(200, { 'Content-Type': 'image/svg+xml' }); return res.end(imageSVG); }
    if (url.pathname === '/favicon.ico') { res.writeHead(204); return res.end(); }
    let file;
    try { file = path.resolve(uiRoot, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname)); }
    catch (_) { res.writeHead(400); return res.end(); }
    if (!file.startsWith(uiRoot + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); return res.end(); }
    const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' }[path.extname(file)] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-store' }); fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}

async function selectFixtureClip(page, id) {
  // Test-fixture selection only: use the existing exported frontend state;
  // no test hook is added to the product and edits still use real DOM controls.
  await page.evaluate(async (clipID) => { const app = await import('/app.js'); app.S.sel = new Set([clipID]); app.S.selCap = null; window.dispatchEvent(new Event('selection')); }, id);
  await page.locator('[data-testid="inspector-tabs"]').waitFor();
}
async function snapshot(page) { return page.evaluate(() => window.__studioMock.snapshot()); }
async function clip(page, id) { const s = await snapshot(page); return s.project.tracks.flatMap((t) => t.clips).find((c) => c.id === id); }
async function waitClip(page, id, field, expected) {
  await page.waitForFunction(({ id, field, expected }) => {
    let value = window.__studioMock.snapshot().project.tracks.flatMap((t) => t.clips).find((c) => c.id === id);
    for (const part of field.split('.')) value = value?.[part];
    return value === expected;
  }, { id, field, expected });
}
async function setRange(locator, value) { await locator.evaluate((el, v) => { el.value = String(v); el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); }, value); }
async function visibleWithin(page, selector, parent = '#right') {
  const result = await page.locator(parent).locator(selector).evaluate((el, parentSelector) => {
    const r = el.getBoundingClientRect(), p = document.querySelector(parentSelector).getBoundingClientRect();
    return { visible: r.width > 0 && r.height > 0 && r.top >= p.top - 1 && r.left >= p.left - 1 && r.bottom <= p.bottom + 1 && r.right <= p.right + 1, rect: { top: r.top, bottom: r.bottom, left: r.left, right: r.right }, parent: { top: p.top, bottom: p.bottom, left: p.left, right: p.right } };
  }, parent);
  assert(result.visible, `${selector} is clipped: ${JSON.stringify(result)}`);
}

(async () => {
  fs.mkdirSync(evidence, { recursive: true });
  const { server, origin } = await serveUI();
  let browser;
  const pageErrors = [], consoleErrors = [], externalRequests = [];
  const manifest = { kind: 'offline Tauri fixture with real editor UI in headless browser', nativeWindowsEvidence: false, screenshots: [], checks: [] };
  try {
    const configured = process.env.EASYCUT_TEST_BROWSER || process.env.EASYCUT_GENERATION_BROWSER;
    const launch = { headless: true, args: ['--disable-background-networking', '--no-first-run'] };
    if (configured) launch.executablePath = configured;
    else if (process.platform === 'darwin') launch.executablePath = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    else if (process.platform === 'win32') launch.channel = 'msedge';
    browser = await playwright.chromium.launch(launch);
    const newFixturePage = async (failFonts = false) => {
      const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'ko-KR' });
      await context.addInitScript(installFixtureBackend, { project: fixtureProject, fonts: fixtureFonts, failFonts });
      await context.route('**/*', (route) => {
        if (new URL(route.request().url()).origin === origin) return route.continue();
        externalRequests.push(route.request().url()); return route.abort();
      });
      const page = await context.newPage();
      page.on('pageerror', (error) => pageErrors.push(error.message));
      page.on('console', (msg) => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
      await page.goto(origin, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.__studioMock?.calls.some((c) => c.command === 'startup_files'));
      return { context, page };
    };
    const { page } = await newFixturePage();
    const saveScreenshot = async (name) => { const file = path.join(evidence, name); await page.screenshot({ path: file }); manifest.screenshots.push(file); };

    await selectFixtureClip(page, TEXT_ID);
    await page.locator('#inspector [data-testid="font-browser-button"]').waitFor();
    await page.locator('#inspector [data-testid="inspector-tab-effects"]').click();
    assert.equal(await page.locator('#inspector [data-testid="text-effect-gallery"] .effect-card').count(), 16);
    await page.locator('#inspector [data-testid="text-effect-bounce"]').click();
    await waitClip(page, TEXT_ID, 'textStyle.animation', 'bounce');
    await setRange(page.locator('#inspector [data-effect-duration]'), 1.2);
    await waitClip(page, TEXT_ID, 'textStyle.animationDuration', 1.2);
    await page.locator('[data-cmd="undo"]').click();
    await waitClip(page, TEXT_ID, 'textStyle.animationDuration', undefined);
    await page.locator('[data-cmd="redo"]').click();
    await waitClip(page, TEXT_ID, 'textStyle.animationDuration', 1.2);
    manifest.checks.push('text gallery, animation duration, undo and redo');

    await page.locator('[data-mode="transition"]').click();
    assert.equal(await page.locator('#inspector [data-testid="transition-gallery"] .effect-card').count(), 19);
    await page.locator('[data-edge="transitionOut"]').click();
    await page.locator('#inspector [data-testid="transition-iris"]').click();
    await waitClip(page, TEXT_ID, 'transitionOut.effect', 'iris');
    await page.locator('#inspector [data-testid="transition-none"]').click();
    await waitClip(page, TEXT_ID, 'transitionOut', null);
    await page.locator('[data-edge="transitionIn"]').click();
    await page.locator('#inspector [data-testid="transition-slideLeft"]').click();
    await waitClip(page, TEXT_ID, 'transitionIn.effect', 'slideLeft');
    await setRange(page.locator('#inspector [data-effect-duration]'), 0.4);
    await waitClip(page, TEXT_ID, 'transitionIn.duration', 0.4);
    manifest.checks.push('transition gallery, start/end settings and clearing');

    await page.locator('[data-mode="text"]').click();
    await page.locator('#inspector [data-testid="effect-preview-button"]').click();
    await page.waitForFunction(async () => (await import('/app.js')).S.time > 0.08);
    const motion = await page.locator(`.preview-clip-layer[data-clip="${TEXT_ID}"]`).evaluate((layer) => layer.firstElementChild.firstElementChild.firstElementChild.style.transform);
    assert(motion && motion !== 'none', 'preview text has a time-based motion transform');
    await page.locator('#playBtn').click();
    manifest.checks.push('effect preview advances the real UI player and updates text motion');
    await saveScreenshot('text-effects-1440x900.png');

    await page.locator('#inspector [data-testid="inspector-tab-basic"]').click();
    await page.locator('#inspector [data-testid="font-browser-button"]').click();
    await page.locator('[data-testid="font-search-field"]').fill('나눔');
    assert.equal(await page.locator('#font-browser .font-result').count(), 2);
    await page.locator('#font-browser [data-family="NanumGothic"]').click();
    await waitClip(page, TEXT_ID, 'textStyle.fontName', 'NanumGothic');
    assert.equal(await page.locator('[data-testid="font-search-field"]').inputValue(), '나눔');
    await saveScreenshot('font-browser-korean-search.png');
    await page.locator('#font-browser .font-done').click();
    await page.locator('#font-browser').waitFor({ state: 'detached' });
    manifest.checks.push('installed-font dialog Korean aliases, real family value and focus retention');

    await selectFixtureClip(page, IMAGE_ID);
    await page.locator('[data-mode="filter"]').click();
    assert.equal(await page.locator('#inspector [data-testid="visual-filter-gallery"] .effect-card').count(), 10);
    await page.locator('#inspector [data-testid="visual-filter-warm"]').click();
    await waitClip(page, IMAGE_ID, 'visualFilter', 'warm');
    await setRange(page.locator('#inspector [data-effect-duration]'), 0.45);
    await waitClip(page, IMAGE_ID, 'filterIntensity', 0.45);
    const imageFilter = await page.locator(`.preview-clip-layer[data-clip="${IMAGE_ID}"]`).evaluate((layer) => layer.firstElementChild.firstElementChild.firstElementChild.firstElementChild.style.filter);
    assert.match(imageFilter, /sepia|saturate|temperature|matrix/i);
    manifest.checks.push('image filters and intensity update the preview');

    for (const viewport of [{ width: 1100, height: 680 }, { width: 1440, height: 900 }]) {
      await page.setViewportSize(viewport);
      await page.locator('[data-mode="transition"]').click();
      await page.locator('#inspector [data-testid="transition-fade"]').click();
      await waitClip(page, IMAGE_ID, 'transitionIn.effect', 'fade');
      await page.locator('.inspector-body').evaluate((el) => { el.scrollTop = 0; });
      for (const selector of ['[data-testid="inspector-context-header"]', '[data-testid="transition-edge-picker"]', '[data-effect-duration]', '[data-testid="effect-preview-button"]']) await visibleWithin(page, selector);
      const overflow = await page.evaluate(() => ({ width: document.documentElement.scrollWidth - innerWidth, height: document.documentElement.scrollHeight - innerHeight }));
      assert(overflow.width <= 1 && overflow.height <= 1, `document overflow at ${viewport.width}×${viewport.height}: ${JSON.stringify(overflow)}`);
      await visibleWithin(page, '[data-cmd="export"]', '#toolbar');
      // Capture a settled frame, while the start effect remains configured.
      await setRange(page.locator('#scrub-bar'), 0.4);
      await saveScreenshot(`studio-transitions-${viewport.width}x${viewport.height}.png`);
    }
    manifest.checks.push('1100×680 and 1440×900 responsive layout, no page overflow, visible pinned effect controls');

    await page.locator('[data-tab="captions"]').click();
    const captionEditor = page.locator(`.caplist .c[data-id="${CAPTION_ID}"] textarea`);
    await captionEditor.focus();
    await captionEditor.evaluate((el) => { window.__captionEditingNode = el; el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true })); el.value = '한글 조합 중'; el.dispatchEvent(new InputEvent('input', { data: '중', inputType: 'insertCompositionText', isComposing: true, bubbles: true })); });
    assert.equal(await captionEditor.evaluate((el) => document.activeElement === el && window.__captionEditingNode === el), true);
    assert.equal((await snapshot(page)).project.captions[0].text, '한글 자막 입력 검사');
    await captionEditor.evaluate((el) => { el.dispatchEvent(new CompositionEvent('compositionend', { data: el.value, bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); });
    await page.waitForFunction(() => window.__studioMock.snapshot().project.captions[0].text === '한글 조합 중');
    await page.locator('#inspector [data-testid="inspector-tab-effects"]').click();
    assert.equal(await page.locator('#inspector [data-testid="text-effect-gallery"] .effect-card').count(), 16);
    await page.locator('#inspector [data-testid="text-effect-typewriter"]').click();
    await page.waitForFunction(() => window.__studioMock.snapshot().project.captionStyle.animation === 'typewriter');
    await page.locator('#inspector [data-testid="effect-preview-button"]').click();
    await page.waitForFunction(async () => { const { S } = await import('/app.js'); return S.time >= 0.25 && S.time < 1; });
    await page.locator('#playBtn').click();
    manifest.checks.push('caption IME node retention, deferred commit and shared caption animation preview');

    const failed = await newFixturePage(true);
    await selectFixtureClip(failed.page, TEXT_ID);
    await failed.page.locator('#inspector [data-testid="font-browser-button"]').click();
    await failed.page.locator('.font-browser-status.warn').waitFor();
    assert.match(await failed.page.locator('.font-browser-status').innerText(), /불러오지 못|fixture font command failed/);
    assert.equal(await failed.page.locator('#font-browser .font-result').count(), 1, 'failure offers the system fallback, not a fabricated installed list');
    await failed.page.evaluate(() => window.__studioMock.setFontFailure(false));
    await failed.page.locator('.font-browser-status button').click();
    await failed.page.waitForFunction(() => document.querySelectorAll('#font-browser .font-results [data-family]').length > 5);
    assert.equal(await failed.page.locator('.font-browser-status.warn').count(), 0);
    const retryScreenshot = path.join(evidence, 'font-query-retry.png'); await failed.page.screenshot({ path: retryScreenshot }); manifest.screenshots.push(retryScreenshot);
    manifest.checks.push('font command failure, honest system fallback and successful retry');
    await failed.context.close();

    assert.deepEqual(pageErrors, [], 'no browser page errors');
    assert.deepEqual(consoleErrors, [], 'no unexpected browser console errors');
    assert.deepEqual(externalRequests, [], 'all test resources are offline');
    manifest.pageErrors = pageErrors; manifest.consoleErrors = consoleErrors; manifest.externalRequests = externalRequests;
    manifest.result = 'passed';
    fs.writeFileSync(path.join(evidence, 'studio-ui-manifest.json'), JSON.stringify(manifest, null, 2));
    console.log(`STUDIO UI FIXTURE CHECKS PASSED (${manifest.checks.length} flows; ${manifest.screenshots.length} screenshots)`);
    console.log(`Evidence: ${evidence}`);
  } catch (error) {
    manifest.result = 'failed'; manifest.error = error.stack || String(error); manifest.pageErrors = pageErrors; manifest.consoleErrors = consoleErrors;
    if (browser) for (const context of browser.contexts()) for (const page of context.pages()) { try { await page.screenshot({ path: path.join(evidence, `failure-${Date.now()}.png`) }); } catch (_) {} }
    fs.writeFileSync(path.join(evidence, 'studio-ui-manifest.json'), JSON.stringify(manifest, null, 2));
    throw error;
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
