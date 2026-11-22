import { mountLayoutEditor, sceneFrames, sceneNames, readLayout, order, paint } from "./studio-layout.js";
import { mountYouTube } from "./studio-youtube.js";

const { core: { invoke }, window: appWindows } = window.__TAURI__;
const $ = id => document.getElementById(id);
const canvas = $("preview");
let phase = "setup", scene = "screen", custom = readLayout();
let streams = [], sources = {}, writers = [], cuts = [], frameTimer, started = 0;
let liveRecorder = null, liveStream = null, audioContext = null, encoderStarted = false;
let liveState = "", liveWrites = Promise.resolve(), liveFailed = false, rawError = "";
let connectTimer, statusTimer, lastStatusCheck = 0, statusPending = false, ownsFiles = false, completedMessage = "";
let ending = null;
const youtube = mountYouTube(invoke,refresh);
const failText = error => L(String(error?.message || error));
const canSwitch = () => ["setup","ready","recording"].includes(phase);
const cameraAvailable = () => Boolean(sources.camera || (phase === "setup" && $("camera").checked));
const output = () => $("output").value;
const aspect = video => video?.videoWidth / video?.videoHeight || 16/9;
const frames = (id = scene, layout = custom) => sceneFrames(id,$("corner").value,layout,aspect(sources.screen),aspect(sources.camera),cameraAvailable());
const names = {setup:"입력 대기",preparing:"장치 연결 중…",ready:"미리보기",starting:"시작 중…",recording:"녹화 중",saving:"저장 중…",done:"녹화 종료"};

function refresh() {
  document.body.dataset.phase = phase;
  const configurable = ["setup","ready"].includes(phase);
  $("devices").disabled = phase !== "setup";
  $("live-options").disabled = !configurable;
  $("output").disabled = youtube.busy;
  $("prepare").hidden = !configurable;
  $("prepare").classList.toggle("primary",phase === "setup");
  $("prepare").disabled = youtube.busy;
  $("go").hidden = phase !== "ready";
  $("go").disabled = youtube.busy;
  $("go").textContent = L(output() === "local" ? "녹화 시작" : "녹화·송출 시작");
  $("stop").hidden = phase !== "recording";
  $("return-editor").hidden = phase !== "done";
  $("retry-end").hidden = phase !== "done" || !youtube.pendingEnd;
  $("retry-end").disabled = Boolean(ending);
  $("return-editor").disabled = Boolean(ending);
  $("status").textContent = [L(names[phase]),L(liveState)].filter(Boolean).join(" · ");
  $("empty-stage").hidden = Boolean(sources.screen);
  $("corner-control").hidden = scene !== "pip";
  $("corner").disabled = !canSwitch();
  $("edit-layout").disabled = !canSwitch();
  $("rtmp-fields").hidden = output() !== "rtmp";
  $("youtube-fields").hidden = output() !== "youtube";
  youtube.render();
  for (const button of $("scenes").children) {
    const value = button.value;
    button.disabled = !canSwitch() || (!cameraAvailable() && !["custom","screen"].includes(value));
    button.setAttribute("aria-pressed",String(value === scene));
    const sample = sceneFrames(value,$("corner").value,custom,16/9,16/9,true);
    const icon = button.querySelector(".scene-icon");
    for (const key of order(sample)) {
      const layer = icon.querySelector("."+key), rect = sample[key];
      layer.hidden = !rect;
      if (!rect) continue;
      [layer.style.left,layer.style.top,layer.style.width,layer.style.height] = rect.map(v=>v*100+"%");
      layer.style.zIndex = String(order(sample).indexOf(key));
    }
  }
}
function draw() {
  paint(canvas,frames(),sources);
  drawLayout();
  if (phase === "recording") {
    const sec = Math.floor((performance.now()-started)/1000);
    $("elapsed").textContent = String(Math.floor(sec/60)).padStart(2,"0")+":"+String(sec%60).padStart(2,"0");
  }
}
function changeScene(id, layout = custom) {
  custom = layout; scene = id;
  if (phase === "recording") cuts.push({at:(performance.now()-started)/1000,...frames()});
  draw(); refresh();
}
const drawLayout = mountLayoutEditor({
  getLayout:() => custom, getFrames:layout => frames("custom",layout), getSources:() => sources,
  cameraAvailable, apply:layout => changeScene("custom",layout),
});
for (const [value,name] of Object.entries(sceneNames)) {
  const btn = document.createElement("button");
  btn.value = value;
  const icon = document.createElement("span"); icon.className = "scene-icon"; icon.setAttribute("aria-hidden","true");
  for (const key of ["screen","camera"]) {
    const layer = document.createElement("i"); layer.className = key; icon.append(layer);
  }
  btn.append(icon,document.createTextNode(L(name)));
  btn.onclick = () => { if (phase !== "saving" && scene !== value) changeScene(value); };
  $("scenes").append(btn);
}
$("corner").onchange = () => changeScene(scene);
$("camera").onchange = () => {
  if (!cameraAvailable() && !["screen","custom"].includes(scene)) scene = "screen";
  draw(); refresh();
};

async function video(stream) {
  const element = document.createElement("video");
  element.muted = true; element.playsInline = true; element.srcObject = stream;
  await element.play(); return element;
}
function releaseSources() {
  clearInterval(frameTimer);
  for (const stream of streams) for (const track of stream.getTracks()) track.stop();
  streams = []; sources = {};
}
async function prepare() {
  phase = "preparing"; releaseSources(); refresh(); $("notice").textContent = "";
  try {
    const display = await navigator.mediaDevices.getDisplayMedia({ video:{frameRate:30},audio:$("system").checked });
    streams.push(display); sources.screen = await video(display);
    if ($("camera").checked) {
      const cam = await navigator.mediaDevices.getUserMedia({video:{width:{ideal:1280},height:{ideal:720}}});
      streams.push(cam); sources.camera = await video(cam);
    }
    if ($("mic").checked) {
      sources.mic = await navigator.mediaDevices.getUserMedia({audio:true}); streams.push(sources.mic);
    }
    if ($("system").checked && !display.getAudioTracks().length)
      $("notice").textContent = L("선택한 화면에서 컴퓨터 소리가 공유되지 않았습니다.");
    display.getVideoTracks()[0].addEventListener("ended",() => {
      if (phase === "recording") finish();
      else if (phase === "ready") { releaseSources(); phase = "setup"; refresh(); draw(); }
    });
    if (display.getVideoTracks()[0].readyState === "ended") throw Error(L("화면 공유가 끝났습니다."));
    if (!sources.camera && !["screen","custom"].includes(scene)) scene = "screen";
    phase = "ready"; frameTimer = setInterval(draw,1000/30);
  } catch (e) { releaseSources(); phase = "setup"; $("notice").textContent = failText(e); }
  refresh(); draw();
}

function makeWriter(kind, stream) {
  const audio = kind === "system";
  const types = audio ? ["audio/webm;codecs=opus","audio/webm"] : ["video/webm;codecs=vp8,opus","video/webm"];
  const mimeType = types.find(type => MediaRecorder.isTypeSupported(type));
  if (!mimeType) throw Error(L("이 장치에서는 녹화 형식을 지원하지 않습니다."));
  const recorder = new MediaRecorder(stream,{mimeType,videoBitsPerSecond:kind === "screen" ? 6000000 : 3000000});
  const writer = {kind,recorder,pending:Promise.resolve()};
  function fail() {
    rawError = L("녹화 파일 일부를 저장하지 못했습니다.");
    if (phase === "recording") finish();
  }
  recorder.onerror = fail;
  recorder.ondataavailable = ({data}) => {
    if (data.size) writer.pending = writer.pending.then(async () => {
      await invoke("rec_chunk",new Uint8Array(await data.arrayBuffer()),{headers:{"x-kind":kind}});
    }).catch(fail);
  };
  return writer;
}
async function stopRecorder(recorder) {
  if (!recorder || recorder.state === "inactive") return;
  await new Promise(resolve => {
    recorder.addEventListener("stop",resolve,{once:true});
    recorder.stop();
  });
}
function liveError(reason) {
  if (liveFailed) return;
  liveFailed = true; clearTimeout(connectTimer); clearInterval(statusTimer);
  liveState = "송출 중단";
  if (liveRecorder?.state === "recording") liveRecorder.stop();
  $("notice").textContent = [L("로컬 녹화는 계속됩니다."),failText(reason)].join(" ");
  if (encoderStarted) invoke("studio_live_stop").catch(() => {});
  refresh();
}
async function checkRemote() {
  const id = youtube.active;
  if (statusPending || !id || liveFailed || phase !== "recording") return;
  if (liveState === "YouTube 방송 중" && Date.now() - lastStatusCheck < 60000) return;
  lastStatusCheck = Date.now(); statusPending = true;
  try {
    const status = await youtube.status(id);
    if (phase !== "recording" || youtube.active !== id || liveFailed) return;
    if (status === "live") liveState = "YouTube 방송 중";
    else if (["complete","revoked"].includes(status)) liveError(L("YouTube 방송이 종료되었습니다."));
    else liveState = "YouTube 방송 시작 대기";
    refresh();
  } catch (error) {
    if (phase === "recording" && !liveFailed) { liveState = "YouTube 상태 확인 중"; refresh(); }
  } finally { statusPending = false; }
}
async function startLive() {
  audioContext = new AudioContext();
  await audioContext.resume();
  const mix = audioContext.createMediaStreamDestination();
  const silence = audioContext.createConstantSource();
  silence.offset.value = 0; silence.connect(mix); silence.start();
  for (const stream of [sources.mic,sources.screen.srcObject]) {
    if (stream?.getAudioTracks().length) audioContext.createMediaStreamSource(stream).connect(mix);
  }
  liveStream = canvas.captureStream(30);
  for (const t of mix.stream.getAudioTracks()) liveStream.addTrack(t);
  liveRecorder = new MediaRecorder(liveStream,{mimeType:"video/webm;codecs=vp8,opus",videoBitsPerSecond:4000000});
  let queued = 0, connected = false;
  liveRecorder.ondataavailable = ({data}) => {
    if (liveFailed || !data.size) return;
    if (++queued > 16) { liveError(L("송출 연결 속도를 확인하세요.")); return; }
    liveWrites = liveWrites.then(async () => {
      if (liveFailed) return;
      const sending = await invoke("studio_live_chunk",new Uint8Array(await data.arrayBuffer()));
      if (sending && !connected) {
        connected = true; clearTimeout(connectTimer);
        liveState = output() === "youtube" ? "YouTube 방송 시작 대기" : "송출 중";
        checkRemote(); refresh();
      }
    }).catch(liveError).finally(() => queued--);
  };
  liveRecorder.onerror = () => liveError(L("송출 인코더 오류"));
  if (output() === "youtube") await youtube.start();
  else {
    await invoke("studio_live_start",{server:$("server").value.trim(),key:$("key").value.trim()});
    $("key").value = "";
  }
  encoderStarted = true;
  liveState = "송출 연결 중…"; liveRecorder.start(250);
  connectTimer = setTimeout(() => liveError(L("송출 서버 연결 시간이 초과되었습니다.")),30000);
  if (youtube.active) statusTimer = setInterval(checkRemote,4000);
}
async function stopLive() {
  clearTimeout(connectTimer); clearInterval(statusTimer);
  await stopRecorder(liveRecorder); await liveWrites;
  if (encoderStarted) { await invoke("studio_live_stop"); encoderStarted = false; }
  liveStream?.getTracks().forEach(t=>t.stop()); liveStream = null;
  await audioContext?.close(); audioContext = null; liveRecorder = null; liveState = "";
}
async function start() {
  if (phase !== "ready" || youtube.busy) return;
  $("notice").textContent = "";
  try {
    if (output() === "youtube") youtube.validate();
    if (output() === "rtmp" && (!/^rtmps?:\/\//i.test($("server").value.trim()) || !$("key").value.trim()))
      throw Error(L("RTMP 또는 RTMPS 서버 주소와 스트림 키를 확인하세요."));
  } catch (e) { $("notice").textContent = failText(e); return; }
  phase = "starting"; refresh(); rawError = ""; liveFailed = false;
  writers = []; cuts = []; liveWrites = Promise.resolve();
  try {
    if (output() === "youtube" && !await youtube.approveStart()) {
      phase = "ready"; refresh(); return;
    }
    const display = sources.screen.srcObject;
    writers.push(makeWriter("screen",new MediaStream([...display.getVideoTracks(),...(sources.mic?.getAudioTracks() || [])])));
    if (sources.camera) writers.push(makeWriter("camera",sources.camera.srcObject));
    if (display.getAudioTracks().length) writers.push(makeWriter("system",new MediaStream(display.getAudioTracks())));
    await invoke("rec_begin",{kinds:writers.map(w=>[w.kind,"webm"])}); ownsFiles = true;
    if (display.getVideoTracks()[0].readyState === "ended") throw Error(L("화면 공유가 끝났습니다."));
    started = performance.now(); cuts = [{at:0,...frames()}];
    for (const writer of writers) writer.recorder.start(500);
    if (output() !== "local") {
      try { await startLive(); }
      catch (e) { liveError(e); }
    }
    phase = "recording"; refresh();
    if (display.getVideoTracks()[0].readyState === "ended" || rawError) await finish();
  } catch (e) {
    await Promise.all(writers.map(w=>stopRecorder(w.recorder)));
    await Promise.all(writers.map(w=>w.pending));
    if (ownsFiles) await invoke("rec_discard");
    ownsFiles = false; writers = []; releaseSources(); phase = "setup";
    $("notice").textContent = failText(e); refresh();
  }
}
async function completeRemote() {
  ending = youtube.finish();
  refresh();
  try { await ending; }
  catch (e) { throw Error(L("YouTube 방송 종료를 확인하지 못했습니다.")+" "+failText(e)); }
  finally { ending = null; refresh(); }
}
async function finish() {
  if (phase !== "recording") return;
  if ($("layout-dialog").open) $("layout-dialog").close();
  phase = "saving"; refresh();
  const errors = [];
  const ends = await Promise.allSettled([stopLive(),...writers.map(w=>stopRecorder(w.recorder))]);
  for (const result of ends) if (result.status === "rejected") errors.push(failText(result.reason));
  await Promise.all(writers.map(w=>w.pending));
  releaseSources();
  const [rec,remote] = await Promise.allSettled([
    invoke("rec_finish",{cameraCircle:false,clicks:null,showClicks:false,area:null,studioCuts:cuts}),
    completeRemote(),
  ]);
  ownsFiles = false;
  if (rec.status === "rejected") errors.push(L("녹화 파일을 가져오지 못했습니다: {}",failText(rec.reason)));
  if (rawError) errors.push(rawError);
  completedMessage = errors.join(" ");
  if (remote.status === "rejected") errors.push(failText(remote.reason));
  if (!errors.length) { await appWindows.getCurrentWindow().destroy(); return; }
  phase = "done"; liveState = ""; $("notice").textContent = errors.join(" "); refresh();
}
$("retry-end").onclick = async () => {
  try { await completeRemote(); $("notice").textContent = completedMessage || L("YouTube 방송을 종료했습니다."); }
  catch (e) { $("notice").textContent = [completedMessage,failText(e)].filter(Boolean).join(" "); }
};
$("return-editor").onclick = () => appWindows.getCurrentWindow().destroy();
$("prepare").onclick = prepare; $("go").onclick = start; $("stop").onclick = finish;
$("output").onchange = () => { refresh(); if (output() === "youtube") youtube.inspect(); };
await appWindows.getCurrentWindow().onCloseRequested(event => {
  if (phase === "recording") { event.preventDefault(); finish(); }
  else if (["saving","starting","preparing"].includes(phase) || youtube.busy || ending) event.preventDefault();
  else releaseSources();
});
window.applyI18n();
for (const element of document.querySelectorAll("[data-l-aria]")) {
  element.setAttribute("aria-label",L(element.dataset.lAria)); element.title = L(element.dataset.lAria);
}
document.title = "EasyCut · "+L("방송 스튜디오");
refresh(); draw();
