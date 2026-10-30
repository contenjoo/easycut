// Real Chrome/Edge + FFmpeg renders. No provider accounts, API keys or model calls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const worker = require('../src-tauri/resources/generation/worker.cjs');

(async () => {
  const evidence = path.resolve(process.env.EASYCUT_GENERATION_EVIDENCE || path.join(os.tmpdir(), 'easycut-generation-integration'));
  fs.mkdirSync(evidence, {recursive:true});
  const runtimeDir = path.resolve(process.env.EASYCUT_GENERATION_RUNTIME || path.join(evidence, 'runtime'));
  const tools = worker.toolPaths({browser:process.env.EASYCUT_GENERATION_BROWSER,ffmpeg:process.env.EASYCUT_GENERATION_FFMPEG,ffprobe:process.env.EASYCUT_GENERATION_FFPROBE});
  assert(tools.browser && tools.ffmpeg && tools.ffprobe, 'Chrome/Edge and FFmpeg/ffprobe are required');
  const fixtures = {
    canvas: {title:'영상 만들기 검사',source:`function frame(i) {
      const t=i/FPS;ctx.fillStyle='#25214a';ctx.fillRect(0,0,W,H);
      ctx.fillStyle='#8dd3f6';ctx.beginPath();ctx.arc(W*(0.5+0.2*Math.sin(t*3)),H*0.38,38,0,Math.PI*2);ctx.fill();
      ctx.font='bold 30px "Malgun Gothic", sans-serif';ctx.textAlign='center';ctx.fillStyle='#ffc93c';ctx.fillText('영상 만들기',W/2,H*0.74);
    }
    function audio(t){return 0.12*Math.sin(2*Math.PI*440*t)*Math.max(0,Math.min(1,t*10,(DURATION-t)*10));}`},
    remotion: {title:'Remotion 기술 검사',source:`import React from 'react';
      import {AbsoluteFill,useCurrentFrame,useVideoConfig} from 'remotion';
      export default function Scene(){const i=useCurrentFrame(),{fps}=useVideoConfig();return <AbsoluteFill style={{backgroundColor:'#25214a',fontFamily:'Malgun Gothic, sans-serif'}}>
      <div style={{position:'absolute',left:(50+20*Math.sin(i/fps*3))+'%',top:'38%',width:76,height:76,borderRadius:'50%',backgroundColor:'#8dd3f6',transform:'translate(-50%,-50%)'}}/>
      <div style={{position:'absolute',top:'65%',width:'100%',textAlign:'center',fontSize:30,fontWeight:700,color:'#ffc93c'}}>영상 만들기</div></AbsoluteFill>;}`},
  };
  const manifest = {fixtures:[]};
  for (const renderer of ['canvas','remotion']) {
    const request = {renderer,provider:'claude',access:'subscription',model:'claude-opus-5-5',automaticSkills:true,prompt:'기술 검증',duration:2,width:640,height:360,fps:30};
    const input = {request,jobDir:path.join(evidence,`${renderer}-한글 테스트-${Date.now()}`),runtimeDir,...tools};
    const preview = await worker.prepareFixture(input,fixtures[renderer]);
    assert.equal(preview.previews.length,4);
    assert(preview.previews.every(p=>worker.validPNG(p,request)));
    assert(!fs.existsSync(path.join(input.jobDir,'render.mp4')),'Preview must not render the complete video');
    assert(!fs.existsSync(path.join(input.jobDir,'music.wav')),'Preview must not synthesize the complete audio');
    const pngs=preview.previews.map(p=>fs.readFileSync(p));
    assert(new Set(pngs.map(p=>crypto.createHash('sha256').update(p).digest('hex'))).size>1,'Frames must show movement');
    await worker.makePreviews(input,tools);
    assert(preview.previews.every((p,i)=>fs.readFileSync(p).equals(pngs[i])),'Out-of-order frames must be reproducible');
    const approved=worker.fingerprint(input.jobDir,request);
    const rendered=await worker.renderJob(input);
    const probe=await worker.validateOutput(rendered.outputPath,request,tools.ffprobe);
    assert.equal(probe.hasAudio,renderer==='canvas');
    assert.equal(worker.fingerprint(input.jobDir,request),approved);
    const original=fs.readFileSync(rendered.outputPath),sceneFile=path.join(input.jobDir,renderer==='canvas'?'scene.js':'Scene.tsx');
    const scene=fs.readFileSync(sceneFile);
    fs.appendFileSync(sceneFile,'\n// Changed after approval\n');
    await assert.rejects(worker.renderJob(input),/미리보기 이후/);
    assert(fs.readFileSync(rendered.outputPath).equals(original),'Unapproved source must not overwrite the completed video');
    fs.writeFileSync(sceneFile,scene);
    const selectedFile=path.join(input.jobDir,'applied-skills.json'),selection=fs.readFileSync(selectedFile);
    fs.appendFileSync(selectedFile,'\n');
    await assert.rejects(worker.renderJob(input),/미리보기 이후/);
    fs.writeFileSync(selectedFile,selection);
    const reused=await worker.renderJob(input);
    assert.equal(reused.outputPath,rendered.outputPath);
    assert(fs.readFileSync(rendered.outputPath).equals(original));
    manifest.fixtures.push({renderer,...rendered,probe});
    console.log(`GENERATION ${renderer.toUpperCase()} REAL PREVIEW + RENDER + APPROVAL CHECKS PASSED`);
  }
  fs.writeFileSync(path.join(evidence,'generation-manifest.json'),JSON.stringify(manifest,null,2));
  console.log('ALL GENERATION INTEGRATION CHECKS PASSED');
})().catch(error=>{console.error(error);process.exitCode=1;});
