// Browser regression of the account and layout workflows. Only synthetic media and an in-memory IPC fixture are used.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {chromium} = require("playwright-core");
const ui = path.join(__dirname,"../ui");

function fixture() {
  localStorage.setItem("uiLang","ko");
  let connected = false, scheduled = [], attemptEnd = 0;
  const calls = window.calls = [];
  const account = () => ({ configured:true, connected, channelTitle:connected ? "테스트 채널" : null });
  window.__TAURI__ = {
    core: { invoke: async (name,args) => {
      if (["studio_live_chunk","rec_chunk"].includes(name)) return true;
      calls.push({name,args});
      switch (name) {
        case "youtube_account_status": return account();
        case "youtube_connect": connected = true; return account();
        case "youtube_disconnect": connected = false; throw Error("Google revoke temporarily unavailable");
        case "youtube_upcoming": return scheduled;
        case "youtube_schedule":
          scheduled.push({id:"scheduled-"+scheduled.length,...args});
          return scheduled.at(-1);
        case "youtube_start": case "rec_begin": case "studio_live_stop": return;
        case "youtube_broadcast_status": return "live";
        case "youtube_complete": if (!attemptEnd++) throw Error("temporary network failure"); return;
        case "rec_finish": window.recorded = args; return;
        default: throw Error("Unexpected IPC "+name);
      }
    }},
    window: {getCurrentWindow:() => ({onCloseRequested:async () => {},destroy:async () => { window.didClose = true; }})},
  };
  function synthetic(color,w,h) {
    const c = document.createElement("canvas"); c.width=w; c.height=h;
    const ctx = c.getContext("2d");
    function draw() {
      ctx.fillStyle=color; ctx.fillRect(0,0,w,h);
      ctx.fillStyle="#fff"; ctx.fillRect(Math.floor(performance.now()/25)%w,0,2,2);
    }
    draw(); setInterval(draw,50); return c.captureStream(20);
  }
  Object.defineProperties(navigator.mediaDevices,{
    getDisplayMedia:{value:async () => synthetic("#3267a5",320,180)},
    getUserMedia:{value:async () => synthetic("#f06d27",180,320)},
  });
}

(async () => {
  const browser = await chromium.launch({
    ...(process.env.EASYCUT_CHROME ? {executablePath:process.env.EASYCUT_CHROME} : {}),
    args:["--autoplay-policy=no-user-gesture-required"],headless:true,
  });
  try {
    const page = await browser.newPage({viewport:{width:800,height:600}});
    const errors=[]; page.on("pageerror",e=>errors.push(String(e)));
    await page.addInitScript(fixture);
    await page.route("**/*",r => {
      const u = new URL(r.request().url()), name=path.basename(u.pathname);
      if (u.hostname !== "localhost" || !/^(studio([a-z-]+)?\.(html|js|css)|i18n\.js|style\.css|strings\.js)$/.test(name)) return r.abort();
      const contentType = name.endsWith(".html") ? "text/html" : name.endsWith(".css") ? "text/css" : "text/javascript";
      return r.fulfill({body:fs.readFileSync(path.join(ui,name)),contentType});
    });
    await page.goto("http://localhost/studio.html");
    await page.waitForSelector('body[data-phase=setup]');
    const $ = s => page.locator(s);
    assert.equal(await $("#camera").isChecked(),false);
    await $("#output").selectOption("youtube");
    await $("#connect").click();
    assert.match(await $("#channel-state").innerText(),/테스트 채널/);
    await $("#disconnect").click();
    await $("#connect").waitFor({state:"visible"});
    assert.match(await $("#notice").innerText(),/revoke/);
    await $("#connect").click();
    await $("#broadcast-title").fill("비공개 방송 점검");
    await $("#broadcast-mode").selectOption("schedule");
    await $("#schedule").click();
    assert.match(await $("#notice").innerText(),/예약 일시/);
    assert.equal(await page.evaluate(()=>calls.filter(c=>c.name==="youtube_schedule").length),0);
    await $("#schedule-time").fill("2099-05-20T15:30");
    await $("#schedule").click();
    await $("#existing-fields").waitFor({state:"visible"});
    assert.equal(await $("#broadcasts").inputValue(),"scheduled-0");
    assert.match(await $("#broadcasts").innerText(),/비공개 방송 점검/);
    await $("#reload").click();
    await $("#camera").check();
    await $("#prepare").click();
    await page.waitForSelector("body[data-phase=ready]");
    await $("#go").click();
    await page.waitForSelector("body[data-phase=recording]");
    assert.equal(await page.evaluate(()=>calls.filter(c=>c.name==="youtube_schedule").length),1);
    let started = await page.evaluate(()=>calls.find(c=>c.name==="youtube_start").args);
    assert.deepEqual(started,{id:"scheduled-0",privacy:"private"});
    await $('#scenes button[value=pip]').click();
    await $("#edit-layout").click();
    await $("#layer").selectOption("camera");
    const sel = $("#selection");
    const before = await sel.boundingBox();
    const stage = await $("#layout-stage").boundingBox();
    await page.mouse.move(before.x+before.width/2,before.y+before.height/2);
    await page.mouse.down(); await page.mouse.move(stage.x+stage.width*.42,stage.y+stage.height*.33,{steps:3}); await page.mouse.up();
    const after = await sel.boundingBox();
    assert(after.x < before.x-stage.width*.15 && after.y < before.y-stage.height*.15);
    const corner = await $('[data-corner="br"]').boundingBox();
    await page.mouse.move(corner.x+corner.width/2,corner.y+corner.height/2);
    await page.mouse.down(); await page.mouse.move(corner.x+35,corner.y+40,{steps:3}); await page.mouse.up();
    assert((await sel.boundingBox()).width > after.width);
    await $("#layer").selectOption("screen"); await $("#shrink").click(); await $("#front").click();
    await $("#apply-layout").click();
    await $("#edit-layout").click(); await $("#reset-layout").click(); await $("#cancel-layout").click();
    assert.equal(await $('#scenes [value=custom]').getAttribute("aria-pressed"),"true");
    await page.waitForFunction(()=>document.getElementById("status").innerText.includes("YouTube 방송 중"));
    await $("#stop").click();
    await page.waitForSelector("body[data-phase=done]");
    const cuts = await page.evaluate(()=>window.recorded.studioCuts);
    assert.equal(cuts.length,3); assert.equal(cuts[0].at,0);
    assert(cuts[2].custom && cuts[2].screenOnTop && cuts[2].screen[2]<1 && cuts[2].camera[0]<.6);
    assert(cuts[2].at>cuts[1].at);
    assert.match(await $("#notice").innerText(),/YouTube 방송 종료/);
    await $("#retry-end").click(); await $("#retry-end").waitFor({state:"hidden"});
    await $("#return-editor").click();
    assert(await page.evaluate(()=>window.didClose));
    await page.reload(); await $("#camera").check(); await $("#edit-layout").click();
    assert.equal(await $("#front").isDisabled(),true);
    await $("#layer").selectOption("camera");
    const persisted=await sel.boundingBox(); assert(Math.abs(persisted.x-after.x)<3);
    await $("#cancel-layout").click();
    await $("#output").selectOption("youtube"); await $("#connect").click();
    await $("#broadcast-title").fill("즉시 방송 점검");
    await $("#camera").uncheck();
    await $('#scenes button[value=custom]').click();
    await $("#prepare").click(); await page.waitForSelector("body[data-phase=ready]");
    await $("#go").click(); await page.waitForSelector("body[data-phase=recording]");
    const instant = await page.evaluate(()=>calls.filter(c=>c.name==="youtube_schedule").map(c=>c.args));
    assert.deepEqual(instant,[{title:"즉시 방송 점검",scheduledAt:null,privacy:"private",madeForKids:false}]);
    await $("#stop").click(); await page.waitForFunction(()=>window.recorded);
    const screenOnly = await page.evaluate(()=>window.recorded.studioCuts[0]);
    assert(screenOnly.custom && screenOnly.camera === null && screenOnly.screen[2] < 1);
    assert.deepEqual(errors,[]);
    console.log("PASS: synthetic studio UI, private scheduling, source geometry, layer ordering, recording cuts, disconnect and end retries");
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
