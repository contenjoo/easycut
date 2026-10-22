// Runs against the real packaged WebView2 app on a disposable Windows runner.
// Test-generated canvas/audio is used instead of recording the runner's desktop.
const { chromium } = require('playwright-core');
const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  let browser;
  for (let n=0;n<60;n++) {
    try { browser = await chromium.connectOverCDP('http://127.0.0.1:9222'); break; }
    catch { await new Promise(r => setTimeout(r,1000)); }
  }
  assert(browser, 'WebView2 remote debugging endpoint did not start');
  const page = browser.contexts()[0].pages().find(p=>p.url().includes('tauri')) || browser.contexts()[0].pages()[0];
  page.setDefaultTimeout(30000);
  await page.waitForFunction(()=>window.__TAURI__?.core && document.querySelector('#natural-edit'));
  const events=[]; page.on('pageerror',e=>events.push(e.message));
  const speech = fs.readFileSync(process.env.EASYCUT_NATIVE_SPEECH).toString('base64');
  const recorded = await page.evaluate(async b64 => {
    const invoke = window.__TAURI__.core.invoke;
    await invoke('new_project');
    const bytes = Uint8Array.from(atob(b64),x=>x.charCodeAt(0));
    const context = new AudioContext(); await context.resume();
    const buffer = await context.decodeAudioData(bytes.buffer);
    const source = context.createBufferSource(); source.buffer=buffer;
    const destination=context.createMediaStreamDestination(); source.connect(destination);
    const canvas=document.createElement('canvas'); canvas.width=640;canvas.height=360;
    const ctx=canvas.getContext('2d'); let count=0;
    const timer=setInterval(()=>{ctx.fillStyle=count++%2?'#123456':'#234567';ctx.fillRect(0,0,640,360);ctx.fillStyle='white';ctx.font='30px sans-serif';ctx.fillText('EasyCut native recording test '+count,20,150);},100);
    const stream=canvas.captureStream(10);
    destination.stream.getAudioTracks().forEach(t=>stream.addTrack(t));
    const mime=MediaRecorder.isTypeSupported('video/webm;codecs=vp8,opus')?'video/webm;codecs=vp8,opus':'video/webm';
    await invoke('rec_begin',{kinds:[['screen','webm']]});
    const recorder=new MediaRecorder(stream,{mimeType:mime}); const chunks=[];
    recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data);};
    const stopped=new Promise((resolve,reject)=>{recorder.onstop=resolve;recorder.onerror=reject;});
    recorder.start(250); source.start();
    await new Promise(resolve=>source.onended=resolve);
    recorder.stop(); await stopped; clearInterval(timer);
    for(const blob of chunks) await invoke('rec_chunk',new Uint8Array(await blob.arrayBuffer()),{headers:{'x-kind':'screen'}});
    stream.getTracks().forEach(t=>t.stop());await context.close();
    const result=await invoke('rec_finish',{cameraCircle:false,clicks:[],showClicks:false,area:null});
    const state=await invoke('get_state');
    const asset=state.project.assets.find(a=>a.id===result.screen);
    if(!asset?.hasAudio || asset.duration<3)throw new Error('Recorded file missing audio or duration');
    await invoke('transcribe',{asset:asset.id,language:'en'});
    const transcribed=await invoke('get_state');
    const words=transcribed.project.assets.find(a=>a.id===asset.id).words;
    if(!words?.length)throw new Error('No words transcribed from real recording');
    return {asset:asset.id,duration:asset.duration,words:words.map(w=>w.text).join(' ')};
  },speech);
  assert.match(recorded.words.toLowerCase(), /video|windows|editor/);
  console.log('NATIVE RECORD → FILE → WHISPER',JSON.stringify(recorded));
  await page.click('#natural-edit');
  await page.check('#ne-file-on');
  await page.fill('#ne-filename','강의_소리꺼줘_자막추가.mp4');
  assert.equal(await page.locator('#ne-request').textContent(),'편집 요청: 소리꺼줘 · 자막추가');
  assert.equal(await page.locator('#ne-go').isEnabled(),true);
  await page.screenshot({path:process.env.EASYCUT_NATIVE_OUTPUT+'/natural-dialog.png'});
  // Native backup and restoration must span multiple actual edit commands.
  await page.evaluate(async()=>{
    const invoke=window.__TAURI__.core.invoke;
    const before=await invoke('get_state');
    await invoke('natural_edit_backup');
    const clip=before.project.tracks.flatMap(t=>t.clips)[0];
    await invoke('update_clip',{id:clip.id,props:{volume:0}});
    await invoke('update_project',{props:{canvasWidth:800,canvasHeight:600}});
    const restored=await invoke('natural_edit_restore');
    if(JSON.stringify(restored.project)!==JSON.stringify(before.project))throw new Error('Native draft restore changed project');
  });
  assert.deepEqual(events,[]);
  console.log('NATIVE NATURAL EDIT DIALOG + BACKUP/RESTORE PASSED (live AI provider not exercised)');
  await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
