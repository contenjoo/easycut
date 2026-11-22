// Exercise the studio window with isolated synthetic devices on the Windows runner.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { chromium } = require('playwright-core');

const output = process.env.EASYCUT_NATIVE_OUTPUT;
const additionalSessions = new Set();
const bin = path.join(process.env.LOCALAPPDATA, 'EasyCut', 'resources', 'bin');
const ffmpeg = path.join(bin, 'ffmpeg.exe');
const ffprobe = path.join(bin, 'ffprobe.exe');

function installDevices() {
  // Install after the test has verified the product actually opened its studio.
  function camera(color) {
    const canvas = document.createElement('canvas');
    canvas.width = 640; canvas.height = 360;
    const ctx = canvas.getContext('2d');
    let n = 0;
    const paint = () => {
      ctx.fillStyle = color; ctx.fillRect(0, 0, 640, 360);
      ctx.fillStyle = 'white'; ctx.fillRect((n++ % 60) * 10, 345, 4, 4);
    };
    paint(); setInterval(paint, 50);
    return canvas.captureStream(20);
  }
  async function tone(frequency) {
    const audio = new AudioContext();
    await audio.resume();
    const dest = audio.createMediaStreamDestination();
    const osc = audio.createOscillator();
    osc.frequency.value = frequency;
    const gain = audio.createGain();
    gain.gain.value = .15;
    osc.connect(gain).connect(dest); osc.start();
    return dest.stream;
  }
  Object.defineProperties(navigator.mediaDevices, {
    getDisplayMedia: { value: async opts => {
      const screen = camera('#1858ce');
      if (opts.audio) screen.addTrack((await tone(880)).getAudioTracks()[0]);
      return screen;
    } },
    getUserMedia: { value: async opts => opts.video ? camera('#e66020') : tone(440) }
  });
}

// Compare the scene seen by a viewer with the edit produced after reopening the file.
function inspectVideo(file, expectedCamera) {
  const streams = JSON.parse(execFileSync(ffprobe, ['-v','error','-show_streams','-of','json',file])).streams;
  assert(streams.some(s => s.codec_name === 'h264'));
  assert(streams.some(s => s.codec_name === 'aac'));
  const pcm = execFileSync(ffmpeg, ['-v','error','-i',file,'-vn','-ac','1','-ar','8000','-t','4','-f','s16le','pipe:1']);
  let peak = 0;
  for (let i = 0; i + 1 < pcm.length; i += 2) peak = Math.max(peak, Math.abs(pcm.readInt16LE(i)));
  const toneLevel = frequency => {
    let real = 0, imag = 0;
    const start = 4000, size = 8000;
    assert(pcm.length >= (start + size) * 2);
    for (let i = 0; i < size; i++) {
      const sample = pcm.readInt16LE((start + i) * 2);
      const angle = 2 * Math.PI * frequency * i / 8000;
      real += sample * Math.cos(angle);
      imag += sample * Math.sin(angle);
    }
    return Math.round(2 * Math.hypot(real,imag) / size);
  };
  const audio = {microphone440:toneLevel(440), computer880:toneLevel(880), reference1100:toneLevel(1100)};
  assert(Math.min(audio.microphone440,audio.computer880) > Math.max(200,5*audio.reference1100),
    'Expected independent microphone and computer audio in ' + path.basename(file));
  const frames = execFileSync(ffmpeg, ['-v','error','-i',file,'-an','-vf','fps=4,scale=64:36',
    '-pix_fmt','rgb24','-f','rawvideo','pipe:1'], {maxBuffer:16 * 1024 * 1024});
  const phases = [];
  const changes = [];
  let cameraBox;
  const stride = 64 * 36 * 3;
  for (let at = 0; at + stride <= frames.length; at += stride) {
    let orange = 0, blue = 0;
    let left = 64, top = 36, right = -1, bottom = -1;
    for (let px = at; px < at + stride; px += 3) {
      const r = frames[px], b = frames[px+2];
      if (r > 140 && r-b > 70) {
        orange++;
        const pixel = (px - at) / 3;
        const x = pixel % 64, y = Math.floor(pixel / 64);
        left = Math.min(left,x); right = Math.max(right,x);
        top = Math.min(top,y); bottom = Math.max(bottom,y);
      }
      if (b > 120 && b-r > 70) blue++;
    }
    const total = 64 * 36;
    const shape = orange/total > .88 ? 'camera' : blue/total > .88 && orange/total < .01 ? 'screen' : orange > 20 && blue > 20 ? 'combined' : 'other';
    if (phases.at(-1) !== shape) {
      phases.push(shape);
      changes.push({scene:shape, seconds:at / stride / 4});
    }
    if (shape === 'combined') cameraBox = [left/64,top/36,(right-left+1)/64,(bottom-top+1)/36];
  }
  const screen = phases.indexOf('screen');
  const camera = phases.indexOf('camera', screen + 1);
  assert(screen >= 0 && camera > screen && phases.indexOf('combined', camera + 1) > camera,
    path.basename(file) + ' has unexpected scene order ' + phases.join(','));
  assert.equal(expectedCamera.length, 4);
  cameraBox.forEach((value, i) => {
    const pixels = Math.abs(value - expectedCamera[i]) * (i % 2 === 0 ? 64 : 36);
    assert(pixels <= 2, path.basename(file) + ' changed the custom camera bounds: ' + JSON.stringify(cameraBox));
  });
  return {phases, changes, peak, audio, expectedCamera, cameraBox};
}

async function openStudio(editor) {
  const browser = editor.context().browser();
  await editor.locator('[data-cmd=studio]').first().click();
  let diagnostic;
  for (let attempt = 0; attempt < 45; attempt++) {
    const find = client => client.contexts().flatMap(c => c.pages()).find(page => /\/studio\.html(?:$|[?#])/.test(page.url()));
    const page = find(browser);
    if (page) return page;
    const targets = await fetch('http://127.0.0.1:9222/json/list').then(r => r.json());
    if (targets.some(t => /\/studio\.html(?:$|[?#])/.test(t.url))) {
      const fresh = await chromium.connectOverCDP('http://127.0.0.1:9222');
      const studio = find(fresh);
      if (studio) { additionalSessions.add(fresh); return studio; }
      await fresh.close();
    }
    if (attempt % 8 === 0) {
      diagnostic = await editor.evaluate(async () => ({
        windows:(await window.__TAURI__.window.getAllWindows()).map(w => w.label),
        toast:document.querySelector('#toast')?.textContent,
      }));
      console.log('Studio target discovery', diagnostic, targets.filter(t=>t.type==='page').map(t=>new URL(t.url).pathname));
      if (diagnostic.toast && /WebView2|0x800|webview creation/i.test(diagnostic.toast)) throw Error(diagnostic.toast);
    }
    await delay(500);
  }
  throw Error('Studio did not expose a WebView2 page. Native window state: ' + JSON.stringify(diagnostic));
}

async function waitForEdit(editor, studio) {
  // rec_finish remuxes the original streams before committing the project. Await
  // native IPC from Node; a Promise in a browser polling predicate can be truthy.
  const deadline = Date.now() + 90000;
  let counts;
  do {
    counts = await editor.evaluate(async () => {
      const {project} = await window.__TAURI__.core.invoke('get_state');
      return {assets:project.assets.length, clips:project.tracks.flatMap(t => t.clips).length};
    });
    if (counts.assets >= 2 && counts.clips >= 4 && studio.isClosed()) return;
    if (!studio.isClosed() && await studio.locator('body').getAttribute('data-phase').catch(() => '') === 'done') {
      throw Error('Studio could not finish: ' + await studio.locator('#notice').textContent());
    }
    await delay(200);
  } while (Date.now() < deadline);
  throw Error('Recording did not reach the editor: ' + JSON.stringify(counts));
}

// This mode is explicitly dispatched for one already-private, non-reusable event. It
// exercises the same Windows UI and encoder while the channel owner retains OAuth.
async function privateYouTube(editor) {
  assert(process.env.EASYCUT_PRIVATE_LIVE_TEST_KEY, 'Missing single-event test destination');
  await editor.evaluate(() => window.__TAURI__.core.invoke('new_project'));
  const studio = await openStudio(editor);
  await studio.waitForSelector('#prepare');
  await studio.evaluate(installDevices);
  await studio.selectOption('#output','rtmp');
  await studio.fill('#server','rtmps://a.rtmps.youtube.com:443/live2');
  await studio.locator('#key').evaluate((input, key) => { input.value = key; }, process.env.EASYCUT_PRIVATE_LIVE_TEST_KEY);
  delete process.env.EASYCUT_PRIVATE_LIVE_TEST_KEY;
  await studio.check('#camera'); await studio.check('#mic'); await studio.check('#system');
  await studio.click('#prepare');
  await studio.waitForSelector('body[data-phase="ready"]');
  await studio.click('#scenes button[value=screen]');
  let expectedCamera;
  try {
    await studio.click('#go');
    await studio.waitForSelector('body[data-phase="recording"]');
    await studio.waitForFunction(() => /송출 중$|Streaming$|Live$/i.test(document.querySelector('#status').textContent),null,{timeout:45000});
    await delay(18000);
    await studio.click('#scenes button[value=camera]');
    await delay(14000);
    await studio.click('#edit-layout');
    await studio.selectOption('#layer','camera');
    await studio.click('#shrink');
    await studio.click('#apply-layout');
    expectedCamera = await studio.evaluate(() => JSON.parse(localStorage.getItem('easycut.studio.customLayout.v1')).camera);
    await delay(25000);
    assert.match(await studio.locator('#status').textContent(), /송출 중$|Streaming$|Live$/i);
  } finally {
    if (await studio.locator('#stop').isVisible().catch(()=>false)) await studio.click('#stop');
  }
  await waitForEdit(editor,studio);
  // Only the verification measurements belong in the CI evidence artifact.
  const privateFiles = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'easycut-private-'));
  const file = path.join(privateFiles,'youtube-reopened.easycut');
  const movie = path.join(privateFiles,'youtube-reopened.mp4');
  const proof = await editor.evaluate(async file => {
    const invoke = window.__TAURI__.core.invoke;
    const saved = await invoke('save_project',{path:file});
    await invoke('new_project');
    const reopened = await invoke('open_project',{path:file});
    if (JSON.stringify(saved.project.tracks) !== JSON.stringify(reopened.project.tracks)) throw Error('Track round trip mismatch');
    return {clips:reopened.project.tracks.flatMap(t=>t.clips).length};
  },file);
  await editor.evaluate(movie => window.__TAURI__.core.invoke('export_video',{path:movie,height:480,burnCaptions:false,format:'mp4',alsoSrt:false,range:null}),movie);
  proof.export = inspectVideo(movie, expectedCamera);
  fs.writeFileSync(path.join(output,'youtube-windows.json'),JSON.stringify(proof,null,2));
  console.log('WINDOWS PRIVATE INGEST AND REOPENED EDIT',JSON.stringify(proof));
}

(async () => {
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const ctx = browser.contexts()[0];
  const editor = ctx.pages().find(page => page.url().includes('tauri'));
  assert(editor, 'Missing editor window');
  if (process.argv.includes('--private-youtube')) {
    try { await privateYouTube(editor); } finally { await browser.close(); }
    return;
  }
  const state = (command, args) => editor.evaluate(([cmd, arg]) => window.__TAURI__.core.invoke(cmd, arg), [command, args]);
  const privatePort = net.createServer();
  privatePort.listen(0, '127.0.0.1');
  await once(privatePort, 'listening');
  const port = privatePort.address().port;
  await new Promise(resolve => privatePort.close(resolve));
  const viewer = path.join(output, 'broadcast-viewer.flv');
  const projectPath = path.join(output, 'broadcast-session.easycut');
  const movie = path.join(output, 'broadcast-reopened.mp4');
  let receiver, studio;
  try {
    await state('new_project');
    studio = await openStudio(editor);
    await studio.waitForSelector('#prepare');
    await studio.evaluate(installDevices);
    const account = await studio.evaluate(() => window.__TAURI__.core.invoke('youtube_account_status'));
    assert.equal(account.configured, true, 'Missing bundled desktop client');
    assert.equal(account.connected, false, 'Runner must be signed out');
    await studio.selectOption('#output','youtube');
    await studio.waitForSelector('#connect');
    assert.equal(await studio.inputValue('#privacy'), 'private');
    await studio.selectOption('#output','rtmp');
    await studio.fill('#server','rtmp://127.0.0.1:' + port + '/live');
    await studio.fill('#key','synthetic');
    await studio.check('#camera'); await studio.check('#mic'); await studio.check('#system');
    await studio.click('#prepare');
    await studio.waitForSelector('body[data-phase="ready"]');
    await studio.click('#scenes button[value=screen]');
    receiver = spawn(ffmpeg, ['-hide_banner','-loglevel','error','-y','-listen','1','-i',
      'rtmp://127.0.0.1:' + port + '/live/synthetic','-c','copy','-f','flv',viewer],
      {stdio:['ignore','ignore','inherit'],windowsHide:true});
    const received = once(receiver, 'close');
    await delay(800);
    await studio.click('#go');
    await studio.waitForSelector('body[data-phase="recording"]');
    await delay(2600);
    await studio.click('#scenes button[value=camera]');
    await delay(2100);
    await studio.click('#edit-layout');
    await studio.selectOption('#layer','camera');
    await studio.click('#shrink');
    await studio.locator('[data-dx="1"]').first().click();
    await studio.click('#apply-layout');
    const expectedCamera = await studio.evaluate(() => JSON.parse(localStorage.getItem('easycut.studio.customLayout.v1')).camera);
    await delay(2600);
    await studio.screenshot({path:path.join(output, 'broadcast-custom.png')});
    await studio.click('#stop');
    await waitForEdit(editor,studio);
    const saved = await state('save_project', {path:projectPath});
    await state('new_project');
    const reopened = await state('open_project', {path:projectPath});
    assert.deepEqual(reopened.project.tracks, saved.project.tracks);
    const clips = reopened.project.tracks.flatMap(t => t.clips);
    assert(clips.some(c => Math.abs(c.offsetX) + Math.abs(c.offsetY) > .01));
    assert(clips.some(c => c.scale > 0 && c.scale < .99));
    await state('export_video', {path:movie,height:480,burnCaptions:false,format:'mp4',alsoSrt:false,range:null});
    await Promise.race([received, delay(15000, 'timeout', {ref:false}).then(() => {throw Error('Receiver failed to finish');})]);
    const proof = {accountConfigured:account.configured, clips:clips.length,
      rtmp:inspectVideo(viewer, expectedCamera), reopened:inspectVideo(movie, expectedCamera)};
    fs.writeFileSync(path.join(output,'broadcast-results.json'),JSON.stringify(proof,null,2));
    console.log('NATIVE WINDOWS BROADCAST → RTMP → REOPENED EDIT', JSON.stringify(proof));
  } catch (error) {
    if (studio && !studio.isClosed()) {
      console.error('Studio status:', await studio.locator('body').getAttribute('data-phase'),
        await studio.locator('#notice').textContent().catch(()=>''));
      await studio.screenshot({path:path.join(output,'broadcast-failure.png')}).catch(()=>{});
    }
    throw error;
  } finally {
    if (receiver && receiver.exitCode === null) receiver.kill();
    await browser.close();
  }
})().finally(() => Promise.all([...additionalSessions].map(client => client.close())))
  .catch(error => { console.error(error); process.exitCode = 1; });
