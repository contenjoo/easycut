// Geometry is normalized to the 16:9 program, with the origin at the top left.
const full = [0, 0, 1, 1];
const storageKey = "easycut.studio.customLayout.v1";
export const sceneNames = { screen: "화면만", camera: "카메라만", pip: "화면 속 카메라", split: "나란히", custom: "내 배치" };
export const defaultLayout = () => ({ screen: [...full], camera: [.70,.70,.28,.28], screenOnTop: false });
const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

function bounded(box, fallback) {
  if (!Array.isArray(box) || box.length !== 4 || !box.every(Number.isFinite)) return [...fallback];
  const w = clamp(box[2], .05, 1), h = clamp(box[3], .05, 1);
  return [clamp(box[0],0,1-w), clamp(box[1],0,1-h), w, h];
}

export function readLayout() {
  const base = defaultLayout();
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey));
    if (saved) return { screen: bounded(saved.screen,base.screen), camera: bounded(saved.camera,base.camera), screenOnTop: saved.screenOnTop === true };
  } catch { /* A restricted or older profile can still use the editor. */ }
  return base;
}

function fit(box, aspect) {
  const ratio = aspect > 0 && Number.isFinite(aspect) ? aspect / (16/9) : 1;
  const w = Math.min(box[2],box[3]*ratio), h = w / ratio;
  return [box[0]+(box[2]-w)/2, box[1]+(box[3]-h)/2, w, h];
}

export function sceneFrames(scene, corner, custom, screenAspect, cameraAspect, hasCamera) {
  let screen = full, camera = null;
  const customScene = scene === "custom";
  if (customScene) {
    screen = custom.screen;
    camera = hasCamera ? fit(custom.camera,cameraAspect) : null;
  } else if (hasCamera) {
    if (scene === "camera") { screen = null; camera = fit(full,cameraAspect); }
    if (scene === "split") { screen = [0,0,.5,1]; camera = fit([.5,0,.5,1],cameraAspect); }
    if (scene === "pip") {
      const [, ,w,h] = fit([0,0,.28,.42],cameraAspect);
      camera = [corner.endsWith("l") ? .02 : .98-w,corner.startsWith("t") ? .02 : .98-h,w,h];
    }
  }
  return { screen: screen && fit(screen,screenAspect), camera, custom: customScene, screenOnTop: customScene && custom.screenOnTop };
}

export function order(frames) { return frames.screenOnTop ? ["camera","screen"] : ["screen","camera"]; }

export function paint(canvas, frames, sources, guides = false) {
  const ctx = canvas.getContext("2d",{alpha:false});
  ctx.fillStyle = "#09090b"; ctx.fillRect(0,0,canvas.width,canvas.height);
  for (const key of order(frames)) {
    const rect = frames[key];
    if (!rect) continue;
    const [x,y,w,h] = rect.map((v,i) => v*(i%2 ? canvas.height : canvas.width));
    const source = sources[key];
    if (source?.videoWidth) ctx.drawImage(source,x,y,w,h);
    else if (guides) {
      ctx.fillStyle = key === "screen" ? "#263b53" : "#37645f";
      ctx.fillRect(x,y,w,h); ctx.fillStyle = "#eef2f7";
      ctx.font = "26px Segoe UI, sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(L(key === "screen" ? "화면" : "카메라"),x+w/2,y+h/2,w);
    }
  }
}

export function mountLayoutEditor({getLayout, getFrames, getSources, cameraAvailable, apply}) {
  const $ = id => document.getElementById(id);
  const dialog = $("layout-dialog"), stage = $("layout-stage"), selector = $("layer");
  let draft, drag = null, explicitSelection = false;
  function render() {
    if (!dialog.open) return;
    const frames = getFrames(draft);
    paint($("layout-preview"),frames,getSources(),true);
    const rect = frames[selector.value] || frames.screen;
    const sel = $("selection");
    [sel.style.left,sel.style.top,sel.style.width,sel.style.height] = rect.map(v => v*100+"%");
    $("front").disabled = !frames.camera || (selector.value === "screen") === draft.screenOnTop;
  }
  function setBox(box) {
    // Dragging an aspect-fitted source must preserve the source's aspect ratio.
    const w = box[2], h = box[3];
    draft[selector.value] = [clamp(box[0],0,1-w),clamp(box[1],0,1-h),w,h];
    render();
  }
  function move(dx,dy) {
    const [x,y,w,h] = getFrames(draft)[selector.value];
    setBox([x+dx,y+dy,w,h]);
  }
  function scale(factor) {
    const [x,y,w,h] = getFrames(draft)[selector.value];
    const amount = clamp(factor,.06/Math.min(w,h),Math.min(1/w,1/h));
    setBox([x+w*(1-amount)/2,y+h*(1-amount)/2,w*amount,h*amount]);
  }
  $("edit-layout").onclick = () => {
    draft = structuredClone(getLayout());
    selector.value = "screen"; selector.options[1].disabled = !cameraAvailable();
    explicitSelection = false;
    dialog.showModal(); render(); stage.focus();
  };
  selector.onchange = () => { explicitSelection = true; render(); };
  $("front").onclick = () => { draft.screenOnTop = selector.value === "screen"; render(); };
  $("shrink").onclick = () => scale(1/1.15);
  $("grow").onclick = () => scale(1.15);
  for (const button of dialog.querySelectorAll("[data-dx],[data-dy]"))
    button.onclick = () => move(Number(button.dataset.dx || 0)*.01,Number(button.dataset.dy || 0)*.01);
  $("reset-layout").onclick = () => { draft = defaultLayout(); render(); };
  $("cancel-layout").onclick = () => dialog.close();
  $("apply-layout").onclick = () => {
    apply(draft); dialog.close();
    try { localStorage.setItem(storageKey,JSON.stringify(draft)); }
    catch { $("notice").textContent = L("배치는 적용했습니다. 이 기기에 저장하지 못했습니다."); }
  };
  stage.onkeydown = event => {
    const delta = {ArrowLeft:[-.01,0], ArrowUp:[0,-.01], ArrowRight:[.01,0], ArrowDown:[0,.01]}[event.key];
    if (delta) { event.preventDefault(); move(...delta.map(v => v*(event.shiftKey ? 5 : 1))); }
    if (["+","=","-"].includes(event.key)) { event.preventDefault(); scale(event.key === "-" ? 1/1.15 : 1.15); }
  };
  stage.onpointerdown = event => {
    if (!event.isPrimary || event.button !== 0) return;
    const bounds = stage.getBoundingClientRect(), frames = getFrames(draft);
    const x = (event.clientX-bounds.left)/bounds.width, y = (event.clientY-bounds.top)/bounds.height;
    const corner = event.target.dataset.corner;
    const hit = key => {
      const r = frames[key]; return r && x>=r[0] && x<=r[0]+r[2] && y>=r[1] && y<=r[1]+r[3];
    };
    if (!corner) {
      const target = explicitSelection && hit(selector.value) ? selector.value : order(frames).reverse().find(hit);
      if (!target) return;
      selector.value = target;
    }
    drag = {id:event.pointerId,x:event.clientX,y:event.clientY,rect:frames[selector.value],bounds,corner};
    stage.setPointerCapture(event.pointerId); stage.focus(); render();
  };
  stage.onpointermove = event => {
    if (!drag || drag.id !== event.pointerId) return;
    const dx = (event.clientX-drag.x)/drag.bounds.width, dy = (event.clientY-drag.y)/drag.bounds.height;
    const [x,y,w,h] = drag.rect;
    if (!drag.corner) return setBox([x+dx,y+dy,w,h]);
    const right = drag.corner.endsWith("r"), bottom = drag.corner.startsWith("b");
    const x0 = right ? x : x+w, y0 = bottom ? y : y+h;
    const sx = w*drag.bounds.width*(right ? 1 : -1), sy = h*drag.bounds.height*(bottom ? 1 : -1);
    const limit = Math.min((right ? 1-x0 : x0)/w,(bottom ? 1-y0 : y0)/h);
    const amt = clamp(1+(dx*drag.bounds.width*sx+dy*drag.bounds.height*sy)/(sx*sx+sy*sy),.06/Math.min(w,h),limit);
    setBox([right ? x0 : x0-w*amt,bottom ? y0 : y0-h*amt,w*amt,h*amt]);
  };
  stage.onlostpointercapture = () => { drag = null; };
  dialog.onclose = () => { drag = null; };
  return render;
}
