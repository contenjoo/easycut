const media = new URL("./media/", import.meta.url);
const scenes = ["screen", "camera", "pip"];
const backgrounds = ["studio", "library", "loft", "midnight"];
const copy = {
  ko: {
    studio: "방송 스튜디오", preview: "미리보기", region: "홈페이지 방송 스튜디오 체험",
    scenes: ["화면", "카메라", "화면 + 카메라"], scene: "장면 선택",
    background: "카메라 배경", backgrounds: ["스튜디오", "서재", "로프트", "미드나이트"],
    screenAlt: "공유 화면에 표시된 스튜디오 풍경", personAlt: name => name + " 배경을 적용한 발표자",
  },
  en: {
    studio: "Broadcast Studio", preview: "Preview", region: "Interactive studio demo",
    scenes: ["Screen", "Camera", "Screen + camera"], scene: "Choose a scene",
    background: "Camera backdrop", backgrounds: ["Studio", "Library", "Loft", "Midnight"],
    screenAlt: "The studio interior on the shared screen", personAlt: name => "Presenter with the " + name + " background",
  },
};
let instances = 0;

class StudioDemo extends HTMLElement {
  connectedCallback() {
    if (this.program) return;
    const lang = this.closest("[lang]")?.lang?.toLowerCase() || "ko";
    this.words = lang.startsWith("en") ? copy.en : copy.ko;
    const w = this.words;
    const group = "demo-scene-" + ++instances;
    this.setAttribute("role", "region");
    this.setAttribute("aria-label", w.region);
    this.innerHTML = `
      <div class="ecd-monitor">
        <div class="ecd-titlebar">
          <span class="ecd-window-marks" aria-hidden="true"><i></i><i></i><i></i></span>
          <span class="ecd-window-title">${w.studio}</span>
          <span class="ecd-preview-label"><i aria-hidden="true"></i>${w.preview}</span>
        </div>
        <div class="ecd-program" data-scene="pip">
          <img class="ecd-screen" alt="${w.screenAlt}" width="1280" height="720" fetchpriority="high" decoding="async">
          <div class="ecd-camera-window"><img class="ecd-camera" width="768" height="432" decoding="async"></div>
        </div>
        <div class="ecd-controls">
          <fieldset class="ecd-scenes">
            <legend class="ecd-visually-hidden">${w.scene}</legend>
            ${scenes.map((scene, i) => `
              <label class="ecd-mode">
                <input type="radio" name="${group}" value="${scene}" ${scene === "pip" ? "checked" : ""}>
                <span><i class="ecd-layout ecd-layout-${scene}" aria-hidden="true"></i>${w.scenes[i]}</span>
              </label>`).join("")}
          </fieldset>
          <label class="ecd-backdrop">
            <span class="ecd-visually-hidden">${w.background}</span>
            <span class="ecd-background-caption" aria-hidden="true">${w.background}</span>
            <span class="ecd-select-wrap">
            <i class="ecd-background-icon" aria-hidden="true"></i>
            <select>${backgrounds.map((id, i) => `<option value="${id}">${w.backgrounds[i]}</option>`).join("")}</select>
            </span>
          </label>
        </div>
      </div>`;
    this.program = this.querySelector(".ecd-program");
    this.person = this.querySelector(".ecd-camera");
    this.select = this.querySelector("select");
    this.backgroundControl = this.querySelector(".ecd-backdrop");
    this.querySelector(".ecd-screen").src = new URL("hero-scene.webp", media).href;
    this.updateBackground();
    this.addEventListener("change", event => {
      if (event.target === this.select) this.updateBackground();
      else if (event.target.matches(".ecd-mode input")) this.updateScene(event.target.value);
    });
  }

  showBackground(id) {
    if (!backgrounds.includes(id)) return;
    this.querySelector('.ecd-mode input[value="camera"]').checked = true;
    this.select.value = id;
    this.updateBackground();
    this.updateScene("camera");
  }

  updateScene(scene) {
    this.program.dataset.scene = scene;
    const screenOnly = scene === "screen";
    this.querySelector(".ecd-camera-window").hidden = screenOnly;
    this.querySelector(".ecd-screen").hidden = scene === "camera";
    this.select.disabled = screenOnly;
    this.backgroundControl.toggleAttribute("data-disabled", screenOnly);
  }

  updateBackground() {
    const selected = this.select.selectedIndex;
    this.person.alt = this.words.personAlt(this.words.backgrounds[selected]);
    this.person.src = new URL("demo-" + backgrounds[selected] + ".webp", media).href;
  }
}

if (!customElements.get("easycut-studio-demo")) customElements.define("easycut-studio-demo", StudioDemo);
