// 화면·얼굴 녹화 (맥 RecordController.swift / RecordViews.swift)
// 화면: getDisplayMedia, 카메라·마이크: getUserMedia, 기록: MediaRecorder(1초마다 조각을 앱에 넘겨 파일로 쓴다)
const tauri = window.__TAURI__;
const invoke = (cmd, args, opts) => tauri.core.invoke(cmd, args, opts);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

let api; // { toast, modal: {box, show, hide}, run, transcribe, S }
const R = {
  phase: "idle", // idle | countdown | recording | paused | saving
  streams: [],
  recorders: [], // { kind, rec }
  writes: Promise.resolve(),
  startedAt: 0,
  pausedTotal: 0,
  pauseBegan: 0,
  timer: null,
  cancelCountdown: false,
  circle: true,
};

// 권한 창을 닫지 않고 두면 끝나지 않으므로 정해진 시간까지만 기다린다
const within = (p, ms) => Promise.race([p, new Promise((_, no) => setTimeout(() => no(new Error(L("시간이 초과되었습니다."))), ms))]);

const pref = (k, d) => { try { const v = localStorage.getItem("rec." + k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } };
const setPref = (k, v) => { try { localStorage.setItem("rec." + k, JSON.stringify(v)); } catch (_) {} };

export function initRecord(a) {
  api = a;
  tauri.event.listen("rec-control", (e) => {
    const act = e.payload?.action;
    if (act === "pause") togglePause();
    if (act === "stop") stop();
    if (act === "cancel") cancel();
  });
}

export const isRecording = () => R.phase !== "idle";

// MARK: 설정 창

export async function openRecordDialog() {
  if (isRecording()) return;
  const box = api.modal.box;
  box.innerHTML = `<h2>🔴 ${L("화면·얼굴 녹화")}</h2><p class="hint">${L("장치 확인 중…")}</p>`;
  api.modal.show();
  // 장치 이름을 보려면 먼저 한 번 권한이 필요하다
  let cams = [], mics = [];
  try {
    const s = await within(navigator.mediaDevices.getUserMedia({ audio: true, video: true }).catch(() => navigator.mediaDevices.getUserMedia({ audio: true })), 8000);
    s.getTracks().forEach((t) => t.stop());
  } catch (_) {}
  try {
    const list = await navigator.mediaDevices.enumerateDevices();
    cams = list.filter((d) => d.kind === "videoinput");
    mics = list.filter((d) => d.kind === "audioinput");
  } catch (_) {}
  const o = {
    target: pref("target", "monitor"),
    useCamera: pref("useCamera", true) && cams.length > 0,
    cameraId: pref("cameraId", ""),
    circle: pref("circle", true),
    useMic: pref("useMic", true) && mics.length > 0,
    micId: pref("micId", ""),
    systemAudio: pref("systemAudio", false),
    clicks: pref("clicks", true),
  };
  const opt = (list, sel) => list.map((d, i) => `<option value="${esc(d.deviceId)}" ${d.deviceId === sel ? "selected" : ""}>${esc(d.label || `#${i + 1}`)}</option>`).join("");
  box.innerHTML = `<h2>🔴 ${L("화면·얼굴 녹화")}</h2>
    <div class="row"><label>${L("녹화할 곳")}</label><select id="r-target">
      <option value="monitor" ${o.target === "monitor" ? "selected" : ""}>${L("전체 화면")}</option>
      <option value="window" ${o.target === "window" ? "selected" : ""}>${L("창")}</option>
      <option value="area" ${o.target === "area" ? "selected" : ""}>${L("영역")}</option></select>
      <button class="mini" id="r-area" style="${o.target === "area" ? "" : "display:none"}">${L("영역 고르기…")}</button></div>
    <p class="hint" id="r-area-info">${o.target === "area" ? (pref("area", null) ? L("고른 영역: 화면의 {}% × {}%", Math.round(pref("area").w * 100), Math.round(pref("area").h * 100)) : L("녹화할 영역을 먼저 고르세요.")) + " " + L("시작하면 그 영역이 있는 화면(전체 화면)을 고르세요.") : L("시작을 누르면 녹화할 화면이나 창을 고르는 창이 뜹니다.")}</p>
    <div class="row"><label><input type="checkbox" id="r-cam" ${o.useCamera ? "checked" : ""} ${cams.length ? "" : "disabled"}/> ${L("카메라")}</label>
      <select id="r-cam-id" ${cams.length ? "" : "disabled"}>${cams.length ? opt(cams, o.cameraId) : `<option>${L("카메라 없음")}</option>`}</select></div>
    <div class="row"><label></label><label class="hint"><input type="checkbox" id="r-circle" ${o.circle ? "checked" : ""}/> ${L("얼굴을 원 모양으로")}</label></div>
    <div class="row"><label><input type="checkbox" id="r-mic" ${o.useMic ? "checked" : ""} ${mics.length ? "" : "disabled"}/> ${L("마이크")}</label>
      <select id="r-mic-id" ${mics.length ? "" : "disabled"}>${mics.length ? opt(mics, o.micId) : `<option>${L("마이크 없음")}</option>`}</select></div>
    <div class="row"><label></label><label class="hint"><input type="checkbox" id="r-sys" ${o.systemAudio ? "checked" : ""}/> ${L("컴퓨터 소리도 녹음 (전체 화면일 때)")}</label></div>
    <div class="row"><label></label><label class="hint"><input type="checkbox" id="r-clicks" ${o.clicks ? "checked" : ""}/> ${L("마우스 클릭 강조 (전체 화면일 때)")}</label></div>
    <p class="hint">${L("녹화 중 단축키: Ctrl+Alt+P 일시정지 · Ctrl+Alt+S 정지")}<br>${L("녹화 파일은 동영상 폴더의 'EasyCut 녹화'에 저장됩니다.")}</p>
    <div class="btns"><button id="r-cancel">${L("취소")}</button><button class="danger" id="r-go">● ${L("녹화 시작")}</button></div>`;
  const q = (s) => box.querySelector(s);
  q("#r-cancel").onclick = api.modal.hide;
  q("#r-target").onchange = (e) => { setPref("target", e.target.value); openRecordDialog(); };
  q("#r-area").onclick = pickArea;
  q("#r-go").onclick = () => {
    if (q("#r-target").value === "area" && !pref("area", null)) return pickArea();
    const opts = {
      target: q("#r-target").value,
      useCamera: q("#r-cam").checked && cams.length > 0,
      cameraId: q("#r-cam-id").value,
      circle: q("#r-circle").checked,
      useMic: q("#r-mic").checked && mics.length > 0,
      micId: q("#r-mic-id").value,
      systemAudio: q("#r-sys").checked,
      clicks: q("#r-clicks").checked,
      area: q("#r-target").value === "area" ? pref("area", null) : null,
    };
    for (const [k, v] of Object.entries(opts)) setPref(k, v);
    api.modal.hide();
    // 화면 고르기는 사용자가 누른 바로 그때 불러야 한다
    start(opts);
  };
}

/// 녹화할 영역 고르기 (화면 위에 끌어서 네모 그리기)
async function pickArea() {
  api.modal.hide();
  const un = await tauri.event.listen("rec-area", async (e) => {
    un();
    await invoke("rec_area", { open: false }).catch(() => {});
    if (e.payload) setPref("area", e.payload);
    openRecordDialog();
  });
  try { await invoke("rec_area", { open: true }); } catch (e) { un(); api.toast(L(String(e))); openRecordDialog(); }
}

// MARK: 시작 · 일시정지 · 정지

/// 녹화 형식. 창 녹화는 창 크기가 바뀔 수 있어(H.264 MP4는 중간에 크기가 바뀌면 깨진다) WebM으로
function pickMime(kind, resizable = false) {
  const mp4 = ["video/mp4;codecs=avc1.640028,mp4a.40.2", "video/mp4;codecs=avc1,opus", "video/mp4"];
  const webm = ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm"];
  const cand = kind === "system" ? ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"] : resizable ? [...webm, ...mp4] : [...mp4, ...webm];
  const found = cand.find((m) => MediaRecorder.isTypeSupported(m)) || "";
  return { mime: found, ext: found.startsWith("video/mp4") || found.startsWith("audio/mp4") ? "mp4" : "webm" };
}

async function start(o) {
  R.circle = o.circle;
  R.area = o.target === "area" ? o.area : null;
  if (o.target === "area") o.target = "monitor";
  R.showClicks = o.clicks;
  let display;
  try {
    display = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: o.target, frameRate: { ideal: 30, max: 60 } },
      audio: o.systemAudio && o.target === "monitor",
      selfBrowserSurface: "exclude",
      systemAudio: o.systemAudio ? "include" : "exclude",
      surfaceSwitching: "exclude",
      monitorTypeSurfaces: "include",
    });
  } catch (e) {
    if (e?.name !== "NotAllowedError" && e?.name !== "AbortError") api.toast(L("화면을 녹화할 수 없습니다: {}", e?.message || e));
    return;
  }
  const streams = [display];
  let mic = null, cam = null;
  try {
    if (o.useMic) { mic = await within(navigator.mediaDevices.getUserMedia({ audio: { deviceId: o.micId ? { exact: o.micId } : undefined, echoCancellation: false, noiseSuppression: true } }), 10000); streams.push(mic); }
  } catch (e) { api.toast(L("마이크를 켜지 못했습니다: {}", e?.message || e)); }
  try {
    if (o.useCamera) { cam = await within(navigator.mediaDevices.getUserMedia({ video: { deviceId: o.cameraId ? { exact: o.cameraId } : undefined, width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } } }), 10000); streams.push(cam); }
  } catch (e) { api.toast(L("카메라를 켜지 못했습니다: {}", e?.message || e)); }
  R.streams = streams;

  // 화면 파일: 화면 영상 + 마이크. 컴퓨터 소리는 따로(트랙 3)
  const screenStream = new MediaStream([...display.getVideoTracks(), ...(mic ? mic.getAudioTracks() : [])]);
  const plan = [{ kind: "screen", stream: screenStream, ...pickMime("screen", o.target === "window") }];
  if (cam) plan.push({ kind: "camera", stream: new MediaStream(cam.getVideoTracks()), ...pickMime("camera") });
  const sysTracks = display.getAudioTracks();
  if (sysTracks.length) plan.push({ kind: "system", stream: new MediaStream(sysTracks), ...pickMime("system") });
  try {
    await invoke("rec_begin", { kinds: plan.map((p) => [p.kind, p.ext]) });
  } catch (e) {
    stopStreams();
    return api.toast(L(String(e)));
  }
  R.recorders = plan.map((p) => {
    const rec = new MediaRecorder(p.stream, { mimeType: p.mime || undefined, videoBitsPerSecond: p.kind === "screen" ? 8_000_000 : 3_000_000, audioBitsPerSecond: 160_000 });
    rec.ondataavailable = (ev) => {
      if (!ev.data?.size) return;
      // 순서대로 쓴다
      R.writes = R.writes.then(async () => {
        const buf = new Uint8Array(await ev.data.arrayBuffer());
        await invoke("rec_chunk", buf, { headers: { "x-kind": p.kind } }).catch((err) => console.error(err));
      });
    };
    return { kind: p.kind, rec };
  });
  // 공유 중지(브라우저 막대)로 화면이 끊기면 녹화도 끝낸다
  display.getVideoTracks()[0]?.addEventListener("ended", () => { if (R.phase === "recording" || R.phase === "paused") stop(); });

  // 정지 창을 띄우고, EasyCut 창을 내린 뒤 3초 세기
  await invoke("rec_panel", { open: true, camera: !!cam }).catch(() => {});
  status();
  const win = tauri.window.getCurrentWindow();
  await win.minimize().catch(() => {});
  R.cancelCountdown = false;
  for (let n = 3; n >= 1; n--) {
    R.phase = "countdown";
    status(n);
    await new Promise((r) => setTimeout(r, 1000));
    if (R.cancelCountdown) return;
  }
  for (const r of R.recorders) r.rec.start(1000);
  // 전체 화면 녹화면 클릭 위치도 기록 (녹화 화면 크기로 모니터를 찾는다)
  const vs = display.getVideoTracks()[0]?.getSettings() || {};
  R.clicks = o.target === "monitor";
  if (R.clicks) invoke("rec_clicks", { action: "start", width: vs.width || 0, height: vs.height || 0 }).catch(() => {});
  R.phase = "recording";
  R.startedAt = performance.now();
  R.pausedTotal = 0;
  R.pauseBegan = 0;
  invoke("rec_hotkeys", { on: true }).catch(() => {});
  status();
}

function elapsed() {
  if (!R.startedAt) return 0;
  const now = R.phase === "paused" ? R.pauseBegan : performance.now();
  return Math.max(0, (now - R.startedAt - R.pausedTotal) / 1000);
}

/// 정지 창에 상태 알림. 창이 내려가 있으면 이쪽 타이머가 느려지므로 경과 시간은 정지 창이 직접 센다 (base = 0초였던 시각)
function status(count) {
  const camId = R.streams.find((s) => s !== R.streams[0] && s.getVideoTracks().length)?.getVideoTracks()[0]?.getSettings().deviceId || null;
  tauri.event.emit("rec-status", { phase: R.phase, elapsed: elapsed(), base: Date.now() - elapsed() * 1000, count: count ?? null, cameraId: camId }).catch(() => {});
}

export function togglePause() {
  if (R.phase === "recording") {
    R.recorders.forEach((r) => r.rec.state === "recording" && r.rec.pause());
    if (R.clicks) invoke("rec_clicks", { action: "pause" }).catch(() => {});
    R.phase = "paused";
    R.pauseBegan = performance.now();
  } else if (R.phase === "paused") {
    R.recorders.forEach((r) => r.rec.state === "paused" && r.rec.resume());
    if (R.clicks) invoke("rec_clicks", { action: "resume" }).catch(() => {});
    R.pausedTotal += performance.now() - R.pauseBegan;
    R.phase = "recording";
  }
  status();
}

function stopStreams() {
  R.streams.forEach((s) => s.getTracks().forEach((t) => t.stop()));
  R.streams = [];
}

async function restoreWindow() {
  const win = tauri.window.getCurrentWindow();
  await win.unminimize().catch(() => {});
  await win.show().catch(() => {});
  await win.setFocus().catch(() => {});
}

async function cancel() {
  if (R.phase === "countdown") R.cancelCountdown = true;
  clearInterval(R.timer);
  R.recorders.forEach((r) => { try { r.rec.stop(); } catch (_) {} });
  stopStreams();
  R.recorders = [];
  R.phase = "idle";
  if (R.clicks) await invoke("rec_clicks", { action: "stop" }).catch(() => {});
  await invoke("rec_hotkeys", { on: false }).catch(() => {});
  await invoke("rec_panel", { open: false, camera: false }).catch(() => {});
  await R.writes;
  await invoke("rec_discard").catch(() => {});
  await restoreWindow();
}

export async function stop() {
  if (R.phase === "countdown") return cancel();
  if (R.phase !== "recording" && R.phase !== "paused") return;
  R.phase = "saving";
  clearInterval(R.timer);
  status();
  await invoke("rec_hotkeys", { on: false }).catch(() => {});
  const clicks = R.clicks ? await invoke("rec_clicks", { action: "stop" }).catch(() => []) : null;
  // 마지막 조각까지 받는다
  await Promise.all(R.recorders.map((r) => new Promise((res) => {
    if (r.rec.state === "inactive") return res();
    r.rec.addEventListener("stop", () => res(), { once: true });
    try { r.rec.stop(); } catch (_) { res(); }
  })));
  await new Promise((r) => setTimeout(r, 50));
  await R.writes;
  stopStreams();
  R.recorders = [];
  await invoke("rec_panel", { open: false, camera: false }).catch(() => {});
  await restoreWindow();
  R.phase = "idle";
  try {
    const a = R.area;
    const r = await invoke("rec_finish", { cameraCircle: R.circle, clicks, showClicks: R.showClicks, area: a ? [a.x, a.y, a.w, a.h] : null });
    api.toast(r.hasCamera ? L("녹화를 넣었습니다 (화면 → 트랙 1, 얼굴 → 트랙 2)") : L("녹화를 타임라인에 넣었습니다"));
    if (r.hasAudio) api.autoTranscribe?.(r.screen);
  } catch (e) {
    api.toast(L("녹화 파일을 가져오지 못했습니다: {}", L(String(e))));
  }
}
