// Run after npm ci with playwright-core, Chromium and ffmpeg available.
// Tauri's file/network boundary is replaced; the UI, segmentation worker, camera
// track, scene mixer and MediaRecorder encoders all run as they do in Studio.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { chromium } = require("playwright-core");
const root = path.resolve(__dirname, "../ui");
const portrait = path.resolve(__dirname, "../../../Tests/CameraBackgrounds/presenter.jpg");

function installFixture() {
  localStorage.setItem("uiLang", "ko");
  const custom = document.createElement("canvas");
  custom.width = 320; custom.height = 180;
  const ctx = custom.getContext("2d");
  ctx.fillStyle = "#df24bf"; ctx.fillRect(0, 0, 320, 180);
  window.chunks = {camera: [], screen: [], program: []};
  window.__TAURI__ = {
    core: {
      convertFileSrc: () => custom.toDataURL(),
      invoke: async (name, data, options) => {
        if (name === "rec_chunk" || name === "studio_live_chunk") {
          const kind = name === "rec_chunk" ? options.headers["x-kind"] : "program";
          window.chunks[kind].push(data.slice());
          return true;
        }
        if (name === "rec_finish") window.cuts = data.studioCuts;
        if (name === "youtube_account_status") return {configured: true, connected: false};
        if (!["rec_begin", "rec_finish", "studio_live_start", "studio_live_stop"].includes(name))
          throw Error("Unexpected command " + name);
      },
    },
    dialog: {open: async () => "test-background.png"},
    window: {getCurrentWindow: () => ({onCloseRequested: async () => {}, destroy: () => {window.finished = true;}})},
  };
  async function source(camera) {
    const c = document.createElement("canvas");
    c.width = 768; c.height = 432;
    const brush = c.getContext("2d");
    const img = new Image();
    if (camera) { img.src = "/presenter.jpg"; await img.decode(); }
    function draw() {
      if (camera) brush.drawImage(img, 0, 0, c.width, c.height);
      else { brush.fillStyle = "#227441"; brush.fillRect(0, 0, c.width, c.height); }
      brush.fillStyle = "#eeeeff"; brush.fillRect((performance.now()/40)%c.width, 0, 2, 2);
    }
    draw(); setInterval(draw, 40);
    return c.captureStream(25);
  }
  Object.defineProperties(navigator.mediaDevices, {
    getDisplayMedia: {value: () => source(false)}, getUserMedia: {value: () => source(true)},
  });
}

function decode(file, multiple = false) {
  const stride = 320*180*3;
  const frames = multiple ? ["-vf","fps=4,scale=320:180"] : ["-frames:v","1","-vf","scale=320:180"];
  const raw = execFileSync(process.env.FFMPEG || "ffmpeg", ["-v","error","-i",file,"-map","0:v:0","-an",...frames,"-pix_fmt","rgb24","-f","rawvideo","pipe:1"], {maxBuffer:64*1024*1024});
  assert(raw.length >= stride && raw.length % stride === 0, "Incomplete decoded video: " + path.basename(file));
  return Array.from({length:raw.length/stride},(_,i)=>raw.subarray(i*stride,(i+1)*stride));
}
function distance(a, b, box) {
  let sum = 0, count = 0;
  for (let y=box[1]; y<box[3]; y++) for (let x=box[0]; x<box[2]; x++)
    for (let ch=0; ch<3; ch++) {
      const i = (y*320+x)*3+ch;
      sum += Math.abs(a[i]-b[i]); count++;
    }
  return sum/count;
}
function contrast(pixels, box) {
  let sum = 0, count = 0;
  for (let y=box[1]; y<box[3]; y++) for (let x=box[0]+1; x<box[2]; x++) {
    const i=(y*320+x)*3;
    sum+=Math.abs(pixels[i]-pixels[i-3]); count++;
  }
  return sum/count;
}

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "easycut-record-bg-"));
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost").pathname;
    const file = url === "/presenter.jpg" ? portrait : path.resolve(root, "."+url);
    if ((file !== portrait && !file.startsWith(root+path.sep)) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404).end(); return;
    }
    const types = {".html":"text/html",".js":"text/javascript",".mjs":"text/javascript",".css":"text/css",".jpg":"image/jpeg",".wasm":"application/wasm"};
    res.setHeader("Content-Type", types[path.extname(file)] || "application/octet-stream");
    fs.createReadStream(file).pipe(res);
  });
  let browser;
  try {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    browser = await chromium.launch({executablePath: process.env.EASYCUT_CHROME || undefined, args:["--autoplay-policy=no-user-gesture-required","--enable-unsafe-swiftshader"]});
    const page = await browser.newPage({viewport:{width:1220,height:880}});
    const errors = [];
    page.on("pageerror", error => errors.push(String(error)));
    await page.addInitScript(installFixture);
    await page.goto("http://127.0.0.1:"+server.address().port+"/studio.html");
    await page.locator("#camera").check();
    await page.selectOption("#output","rtmp");
    await page.fill("#server","rtmp://localhost/test"); await page.fill("#key","offline-fixture");
    await page.click("#prepare"); await page.waitForSelector("body[data-phase=ready]");
    await page.click("#scenes [value=camera]");
    await page.click("#go"); await page.waitForSelector("body[data-phase=recording]");
    for (const [key,label] of Object.entries({off:"원본",blur:"배경 흐림",preset:"미드나이트",custom:"내 사진…"})) {
      const button = page.getByRole("button",{name:label,exact:true});
      if (key !== "off") {
        await button.click();
        await page.waitForFunction(label => [...document.querySelectorAll("#camera-background button")].some(b=>b.textContent===label && b.getAttribute("aria-pressed")==="true"),label);
      }
      await page.waitForTimeout(1800);
    }
    await page.click("#scenes [value=screen]"); await page.waitForTimeout(1400);
    await page.click("#stop"); await page.waitForFunction(()=>window.finished);
    const cuts = await page.evaluate(()=>window.cuts);
    assert(cuts[0].camera && !cuts[0].screen && cuts.at(-1).screen && !cuts.at(-1).camera);
    assert.deepEqual(errors,[]);
    const face = [139,45,178,90], side = [8,15,84,96];
    const [original] = decode(portrait);
    const [midnight] = decode(path.join(root,"camera-backgrounds/presets/midnight.jpg"));
    const solid = rgb => Buffer.from(Array.from({length:320*180*3},(_,i)=>rgb[i%3]));
    const pink = solid([223,36,191]), cyan = solid([128,243,246]), screen = solid([34,116,65]);
    for (const kind of ["program","camera"]) {
      // Measure actual encoded frames, independent of WebView/encoder start-up latency.
      const base64 = await page.evaluate(async key => {
        const reader = new FileReader();
        const ready = new Promise((resolve,reject) => {reader.onload=()=>resolve(reader.result.split(",")[1]); reader.onerror=reject;});
        reader.readAsDataURL(new Blob(window.chunks[key],{type:"video/webm"}));
        return ready;
      },kind);
      const file = path.join(tmp,kind+".webm");
      fs.writeFileSync(file,Buffer.from(base64,"base64"));
      const frames = decode(file,true);
      const checks = {
        original: p => distance(p,original,side)<16,
        blur: p => distance(p,cyan,side)<32 && contrast(p,side)<contrast(original,side)*.55,
        preset: p => distance(p,midnight,side)<18,
        custom: p => distance(p,pink,side)<18,
      };
      let cursor = 0;
      for (const [name,matches] of Object.entries(checks)) {
        const index = frames.findIndex((p,i)=>i>=cursor && matches(p) && distance(original,p,face)<17 &&
          i+1<frames.length && matches(frames[i+1]) && distance(original,frames[i+1],face)<17);
        assert(index>=0,kind+" is missing "+name+" with subject preserved ("+frames.length+" frames)");
        cursor = index+2;
      }
      if (kind==="program") assert(frames.slice(cursor).some(p=>distance(p,screen,[4,4,316,176])<12),"Missing final screen scene in program");
    }
    console.log("PASS · encoded program + editor camera track preserve the subject across original, blur, template and custom image; scene cuts handed to editor.");
  } finally {
    await browser?.close(); server.close(); fs.rmSync(tmp,{recursive:true,force:true});
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
