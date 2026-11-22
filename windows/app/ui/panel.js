// 녹화 중 떠 있는 작은 창: 경과 시간, 일시정지, 정지, 카메라 미리보기 (녹화 영상에는 찍히지 않는다)
(function () {
  const ev = window.__TAURI__.event;
  const $ = (s) => document.querySelector(s);
  let st = { phase: "countdown", base: Date.now(), elapsed: 0 };
  const fmt = (s) => {
    s = Math.floor(s);
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return (h ? h + ":" + String(m).padStart(2, "0") : String(m).padStart(2, "0")) + ":" + String(x).padStart(2, "0");
  };
  $("#hint").textContent = L("Ctrl+Alt+P 일시정지 · Ctrl+Alt+S 정지");
  $("#pause").onclick = () => ev.emit("rec-control", { action: st.phase === "countdown" ? "cancel" : "pause" });
  $("#stop").onclick = () => ev.emit("rec-control", { action: "stop" });

  ev.listen("rec-camera-error", ({payload}) => { $("#hint").textContent = payload; });
  ev.listen("rec-camera-preview", ({payload}) => {
    const image = $("#cam");
    image.src = payload;
    image.style.display = "block";
  });

  function draw() {
    const running = st.phase === "recording";
    const secs = running ? (Date.now() - st.base) / 1000 : st.elapsed;
    $("#t").textContent = st.phase === "saving" ? L("저장 중…") : fmt(secs);
    $("#dot").className = running ? "blink" : st.phase === "paused" ? "paused" : "";
    $("#pause").textContent = st.phase === "paused" ? "▶" : st.phase === "countdown" ? "✕" : "❚❚";
    $("#pause").title = st.phase === "countdown" ? L("취소") : "Ctrl+Alt+P";
    const c = $("#count");
    if (st.phase === "countdown" && st.count) { c.style.display = "flex"; c.textContent = st.count; } else c.style.display = "none";
  }

  ev.listen("rec-status", (e) => {
    st = e.payload;
    draw();
  });
  setInterval(draw, 250);
  draw();
})();
