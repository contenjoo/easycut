// Real Windows installer regression. Synthetic devices replace hardware only;
// the app opens its own Studio window, loads its own model and images, and calls
// native record, save, reopen and export IPC without a mocked backend.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');

async function installSyntheticDevices(dataUrl) {
  const person = new Image();
  person.src = dataUrl; await person.decode();
  function source(camera) {
    const canvas = document.createElement('canvas');
    canvas.width = 768; canvas.height = 432;
    const ctx = canvas.getContext('2d');
    function draw() {
      if (camera) ctx.drawImage(person, 0, 0, 768, 432);
      else { ctx.fillStyle = '#227441'; ctx.fillRect(0, 0, 768, 432); }
      ctx.fillStyle = '#fff'; ctx.fillRect(Math.floor(performance.now()/40)%768, 0, 2, 2);
    }
    draw(); setInterval(draw, 40); return canvas.captureStream(25);
  }
  Object.defineProperties(navigator.mediaDevices, {
    getDisplayMedia: {value: async () => source(false)},
    getUserMedia: {value: async opts => { if (!opts.video) throw Error('Unexpected microphone request'); return source(true); }},
  });
}

const face = [139,45,178,90], wall = [8,15,84,96];
function difference(frame, reference, box) {
  let sum = 0, count = 0;
  for (let y=box[1]; y<box[3]; y++) for (let x=box[0]; x<box[2]; x++) {
    const index = (y*320+x)*3;
    for (let ch=0; ch<3; ch++) { sum += Math.abs(frame[index+ch]-reference[index+ch]); count++; }
  }
  return sum/count;
}
function contrast(frame) {
  let sum = 0, count = 0;
  for (let y=wall[1]; y<wall[3]; y++) for (let x=wall[0]+1; x<wall[2]; x++) {
    const i=(y*320+x)*3; sum+=Math.abs(frame[i]-frame[i-3]); count++;
  }
  return sum/count;
}

module.exports = async function ({editor,openStudio,waitForEdit,output,ffmpeg}) {
  const invoke = (command,args) => editor.evaluate(([c,a])=>window.__TAURI__.core.invoke(c,a),[command,args]);
  const presenter = path.resolve(__dirname,'../../../Tests/CameraBackgrounds/presenter.jpg');
  const midnight = path.resolve(__dirname,'../ui/camera-backgrounds/presets/midnight.jpg');
  const photo = path.join(output,'local camera background.png');
  const projectFile = path.join(output,'camera-background.easycut');
  const movie = path.join(output,'camera-background-export.mp4');
  fs.mkdirSync(output,{recursive:true});
  execFileSync(ffmpeg,['-v','error','-y','-f','lavfi','-i','color=c=0xdf24bf:s=320x180','-frames:v','1',photo]);
  function frame(file, time=0) {
    const bytes = execFileSync(ffmpeg,['-v','error','-i',file,'-ss',String(time),'-frames:v','1','-vf','scale=320:180','-pix_fmt','rgb24','-f','rawvideo','pipe:1']);
    assert.equal(bytes.length,320*180*3,'Missing decoded frame at '+time+' in '+path.basename(file));
    return bytes;
  }
  const reference = {presenter:frame(presenter), preset:frame(midnight), custom:frame(photo)};
  await invoke('new_project');
  // Seed a previously selected file, then exercise the real Tauri asset URL,
  // including Windows drive letters and spaces, through the installed app.
  await editor.evaluate(file=>{
    localStorage.setItem('rec.cameraBackground',JSON.stringify({id:'custom',path:file}));
  },photo);
  const studio = await openStudio(editor);
  const errors = [];
  studio.on('pageerror',e=>errors.push(e.message));
  try {
    await studio.waitForSelector('#prepare');
    await studio.evaluate(installSyntheticDevices,'data:image/jpeg;base64,'+fs.readFileSync(presenter).toString('base64'));
    await studio.check('#camera');
    assert.equal(await studio.inputValue('#output'),'local');
    const picker = studio.locator('#camera-background');
    await picker.locator('img').first().waitFor();
    assert.equal(await picker.locator('img').count(),4);
    await picker.locator('img').evaluateAll(async items=>{
      await Promise.all(items.map(img=>img.decode()));
      if (items.some(img=>img.naturalWidth<500)) throw Error('Missing bundled template');
    });
    assert.equal(await picker.locator('.camera-background-modes button').last().getAttribute('aria-pressed'),'true');
    await studio.click('#prepare');
    await studio.waitForSelector('body[data-phase="ready"]',{timeout:60000});
    await studio.click('#scenes [value=camera]');
    await studio.click('#go');
    await studio.waitForSelector('body[data-phase="recording"]');
    const start = await studio.evaluate(()=>performance.now());
    const times = {};
    async function sample(name) {
      await delay(1500);
      times[name] = (await studio.evaluate(()=>performance.now())-start)/1000;
      await delay(1250);
    }
    async function select(button) {
      await button.click();
      const handle=await button.elementHandle();
      try { await studio.waitForFunction(b=>b.getAttribute('aria-pressed')==='true' && b.closest('fieldset').getAttribute('aria-busy')==='false',handle,{timeout:60000}); }
      finally { await handle.dispose(); }
    }
    await sample('custom');
    const modes = picker.locator('.camera-background-modes button');
    await select(modes.nth(0)); await sample('off');
    await select(modes.nth(1)); await sample('blur');
    await select(picker.locator('button').filter({has:studio.locator('img[src$="/midnight.jpg"]')}));
    await sample('preset');
    await studio.click('#scenes [value=screen]'); await sample('screen');
    await studio.click('#scenes [value=pip]'); await sample('pip');
    await studio.screenshot({path:path.join(output,'camera-background-studio.png')});
    await studio.click('#stop'); await waitForEdit(editor,studio);
    const saved = await invoke('save_project',{path:projectFile});
    await invoke('new_project');
    const reopened = await invoke('open_project',{path:projectFile});
    assert.deepEqual(reopened.project.tracks,saved.project.tracks);
    const clips = reopened.project.tracks.flatMap(track=>track.clips);
    assert(clips.some(clip=>clip.scale>0 && clip.scale<.99),'Missing camera picture-in-picture layout in editor');
    const camera = reopened.project.assets.find(asset=>asset.name.includes('카메라'));
    assert(camera && fs.existsSync(camera.path),'Missing editable camera source');
    await invoke('export_video',{path:movie,height:480,burnCaptions:false,format:'mp4',alsoSrt:false,range:null});
    const measured={};
    for (const [kind,file] of Object.entries({camera:camera.path,export:movie})) {
      const pixels = {};
      for (const name of ['custom','off','blur','preset']) pixels[name]=frame(file,times[name]);
      const faces = Object.fromEntries(Object.entries(pixels).map(([name,data])=>[name,difference(data,reference.presenter,face)]));
      for (const [name,value] of Object.entries(faces)) assert(value<19,kind+' lost foreground at '+name+': '+value);
      const original=difference(pixels.off,reference.presenter,wall);
      const custom=difference(pixels.custom,reference.custom,wall), preset=difference(pixels.preset,reference.preset,wall);
      const blurRatio=contrast(pixels.blur)/Math.max(.01,contrast(pixels.off));
      assert(original<17 && custom<19 && preset<19 && blurRatio<.65,kind+' background mismatch '+JSON.stringify({original,custom,preset,blurRatio,times}));
      measured[kind]={faces,original,custom,preset,blurRatio};
    }
    const green=Buffer.alloc(320*180*3);
    for (let i=0;i<green.length;i+=3) {green[i]=34;green[i+1]=116;green[i+2]=65;}
    assert(difference(frame(movie,times.screen),green,[2,2,318,178])<12,'Expected screen-only scene in reopened export');
    const pip=frame(movie,times.pip);
    assert(difference(pip,green,[2,2,150,90])<12 && difference(pip,green,[235,133,303,163])>14,'Missing camera on the lower-right of the reopened overlay scene');
    assert.deepEqual(errors,[]);
    const proof={engine:'installed Windows WebView2',destination:'local',sceneOrder:['camera','screen','pip'],clips:clips.length,times,measured};
    fs.writeFileSync(path.join(output,'camera-background-native.json'),JSON.stringify(proof,null,2));
    console.log('PASS · INSTALLED WEBVIEW2 BACKGROUNDS → NATIVE CAMERA TRACK → REOPENED EXPORT',JSON.stringify(proof));
  } catch(error) {
    if (!studio.isClosed()) {
      console.error('Camera background studio state:',await studio.locator('body').getAttribute('data-phase'),await studio.locator('#notice').textContent().catch(()=>''),errors);
      await studio.screenshot({path:path.join(output,'camera-background-failure.png')}).catch(()=>{});
    }
    throw error;
  }
};
