// Regression cases for camera privacy and lifetime. The studio test exercises recorded output.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const {chromium} = require("playwright-core");
const ui = path.resolve(__dirname, "../ui");

async function exercise() {
  const {createCameraBackgroundStream} = await import("/camera-backgrounds/processor.js");
  const canvas = document.createElement("canvas");
  canvas.width = 128; canvas.height = 96;
  const ctx = canvas.getContext("2d");
  const draw = () => { ctx.fillStyle = "red"; ctx.fillRect(0, 0, 128, 96); };
  draw();
  const input = canvas.captureStream(12), ticker = setInterval(draw, 100);
  const errors = [], pipe = await createCameraBackgroundStream(input, {mode:"off"}, {onError:e=>errors.push(e.message)});
  const inputTrack = input.getVideoTracks()[0], outputTrack = pipe.stream.getVideoTracks()[0];
  const pix = new OffscreenCanvas(1,1).getContext("2d", {willReadFrequently:true});
  async function color() {
    const clone = outputTrack.clone();
    const reader = new MediaStreamTrackProcessor({track:clone}).readable.getReader();
    try {
      const {value} = await reader.read();
      try {
        pix.drawImage(value, 0, 0, 1, 1);
        return [...pix.getImageData(0, 0, 1, 1).data];
      } finally { value.close(); }
    } finally { await reader.cancel(); clone.stop(); }
  }
  try {
    const original = await color();
    const invalidFile = await pipe.setEffect({mode:"image",url:"/missing.jpg"}).then(()=>false,()=>true);
    const neutral = await color();
    const skipped = pipe.setEffect({mode:"image", url:"/slow-image.jpg"}).then(()=>"", e=>e.name);
    await pipe.setEffect({mode:"off"});
    const restored = await color();
    const invalidHost = await pipe.setEffect({mode:"image",url:"https://unrelated.invalid/file.png"}).then(()=>false,()=>true);
    pipe.stop();
    const endsOnlyOutput = outputTrack.readyState === "ended" && inputTrack.readyState === "live";
    const nativeProcessor = window.MediaStreamTrackProcessor;
    window.MediaStreamTrackProcessor = undefined;
    let fallbackClosed;
    try {
      const legacy = await createCameraBackgroundStream(input, {mode:"off"});
      try {
        const output = legacy.stream.getVideoTracks()[0];
        const rejected = await legacy.setEffect({mode:"blur"}).then(()=>false,()=>true);
        fallbackClosed = rejected && !output.enabled;
        await legacy.setEffect({mode:"off"});
        fallbackClosed &&= output.enabled && inputTrack.enabled;
      } finally {legacy.stop();}
    } finally {window.MediaStreamTrackProcessor = nativeProcessor;}
    // With no input frames, setup must release the worker, reject, and preserve the caller's camera.
    const silent = new MediaStreamTrackGenerator({kind:"video"});
    const timeout = await createCameraBackgroundStream(new MediaStream([silent])).then(()=>"",e=>e.message);
    const keepsInput = silent.readyState === "live"; silent.stop();
    return {original, invalidFile, neutral, restored, skipped:await skipped, invalidHost, endsOnlyOutput,
      fallbackClosed, timeout, keepsInput, errors};
  } finally {
    pipe.stop(); clearInterval(ticker); inputTrack.stop();
  }
}

(async () => {
  const server = http.createServer((req,res) => {
    const pathname = new URL(req.url, "http://localhost").pathname;
    if (pathname === "/") {res.writeHead(200,{"Content-Type":"text/html"});return res.end("<title>Camera worker test</title>");}
    const file = path.resolve(ui, "." + decodeURIComponent(pathname));
    if (!file.startsWith(ui + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {res.writeHead(404);return res.end();}
    res.writeHead(200,{"Content-Type":{".mjs":"text/javascript",".js":"text/javascript",".wasm":"application/wasm"}[path.extname(file)] || "application/octet-stream"});
    fs.createReadStream(file).pipe(res);
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    browser = await chromium.launch({executablePath:process.env.EASYCUT_CHROME || undefined,headless:true,
      args:["--enable-unsafe-swiftshader"]});
    const page = await browser.newPage();
    const origin = "http://127.0.0.1:" + server.address().port;
    const external = [];
    await page.context().route(/^https?:/, route => {
      if (new URL(route.request().url()).origin === origin) return route.continue();
      external.push(route.request().url()); return route.abort();
    });
    await page.goto(origin);
    const result = await page.evaluate(exercise);
    assert(result.original[0] > 230 && result.restored[0] > 230);
    assert(result.neutral[0] < 50 && result.neutral[2] > 30);
    assert.equal(result.skipped,"AbortError");
    assert(result.invalidFile && result.invalidHost && result.endsOnlyOutput && result.fallbackClosed && result.keepsInput);
    assert.match(result.timeout, /다시 연결/);
    assert.deepEqual(result.errors,[]); assert.deepEqual(external,[]);
    console.log("Camera worker passed local-only, fail-closed, rapid switching, shutdown, legacy and no-frame tests.");
  } finally {
    await browser?.close();server.close();
  }
})().catch(error => {console.error(error);process.exitCode=1;});
