const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn, execFileSync } = require('node:child_process');
const { chromium } = require('playwright-core');

const evidence = process.env.OKCUT_EVIDENCE;
const installed = process.env.OKCUT_EXE;
const helper = path.join(__dirname, 'okcut-vm-ui.ps1');
const psArgs = (...args) => ['-NoProfile', '-NonInteractive', '-Sta', '-File', helper, ...args];
const ui = (...args) => execFileSync('powershell.exe', psArgs(...args), { stdio: 'inherit', timeout: 35000 });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function until(check, message, timeout = 30000) {
  const deadline = Date.now() + timeout;
  do {
    const result = await check();
    if (result) return result;
    await delay(300);
  } while (Date.now() < deadline);
  throw new Error(message);
}

async function playExport(output) {
  const player = '<!doctype html><meta charset="utf-8"><title>OK Cut exported MP4 playback</title>' +
    '<h1>OK Cut 0.10.0 — exported MP4</h1><video controls muted playsinline src="/export.mp4" style="width:95vw;max-height:76vh"></video>';
  const server = http.createServer((req, res) => {
    if (req.url === '/export.mp4') {
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': fs.statSync(output).size });
      fs.createReadStream(output).pipe(res);
    } else if (req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(player);
    } else { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let edge;
  try {
    edge = await chromium.launch({ channel: 'msedge', headless: false });
    const page = await edge.newPage({ viewport: { width: 1040, height: 700 } });
    await page.goto('http://127.0.0.1:' + server.address().port);
    const video = page.locator('video');
    await video.evaluate(v => v.play());
    const opened = await page.evaluate(async () => {
      const v = document.querySelector('video');
      const canvas = document.createElement('canvas');
      canvas.width = 32;
      canvas.height = 24;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      const observed = new Set();
      const deadline = performance.now() + 8000;
      while (performance.now() < deadline && !v.error) {
        ctx.drawImage(v, 0, 0, canvas.width, canvas.height);
        const [r, g, b] = ctx.getImageData(7, 17, 1, 1).data;
        if (r > 160 && g < 110 && b < 115) observed.add('red');
        if (b > 165 && r < 110 && g < 130) observed.add('blue');
        if (v.currentTime > 2 && observed.size === 2) break;
        await new Promise(resolve => setTimeout(resolve, 120));
      }
      return {
        secondsPlayed: v.currentTime, duration: v.duration,
        decodedFrames: v.getVideoPlaybackQuality().totalVideoFrames,
        fixtureColors: [...observed], error: v.error?.message ?? null
      };
    });
    await page.screenshot({ path: path.join(evidence, 'export-playing-in-edge.png') });
    assert.equal(opened.error, null);
    assert(opened.secondsPlayed > 2 && opened.decodedFrames > 10, 'MP4 did not advance in Edge');
    assert.equal(opened.fixtureColors.length, 2, 'Missing changing Windows fixture colors in the decoded MP4');
    return opened;
  } finally {
    if (edge) await edge.close();
    server.close();
  }
}

(async () => {
  assert(installed && evidence);
  const fixture = spawn('powershell.exe', psArgs('Fixture'), { stdio: 'inherit' });
  await delay(1800);
  const app = spawn(installed, [], { stdio: 'ignore' });
  let browser;
  try {
    browser = await until(async () => {
      try { return await chromium.connectOverCDP('http://127.0.0.1:9222', { timeout: 2000 }); }
      catch { return null; }
    }, 'The installed WebView2 did not launch');
    const context = browser.contexts()[0];
    const page = await until(() => context.pages().find(p => /tauri/.test(p.url())), 'App page missing');
    await page.locator('#rec-btn').click();
    await page.locator('#r-go').waitFor();
    if (await page.locator('#r-target').inputValue() !== 'window') {
      await page.locator('#r-target').selectOption('window');
      await page.locator('#r-go').waitFor();
    }
    for (const id of ['#r-cam', '#r-mic', '#r-sys', '#r-clicks']) {
      const box = page.locator(id);
      if (await box.isEnabled()) await box.setChecked(false);
    }
    await page.screenshot({ path: path.join(evidence, 'app-record-dialog.png') });
    await page.locator('#r-go').click();
    ui('Pick');
    const panel = await until(() => context.pages().find(p => /\/panel\.html/.test(p.url())), 'Recording controller did not open');
    await panel.locator('#dot.blink').waitFor({ timeout: 30000 });
    ui('Focus');
    await delay(1200);
    ui('Screenshot', path.join(evidence, 'windows-desktop-recording.png'));
    await delay(5200);
    await panel.locator('#stop').click();
    const captured = await until(async () => {
      const data = await page.evaluate(() => window.__TAURI__.core.invoke('get_state'));
      const asset = data.project.assets.find(a => a.kind === 'video' && a.duration > 2);
      return asset && data.project.tracks.some(t => t.clips.some(c => c.assetID === asset.id)) && asset;
    }, 'Recording did not land on the real edit timeline', 45000);
    assert(fs.statSync(captured.path).size > 1000, 'Recorded file was not written to disk');
    console.log('Real Windows capture:', JSON.stringify({ duration: captured.duration, width: captured.width, height: captured.height, bytes: fs.statSync(captured.path).size }));
    fixture.kill();
    await page.locator('button[data-cmd="export"]').click();
    await page.locator('#e-fmt').waitFor();
    assert.equal(await page.locator('#e-fmt').inputValue(), 'mp4');
    await page.locator('#e-res').selectOption('720');
    await page.locator('#e-go').click();
    const output = path.join(evidence, 'okcut-0.10.0-windows-screen.mp4');
    ui('Save', output);
    await page.locator('#e-play').waitFor({ timeout: 90000 });
    await page.screenshot({ path: path.join(evidence, 'mp4-export-complete.png') });
    const ffprobe = path.join(path.dirname(installed), 'resources/bin/ffprobe.exe');
    const metadata = JSON.parse(execFileSync(ffprobe, ['-v','error','-show_streams','-show_format','-of','json',output], { encoding: 'utf8' }));
    const stream = metadata.streams.find(s => s.codec_type === 'video');
    assert.equal(stream.codec_name, 'h264');
    assert.equal(stream.height, 720);
    assert(Number(metadata.format.duration) > 3);
    console.log('App export:', JSON.stringify({ codec: stream.codec_name, width: stream.width, height: stream.height, duration: metadata.format.duration, bytes: metadata.format.size }));
    const playback = await playExport(output);
    const result = {
      captured: { duration: captured.duration, width: captured.width, height: captured.height },
      export: { codec: stream.codec_name, width: stream.width, height: stream.height, duration: Number(metadata.format.duration), bytes: Number(metadata.format.size) },
      playback
    };
    fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify(result, null, 2));
    console.log('REAL WINDOWS RECORDING -> APP EXPORT -> EDGE PLAYBACK PASSED', JSON.stringify(result));
  } finally {
    if (browser) await browser.close().catch(() => {});
    app.kill();
    fixture.kill();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
