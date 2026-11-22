const presets = [
  ["studio", "스튜디오"],
  ["library", "서재"],
  ["loft", "로프트"],
  ["midnight", "미드나이트"],
];
const preference = "rec.cameraBackground";
const presetURL = id => new URL("./presets/" + id + ".jpg", import.meta.url).href;

function readSelection() {
  try {
    const value = JSON.parse(localStorage.getItem(preference));
    if (value?.id === "blur" || presets.some(([id]) => id === value?.id)) return value;
    if (value?.id === "custom" && typeof value.path === "string" && value.path) return value;
  } catch {}
  return { id: "off" };
}
function effect(selection) {
  if (selection.id === "off" || selection.id === "blur") return { mode: selection.id };
  const url = selection.id === "custom" ? window.__TAURI__.core.convertFileSrc(selection.path) : presetURL(selection.id);
  return { mode: "image", url };
}

export function mountCameraBackgroundPicker(root, {apply, onBusy = () => {}, onError}) {
  let selection = readSelection(), enabled = true, busy = false;
  root.classList.add("camera-background-picker");
  root.replaceChildren();
  const legend = document.createElement("legend");
  legend.textContent = L("카메라 배경");
  const options = document.createElement("div");
  options.className = "camera-background-modes";
  const gallery = document.createElement("div");
  gallery.className = "camera-background-presets";
  root.append(legend, options, gallery);
  const buttons = new Map();

  function render() {
    root.disabled = !enabled || busy;
    root.setAttribute("aria-busy", String(busy));
    for (const [id, button] of buttons) button.setAttribute("aria-pressed", String(id === selection.id));
    buttons.get("custom").title = selection.id === "custom" ? selection.path.split(/[\\/]/).pop() : L("내 사진 선택");
  }
  async function choose(id) {
    if (!enabled || busy) return;
    busy = true; render(); onBusy(true);
    try {
      const next = {id};
      if (id === "custom") {
        const path = await window.__TAURI__.dialog.open({
          multiple: false, title: L("내 사진 선택"),
          filters: [{name: L("배경 이미지"), extensions: ["jpg", "jpeg", "png", "webp"]}],
        });
        if (!path) return;
        next.path = path;
        const check = new Image();
        check.src = effect(next).url;
        try { await check.decode(); } catch { throw Error(L("이 사진을 열 수 없습니다. 다른 이미지를 선택하세요.")); }
      }
      await apply(effect(next));
      selection = next;
      try { localStorage.setItem(preference, JSON.stringify(next)); } catch {}
    } catch (e) { onError(e); }
    finally { busy = false; render(); onBusy(false); }
  }
  function add(id, name, parent, thumb = false) {
    const button = document.createElement("button");
    button.type = "button";
    if (thumb) {
      const image = document.createElement("img");
      image.src = presetURL(id); image.alt = ""; image.draggable = false;
      button.append(image);
    }
    button.append(document.createTextNode(L(name)));
    button.onclick = () => choose(id);
    buttons.set(id, button); parent.append(button);
  }
  add("off", "원본", options); add("blur", "배경 흐림", options); add("custom", "내 사진…", options);
  for (const [id, name] of presets) add(id, name, gallery, true);
  render();
  return {
    effect: () => effect(selection),
    get busy() { return busy; },
    setEnabled(value) { enabled = value; render(); },
  };
}
