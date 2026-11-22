// Exercise the normal recorder dialog and inspect the exact encoded camera data
// sent to the native editor. Every input and the IPC boundary are local fixtures.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const {chromium} = require("playwright-core");
const ui = path.resolve(__dirname,"../ui");

function installFixture() {
  localStorage.setItem("uiLang","ko");
  const listeners = new Map();
  const files = window.chunks = {screen:[], camera:[]};
  window.messages = [];
  window.__TAURI__ = {
    dialog: {open: async () => "C:\\Pictures\\background.png"},
    core: {
      convertFileSrc: () => window.testPicture,
      async invoke(cmd,args,options) {
        if (cmd === "rec_begin") window.kinds = Object.fromEntries(args.kinds);
        if (cmd === "rec_chunk") files[options.headers["x-kind"]].push(args);
        if (cmd === "rec_finish") { window.finished = args; return {hasCamera:true}; }
      },
    },
    event: {
      listen: async (name,callback) => { listeners.set(name,callback); return () => listeners.delete(name); },
      emit: async (name,status) => { if (name === "rec-status") window.phase = status.phase; },
      emitTo: async (name,event,frame) => { if (name === "recpanel" && event === "rec-camera-preview") window.thumbnail = frame; },
    },
    window: {getCurrentWindow: () => ({
      minimize:async () => {}, unminimize:async () => {}, show:async () => {}, setFocus:async () => {},
    })},
  };
  function synthetic(color) {
    const canvas = document.createElement("canvas"); canvas.width=320; canvas.height=180;
    const ctx = canvas.getContext("2d");
    function draw() {
      ctx.fillStyle=color; ctx.fillRect(0,0,320,180);
      ctx.fillStyle="#eee"; ctx.fillRect(Math.floor(performance.now()/10)%320,0,2,2);
    }
    draw(); setInterval(draw,50); return canvas.captureStream(20);
  }
  Object.defineProperties(navigator.mediaDevices,{
    enumerateDevices:{value:async () => [{kind:"videoinput",deviceId:"synthetic",label:"Synthetic"}]},
    getDisplayMedia:{value:async () => synthetic("#275eaf")},
    getUserMedia:{value:async () => synthetic("#c7218d")},
  });
}

(async () => {
  const server = http.createServer((req,res) => {
    const url = new URL(req.url,"http://localhost");
    if (url.pathname === "/") {
      res.writeHead(200,{"Content-Type":"text/html"});
      return res.end('<html><head><link rel="stylesheet" href="/style.css"></head><body><div id="modal"><div id="modal-box" class="box"></div></div><script src="/strings.js"></script><script src="/i18n.js"></script></body></html>');
    }
    const file = path.resolve(ui,"." + decodeURIComponent(url.pathname));
    if (!file.startsWith(ui+path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); return res.end(); }
    const types = {".js":"text/javascript",".mjs":"text/javascript",".css":"text/css",".jpg":"image/jpeg",".wasm":"application/wasm"};
    res.writeHead(200,{"Content-Type":types[path.extname(file)] || "application/octet-stream"}); fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve,reject) => {server.once("error",reject); server.listen(0,"127.0.0.1",resolve);});
  let browser;
  try {
    browser = await chromium.launch({executablePath:process.env.EASYCUT_CHROME || undefined,args:["--autoplay-policy=no-user-gesture-required"]});
    const page = await browser.newPage({locale:"ko-KR",viewport:{width:1100,height:680}});
    const errors=[]; page.on("pageerror",error=>errors.push(error.message));
    await page.addInitScript(installFixture);
    await page.goto("http://127.0.0.1:" + server.address().port);
    await page.evaluate(async () => {
      const image = document.createElement("canvas"); image.width=64; image.height=36;
      const brush = image.getContext("2d"); brush.fillStyle="#1ab84d"; brush.fillRect(0,0,64,36);
      window.testPicture = image.toDataURL("image/png");
      const module = window.recordModule = await import("/record.js");
      const container = document.querySelector("#modal");
      module.initRecord({
        toast:msg=>window.messages.push(msg),
        modal:{box:document.querySelector("#modal-box"), show:()=>container.classList.remove("hidden"),
          hide:()=>{container.classList.add("hidden"); window.dispatchEvent(new Event("easycut-modal-hidden"));}},
      });
      await module.openRecordDialog();
    });
    await page.locator("#r-cam").uncheck();
    assert(await page.locator("#r-background").isHidden());
    await page.locator("#r-cam").check();
    await page.getByRole("button",{name:"내 사진…"}).click();
    await page.waitForFunction(()=>document.querySelector('.camera-background-modes button:last-child').getAttribute("aria-pressed")==="true");
    await page.locator("#r-preview-toggle").click();
    await page.waitForFunction(()=>document.querySelector("#r-preview-video").readyState>=2);
    async function colors() {
      return page.evaluate(async () => {
        function sample(source) {
          const canvas = document.createElement("canvas"); canvas.width=4; canvas.height=4;
          const ctx = canvas.getContext("2d"); ctx.drawImage(source,0,0,4,4);
          return [...ctx.getImageData(2,2,1,1).data].slice(0,3);
        }
        if (!window.finished) return {preview:sample(document.querySelector("#r-preview-video"))};
        async function encoded(kind) {
          const url = URL.createObjectURL(new Blob(window.chunks[kind],{type:"video/"+window.kinds[kind]}));
          const video = document.createElement("video"); video.muted=true;
          try { video.src=url; await video.play(); return sample(video); }
          finally { video.pause(); URL.revokeObjectURL(url); }
        }
        const panel = new Image(); panel.src=window.thumbnail; await panel.decode();
        return {panel:sample(panel),camera:await encoded("camera"),screen:await encoded("screen")};
      });
    }
    function near(pixel,expected) {
      assert(pixel.every((value,index)=>Math.abs(value-expected[index])<=14), `Expected ${expected}, got ${pixel}`);
    }
    near((await colors()).preview,[26,184,77]);
    await page.locator("#r-go").click();
    await page.waitForFunction(()=>window.phase==="recording" && window.thumbnail);
    await page.waitForFunction(()=>window.chunks.camera.length && window.chunks.screen.length);
    await page.evaluate(()=>window.recordModule.stop());
    const shots=await colors(); near(shots.camera,[26,184,77]); near(shots.panel,[26,184,77]); near(shots.screen,[39,94,175]);
    assert.equal((await page.evaluate(()=>window.finished)).cameraCircle,true);
    assert.deepEqual(errors,[]);
    console.log("PASS: custom photo in camera preview, control panel and decoded editor camera track; screen track remains independent.");
  } finally { await browser?.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(error=>{console.error(error);process.exitCode=1;});
