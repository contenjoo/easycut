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
  window.__TAURI__ = {
    core: {
      convertFileSrc: () => custom.toDataURL(),
      invoke: async (name, data, options) => {
        if (name === "rec_chunk" || name === "studio_live_chunk") {
          const kind = name === "rec_chunk" ? options.headers["x-kind"] : "program";
          await window.saveChunk(kind, [...data]);
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

function frame(file, time = 0) {
  const out = execFileSync(process.env.FFMPEG || "ffmpeg", ["-v","error","-i",file,"-ss",String(time),"-frames:v","1","-vf","scale=320:180","-pix_fmt","rgb24","-f","rawvideo","pipe:1"]);
  assert.equal(out.length, 320*180*3, "Missing decoded frame at " + time);
  return out;
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
    await page.exposeFunction("saveChunk", (kind, data) => {
      assert(["screen","camera","program"].includes(kind)); fs.appendFileSync(path.join(tmp,kind+".webm"),Buffer.from(data));
    });
    await page.addInitScript(installFixture);
    await page.goto("http://127.0.0.1:"+server.address().port+"/studio.html");
    await page.locator("#camera").check();
    await page.selectOption("#output","rtmp");
    await page.fill("#server","rtmp://localhost/test"); await page.fill("#key","offline-fixture");
    await page.click("#prepare"); await page.waitForSelector("body[data-phase=ready]");
    await page.click("#scenes [value=camera]");
    await page.click("#go"); await page.waitForSelector("body[data-phase=recording]");
    await page.evaluate(() => { window.testStart = performance.now(); });
    const times = {};
    for (const [key,label] of Object.entries({off:"원본",blur:"배경 흐림",preset:"미드나이트",custom:"내 사진…"})) {
      const button = page.getByRole("button",{name:label,exact:true});
      if (key !== "off") {
        await button.click();
        await page.waitForFunction(label => [...document.querySelectorAll("#camera-background button")].some(b=>b.textContent===label && b.getAttribute("aria-pressed")==="true"),label);
      }
      await page.waitForTimeout(780);
      times[key] = await page.evaluate(()=>(performance.now()-window.testStart)/1000);
      await page.waitForTimeout(500);
    }
    await page.click("#scenes [value=screen]"); await page.waitForTimeout(1400);
    await page.click("#stop"); await page.waitForFunction(()=>window.finished);
    const cuts = await page.evaluate(()=>window.cuts);
    assert(cuts[0].camera && !cuts[0].screen && cuts.at(-1).screen && !cuts.at(-1).camera);
    assert.deepEqual(errors,[]);
    const face = [139,45,178,90], side = [8,15,84,96];
    const original = frame(portrait);
    const midnight = frame(path.join(root,"camera-backgrounds/presets/midnight.jpg"));
    const pink = Buffer.from(Array.from({length:320*180*3},(_,i)=>[223,36,191][i%3]));
    for (const kind of ["program","camera"]) {
      const file = path.join(tmp,kind+".webm");
      const sampled = Object.fromEntries(Object.entries(times).map(([key,t])=>[key,frame(file,t)]));
      for (const [key,pixels] of Object.entries(sampled))
        assert(distance(original,pixels,face)<17,kind+" lost facial details in "+key);
      assert(distance(original,sampled.off,side)<16,kind+" lost original background");
      assert(contrast(sampled.blur,side)<contrast(sampled.off,side)*0.55,kind+" did not blur the checkerboard");
      assert(distance(midnight,sampled.preset,side)<18,kind+" did not record preset");
      assert(distance(pink,sampled.custom,side)<18,kind+" did not record chosen image");
    }
    console.log("PASS · encoded program + editor camera track preserve the subject across original, blur, template and custom image; scene cuts handed to editor.");
  } finally {
    await browser?.close(); server.close(); fs.rmSync(tmp,{recursive:true,force:true});
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
