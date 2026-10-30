// Prompt-first video creation. Credentials stay in the password field until sent
// to the native credential store; drafts and job state never contain API keys.
import { modalBox, showModal, hideModal } from "./shell.js";

const invoke = (command, args) => window.__TAURI__.core.invoke(command, args);
const copy = (ko, en) => window.LANG === "en" ? en : ko;
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const modelFor = (provider, access) => provider === "claude" ? "claude-opus-5-5" : provider === "gemini" ? "gemini-3.8-flash" : access === "subscription" ? "codex-default" : "gpt-6.1-sol";
const V = {
  draft: { prompt: "", provider: "claude", access: "subscription", renderer: "canvas", duration: 20, width: 1080, height: 1080, fps: 30, automaticSkills: true },
  models: { claude: "claude-opus-5-5", openai: "gpt-6.1-sol", gemini: "gemini-3.8-flash" },
  state: {}, capabilities: { providers: {}, skills: [], runtime: {} }, capabilitySequence: 0,
  loading: false, connecting: false, saving: false, importing: false, pending: false, hydrated: false, localError: "", resultsKey: "", progressKey: "", agents: {}, initialized: false, toast: () => {}, returnFocus: null,
};
const q = (selector) => modalBox()?.querySelector(selector);
const isOpen = () => !document.querySelector("#modal")?.classList.contains("hidden") && !!q("#video-generation");
const busy = () => !!V.state.busy || V.pending;
const providerName = () => V.draft.provider === "openai" ? "GPT" : V.draft.provider === "gemini" ? "Gemini" : "Claude";
const currentProvider = () => V.capabilities.providers?.[V.draft.provider] || {};
const connectionReady = () => V.draft.access === "subscription" ? !!currentProvider().subscriptionReady : !!currentProvider().hasKey;
const fileURL = (path) => window.__TAURI__.core.convertFileSrc(path);

const EXAMPLES = [
  ["교육 설명", "Educational Explainer", "물의 순환을 초등학생이 이해하기 쉬운 설명 애니메이션으로 만들어줘. 종이 오려 붙이기 스타일로 바다에서 증발한 물이 구름이 되고 비가 내려 강으로 돌아오는 과정을 보여줘. 핵심 단어만 한국어로 넣어줘.", "Explain the water cycle for elementary students with a paper-cutout animation. Show evaporation, clouds, rain and water returning through a river. Include only the key labels."],
  ["제품 홍보", "Product Promo", "새로운 텀블러를 소개하는 홍보 영상. 밝고 미니멀한 배경에서 텀블러가 회전하고 '가볍게 들고, 오래 따뜻하게'라는 문구가 나타나게 해줘. 제품의 색은 민트, 분위기는 산뜻하게 해줘.", "Promote a new mint tumbler. Let it rotate on a bright minimal background, then reveal 'Carry light. Stay warm.' Keep the mood fresh and clean."],
  ["데이터 이야기", "Data Story", "작은 습관이 쌓여 큰 변화가 되는 과정을 막대그래프와 도형으로 보여줘. 남색 배경에 흰색과 주황색을 쓰고, 막대가 하나씩 자란 뒤 하나의 큰 상승 곡선으로 연결되게 해줘. 수치는 예시임을 표시해줘.", "Show how small habits create big changes using bars and shapes. Use white and orange on navy. Grow bars one by one, then connect them with a rising curve. Label any numbers as illustrative."],
  ["손그림 이야기", "Hand-drawn Story", "작은 씨앗이 싹을 틔우고 나무로 자라는 따뜻한 손그림 애니메이션. 크레용 질감과 부드러운 파스텔 색상을 쓰고, 마지막에 새 한 마리가 가지에 앉게 해줘. 글자 없이 잔잔한 분위기로 만들어줘.", "Make a warm hand-drawn animation of a seed growing into a tree. Use crayon textures and soft pastels, ending with a bird landing on a branch. Keep it gentle with no text."],
];

function draftRequest() {
  return { ...V.draft, model: V.draft.access === "api" ? V.models[V.draft.provider].trim() : modelFor(V.draft.provider, "subscription") };
}
function validDraft() {
  const d = V.draft;
  return !!d.prompt.trim() && d.prompt.length <= 20000 && Number.isFinite(d.duration) && d.duration >= 2 && d.duration <= 60 &&
    [24, 30, 60].includes(d.fps) && (d.access !== "api" || /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/.test(V.models[d.provider].trim()));
}
function matchesPreview() {
  const approved = V.state.request;
  if (!approved) return true;
  const current = draftRequest();
  return Object.keys(current).every((key) => approved[key] === current[key]);
}
function usageText() {
  return V.draft.access === "subscription"
    ? copy(`${V.draft.provider === "openai" ? "ChatGPT" : "Claude Opus 5.5"} · 구독 사용 한도 적용`, `${V.draft.provider === "openai" ? "ChatGPT" : "Claude Opus 5.5"} · Subscription limits apply`)
    : copy(`${providerName()} API · 모델별 API 요금 발생`, `${providerName()} API · Model-specific API charges apply`);
}
function safeURL(value) {
  try { const url = new URL(value); return url.protocol === "https:" ? url.href : null; } catch (_) { return null; }
}
function skillHTML(skill) {
  const title = window.LANG === "en" ? skill.englishTitle || skill.title : skill.title;
  const description = window.LANG === "en" ? skill.englishSummary || skill.summary : skill.summary;
  const url = safeURL(skill.sourceURL);
  return `<div class="video-skill"><div class="row"><b>${esc(title)}</b><span class="spacer"></span>${url ? `<button class="video-link" data-video-url="${esc(url)}" title="${esc([skill.upstreamName, skill.licenseName, skill.revision].filter(Boolean).join(" · "))}">${copy("원본 보기", "View Source")} ↗</button>` : ""}</div><p class="hint">${esc(description)}</p></div>`;
}
function accountHTML() {
  const d = V.draft;
  const guide = d.provider === "claude" ? "https://platform.claude.com/docs/en/api/overview" : d.provider === "openai" ? "https://developers.openai.com/api/docs/quickstart" : "https://ai.google.dev/gemini-api/docs/api-key";
  return `<section class="video-account">
    <label for="video-provider" class="video-label">${copy("영상 제작 AI", "Video Creation AI")}</label>
    <select id="video-provider" data-video-input><option value="claude" ${d.provider === "claude" ? "selected" : ""}>Claude</option><option value="openai" ${d.provider === "openai" ? "selected" : ""}>GPT</option><option value="gemini" ${d.provider === "gemini" ? "selected" : ""}>Gemini</option></select>
    <p class="hint">${copy("영상 제작 품질을 우선한다면 현재 Claude Opus 5.5를 가장 권장합니다.", "For the best video creation quality in EasyCut, we currently recommend Claude Opus 5.5.")}</p>
    ${d.provider !== "gemini" ? `<div class="row"><label for="video-access">${copy("연결 방식", "Connection Method")}</label><select id="video-access" data-video-input><option value="subscription" ${d.access === "subscription" ? "selected" : ""}>${copy("구독 로그인", "Subscription Sign-in")}</option><option value="api" ${d.access === "api" ? "selected" : ""}>${copy("API 키", "API Key")}</option></select></div>` : `<p class="hint">${copy("Gemini는 API 키로 연결합니다. 구독 계정 로그인은 현재 지원하지 않습니다.", "Gemini connects with an API key. Subscription sign-in is not currently supported.")}</p>`}
    ${d.access === "subscription" ? `<div class="row"><span id="video-connection-state" class="hint" role="status"></span><span class="spacer"></span><button id="video-connect">${d.provider === "openai" ? copy("ChatGPT로 로그인", "Sign in to ChatGPT") : copy("Claude로 로그인", "Sign in to Claude")}</button></div><p class="hint">${copy("본인 구독 계정의 사용 한도가 적용됩니다. 필요한 연결 도구는 앱에서 준비합니다.", "Your subscription account's usage limits apply. The app prepares the connection tools it needs.")}</p>` : `
      <div class="row video-key-row"><input type="password" id="video-api-key" autocomplete="off" spellcheck="false" data-video-input aria-label="${esc(providerName())} API ${copy("키", "key")}" placeholder="${esc(providerName())} API ${copy("키 입력", "key")}"/><button id="video-save-key">${copy("키 저장", "Save Key")}</button></div>
      <p class="hint">${copy("본인 계정의 키를 입력하세요. 이 PC의 자격 증명 관리자에 저장합니다.", "Use your own account's key. It is saved in this PC's Credential Manager.")} <button class="video-link" data-video-url="${guide}">${copy("API 키 발급 안내", "Get an API Key")} ↗</button></p>
      <p id="video-connection-state" class="hint" role="status"></p>
      <div class="row"><label for="video-model">${copy("모델", "Model")}</label><input id="video-model" data-video-input spellcheck="false" value="${esc(V.models[d.provider])}"/></div>
      <p class="hint">${copy("구독 요금과 별도로 선택한 모델의 API 사용 요금이 발생합니다.", "The selected model's API usage is billed separately from subscriptions.")}</p>`}
    ${d.access === "subscription" ? '<div id="video-login-feedback" aria-live="polite"></div>' : ""}
  </section>`;
}

function render() {
  const box = modalBox();
  box.classList.remove("wide");
  box.classList.add("generation-box");
  box.setAttribute("role", "dialog"); box.setAttribute("aria-modal", "true"); box.setAttribute("aria-labelledby", "video-title");
  const d = V.draft;
  box.innerHTML = `<div id="video-generation">
    <header class="video-header"><div><h2 id="video-title">${copy("영상 만들기", "Create a Video")}</h2><p class="hint">${copy("원하는 내용을 설명하고, 미리보기 4장을 확인한 뒤 영상으로 만드세요", "Describe your idea, review four sample frames, then make your video")}</p></div><button id="video-close">${copy("닫기", "Close")}</button></header>
    <div class="video-body">${accountHTML()}
      <section><label class="video-label" for="video-prompt">${copy("어떤 영상을 만들까요?", "What would you like to make?")}</label><p class="hint">${copy("주제와 이야기, 원하는 스타일·색상·움직임·글자·소리를 자유롭게 적어 주세요. 특정 스타일을 고를 필요는 없습니다.", "Describe your subject and story, style, colors, movement, text and sound. You do not need to choose a preset style.")}</p>
      <textarea id="video-prompt" data-video-input maxlength="20000" rows="5">${esc(d.prompt)}</textarea>
      <p class="hint">${copy("어떻게 적을지 막막하면 예시에서 시작해 바꿔 보세요", "Start with an example and make it your own")}</p><div class="video-examples">${EXAMPLES.map((ex, i) => `<button data-video-example="${i}" data-video-input title="${copy("설명만 채우며 화면·길이·제작 방식 설정은 유지합니다", "Fills the description and keeps your settings")}">${esc(copy(ex[0], ex[1]))}</button>`).join("")}</div></section>
      <div class="video-options"><label>${copy("화면", "Canvas")}<select id="video-size" data-video-input>${[["1280x720", "가로 16:9 · 720p", "Landscape 16:9 · 720p"], ["720x1280", "세로 9:16 · 720p", "Portrait 9:16 · 720p"], ["1080x1080", "정사각형 · 1080p", "Square · 1080p"], ["1920x1080", "가로 16:9 · 1080p", "Landscape 16:9 · 1080p"]].map(([value, ko, en]) => `<option value="${value}" ${value === `${d.width}x${d.height}` ? "selected" : ""}>${copy(ko, en)}</option>`).join("")}</select></label><label>${copy("길이 (초)", "Length (seconds)")}<input id="video-duration" data-video-input type="number" min="2" max="60" step="1" value="${d.duration}"/></label><label>fps<select id="video-fps" data-video-input>${[24, 30, 60].map((fps) => `<option ${d.fps === fps ? "selected" : ""}>${fps}</option>`).join("")}</select></label></div>
      <section><label class="video-auto"><input id="video-skills" data-video-input type="checkbox" ${d.automaticSkills ? "checked" : ""}/> ${copy("제작 스킬 자동 적용", "Automatically Apply Production Skills")}</label><p class="hint">${copy("설명에 맞는 제작 지침을 골라 적용합니다. 적어 주신 스타일과 내용이 우선합니다.", "Selects guidance for your description. Your requested style and content come first.")}</p><details id="video-skill-list"><summary>${copy("사용할 수 있는 스킬", "Available Skills")}</summary><div id="video-catalog">${(V.capabilities.skills || []).map(skillHTML).join("") || `<p class="hint">${copy("스킬을 확인하는 중…", "Loading skills…")}</p>`}</div></details></section>
      <details id="video-advanced"><summary>${copy("고급 설정", "Advanced Settings")}</summary><div class="row"><label for="video-renderer">${copy("제작 방식", "Rendering Method")}</label><select id="video-renderer" data-video-input><option value="canvas" ${d.renderer === "canvas" ? "selected" : ""}>Canvas · ${copy("자유 애니메이션", "Animation")}</option><option value="remotion" ${d.renderer === "remotion" ? "selected" : ""}>Remotion · ${copy("모션그래픽", "Motion Graphics")}</option></select></div><p id="video-renderer-note" class="hint"></p><p class="hint">${copy("Node.js·npm과 Chrome 또는 Edge가 필요합니다. 렌더링 도구는 처음 한 번 자동으로 준비합니다.", "Node.js, npm and Chrome or Edge are required. Rendering tools are prepared on first use.")}</p></details>
      <p id="video-transmission" class="hint"></p><div id="video-progress" aria-live="polite"></div><p id="video-error" role="alert" class="warn" hidden></p><div id="video-results"></div>
    </div><footer class="video-footer"><span class="hint" id="video-usage"></span><span class="spacer"></span><button id="video-generate" class="primary">✨ ${copy("설명으로 미리보기 만들기", "Create Previews from Description")}</button></footer>
    <dialog id="video-frame-dialog"><button id="video-frame-close">${copy("닫기", "Close")}</button><img id="video-frame-image" alt=""/></dialog>
  </div>`;
  q("#video-close").onclick = close;
  q("#video-provider").onchange = (event) => { V.draft.provider = event.target.value; V.draft.access = event.target.value === "gemini" ? "api" : "subscription"; V.localError = ""; render(); q("#video-provider").focus(); };
  if (q("#video-access")) q("#video-access").onchange = (event) => { V.draft.access = event.target.value; V.localError = ""; render(); q("#video-access").focus(); };
  if (q("#video-api-key")) q("#video-api-key").oninput = updateControls;
  if (q("#video-model")) q("#video-model").oninput = (event) => { V.models[V.draft.provider] = event.target.value; updateControls(); };
  if (q("#video-save-key")) q("#video-save-key").onclick = saveKey;
  if (q("#video-connect")) q("#video-connect").onclick = connect;
  q("#video-prompt").oninput = (event) => { V.draft.prompt = event.target.value; updateControls(); };
  box.querySelectorAll("[data-video-example]").forEach((button) => { button.onclick = () => { const ex = EXAMPLES[+button.dataset.videoExample]; V.draft.prompt = copy(ex[2], ex[3]); q("#video-prompt").value = V.draft.prompt; updateControls(); }; });
  q("#video-size").onchange = (event) => { [V.draft.width, V.draft.height] = event.target.value.split("x").map(Number); updateControls(); };
  q("#video-duration").oninput = (event) => { V.draft.duration = Number(event.target.value); updateControls(); };
  q("#video-fps").onchange = (event) => { V.draft.fps = Number(event.target.value); updateControls(); };
  q("#video-skills").onchange = (event) => { V.draft.automaticSkills = event.target.checked; updateControls(); };
  q("#video-renderer").onchange = (event) => { V.draft.renderer = event.target.value; updateControls(); };
  q("#video-generate").onclick = generate;
  q("#video-frame-close").onclick = () => q("#video-frame-dialog").close();
  V.resultsKey = ""; V.progressKey = "";
  wireSources(box);
  update();
}

function wireSources(element) {
  element.querySelectorAll("[data-video-url]").forEach((button) => { button.onclick = () => invoke("open_url", { url: button.dataset.videoUrl }).catch((error) => showError(error)); });
}
function showError(error) { V.localError = String(error?.message ?? error); update(); }
function updateControls() {
  if (!isOpen()) return;
  q("#video-generation").querySelectorAll("[data-video-input]").forEach((el) => { el.disabled = busy() || V.saving || V.connecting; });
  q("#video-generate").disabled = busy() || V.loading || V.connecting || V.saving || !connectionReady() || !validDraft();
  const provider = currentProvider();
  q("#video-connection-state").textContent = V.loading || V.connecting
    ? copy("연결을 확인하는 중…", "Checking your connection…")
    : V.draft.access === "subscription"
      ? provider.subscriptionReady ? copy(`${providerName()} 구독 연결됨`, `${providerName()} subscription connected`) : copy("본인 구독 계정으로 로그인하세요", "Sign in with your own subscription account")
      : provider.hasKey ? copy("API 키가 저장되어 있습니다", "API key is saved") : copy("API 키를 저장하면 이 공급자로 영상을 만들 수 있습니다.", "Save an API key to create videos with this provider.");
  q("#video-connection-state").classList.toggle("ok", connectionReady());
  if (q("#video-connect")) { q("#video-connect").disabled = busy() || V.connecting || V.loading; q("#video-connect").hidden = !!provider.subscriptionReady; }
  if (q("#video-login-feedback")) {
    const agent = V.agents[V.draft.provider === "openai" ? "codex" : "claude"] || {};
    const waiting = V.connecting || agent.state === "working";
    const url = safeURL(V.agents.loginUrl);
    const key = JSON.stringify([waiting, agent.message, url]);
    const feedback = q("#video-login-feedback");
    if (feedback.dataset.status !== key) {
      feedback.dataset.status = key;
      feedback.innerHTML = waiting ? `<div class="row"><span class="spin" aria-hidden="true"></span><span class="hint">${esc(window.L?.(agent.message || "") || copy("연결 도구를 준비하는 중…", "Preparing connection tools…"))}</span><span class="spacer"></span>${url ? `<button class="video-link" data-video-url="${esc(url)}">${copy("브라우저 다시 열기", "Reopen Browser")}</button>` : ""}${(agent.message || "").includes("브라우저") ? `<button id="video-login-cancel">${copy("로그인 취소", "Cancel Sign-in")}</button>` : ""}</div>` : "";
      wireSources(feedback);
      if (q("#video-login-cancel")) q("#video-login-cancel").onclick = () => invoke("ai_cancel_login").catch(showError);
    }
  }
  if (q("#video-save-key")) q("#video-save-key").disabled = busy() || V.loading || V.saving || !q("#video-api-key").value.trim();
  q("#video-usage").textContent = usageText();
  q("#video-transmission").textContent = copy(`입력한 설명은 선택한 ${providerName()}에 전송되며, 생성 코드는 이 PC에서 실행됩니다.`, `Your description is sent to the selected ${providerName()} provider, and generated code runs on this PC.`);
  q("#video-renderer-note").textContent = V.draft.renderer === "canvas"
    ? copy("장면과 배경음악·효과음을 함께 만들 수 있습니다. 원하는 소리를 설명하거나 무음을 요청하세요.", "Creates animated scenes with optional synthesized music and sound effects. Describe the sound you want or request silence.")
    : copy("React 기반 모션그래픽을 만듭니다. 기본 생성물은 무음이며 타임라인에서 소리를 더할 수 있습니다.", "Creates React motion graphics. Output is silent by default; you can add audio on the timeline.");
  if (q("#video-render")) q("#video-render").disabled = busy() || !matchesPreview() || (V.state.previews || []).length !== 4 || !!V.state.outputPath;
  if (q("#video-stale")) q("#video-stale").hidden = matchesPreview();
  if (q("#video-import")) q("#video-import").disabled = busy() || V.importing;
}

function update() {
  if (!isOpen()) return;
  const error = V.localError || V.state.error || "";
  q("#video-error").textContent = window.L?.(error) || error; q("#video-error").hidden = !error;
  const progressKey = JSON.stringify([busy(), V.state.status]);
  if (progressKey !== V.progressKey) {
    V.progressKey = progressKey;
    q("#video-progress").innerHTML = busy()
    ? `<div class="video-working"><span class="spin" aria-hidden="true"></span><div><b>${esc(window.L?.(V.state.status || "") || copy("영상 생성을 준비하는 중…", "Preparing video creation…"))}</b><p class="hint">${copy("창을 닫아도 작업은 계속됩니다.", "Work continues if you close this window.")}</p></div><span class="spacer"></span><button id="video-stop">${copy("중지", "Stop")}</button></div>`
    : V.state.status ? `<p class="hint">${esc(window.L?.(V.state.status) || V.state.status)}</p>` : "";
    if (q("#video-stop")) q("#video-stop").onclick = () => invoke("generation_cancel").then(refreshState).catch(showError);
  }
  const resultKey = JSON.stringify([V.state.jobId, V.state.previews, V.state.appliedSkills, V.state.appliedSkillReason, V.state.outputPath]);
  if (resultKey !== V.resultsKey) { V.resultsKey = resultKey; renderResults(); }
  updateControls();
}
function renderResults() {
  const previews = V.state.previews || [], skills = V.state.appliedSkills || [];
  q("#video-results").innerHTML = `${previews.length ? `<section class="video-review"><h3>${copy("전체 렌더링 전 확인", "Review Before Full Render")}</h3><p class="hint">${copy("구도·색상·글자·장면 변화를 확인하세요. 이미지를 누르면 크게 볼 수 있습니다.", "Check composition, colors, text and scene changes. Click a frame to enlarge it.")}</p>${skills.length ? `<div class="video-applied"><h4>${copy("적용한 제작 스킬", "Applied Production Skills")}</h4><p class="hint">${esc(V.state.appliedSkillReason)}</p>${skills.map(skillHTML).join("")}</div>` : ""}<div class="video-previews" id="video-previews">${previews.map((path, i) => `<button class="video-preview" data-video-preview="${i}" aria-label="${copy(`미리보기 ${i + 1} 크게 보기`, `Enlarge preview ${i + 1}`)}"><img src="${esc(fileURL(path))}" alt="${copy(`미리보기 ${i + 1}`, `Preview ${i + 1}`)}"/><span>preview-${i + 1}</span></button>`).join("")}</div><p class="hint">${copy("전체 렌더링에는 미리보기를 만든 코드와 설정을 사용합니다. 설명이나 설정을 바꾸면 미리보기를 다시 생성하세요.", "Full rendering uses the code and settings that produced these frames. Generate new previews after changing the description or settings.")}</p><p id="video-stale" class="warn" hidden>${copy("설명이나 설정을 바꿨습니다. 미리보기를 다시 생성하세요.", "Your description or settings changed. Generate new previews.")}</p><div class="row"><button data-video-open="folder">${copy("생성 코드 보기", "Show Generated Code")}</button><span class="spacer"></span><button id="video-render" class="primary">${copy("확인하고 전체 렌더링", "Approve & Render Full Video")}</button></div></section>` : ""}${V.state.outputPath ? `<section class="video-result"><h3>✓ ${copy("영상이 준비됐습니다", "Your Video Is Ready")}</h3><p class="hint">${esc(V.state.outputPath.split(/[\\/]/).pop())}</p><div class="row"><button data-video-open="video">${copy("재생", "Play")}</button><button data-video-open="folder">${copy("폴더에서 보기", "Show Folder")}</button><span class="spacer"></span><button id="video-import" class="primary">${copy("타임라인에 추가", "Add to Timeline")}</button></div></section>` : ""}`;
  wireSources(q("#video-results"));
  q("#video-results").querySelectorAll("[data-video-open]").forEach((button) => { button.onclick = () => invoke("generation_open", { jobId: V.state.jobId, kind: button.dataset.videoOpen }).catch(showError); });
  q("#video-results").querySelectorAll("[data-video-preview]").forEach((button) => { button.onclick = () => { const index = +button.dataset.videoPreview; q("#video-frame-image").src = fileURL(previews[index]); q("#video-frame-image").alt = copy(`미리보기 ${index + 1}`, `Preview ${index + 1}`); q("#video-frame-dialog").showModal(); }; });
  if (q("#video-render")) q("#video-render").onclick = renderVideo;
  if (q("#video-import")) q("#video-import").onclick = async () => {
    if (V.importing) return;
    V.importing = true; updateControls();
    try { await invoke("generation_import", { jobId: V.state.jobId }); V.toast(copy("생성한 영상을 타임라인에 추가했습니다", "Added the generated video to the timeline")); }
    catch (error) { showError(error); }
    finally { V.importing = false; updateControls(); }
  };
}

async function refreshCapabilities() {
  const sequence = ++V.capabilitySequence;
  V.loading = true; updateControls();
  try {
    const capabilities = await invoke("generation_capabilities");
    if (sequence !== V.capabilitySequence) return;
    V.capabilities = capabilities || { providers: {}, skills: [], runtime: {} };
    if (isOpen()) { q("#video-catalog").innerHTML = (V.capabilities.skills || []).map(skillHTML).join(""); wireSources(q("#video-catalog")); }
  }
  catch (error) { if (sequence === V.capabilitySequence) showError(error); }
  finally { if (sequence === V.capabilitySequence) { V.loading = false; updateControls(); } }
}
async function refreshState() {
  try { const state = await invoke("generation_state"); if (state) acceptState(state); }
  catch (error) { if (isOpen()) showError(error); }
}
function acceptState(state) {
  if (!state || typeof state !== "object") return;
  const wasBusy = !!V.state.busy;
  if (!V.hydrated) {
    V.hydrated = true;
    if (state.request && !V.draft.prompt) {
      for (const key of Object.keys(V.draft)) if (state.request[key] !== undefined) V.draft[key] = state.request[key];
      if (V.draft.access === "api" && state.request.model) V.models[V.draft.provider] = state.request.model;
      V.state = state;
      if (isOpen()) render();
    }
  }
  V.state = state; update();
  if (wasBusy && !state.busy && !isOpen()) V.toast(state.error ? String(state.error) : state.outputPath ? copy("생성 영상이 준비됐습니다", "Your generated video is ready") : (state.previews || []).length === 4 ? copy("영상 미리보기 4장이 준비됐습니다", "Four sample frames are ready") : copy("영상 생성이 중지되었습니다", "Video creation stopped"));
}
async function saveKey() {
  if (V.saving || busy()) return;
  const input = q("#video-api-key"), key = input.value;
  if (!key.trim()) return;
  input.value = ""; V.localError = ""; V.saving = true; updateControls();
  try { await invoke("generation_save_key", { provider: V.draft.provider, key }); await refreshCapabilities(); }
  catch (error) { showError(error); }
  finally { V.saving = false; updateControls(); }
}
async function connect() {
  V.connecting = true; V.localError = ""; updateControls();
  try { await invoke("generation_connect", { provider: V.draft.provider }); await refreshCapabilities(); }
  catch (error) { showError(error); }
  finally { V.connecting = false; updateControls(); }
}
async function generate() {
  if (busy() || !connectionReady() || !validDraft()) return;
  V.localError = ""; V.pending = true; update();
  try { const state = await invoke("generation_start", { request: draftRequest() }); if (state) acceptState(state); }
  catch (error) { showError(error); }
  finally { V.pending = false; await refreshState(); update(); }
}
async function renderVideo() {
  if (busy() || !matchesPreview() || (V.state.previews || []).length !== 4 || V.state.outputPath) return;
  V.localError = ""; V.pending = true; update();
  try { const state = await invoke("generation_render", { jobId: V.state.jobId }); if (state) acceptState(state); }
  catch (error) { showError(error); }
  finally { V.pending = false; await refreshState(); update(); }
}
function cleanup() {
  if (q("#video-api-key")) q("#video-api-key").value = "";
  const image = q("#video-frame-dialog"); if (image?.open) image.close();
  modalBox()?.classList.remove("generation-box");
  for (const attribute of ["role", "aria-modal", "aria-labelledby"]) modalBox()?.removeAttribute(attribute);
}
function close() { cleanup(); hideModal(); V.returnFocus?.focus?.(); }

export async function initGeneration({ toast } = {}) {
  V.toast = toast || (() => {});
  if (V.initialized) return;
  V.initialized = true;
  await window.__TAURI__.event.listen("video-generation", (event) => acceptState(event.payload));
  await window.__TAURI__.event.listen("ai", (event) => { if (event.payload?.type === "agents") { V.agents = event.payload.agents || {}; updateControls(); } });
  window.addEventListener("easycut-modal-hidden", cleanup);
  window.addEventListener("keydown", (event) => {
    if (!isOpen()) return;
    if (event.key === "Escape") { event.preventDefault(); event.stopImmediatePropagation(); if (q("#video-frame-dialog")?.open) q("#video-frame-dialog").close(); else close(); return; }
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") { event.preventDefault(); event.stopImmediatePropagation(); generate(); return; }
    if (event.key === "Tab") {
      const container = q("#video-frame-dialog")?.open ? q("#video-frame-dialog") : q("#video-generation");
      const all = [...container.querySelectorAll('button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),summary')].filter((el) => el.getClientRects().length && !el.hidden);
      if (all.length && event.shiftKey && document.activeElement === all[0]) { event.preventDefault(); all.at(-1).focus(); }
      else if (all.length && !event.shiftKey && document.activeElement === all.at(-1)) { event.preventDefault(); all[0].focus(); }
    }
    event.stopPropagation();
  }, true);
  setInterval(() => { if (isOpen() || V.state.busy) refreshState(); }, 1000);
}

export async function openGeneration() {
  V.returnFocus = document.activeElement;
  V.localError = "";
  render(); showModal(); update();
  q("#video-prompt").focus();
  await Promise.all([refreshState(), refreshCapabilities()]);
}
