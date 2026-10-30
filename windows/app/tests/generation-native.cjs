// Real Windows WebView2, credentials, editor and generation commands. The final
// flow substitutes only a disposable CLI response; Rust, worker and renderers are real.
const {chromium}=require('playwright-core');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
(async()=>{
  const browser=await chromium.connectOverCDP('http://127.0.0.1:9222');
  const page=browser.contexts()[0].pages().find(p=>p.url().includes('tauri'))||browser.contexts()[0].pages()[0];
  page.setDefaultTimeout(30000);
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const out=process.env.EASYCUT_NATIVE_OUTPUT;
  const fixture=JSON.parse(fs.readFileSync(process.env.EASYCUT_GENERATION_MANIFEST,'utf8')).fixtures[0];
  await page.waitForSelector('#video-create');
  const actual=await page.evaluate(async()=>{
    const invoke=window.__TAURI__.core.invoke;
    const caps=await invoke('generation_capabilities');
    const state=await invoke('generation_state');
    const invalid=[];
    for(const [command,args] of [['generation_save_key',{provider:'openai',key:''}],['generation_render',{jobId:'untrusted-job'}],['generation_import',{jobId:'untrusted-job'}],['generation_start',{request:{prompt:'',provider:'gemini',access:'subscription'}}]]){
      try{await invoke(command,args);throw new Error('unexpected success: '+command);}catch(e){invalid.push(String(e));}
    }
    return {caps,state,invalid};
  });
  assert.equal(actual.caps.skills.length,5);
  assert.equal(actual.state.busy,false);
  assert(actual.invalid.every(e=>!e.includes('unexpected success')));
  await page.click('#video-create');
  await page.waitForSelector('#video-generation');
  await page.fill('#video-prompt','프롬프트 보존 검사');
  await page.fill('#video-duration','6');
  await page.selectOption('#video-size','720x1280');
  await page.selectOption('#video-fps','24');
  await page.click('#video-advanced > summary');
  await page.selectOption('#video-renderer','remotion');
  for(const provider of ['claude','openai','gemini']){
    await page.selectOption('#video-provider',provider);
    if(provider!=='gemini'){
      assert.equal(await page.locator('#video-access').inputValue(),'subscription');
      assert.equal(await page.locator('#video-connect').isVisible(),true);
      await page.selectOption('#video-access','api');
    }else assert.equal(await page.locator('#video-access').count(),0);
    assert.equal(await page.locator('#video-api-key').getAttribute('type'),'password');
    assert.equal(await page.locator('#video-generate').isDisabled(),true);
    // Disposable runner: exercise actual Credential Manager without a paid account.
    await page.fill('#video-api-key','easycut-disposable-ci-not-a-real-key');
    await page.click('#video-save-key');
    await page.waitForFunction(()=>document.querySelector('#video-connection-state')?.textContent.includes('저장되어'));
    assert.equal(await page.locator('#video-api-key').inputValue(),'');
    assert.equal(await page.locator('#video-generate').isEnabled(),true);
    assert.equal(await page.locator('#video-prompt').inputValue(),'프롬프트 보존 검사');
    assert.equal(await page.locator('#video-duration').inputValue(),'6');
    assert.equal(await page.locator('#video-size').inputValue(),'720x1280');
    assert.equal(await page.locator('#video-fps').inputValue(),'24');
    await page.screenshot({path:path.join(out,`video-${provider}-api.png`)});
  }
  await page.click('[data-video-example="0"]');
  assert.match(await page.locator('#video-prompt').inputValue(),/물의 순환/);
  assert.equal(await page.locator('#video-duration').inputValue(),'6');
  await page.click('#video-skill-list > summary');
  assert.equal(await page.locator('#video-catalog .video-skill').count(),5);
  // Replace only generation job commands. Never call a paid provider during CI.
  await page.evaluate(fixture=>{
    const original=window.__TAURI__.core.invoke;
    const qa=window.__generationQA={original,fixture,phase:'ok',calls:[],state:{busy:false,status:'',error:null,previews:[],appliedSkills:[]}};
    window.__TAURI__.core.invoke=async(command,args)=>{
      if(!command.startsWith('generation_'))return original(command,args);
      qa.calls.push(command);
      if(command==='generation_state')return qa.state;
      if(command==='generation_start'){
        if(qa.phase==='error')throw new Error('CI 오류 화면 검사');
        qa.state={busy:qa.phase==='busy',status:qa.phase==='busy'?'작업 중':'샘플 4장 준비',error:null,jobId:'ci-approved-job',request:args.request,previews:qa.phase==='busy'?[]:fixture.previews,appliedSkills:fixture.skills,appliedSkillReason:'실제 렌더 검사 샘플'};
        return qa.state;
      }
      if(command==='generation_cancel'){qa.state={...qa.state,busy:false,status:'중지됨'};return;}
      if(command==='generation_render'){qa.state={...qa.state,outputPath:fixture.outputPath,status:'영상이 준비됐습니다'};return qa.state;}
      if(command==='generation_import'){
        await original('new_project');
        return original('import_files',{paths:[fixture.outputPath],place:[0,0]});
      }
      return original(command,args);
    };
  },fixture);
  await page.click('#video-generate');
  await page.waitForSelector('#video-previews img');
  assert.equal(await page.locator('#video-previews img').count(),4);
  await page.waitForFunction(()=>[...document.querySelectorAll('#video-previews img')].every(el=>el.complete&&el.naturalWidth===640));
  await page.click('[data-video-preview="0"]');
  assert.equal(await page.locator('#video-frame-dialog').evaluate(e=>e.open),true);
  await page.click('#video-frame-close');
  await page.fill('#video-prompt','바꾼 설명');
  assert.equal(await page.locator('#video-render').isDisabled(),true);
  assert.equal(await page.locator('#video-stale').isVisible(),true);
  await page.click('#video-generate');
  await page.waitForFunction(()=>!document.querySelector('#video-render')?.disabled);
  await page.locator('#video-render').scrollIntoViewIfNeeded();
  await page.screenshot({path:path.join(out,'video-four-real-previews.png')});
  await page.click('#video-render');
  await page.waitForSelector('#video-import');
  await page.click('#video-import');
  await page.waitForFunction(async()=>{
    const state=await window.__generationQA.original('get_state');
    return state.project.tracks.flatMap(t=>t.clips).length===1;
  });
  const imported=await page.evaluate(async()=>{
    const invoke=window.__generationQA.original;
    const state=await invoke('get_state');
    await invoke('undo');const undone=await invoke('get_state');
    await invoke('redo');return{state,undone};
  });
  assert.equal(imported.state.project.assets[0].width,640);
  assert.equal(imported.undone.project.tracks.flatMap(t=>t.clips).length,0);
  await page.screenshot({path:path.join(out,'video-render-and-import.png')});
  await page.evaluate(()=>window.__generationQA.phase='busy');
  await page.click('#video-generate');
  await page.waitForSelector('#video-stop');
  assert.equal(await page.locator('#video-prompt').isDisabled(),true);
  await page.click('#video-close');
  await page.click('#video-create');
  await page.waitForSelector('#video-stop');
  await page.click('#video-stop');
  await page.waitForFunction(()=>!document.querySelector('#video-prompt')?.disabled);
  await page.evaluate(()=>window.__generationQA.phase='error');
  await page.click('#video-generate');
  await page.waitForFunction(()=>document.querySelector('#video-error')?.textContent.includes('CI 오류'));
  await page.screenshot({path:path.join(out,'video-error-and-retry.png')});
  assert.equal(await page.locator('#video-generate').isEnabled(),true);
  await page.click('#video-close');
  // Resize the real native WebView viewport through CDP, without adding
  // application permissions for synthetic window resizing.
  const viewportCDP=await page.context().newCDPSession(page);
  try{
    await viewportCDP.send('Emulation.setDeviceMetricsOverride',{width:1100,height:580,deviceScaleFactor:1,mobile:false});
    await page.click('#video-create');
    for(const selector of ['#video-close','#video-generate']){
      const rect=await page.locator(selector).boundingBox();
      const viewport=await page.evaluate(()=>({w:innerWidth,h:innerHeight}));
      assert.equal(viewport.w,1100);assert.equal(viewport.h,580);
      assert(rect&&rect.y>=0&&rect.y+rect.height<=viewport.h&&rect.x+rect.width<=viewport.w,selector+' clipped in the native WebView viewport');
    }
    await page.screenshot({path:path.join(out,'video-minimum-window.png')});
    await page.click('#video-close');
  }finally{
    await viewportCDP.send('Emulation.clearDeviceMetricsOverride');
    await viewportCDP.detach();
  }
  await page.evaluate(()=>{window.__TAURI__.core.invoke=window.__generationQA.original;});
  // End-to-end native flow: only the disposable provider CLI is substituted.
  // No production fixture action, API transport or paid model is used here.
  assert.equal(process.platform,'win32','Native end-to-end fixture requires Windows');
  assert.equal(process.env.GITHUB_ACTIONS,'true','CLI fixtures are limited to disposable CI runners');
  const appData=path.join(process.env.APPDATA,'com.contenjoo.easycut.windows');
  const npmDir=path.join(process.env.APPDATA,'npm');
  const shim=path.join(npmDir,'codex.cmd');
  const script=path.join(npmDir,'node_modules','@openai','codex','bin','codex.js');
  const runtime=path.resolve(path.dirname(process.env.EASYCUT_GENERATION_MANIFEST),'runtime');
  const runtimeLink=path.join(appData,'video-runtime-v1');
  const cliTrace=path.join(out,'video-native-cli-calls.jsonl');
  for(const candidate of [shim,script,path.join(appData,'bin','codex.exe'),path.join(process.env.USERPROFILE,'.local','bin','codex.exe')]){
    assert(!fs.existsSync(candidate),'Refusing to replace an existing provider CLI: '+candidate);
  }
  assert(fs.existsSync(path.join(runtime,'node_modules','puppeteer-core','package.json')),'Real integration runtime is required');
  assert(!fs.existsSync(runtimeLink),'Refusing to replace an existing native render runtime');
  const scene={title:'Native Canvas CI',source:`function frame(i){
    const t=i/FPS;ctx.fillStyle='#25214a';ctx.fillRect(0,0,W,H);
    ctx.fillStyle='#ffc93c';ctx.beginPath();ctx.arc(W*(0.25+0.25*t),H*0.45,65,0,Math.PI*2);ctx.fill();
    ctx.fillStyle='#8dd3f6';ctx.font='bold 48px "Malgun Gothic",sans-serif';ctx.textAlign='center';ctx.fillText('Native Canvas',W/2,H*0.8);
  }
  function audio(t){return 0.08*Math.sin(2*Math.PI*330*t)*Math.max(0,Math.min(1,t*10,(DURATION-t)*10));}`};
  const cliSource=`// Disposable CI provider replies, never installed in a shipped app.\n`+
    `const fs=require('node:fs');const args=process.argv.slice(2);const trace=${JSON.stringify(cliTrace)};\n`+
    `const log=phase=>fs.appendFileSync(trace,JSON.stringify({phase})+'\\n');\n`+
    `if(args[0]==='login'&&args[1]==='status'){log('login');console.log('Logged in using ChatGPT');process.exit(0);}\n`+
    `if(args[0]!=='exec'){console.error('Unexpected CLI action');process.exit(2);}\n`+
    `let prompt='';process.stdin.setEncoding('utf8');process.stdin.on('data',s=>prompt+=s);process.stdin.on('end',()=>{\n`+
    `const selection=prompt.includes('You select creative guidance');log(selection?'skills':'source');\n`+
    `const reply=selection?{skillIDs:['visual-explainer'],reason:'CI fixture'}:${JSON.stringify(scene)};\n`+
    `console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:JSON.stringify(reply)}}));});\n`;
  let nativeFlow;
  fs.mkdirSync(path.dirname(script),{recursive:true});
  fs.mkdirSync(appData,{recursive:true});
  try{
    fs.writeFileSync(script,cliSource,'utf8');
    fs.writeFileSync(shim,`@echo off\r\n"${process.execPath}" "%~dp0node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n`,'utf8');
    fs.symlinkSync(runtime,runtimeLink,'junction');
    const nativeCaps=await page.evaluate(()=>window.__TAURI__.core.invoke('generation_capabilities'));
    assert.equal(nativeCaps.providers.openai.subscriptionReady,true);
    assert.equal(nativeCaps.providers.openai.installed,true);
    await page.evaluate(()=>window.__TAURI__.core.invoke('new_project'));
    await page.click('#video-create');
    await page.selectOption('#video-provider','openai');
    assert.equal(await page.locator('#video-access').inputValue(),'subscription');
    await page.fill('#video-prompt','Native CI: explain a moving circle, with synthesized sound.');
    await page.fill('#video-duration','2');
    await page.selectOption('#video-size','1280x720');
    await page.selectOption('#video-fps','24');
    await page.click('#video-advanced > summary');
    await page.selectOption('#video-renderer','canvas');
    await page.check('#video-skills');
    await page.waitForFunction(()=>!document.querySelector('#video-generate')?.disabled);
    await page.click('#video-generate');
    await page.waitForFunction(async()=>{
      const s=await window.__TAURI__.core.invoke('generation_state');
      return !s.busy&&(s.error||s.previews.length===4);
    },null,{timeout:180000});
    const preview=await page.evaluate(()=>window.__TAURI__.core.invoke('generation_state'));
    assert.equal(preview.error,null,preview.error||'Native preview failed');
    assert.equal(preview.previews.length,4);
    assert.equal(preview.appliedSkills.length,1);
    assert.equal(preview.appliedSkills[0].id,'visual-explainer');
    assert.equal(preview.appliedSkillReason,'CI fixture');
    assert.equal(preview.request.provider,'openai');assert.equal(preview.request.access,'subscription');
    assert.equal(preview.request.renderer,'canvas');assert.equal(preview.request.model,'codex-default');
    for(const file of preview.previews){
      const png=fs.readFileSync(file);assert.equal(png.readUInt32BE(16),1280);assert.equal(png.readUInt32BE(20),720);
    }
    assert(!fs.existsSync(path.join(path.dirname(preview.previews[0]),'render.mp4')),'Full video must wait for approval');
    await page.waitForFunction(()=>document.querySelectorAll('#video-previews img').length===4&&[...document.querySelectorAll('#video-previews img')].every(i=>i.complete&&i.naturalWidth===1280));
    await page.waitForFunction(()=>!document.querySelector('#video-render')?.disabled);
    await page.locator('#video-render').scrollIntoViewIfNeeded();
    await page.screenshot({path:path.join(out,'video-native-rust-worker-four-previews.png')});
    await page.click('#video-render');
    await page.waitForFunction(async()=>{
      const s=await window.__TAURI__.core.invoke('generation_state');return !s.busy&&(s.error||s.outputPath);
    },null,{timeout:180000});
    const rendered=await page.evaluate(()=>window.__TAURI__.core.invoke('generation_state'));
    assert.equal(rendered.error,null,rendered.error||'Native render failed');
    assert(rendered.outputPath&&fs.statSync(rendered.outputPath).size>1000);
    assert.equal(rendered.jobId,preview.jobId);
    await page.waitForSelector('#video-import');
    await page.click('#video-import');
    await page.waitForFunction(async()=>{
      const s=await window.__TAURI__.core.invoke('get_state');return s.project.tracks.flatMap(t=>t.clips).length===1;
    });
    const state=await page.evaluate(()=>window.__TAURI__.core.invoke('get_state'));
    assert.equal(state.project.assets.length,1);
    assert.equal(state.project.assets[0].width,1280);assert.equal(state.project.assets[0].height,720);
    assert(Math.abs(state.project.assets[0].duration-2)<0.2);
    await page.screenshot({path:path.join(out,'video-native-rust-worker-render-import.png')});
    await page.evaluate(()=>window.__TAURI__.core.invoke('undo'));
    const undone=await page.evaluate(()=>window.__TAURI__.core.invoke('get_state'));
    assert.equal(undone.project.tracks.flatMap(t=>t.clips).length,0);
    assert.equal(undone.project.assets.length,0);
    const calls=fs.readFileSync(cliTrace,'utf8').trim().split(/\r?\n/).map(line=>JSON.parse(line));
    assert(calls.filter(c=>c.phase==='login').length>=2);
    assert.equal(calls.filter(c=>c.phase==='skills').length,1);
    assert.equal(calls.filter(c=>c.phase==='source').length,1);
    nativeFlow={provider:'disposable Codex CLI response fixture',commands:'real Rust generation_start/render/import/undo',preview,rendered,asset:state.project.assets[0],undoClips:0,cliCalls:calls};
    await page.click('#video-close');
  }finally{
    if(fs.existsSync(runtimeLink)){try{fs.unlinkSync(runtimeLink);}catch(error){if(error.code==='EPERM'||error.code==='EISDIR')fs.rmdirSync(runtimeLink);else throw error;}}
    fs.rmSync(shim,{force:true});fs.rmSync(script,{force:true});
  }
  fs.writeFileSync(path.join(out,'video-ui-checks.json'),JSON.stringify({nativeCapabilities:{runtime:actual.caps.runtime,skillCount:actual.caps.skills.length},credentialManager:'3 providers round-tripped',nativeImport:imported.state.project.assets[0],uiProviderReplies:'controlled fixtures, no model call',nativeFlow,errors},null,2));
  assert.deepEqual(errors,[]);
  console.log('NATIVE VIDEO UI + CREDENTIAL MANAGER + REAL RUST/WORKER CANVAS PREVIEW/RENDER/IMPORT/UNDO PASSED (disposable CLI responses, zero paid model calls)');
  await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1;});
