import Foundation

/// App-owned harnesses. Claude supplies only Scene.tsx or scene.js, never commands or paths.
enum VideoGenerationRuntime {
    static let package = #"""
    {"name":"easycut-video-runtime","private":true,"version":"1.0.0","dependencies":{"@remotion/cli":"4.0.537","remotion":"4.0.537","react":"19.2.9","react-dom":"19.2.9","puppeteer-core":"24.26.1"}}
    """#

    static func remotionEntry(_ request: VideoGenerationRequest) -> String {
        """
        import React from 'react';
        import {registerRoot, Composition} from 'remotion';
        import Scene from './Scene';
        registerRoot(() => <Composition id="EasyCutGenerated" component={Scene}
          width={\(request.width)} height={\(request.height)} fps={\(request.fps)} durationInFrames={\(request.frames)} />);
        """
    }

    static let canvasRunner = #"""
    const fs = require('node:fs');
    const path = require('node:path');
    const {spawn} = require('node:child_process');
    const puppeteer = require('puppeteer-core');
    const [action, browserPath, ffmpegPath] = process.argv.slice(2);
    const spec = JSON.parse(fs.readFileSync('request.json', 'utf8'));
    const frames = Math.round(spec.duration * spec.fps);
    const source = fs.readFileSync('scene.js', 'utf8');
    let browser;
    let encoder;
    async function stop() {
      if (encoder) encoder.kill('SIGTERM');
      if (browser) await browser.close().catch(() => {});
    }
    for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
      stop().finally(() => process.exit(130));
    });
    (async () => {
      browser = await puppeteer.launch({executablePath:browserPath, headless:true,
        args:['--disable-background-networking', '--disable-extensions', '--disable-sync']});
      const page = await browser.newPage();
      await page.setViewport({width:spec.width,height:spec.height,deviceScaleFactor:1});
      await page.setRequestInterception(true);
      page.on('request', req => /^(about:|data:)/.test(req.url()) ? req.continue() : req.abort());
      const errors = [];
      page.on('pageerror', error => errors.push(String(error)));
      await page.setContent('<html><body style="margin:0;overflow:hidden"><canvas id="c"></canvas></body></html>');
      await page.evaluate(s => {
        window.W=s.width; window.H=s.height; window.FPS=s.fps; window.DURATION=s.duration;
        window.canvas=document.getElementById('c'); canvas.width=W; canvas.height=H;
        window.ctx=canvas.getContext('2d');
        window.seededRandom = n => { const x=Math.sin(n*127.1+311.7)*43758.5453; return x-Math.floor(x); };
      }, spec);
      await page.addScriptTag({content:source});
      await page.evaluate(() => {
        if (typeof window.frame!=='function') throw new Error('scene.js must define function frame(i)');
        if (typeof window.audio!=='function') throw new Error('scene.js must define function audio(t)');
      });
      const draw = async index => {
        await page.evaluate(i => {
          ctx.resetTransform(); ctx.globalAlpha=1; ctx.globalCompositeOperation='source-over';
          ctx.clearRect(0,0,W,H); ctx.save(); window.frame(i); ctx.restore();
        }, index);
        if (errors.length) throw new Error(errors.join('\n'));
      };
      if (action==='preview') {
        for (const [index, fraction] of [0.1,0.35,0.6,0.85].entries()) {
          await draw(Math.min(frames-1,Math.floor(frames*fraction)));
          await page.screenshot({path:`preview-${index+1}.png`,type:'png'});
        }
      } else if (action==='render') {
        const frameDir=path.resolve('frames'); fs.mkdirSync(frameDir,{recursive:true});
        for (let i=0;i<frames;i++) {
          await draw(i);
          await page.screenshot({path:path.join(frameDir,`frame-${String(i).padStart(6,'0')}.png`),type:'png'});
        }
        const rate=44100, samples=Math.round(spec.duration*rate);
        const wav=fs.openSync('music.wav','w');
        const header=Buffer.alloc(44); header.write('RIFF'); header.writeUInt32LE(36+samples*4,4);
        header.write('WAVEfmt ',8); header.writeUInt32LE(16,16); header.writeUInt16LE(1,20);
        header.writeUInt16LE(2,22); header.writeUInt32LE(rate,24); header.writeUInt32LE(rate*4,28);
        header.writeUInt16LE(4,32); header.writeUInt16LE(16,34); header.write('data',36); header.writeUInt32LE(samples*4,40);
        fs.writeSync(wav,header);
        try {
          for (let start=0;start<samples;start+=rate) {
            const count=Math.min(rate,samples-start);
            const encoded=await page.evaluate(({start,count,rate}) => {
              const bytes=new Uint8Array(count*4), view=new DataView(bytes.buffer);
              for(let i=0;i<count;i++) {
                const a=window.audio((start+i)/rate);
                const pair=Array.isArray(a)?a:[a,a];
                for(let ch=0;ch<2;ch++) {
                  const sample=pair[ch];
                  if(typeof sample!=='number'||!Number.isFinite(sample)) throw new Error('audio(t) returned a non-finite sample');
                  view.setInt16(i*4+ch*2,Math.round(Math.max(-0.95,Math.min(0.95,sample))*32767),true);
                }
              }
              let binary=''; for(let i=0;i<bytes.length;i+=8192) binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
              return btoa(binary);
            },{start,count,rate});
            fs.writeSync(wav,Buffer.from(encoded,'base64'));
          }
        } finally { fs.closeSync(wav); }
        const encoders=await new Promise((resolve,reject) => {
          const probe=spawn(ffmpegPath,['-hide_banner','-encoders'],{stdio:['ignore','pipe','pipe']});
          let text=''; probe.stdout.on('data',chunk => text+=chunk);
          probe.on('error',reject); probe.on('exit',code => code===0?resolve(text):reject(new Error('Unable to query FFmpeg encoders')));
        });
        const videoOptions=encoders.includes('libx264')
          ? ['-c:v','libx264','-preset','fast','-crf','20']
          : ['-c:v','h264_videotoolbox','-q:v','65'];
        await new Promise((resolve,reject) => {
          encoder=spawn(ffmpegPath,['-hide_banner','-loglevel','error','-nostdin','-y',
            '-framerate',String(spec.fps),'-i',path.join(frameDir,'frame-%06d.png'),'-i','music.wav',
            ...videoOptions,'-vf','scale=out_color_matrix=bt709:out_range=tv','-pix_fmt','yuv420p',
            '-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-color_range','tv',
            '-c:a','aac','-b:a','192k',
            '-t',String(spec.duration),'-movflags','+faststart','render-pending.mp4'],{stdio:['ignore','ignore','pipe']});
          let error=''; encoder.stderr.on('data',chunk => error=(error+chunk).slice(-8000));
          encoder.on('error',reject); encoder.on('exit',code => code===0?resolve():reject(new Error(error||`ffmpeg exited ${code}`)));
        });
        fs.rmSync(frameDir,{recursive:true,force:true});
      } else throw new Error('Unknown render action');
      await stop();
      console.log(JSON.stringify({ok:true,action,frames}));
    })().catch(async error => { console.error(error.stack||String(error)); await stop(); process.exit(1); });
    """#
}
