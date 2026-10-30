'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const worker=require('../src-tauri/resources/generation/worker.cjs');

const request=(patch={})=>({renderer:'canvas',provider:'claude',access:'subscription',model:'claude-opus-5-5',automaticSkills:true,prompt:'한글 기술 검증',duration:2,width:640,height:360,fps:30,...patch});
const source={title:'기술 검증',source:"function frame(i){ctx.fillStyle='#123';ctx.fillRect(0,0,W,H);}\nfunction audio(t){return 0;}"};
const j=v=>JSON.stringify(v);
const openAI=text=>({status:'completed',output:[{type:'reasoning',content:[{type:'output_text',text:'not final'}]},{type:'message',content:[{type:'output_text',text}]}]});
const gemini=text=>({candidates:[{finishReason:'STOP',content:{parts:[{thought:true,text:'not final'},{text}]}}]});
const claude=text=>({type:'message',stop_reason:'end_turn',content:[{type:'thinking',thinking:'not final'},{type:'text',text}]});

test('request preserves creative choices and validates finite supported settings',()=>{
  assert.deepEqual(worker.validateRequest(request()),request());
  assert.equal(worker.validateRequest(request({access:'api',provider:'openai',model:'gpt-6.1-sol'})).provider,'openai');
  for(const patch of [{prompt:' '},{prompt:'가'.repeat(20001)},{duration:NaN},{duration:Infinity},{duration:1},{duration:61},{width:641},{height:318},{fps:25},{provider:'unknown'},{renderer:'other'},{access:'untrusted'},{provider:'gemini',access:'subscription'},{model:'x\n'},{model:'x?key=oops'}]) assert.throws(()=>worker.validateRequest(request(patch)));
});

test('Claude envelopes and code fences preserve the complete Korean source',()=>{
  assert.deepEqual(worker.decodeSource(j(source),'canvas'),source);
  assert.deepEqual(worker.decodeSource(j({result:j(source)}),'canvas'),source);
  assert.deepEqual(worker.decodeSource(j({result:'```json\n'+j(source)+'\n```'}),'canvas'),source);
  assert.deepEqual(worker.decodeSource(j({structured_output:source}),'canvas'),source);
  assert.throws(()=>worker.decodeSource(j({is_error:true,result:'private server text'}),'canvas'));
});

test('source contract rejects common network, process, import and mutable-time mistakes',()=>{
  const additions=["fetch('https://invalid')", "require('child_process')", 'Math.random()', 'Date.now()', 'performance.now()', 'setInterval(()=>{},10)', "import x from 'anything';"];
  for(const addition of additions) assert.throws(()=>worker.decodeSource(j({...source,source:source.source+'\n'+addition}),'canvas'));
  assert.throws(()=>worker.decodeSource(j({...source,source:'function frame(i){ ctx.fillRect(0,0,W,H); }'}),'canvas'));
  const remotion="import React from 'react'; import {AbsoluteFill} from 'remotion'; export default function Scene(){return <AbsoluteFill/>;}";
  assert.equal(worker.decodeSource(j({title:'React',source:remotion}),'remotion').source,remotion);
  assert.throws(()=>worker.decodeSource(j({title:'React',source:"import a from 'left-pad';"+remotion}),'remotion'));
});

test('selection accepts only reviewed unique IDs and can choose no unnecessary skill',()=>{
  const catalog=worker.loadCatalog();assert.equal(catalog.catalog.length,5);
  assert.equal(new Set(catalog.catalog.map(s=>s.id)).size,5);
  assert(catalog.catalog.every(s=>s.sourceURL.startsWith('https://') && s.revision && s.instructions));
  const selected=worker.decodeSelection(j({skillIDs:['visual-explainer'],reason:'원인과 결과'}));
  assert.deepEqual(selected.skills.map(s=>s.id),['visual-explainer']);
  assert.equal(selected.catalogVersion,catalog.version);
  assert.deepEqual(worker.decodeSelection(j({skillIDs:[],reason:'단순한 장면'})).skills,[]);
  for(const v of [{skillIDs:['unknown'],reason:'검사'},{skillIDs:['visual-explainer','visual-explainer'],reason:'검사'},{skillIDs:catalog.catalog.slice(0,4).map(s=>s.id),reason:'검사'},{skillIDs:[],reason:' '},{skillIDs:[],reason:'가'.repeat(501)}]) assert.throws(()=>worker.decodeSelection(j(v)));
});

test('only chosen guidance is supplied and renderer/no-text/no-sound contracts remain explicit',()=>{
  const c=worker.loadCatalog(),selection=worker.decodeSelection(j({skillIDs:['visual-explainer'],reason:'설명'}));
  const prompt=worker.generationPrompt(request(),selection);
  assert(prompt.includes(selection.skills[0].instructions));
  assert(c.catalog.filter(s=>s.id!=='visual-explainer').every(s=>!prompt.includes(s.instructions)));
  assert(prompt.includes('function frame(i)') && prompt.includes('function audio(t)') && prompt.includes('Malgun Gothic'));
  const remotion=worker.generationPrompt(request({renderer:'remotion'}),selection);
  assert(remotion.includes('Import only react and remotion') && remotion.includes('Output is silent'));
});

test('subscription commands isolate settings and do not force an API-only GPT model',()=>{
  const a=worker.claudeArguments('/private/job','claude-opus-5-5');
  assert.equal(a[a.indexOf('--tools')+1],'');assert(a.includes('--safe-mode'));
  const c=worker.codexArguments('codex-default');
  assert(c.includes('--ignore-user-config') && c.includes('--ignore-rules') && c.includes('--ephemeral'));
  assert(!c.includes('--model'));
  assert.equal(c[c.indexOf('--sandbox')+1],'read-only');
  assert(c.includes('shell_tool') && c.includes('plugins') && c.includes('hooks'));
});

test('GPT JSONL selects final text and rejects failed or tool-using turns',()=>{
  const output=[j({type:'thread.started'}),j({type:'item.completed',item:{type:'reasoning',text:'thinking'}}),j({type:'item.completed',item:{type:'agent_message',text:j(source)}}),j({type:'turn.completed'})].join('\n');
  assert.equal(worker.decodeCodex(output),j(source));
  for(const e of [{type:'turn.failed'},{type:'error'},{type:'item.completed',item:{type:'command_execution'}},{type:'turn.completed'}]) assert.throws(()=>worker.decodeCodex(j(e)));
});

test('API keys appear only in fixed endpoint authentication headers',()=>{
  const key='unit-fake-key-not-a-secret';
  for(const provider of ['claude','openai','gemini']) {
    const config=worker.apiConfiguration(provider,'test-model',key,'Return JSON',512);
    assert(!config.url.includes(key));assert(!JSON.stringify(config.body).includes(key));
    assert.equal(config.url.startsWith('https://'),true);
    assert.equal(new URL(config.url).search,'');
    assert(Object.values(config.headers).some(v=>v.includes(key)));
    assert.throws(()=>worker.apiConfiguration(provider,'test/model',key,'Return JSON',512));
    assert.throws(()=>worker.apiConfiguration(provider,'test\n',key,'Return JSON',512));
    assert.throws(()=>worker.apiConfiguration(provider,'test','bad\nkey','Return JSON',512));
  }
  assert.equal(worker.apiConfiguration('openai','gpt-6.1-sol',key,'JSON',512).body.store,false);
  assert.equal(worker.apiConfiguration('claude','claude-opus-5-5',key,'JSON',512).headers['anthropic-version'],'2023-06-01');
});

test('API decoders discard reasoning/thought blocks and preserve final JSON',()=>{
  for(const [provider,response] of [['claude',claude(j(source))],['openai',openAI(j(source))],['gemini',gemini(j(source))]]) {
    const text=worker.decodeAPI(provider,response);assert.equal(text,j(source));assert.deepEqual(worker.decodeSource(text,'canvas'),source);
  }
  assert.throws(()=>worker.decodeAPI('claude',{...claude(j(source)),stop_reason:'max_tokens'}));
  assert.throws(()=>worker.decodeAPI('claude',{...claude(j(source)),stop_reason:'tool_use'}));
  assert.throws(()=>worker.decodeAPI('openai',{...openAI(j(source)),status:'incomplete'}));
  assert.throws(()=>worker.decodeAPI('openai',{status:'completed',output:[{type:'message',content:[{type:'refusal',refusal:'no'}]}]}));
  assert.throws(()=>worker.decodeAPI('gemini',{candidates:[{finishReason:'MAX_TOKENS'}]}));
  assert.throws(()=>worker.decodeAPI('gemini',{promptFeedback:{blockReason:'SAFETY'}}));
  assert.throws(()=>worker.decodeAPI('gemini',gemini(' ')));
});

test('API transport errors cannot echo server bodies or credentials; response size is bounded',async()=>{
  const key='fake-key-only-for-unit-tests';
  for(const [provider,code] of [['claude',403],['openai',401],['gemini',429]]) {
    await assert.rejects(worker.requestAPI(provider,'test-model',key,'JSON',512,async()=>new Response('echo '+key,{status:code})),error=>!error.message.includes(key) && !error.message.includes('echo'));
  }
  await assert.rejects(worker.requestAPI('openai','test-model',key,'JSON',512,async()=>{throw new Error('transport '+key);}),error=>!error.message.includes(key) && !error.message.includes('transport'));
  const tooLarge=()=>Promise.resolve(new Response(' ',{headers:{'Content-Length':String(worker.LIMIT+1)}}));
  await assert.rejects(worker.requestAPI('openai','test-model',key,'JSON',512,tooLarge),/2MB/);
  await assert.rejects(worker.requestAPI('openai','test-model',key,'JSON',512,async()=>new Response(' '.repeat(worker.LIMIT+1))),/2MB/);
  for(const [provider,response] of [['claude',claude(j(source))],['openai',openAI(j(source))],['gemini',gemini(j(source))]]) {
    const actual=await worker.requestAPI(provider,'test-model',key,'JSON',512,async(url,opts)=>{
      assert.equal(opts.redirect,'error');assert.equal(opts.method,'POST');
      assert(!opts.body.includes(key));return new Response(j(response));
    });assert.equal(actual,j(source));
  }
});

test('partial runtime installation is rejected, pinned complete installation accepted',()=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'easycut-worker-runtime-'));
  try {
    const spec=JSON.parse(fs.readFileSync(path.join(__dirname,'../src-tauri/resources/generation/package.json'),'utf8'));
    const writePackage=(name,version)=>{const p=path.join(temp,'node_modules',name);fs.mkdirSync(p,{recursive:true});fs.writeFileSync(path.join(p,'package.json'),j({version}));};
    writePackage('puppeteer-core',spec.dependencies['puppeteer-core']);assert.equal(worker.runtimeReady(temp),false);
    for(const [name,version] of Object.entries(spec.dependencies)) writePackage(name,version);
    fs.writeFileSync(path.join(temp,'node_modules/@remotion/cli/remotion-cli.js'),'// fixture');assert.equal(worker.runtimeReady(temp),true);
    writePackage('react','0.0.0');assert.equal(worker.runtimeReady(temp),false);
  } finally {fs.rmSync(temp,{recursive:true,force:true});}
});

test('approved fingerprint freezes source, settings, harness and chosen guidance',()=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'easycut-worker-digest-'));
  try {
    const input={jobDir:path.join(temp,'job'),runtimeDir:path.join(temp,'runtime'),request:request()};
    fs.mkdirSync(path.join(input.runtimeDir,'node_modules'),{recursive:true});
    const selection=worker.decodeSelection(j({skillIDs:['visual-explainer'],reason:'설명'}));
    worker.writePreparedSource(input,source,selection);const original=worker.fingerprint(input.jobDir,input.request);
    for(const file of ['request.json','scene.js','canvas-render.cjs','applied-skills.json']) {
      const p=path.join(input.jobDir,file),bytes=fs.readFileSync(p);fs.appendFileSync(p,'\n');
      assert.notEqual(worker.fingerprint(input.jobDir,input.request),original);fs.writeFileSync(p,bytes);
    }
    assert.equal(worker.fingerprint(input.jobDir,input.request),original);
    assert(!fs.existsSync(path.join(input.jobDir,'render.mp4')));
  } finally {fs.rmSync(temp,{recursive:true,force:true});}
});

test('render chooses a free high port and bounded command output/timeout fails promptly',async()=>{
  const port=await worker.freeRenderPort();assert(port>1024 && port<65536);
  const result=await worker.runChild(process.execPath,['-e',"process.stdout.write('한글 응답');process.stderr.write('진단');"],{timeout:5000});
  assert.equal(result.stdout,'한글 응답');assert.equal(result.stderr,'진단');
  await assert.rejects(worker.runChild(process.execPath,['-e',`process.stdout.write('x'.repeat(${worker.LIMIT+1}));setInterval(()=>{},1000);`],{timeout:5000}),/2MB/);
  await assert.rejects(worker.runChild(process.execPath,['-e','setInterval(()=>{},1000)'],{timeout:40}),/초과/);
});

test('Windows npm CLI shims resolve to vendor JS without cmd.exe interpolation',{skip:process.platform!=='win32'},()=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'easycut & shim-'));
  try {
    const script=path.join(temp,'node_modules/@openai/codex/bin/codex.js');fs.mkdirSync(path.dirname(script),{recursive:true});fs.writeFileSync(script,'// fixture');
    const resolved=worker.commandFor(path.join(temp,'codex.cmd'),['a&b','한글'],'codex');
    assert.equal(resolved.file,process.execPath);assert.deepEqual(resolved.args,[script,'a&b','한글']);
  } finally {fs.rmSync(temp,{recursive:true,force:true});}
});

test('production process protocol rejects fixture actions instead of accepting source',async()=>{
  await assert.rejects(worker.runChild(process.execPath,[path.join(__dirname,'../src-tauri/resources/generation/worker.cjs')],{input:j({action:'fixture',source}),timeout:5000}));
});
