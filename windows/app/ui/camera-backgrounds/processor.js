// The worker consumes camera frames directly, including while the editor is minimized.
// The caller owns the input stream; the output track stays stable across effect changes.
export async function createCameraBackgroundStream(raw, effect = {mode: "off"}, {onError} = {}) {
  const camera = raw.getVideoTracks()[0];
  if (!camera || camera.readyState === "ended") throw new Error("카메라 입력이 종료되었습니다.");
  if (!window.MediaStreamTrackProcessor || !window.MediaStreamTrackGenerator) {
    const unsupported = () => new Error("카메라 배경 효과를 사용하려면 Microsoft Edge WebView2를 업데이트해 주세요.");
    if (effect.mode !== "off") throw unsupported();
    const track = camera.clone();
    return {
      stream: new MediaStream([track]),
      async setEffect(value) {
        track.enabled = value.mode === "off";
        if (!track.enabled) throw unsupported();
      },
      stop() { track.stop(); },
    };
  }
  const worker = new Worker(new URL("./worker.js", import.meta.url), {type: "module"});
  let input, output;
  const pending = new Map();
  let sequence = 0, stopped = false;

  function stop() {
    if (stopped) return;
    stopped = true;
    worker.terminate();
    input?.stop();
    output?.stop();
    for (const request of pending.values()) request.reject(new Error("카메라 배경 처리가 종료되었습니다."));
    pending.clear();
  }

  function fatal(error) {
    if (stopped) return;
    for (const request of pending.values()) request.reject(error);
    pending.clear();
    stop();
    onError?.(error);
  }
  worker.onerror = event => fatal(new Error(event.message || "카메라 배경 처리를 시작할 수 없습니다."));
  worker.onmessage = ({data}) => {
    if (data.type === "fatal") return fatal(new Error(data.message));
    if (data.type === "error") return onError?.(new Error(data.message));
    const request = pending.get(data.id);
    if (!request) return;
    pending.delete(data.id);
    if (data.type === "ready") request.resolve();
    else if (data.type === "superseded") request.reject(new DOMException("배경 선택이 바뀌었습니다.", "AbortError"));
    else request.reject(new Error(data.message));
  };

  function setEffect(selection) {
    if (stopped) return Promise.reject(new Error("카메라가 종료되었습니다."));
    if (!["off", "blur", "image"].includes(selection?.mode)) return Promise.reject(new Error("지원하지 않는 카메라 배경입니다."));
    let url;
    if (selection.mode === "image") {
      url = new URL(selection.url, document.baseURI);
      // Only bundled presets and locally selected pictures can be used here.
      const nativeFile = ["http:", "https:"].includes(url.protocol) && url.host === "asset.localhost" && !url.username && !url.password;
      if (url.origin !== location.origin && !nativeFile && !(url.protocol === "data:" && /^data:image\//i.test(url.href))) {
        return Promise.reject(new Error("이 기기에 저장된 배경 이미지를 선택해 주세요."));
      }
    }
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (pending.has(id)) fatal(new Error("카메라 영상을 받지 못했습니다. 카메라를 다시 연결해 주세요."));
      }, 20000);
      pending.set(id, {
        resolve() { clearTimeout(timer); resolve(); },
        reject(error) { clearTimeout(timer); reject(error); },
      });
      worker.postMessage({type: "effect", id, mode: selection.mode, url: url?.href});
    });
  }
  try {
    input = camera.clone();
    output = new MediaStreamTrackGenerator({kind: "video"});
    const {readable} = new MediaStreamTrackProcessor({track: input, maxBufferSize: 1});
    const {writable} = output;
    worker.postMessage({type: "start", readable, writable}, [readable, writable]);
    await setEffect(effect);
    return {stream: new MediaStream([output]), setEffect, stop};
  } catch (error) {
    stop();
    throw error;
  }
}
