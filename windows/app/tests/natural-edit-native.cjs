// Runs against the real packaged WebView2 app on a disposable Windows runner.
// Test-generated canvas/audio is used instead of recording the runner's desktop.
const { chromium } = require('playwright-core');
const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  let browser, lastError;
  for (let n=0;n<60;n++) {
    try { browser = await chromium.connectOverCDP('http://127.0.0.1:9222'); break; }
    catch (e) { lastError = e; await new Promise(r => setTimeout(r,1000)); }
  }
  if (!browser) console.error('Last CDP error:',lastError?.message);
  assert(browser, 'WebView2 remote debugging endpoint did not start');
  const page = browser.contexts()[0].pages().find(p=>p.url().includes('tauri')) || browser.contexts()[0].pages()[0];
  page.setDefaultTimeout(30000);
  await page.waitForFunction(()=>window.__TAURI__?.core && document.querySelector('#natural-edit'));
  const events=[]; page.on('pageerror',e=>events.push(e.message));
  // New users can set up Gemini without installing either CLI or owning a subscription.
  await page.click('[data-tab="ai"]');
  await page.selectOption('#ai-backend','gemini');
  await page.waitForSelector('#gemini-key');
  assert.equal(await page.locator('#gemini-key').getAttribute('type'),'password');
  assert.equal(await page.locator('#ai-model').isDisabled(),true);
  assert.equal(await page.locator('#ai-effort').isDisabled(),true);
  assert.match(await page.locator('#tab-ai').textContent(),/Google AI Studio/);
  assert.match(await page.locator('#tab-ai').textContent(),/한도/);
  await page.click('#gemini-key-help > summary');
  assert.equal(await page.locator('#gemini-key-help').evaluate(el=>el.open),true);
  assert.match(await page.locator('#gemini-key-help').textContent(),/Create API key/);
  assert.match(await page.locator('#gemini-key-help').textContent(),/Free Tier/);
  await page.locator('#gemini-key-docs').scrollIntoViewIfNeeded();
  assert.equal(await page.locator('#gemini-key-docs').isVisible(),true);
  await page.screenshot({path:process.env.EASYCUT_NATIVE_OUTPUT+'/gemini-key-guide.png'});
  await page.click('#gemini-key-help > summary');
  await page.click('#gemini-save'); // Empty key must not be stored or sent.
  const agents = await page.evaluate(()=>window.__TAURI__.core.invoke('ai_agents'));
  assert.equal(agents.hasGeminiKey,false);
  const keyCheck = await page.evaluate(async()=>{
    try { await window.__TAURI__.core.invoke('ai_check_gemini'); return 'unexpected success'; }
    catch(e) { return String(e); }
  });
  assert.match(keyCheck,/키를 먼저/);
  await page.screenshot({path:process.env.EASYCUT_NATIVE_OUTPUT+'/gemini-setup.png'});
  await page.click('[data-tab="media"]');
  console.log('NATIVE GEMINI FREE-TIER ONBOARDING PASSED (no key or network call)');
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
  const gutter = await page.evaluate(() => {
    const scroller=document.querySelector('#tl-scroll');
    return scroller.offsetHeight-scroller.clientHeight;
  });
  assert(gutter >= 12, 'Timeline horizontal scrollbar must reserve visible space without hover');
  await page.mouse.move(0,0);
  await page.screenshot({path:process.env.EASYCUT_NATIVE_OUTPUT+'/persistent-scrollbar.png'});
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
  await page.click('#ne-cancel');
  const speedEvidence = await page.evaluate(async () => {
    const invoke=window.__TAURI__.core.invoke;
    let state=await invoke('get_state');
    const original=state.project.tracks.flatMap(t=>t.clips)[0];
    const length=(original.sourceOut-original.sourceIn)/original.speed;
    const a=length/3, b=length*2/3;
    await invoke('split',{time:a,ids:[]});
    await invoke('split',{time:b,ids:[]});
    await invoke('clear_captions');
    for(const [time,text] of [[a/2,'before'],[a+(b-a)/4,'inside'],[b+a/4,'after']]) {
      await invoke('add_caption',{time,end:time+0.3,text});
    }
    state=await invoke('get_state');
    const caps=state.project.captions;
    const middle=state.project.tracks.flatMap(t=>t.clips).find(c=>Math.abs(c.start-a)<0.01);
    await invoke('set_speed',{ids:[middle.id],speed:2});
    const result=await invoke('get_state');
    const expected=[caps[0].start,a+(caps[1].start-a)/2,caps[2].start-(b-a)/2];
    result.project.captions.forEach((c,i)=>{
      if(Math.abs(c.start-expected[i])>0.001) throw new Error('Native partial-speed caption mismatch');
      if(c.id!==caps[i].id || c.text!==caps[i].text) throw new Error('Caption identity/content changed');
    });
    await invoke('undo');
    const restored=await invoke('get_state');
    restored.project.captions.forEach((c,i)=>{if(Math.abs(c.start-caps[i].start)>0.001)throw new Error('Caption undo mismatch');});
    await invoke('redo');
    const {S}=await import('./app.js');
    const {Timeline}=await import('./timeline.js');
    // Exercise the actual renderer with a full-scale peak: its video wave must exceed the old 45% area.
    const canvas=document.createElement('canvas'); canvas.width=300;canvas.height=100;
    const ctx=canvas.getContext('2d'); const rectangles=[];
    const fill=ctx.fillRect.bind(ctx); ctx.fillRect=(...args)=>{rectangles.push(args);fill(...args);};
    const asset=result.project.assets[0];
    const oldMedia=S.media, oldZoom=S.zoom;
    try {
      S.zoom=40; S.media={[asset.id]:{thumbs:[],peaks:Array(1000).fill(1)}};
      const renderer={ctx,round:Timeline.prototype.round};
      Timeline.prototype.media.call(renderer,{sourceIn:0,speed:1},asset,'video',0,0,200,52,0,200);
    } finally {S.media=oldMedia;S.zoom=oldZoom;}
    const maxWave=Math.max(...rectangles.filter(r=>r[2]===1.5).map(r=>r[3]));
    if(maxWave<28) throw new Error('Native video waveform remains too short: '+maxWave);
    return {captions:result.project.captions,expected,waveHeight:maxWave};
  });
  fs.writeFileSync(process.env.EASYCUT_NATIVE_OUTPUT+'/speed-caption-waveform.json',JSON.stringify(speedEvidence,null,2));
  await page.screenshot({path:process.env.EASYCUT_NATIVE_OUTPUT+'/speed-caption-waveform.png'});
  console.log('NATIVE PARTIAL SPEED + CAPTION UNDO/REDO + WAVEFORM PASSED',JSON.stringify(speedEvidence));
  assert.deepEqual(events,[]);
  console.log('NATIVE NATURAL EDIT DIALOG + BACKUP/RESTORE PASSED (live AI provider not exercised)');
  await browser.close();
})().catch(e=>{console.error(e);process.exit(1);});
