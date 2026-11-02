// 실제 Windows WebView2 + 설치 앱의 Rust 명령을 검사한다. 모의 backend를 사용하지 않는다.
const { chromium } = require('playwright-core');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');

// WebView2 IPC의 명령 완료와 프런트엔드 재렌더링은 클릭보다 늦을 수 있다.
// 두 상태가 모두 반영된 뒤 다음 입력을 보내 이전 클립 복사본을 쓰지 않게 한다.
async function waitClip(page, id, field, expected) {
  await page.waitForFunction(async ({id, field, expected}) => {
    const result = await window.__TAURI__.core.invoke('get_state');
    const {S} = await import('./app.js');
    const read = project => {
      let value = project?.tracks.flatMap(t=>t.clips).find(c=>c.id===id);
      for (const key of field.split('.')) value = value?.[key];
      return value;
    };
    return read(result.project) === expected && read(S.project) === expected;
  }, {id, field, expected}, {polling:100, timeout:20000});
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  try {
    const page = browser.contexts()[0].pages().find(p => /tauri/.test(p.url())) || browser.contexts()[0].pages()[0];
    assert(page, 'The native WebView2 app page was not found');
    page.setDefaultTimeout(20000);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.waitForSelector('[data-testid="inspector-context-header"]');
    const inspector = page.locator('#inspector');
    const output = process.env.EASYCUT_NATIVE_OUTPUT;
    assert(output, 'EASYCUT_NATIVE_OUTPUT is required');
    fs.mkdirSync(output, {recursive:true});
    const state = await page.evaluate(async () => {
      const invoke = window.__TAURI__.core.invoke;
      const {setState, S} = await import('./app.js');
      setState(await invoke('new_project'));
      setState(await invoke('add_text', {time:0, text:'Windows 글꼴·효과 확인'}));
      const result = await invoke('get_state');
      const clip = result.project.tracks.flatMap(t=>t.clips).find(c=>c.kind==='text');
      setState(result);
      S.sel = new Set([clip.id]); S.selCap = null;
      window.dispatchEvent(new Event('selection'));
      return {id:clip.id};
    });
    await inspector.getByTestId('inspector-tab-effects').click();
    assert.equal(await inspector.locator('[data-testid="text-effect-gallery"] [data-effect]').count(), 16);
    await inspector.getByTestId('text-effect-bounce').click();
    await waitClip(page, state.id, 'textStyle.animation', 'bounce');
    const duration = inspector.locator('[data-effect-duration]');
    await duration.evaluate(input => {
      input.value='0.8';
      input.dispatchEvent(new Event('input',{bubbles:true}));
      input.dispatchEvent(new Event('change',{bubbles:true}));
    });
    await waitClip(page, state.id, 'textStyle.animationDuration', 0.8);
    await inspector.locator('[data-mode="transition"]').click();
    assert.equal(await inspector.locator('[data-testid="transition-gallery"] [data-effect]').count(),19);
    await inspector.getByTestId('transition-iris').click();
    await waitClip(page, state.id, 'transitionIn.effect', 'iris');
    await inspector.locator('[data-edge="transitionOut"]').click();
    await inspector.getByTestId('transition-flip').click();
    await waitClip(page, state.id, 'transitionOut.effect', 'flip');
    await waitClip(page, state.id, 'transitionIn.effect', 'iris');
    await inspector.getByTestId('inspector-tab-basic').click();
    const fonts = await page.evaluate(()=>window.__TAURI__.core.invoke('list_fonts'));
    assert(fonts.length > 10, 'Native Windows installed font catalog must contain actual fonts');
    const chosen = fonts.find(f=>/^Segoe UI$|^Arial$|^맑은 고딕$|^Malgun Gothic$/.test(f.family)) || fonts[0];
    await inspector.getByTestId('font-browser-button').click();
    await page.getByTestId('font-search-field').fill(chosen.family);
    const familySelector = await page.evaluate(family => CSS.escape(family), chosen.family);
    await page.locator(`#font-browser .font-result[data-family="${familySelector}"]`).click();
    await waitClip(page, state.id, 'textStyle.fontName', chosen.fontName);
    await page.locator('#font-browser .font-done').click();
    await page.screenshot({path:path.join(output,'studio-fonts-native.png')});
    await inspector.getByTestId('inspector-tab-effects').click();
    for (const viewport of [{width:1440,height:900},{width:1100,height:680}]) {
      // Emulation checks the WebView content; the app window keeps its native titlebar.
      await page.setViewportSize(viewport);
      assert(await inspector.getByTestId('inspector-context-header').isVisible());
      assert(await inspector.getByTestId('effect-preview-button').isVisible());
      assert(await inspector.getByTestId('transition-iris').isVisible());
      const overflow=await page.evaluate(()=>document.documentElement.scrollWidth > innerWidth+1);
      assert.equal(overflow,false,`page overflow at ${viewport.width}`);
      await page.screenshot({path:path.join(output,`studio-native-${viewport.width}.png`)});
    }
    const exportPath = path.join(output,'studio-native-export.mp4');
    await page.evaluate(async path => {
      await window.__TAURI__.core.invoke('export_video',{path,height:480,burnCaptions:true,format:'mp4',alsoSrt:false,range:null});
    },exportPath);
    assert(fs.statSync(exportPath).size>1000,'Native effect export did not produce a video');
    assert.deepEqual(errors,[],'WebView2 runtime errors');
    console.log('NATIVE WINDOWS STUDIO PASSED',JSON.stringify({fonts:fonts.length,font:chosen.family,export:exportPath}));
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
