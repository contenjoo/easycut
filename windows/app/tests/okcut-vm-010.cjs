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

function makeWav(filename, frequency) {
  const rate = 48000;
  const samples = rate * 3;
  const bytes = Buffer.alloc(44 + samples * 2);
  bytes.write('RIFF', 0);
  bytes.writeUInt32LE(bytes.length - 8, 4);
  bytes.write('WAVEfmt ', 8);
  bytes.writeUInt32LE(16, 16);
  bytes.writeUInt16LE(1, 20);
  bytes.writeUInt16LE(1, 22);
  bytes.writeUInt32LE(rate, 24);
  bytes.writeUInt32LE(rate * 2, 28);
  bytes.writeUInt16LE(2, 32);
  bytes.writeUInt16LE(16, 34);
  bytes.write('data', 36);
  bytes.writeUInt32LE(samples * 2, 40);
  for (let i=0; i<samples; i++) {
    const t = i / rate;
    const envelope = 0.11 * (0.2 + 0.8 * Math.sin(2 * Math.PI * 3 * t)**2);
    const signal = envelope * (Math.sin(2 * Math.PI * frequency * t) + 0.3 * Math.sin(2 * Math.PI * (frequency / 2) * t));
    bytes.writeInt16LE(Math.round(signal * 32767), 44 + 2 * i);
  }
  fs.writeFileSync(filename, bytes);
}

function measureMarker(filename, frequencyHz) {
  const ffmpeg=path.join(path.dirname(installed), 'resources/bin/ffmpeg.exe');
  const data=execFileSync(ffmpeg, ['-v','error','-i',filename,'-map','0:a:0','-ac','1','-ar','48000','-f','f32le','pipe:1'], {maxBuffer:12*1024*1024});
  const block=12000;
  let highest=0;
  let blocksAbove=0;
  for (let start=0; start+block<=data.length/4; start+=block) {
    let real=0,imag=0;
    for(let i=0;i<block;i++) {
      const angle=2*Math.PI*frequencyHz*i/48000;
      const sample=data.readFloatLE((start+i)*4);
      real+=sample*Math.cos(angle);
      imag+=sample*Math.sin(angle);
    }
    const peak=Math.hypot(real,imag)*2/block;
    highest=Math.max(highest,peak);
    if(peak>0.0015) blocksAbove++;
  }
  let peak=0,sumSquares=0;
  for(let i=0;i<data.length;i+=4) {
    const value=data.readFloatLE(i);
    peak=Math.max(peak,Math.abs(value));
    sumSquares+=value*value;
  }
  return {frequencyHz,strongestAmplitude:highest,blocksAbove,peak,rms:Math.sqrt(sumSquares/(data.length/4))};
}

const hasTone=stats=>stats?.blocksAbove>=2;
const micHz=613;
const systemHz=997;
const loopbackHelper=path.join(__dirname,'okcut-vm-loopback.ps1');

function measureInputs(filename) {
  if (!filename) return null;
  return {mic:measureMarker(filename,micHz),system:measureMarker(filename,systemHz)};
}

let cableActionIndex=0;
function cableAction(action) {
  const report=path.join(evidence,`cable-${++cableActionIndex}-${action}.json`);
  try {
    execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Sta','-File',loopbackHelper,'-Mode',action,'-EvidencePath',report],
      {stdio:'inherit',timeout:35000});
  } catch (error) {
    if(action==='Restart' || !fs.existsSync(report) || error.status!==2) throw error;
    console.log('Control-panel state was not confirmed; using the subsequent native audio measurement');
  }
}

async function probeFreshLoopback(wav) {
  const checkpoints={};
  async function sample(name) {
    const close=await startSoundFixture(wav);
    try {
      const file=path.join(evidence,`native-${name}.wav`);
      execFileSync('dotnet',[process.env.OKCUT_LOOPBACK_PROBE,file],{stdio:'inherit',timeout:15000});
      const stats=measureMarker(file,systemHz);
      checkpoints[name]=stats;
      fs.writeFileSync(path.join(evidence,'loopback-comparison.json'),JSON.stringify(checkpoints,null,2));
      console.log('Native loopback '+name+':',JSON.stringify(stats));
      return stats;
    } finally { await close(); }
  }
  await sample('01-clean-install');
  cableAction('Restart');
  await sample('02-restart-only');
  cableAction('Inspect');
  await sample('03-control-panel-inspected');
  cableAction('Enable');
  await sample('04-enabled-before-restart');
  cableAction('Restart');
  const first=await sample('05-enabled-after-restart');
  if(hasTone(first)) {
    cableAction('Disable');
    cableAction('Restart');
    await sample('06-disabled-again');
    cableAction('Enable');
    cableAction('Restart');
    await sample('07-reenabled');
  }
  return checkpoints;
}

async function startSoundFixture(wav) {
  const server=http.createServer((req,res)=>{
    if(req.url==='/tone.wav') {
      res.writeHead(200,{'Content-Type':'audio/wav','Content-Length':fs.statSync(wav).size});
      fs.createReadStream(wav).pipe(res);
    } else if(req.url==='/') {
      res.writeHead(200,{'Content-Type':'text/html'});
      res.end('<!doctype html><title>OK Cut QA computer sound fixture</title><audio loop controls src="/tone.wav"></audio><button id="play" onclick="document.querySelector(\'audio\').play()">Play test sound</button>');
    } else { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let edge;
  const close=async()=>{ if(edge) await edge.close(); server.close(); };
  try {
    edge=await chromium.launch({channel:'msedge',headless:false});
    const page=await edge.newPage();
    await page.goto('http://127.0.0.1:'+server.address().port);
    await page.locator('#play').click();
    await page.waitForFunction(()=>document.querySelector('audio').currentTime>0.4);
    console.log('Separate Edge process is playing the unmuted test signal through Windows speakers');
    return close;
  } catch(error) { await close(); throw error; }
}

async function playExport(output) {
  const player = '<!doctype html><meta charset="utf-8"><title>OK Cut exported MP4 playback</title>' +
    '<h1>OK Cut 0.10.0 — exported MP4</h1><button id="play">Play with sound</button>' +
    '<video controls playsinline src="/export.mp4" style="width:95vw;max-height:76vh"></video>';
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
    await page.evaluate(() => {
      const v=document.querySelector('video');
      document.querySelector('#play').onclick=async () => {
        const audio=new AudioContext();
        const analyser=audio.createAnalyser();
        audio.createMediaElementSource(v).connect(analyser);
        analyser.connect(audio.destination);
        window.playbackAudio={audio,analyser};
        await audio.resume();
        await v.play();
      };
    });
    await page.locator('#play').click();
    await page.waitForFunction(() => document.querySelector('video').currentTime > 0.15);
    const opened = await page.evaluate(async () => {
      const v = document.querySelector('video');
      const canvas = document.createElement('canvas');
      canvas.width = 32;
      canvas.height = 24;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      const observed = new Set();
      const meter=new Float32Array(window.playbackAudio.analyser.fftSize);
      let audioRms=0;
      const deadline = performance.now() + 8000;
      while (performance.now() < deadline && !v.error) {
        ctx.drawImage(v, 0, 0, canvas.width, canvas.height);
        const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data;
        let red=0,blue=0;
        for(let i=0;i<rgba.length;i+=4) {
          const [r,g,b]=rgba.subarray(i,i+3);
          if (r>160 && g<110 && b<115) red++;
          if (b>165 && r<110 && g<130) blue++;
        }
        if (red>140) observed.add('red');
        if (blue>140) observed.add('blue');
        window.playbackAudio.analyser.getFloatTimeDomainData(meter);
        const rms=Math.sqrt(meter.reduce((sum,x) => sum+x*x,0)/meter.length);
        audioRms=Math.max(audioRms,rms);
        if (v.currentTime > 3 && observed.size === 2 && audioRms>0.003) break;
        await new Promise(resolve => setTimeout(resolve, 120));
      }
      return {
        secondsPlayed: v.currentTime, duration: v.duration,
        decodedFrames: v.getVideoPlaybackQuality().totalVideoFrames,
        fixtureColors: [...observed], audioRms, muted:v.muted, audioContext:window.playbackAudio.audio.state, error: v.error?.message ?? null
      };
    });
    await page.screenshot({ path: path.join(evidence, 'export-playing-in-edge.png') });
    assert.equal(opened.error, null);
    assert(opened.secondsPlayed > 2 && opened.decodedFrames > 10, 'MP4 did not advance in Edge');
    assert.equal(opened.fixtureColors.length, 2, 'Missing changing Windows fixture colors in the decoded MP4');
    assert.equal(opened.muted,false);
    assert.equal(opened.audioContext,'running');
    assert(opened.audioRms>0.003,'Edge playback audio was silent');
    return opened;
  } finally {
    if (edge) await edge.close();
    server.close();
  }
}

(async () => {
  assert(installed && evidence);
  const testWav=path.join(process.env.RUNNER_TEMP,'system-signal.wav');
  const micWav=path.join(process.env.RUNNER_TEMP,'okcut-mic-fixture.wav');
  makeWav(testWav,systemHz);
  makeWav(micWav,micHz);
  const nativeReference=await probeFreshLoopback(testWav);
  const fixture = spawn('powershell.exe', psArgs('Fixture'), { stdio: 'inherit' });
  const stopSound=await startSoundFixture(testWav);
  await delay(1800);
  const app = spawn(installed, [], { stdio: 'ignore' });
  let browser;
  let page;
  try {
    browser = await until(async () => {
      assert.equal(app.exitCode, null, 'The public installed app exited before UI automation');
      try { return await chromium.connectOverCDP('http://127.0.0.1:9222', { timeout: 2000 }); }
      catch { return null; }
    }, 'The installed WebView2 did not launch');
    const context = browser.contexts()[0];
    page = await until(() => context.pages().find(p => /tauri/.test(p.url())), 'App page missing');
    page.on('pageerror', error => console.error(`App error: ${error}`));
    page.on('console', msg => {
      if (msg.type() === 'error' || msg.text().startsWith('Real media input:')) console.log(`App console: ${msg.text()}`);
    });
    await page.waitForFunction(() => document.querySelector('#rec-btn')?.onclick && document.querySelector('#title')?.textContent.trim());
    await context.grantPermissions(['microphone'],{origin:new URL(page.url()).origin});
    await page.evaluate(() => {
      for (const name of ['getUserMedia','getDisplayMedia']) {
        const original=navigator.mediaDevices[name].bind(navigator.mediaDevices);
        navigator.mediaDevices[name]=async options=>{
          try {
            const stream=await original(options);
            console.log('Real media input: '+JSON.stringify({name,options,tracks:stream.getTracks().map(t=>({kind:t.kind,label:t.label,settings:t.getSettings()}))}));
            return stream;
          } catch(error) {
            console.log('Real media input: '+JSON.stringify({name,options,error:{name:error.name,message:error.message,constraint:error.constraint}}));
            throw error;
          }
        };
      }
    });
    ui('FocusApp', String(app.pid));
    await page.locator('#rec-btn').click();
    await page.locator('#r-go').waitFor();
    assert.equal(await page.locator('#r-target').inputValue(),'monitor');
    for (const id of ['#r-cam','#r-clicks','#r-spoken']) {
      const box=page.locator(id);
      if (await box.isEnabled()) await box.setChecked(false);
    }
    assert(await page.locator('#r-mic').isEnabled(),'Installed WebView2 app could not see the virtual Windows microphone');
    await page.locator('#r-mic').setChecked(true);
    await page.locator('#r-sys').setChecked(true);
    const exactMic=await page.locator('#r-mic-id option').evaluateAll(options=>options.find(o=>/fake|file/i.test(o.label))?.value);
    if(exactMic) await page.locator('#r-mic-id').selectOption(exactMic);
    const devices=await page.evaluate(async () => (await navigator.mediaDevices.enumerateDevices()).map(d=>({kind:d.kind,label:d.label})));
    console.log('WebView2 audio devices:',JSON.stringify(devices));
    fs.writeFileSync(path.join(evidence,'webview-devices.json'),JSON.stringify(devices,null,2));
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
    const {screen:captured,system} = await until(async () => {
      const data = await page.evaluate(() => window.__TAURI__.core.invoke('get_state'));
      const timeline=data.project.tracks.flatMap(t=>t.clips);
      const screen=data.project.assets.find(a=>a.kind==='video' && a.duration>2 && timeline.some(c=>c.assetID===a.id));
      if(!screen) return null;
      const system=data.project.assets.find(a=>a.hasAudio && a.kind==='audio' && data.project.tracks[2]?.clips.some(c=>c.assetID===a.id));
      return {screen,system};
    }, 'Recording did not land on the real edit timeline', 45000);
    fixture.kill();
    await stopSound();
    console.log('Real Windows capture:', JSON.stringify({ duration: captured.duration, width: captured.width, height: captured.height, mic:captured.hasAudio, system:!!system, bytes: fs.statSync(captured.path).size }));
    assert(captured.width>=1000 && captured.height>=700,'Expected a monitor-size recording');
    assert(system,'No separate computer audio clip landed on track 3');
    const inputTones={mic:captured.hasAudio?measureInputs(captured.path):null,system:measureInputs(system.path)};
    fs.copyFileSync(captured.path,path.join(evidence,'screen-capture-with-mic.mp4'));
    fs.copyFileSync(system.path,path.join(evidence,'separate-system-audio.m4a'));
    console.log('Capture file test tones:',JSON.stringify(inputTones));
    await page.locator('button[data-cmd="export"]').click();
    await page.locator('#e-fmt').waitFor();
    assert.equal(await page.locator('#e-fmt').inputValue(), 'mp4');
    await page.locator('#e-res').selectOption('720');
    await page.locator('#e-go').click();
    const output = path.join(evidence, 'okcut-0.10.0-fullscreen-with-audio.mp4');
    ui('Save', output);
    await page.locator('#e-play').waitFor({ timeout: 90000 });
    await page.screenshot({ path: path.join(evidence, 'mp4-export-complete.png') });
    const ffprobe = path.join(path.dirname(installed), 'resources/bin/ffprobe.exe');
    const metadata = JSON.parse(execFileSync(ffprobe, ['-v','error','-show_streams','-show_format','-of','json',output], { encoding: 'utf8' }));
    const stream = metadata.streams.find(s => s.codec_type === 'video');
    assert.equal(stream.codec_name, 'h264');
    assert.equal(stream.height, 720);
    assert(Number(metadata.format.duration) > 3);
    const audio=metadata.streams.find(s=>s.codec_type==='audio');
    assert.equal(audio.codec_name,'aac');
    const exportTone=measureInputs(output);
    console.log('App export:', JSON.stringify({ codec: stream.codec_name, width: stream.width, height: stream.height, duration: metadata.format.duration, bytes: metadata.format.size }));
    const playback = await playExport(output);
    const result = {
      captured: { duration: captured.duration, width: captured.width, height: captured.height },
      export: { codec: stream.codec_name, width: stream.width, height: stream.height, duration: Number(metadata.format.duration), bytes: Number(metadata.format.size) },
      inputs:inputTones, nativeReference, exportTone, playback
    };
    fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify(result, null, 2));
    assert(hasTone(inputTones.mic?.mic), '613Hz WAV is missing from microphone capture');
    assert(hasTone(inputTones.system?.system), '997Hz is missing from true Windows system capture');
    assert(inputTones.mic.system.strongestAmplitude < inputTones.mic.mic.strongestAmplitude * 0.08,
      'System sound leaked into the independent microphone stimulus');
    assert(inputTones.system.mic.strongestAmplitude < inputTones.system.system.strongestAmplitude * 0.08,
      'Microphone stimulus leaked into Windows system capture');
    assert(hasTone(exportTone.mic) && hasTone(exportTone.system),
      'Export is missing one or both independently captured frequencies');
    console.log('REAL WINDOWS RECORDING -> APP EXPORT -> EDGE PLAYBACK PASSED', JSON.stringify(result));
  } catch (error) {
    if (page && !page.isClosed()) {
      try {
        console.error('App state:', JSON.stringify(await page.evaluate(() => ({
          modalOpen: !document.querySelector('#modal')?.classList.contains('hidden'),
          modal: document.querySelector('#modal-box')?.textContent,
          toast: document.querySelector('#toast')?.textContent,
          focused: document.hasFocus()
        }))));
      } catch {}
    }
    try { ui('Screenshot', path.join(evidence, 'final-desktop.png')); } catch {}
    throw error;
  } finally {
    if (browser) await browser.close().catch(() => {});
    app.kill();
    fixture.kill();
    await stopSound().catch(()=>{});
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
