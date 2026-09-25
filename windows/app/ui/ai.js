// AI 편집 탭 (맥 AIPanel.swift): 대화, 연결 방식·모델·추론 강도, 원클릭 로그인, 다른 AI 앱 연결
const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);
const listen = (ev, f) => window.__TAURI__.event.listen(ev, f);

const EXAMPLES = [
  "말 없는 부분 다 잘라줘",
  "'음', '어' 같은 말 빼고 자막 만들어줘",
  "처음 10초 잘라내고 나머지는 1.5배속",
  "자막을 노란색 글자, 외곽선으로 크게",
  "'감사합니다'라고 말한 부분 찾아서 삭제",
  "5초에 '오늘의 주제' 제목 넣어줘",
];
const EFFORTS = [["", "자동 (모델 기본)"], ["low", "낮음 · 빠름"], ["medium", "보통"], ["high", "높음"], ["xhigh", "매우 높음"], ["max", "최대 · 가장 깊게"]];
const BACKENDS = [["plan", "Claude 플랜 (Pro/Max 로그인)"], ["codex", "ChatGPT · Codex"], ["api", "API 키"]];

const A = {
  settings: { backend: "plan", model: "", effort: "", showThinking: false },
  models: [],
  agents: { claude: { state: "unknown" }, codex: { state: "unknown" }, hasKey: false, needsLogin: false, loginUrl: null },
  items: [],
  busy: false,
  status: "",
  draft: "",
};

let root, toastFn, modalBox, showModal, hideModal;

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const working = (st) => st?.state === "working";

function ready() {
  const b = A.settings.backend;
  if (b === "api") return A.agents.hasKey;
  const p = b === "codex" ? "codex" : "claude";
  const st = A.agents[p]?.state;
  return st === "ready" || (st === "unknown" && A.agents[p + "Installed"]);
}

export async function initAI(el, { toast, modal }) {
  root = el;
  toastFn = toast;
  ({ box: modalBox, show: showModal, hide: hideModal } = modal);
  const s = await invoke("ai_settings");
  A.settings = s.settings;
  A.models = s.models;
  A.agents = await invoke("ai_agents");
  await listen("ai", (e) => onEvent(e.payload));
  render();
  // CLI 상태 확인은 몇 초 걸릴 수 있어 뒤에서
  invoke("ai_refresh_agents").then((a) => { A.agents = a; render(); }).catch(() => {});
}

function onEvent(ev) {
  switch (ev.type) {
    case "item": A.items.push({ role: ev.role, text: ev.text }); break;
    case "status": A.status = ev.text; break;
    case "busy": A.busy = ev.value; if (!ev.value) A.status = ""; break;
    case "agents": A.agents = ev.agents; break;
    case "reset": A.items = []; A.busy = false; A.status = ""; break;
    case "settings": A.settings = ev.value.settings; break;
  }
  render();
}

export function focusAI() {
  root?.querySelector("#ai-input")?.focus();
}

export function sendAI(text) {
  const t = text.trim();
  if (!t || A.busy) return;
  A.busy = true;
  invoke("ai_send", { text: t });
  render();
}

async function saveSettings(patch) {
  const v = await invoke("ai_set_settings", { settings: { ...A.settings, ...patch } });
  A.settings = v.settings;
  render();
}

function modelLabel() {
  if (A.settings.backend === "codex") return L("ChatGPT 기본 모델");
  if (A.settings.backend === "plan" && !A.settings.model) return L("계정 기본 모델");
  return (A.models.find((m) => m.id === A.settings.model) || A.models.find((m) => m.id === "claude-opus-5"))?.name || "";
}

function header() {
  const b = A.settings.backend;
  const models = b === "codex"
    ? `<option>${L("ChatGPT 기본 모델")}</option>`
    : (b === "plan" ? `<option value="">${L("계정 기본값")}</option>` : "") +
      A.models.map((m) => `<option value="${m.id}" ${A.settings.model === m.id || (b === "api" && !A.settings.model && m.id === "claude-opus-5") ? "selected" : ""}>${esc(m.name)} — ${esc(L(m.note))}</option>`).join("");
  return `<div class="ai-head">
      <b>✨ ${L("AI 편집")}</b><span class="spacer"></span>
      <button id="ai-connect" title="${L("계정 연결 관리…")}">${L("계정 연결")}</button>
      <button id="ai-clear" title="${L("대화 지우기")}">🗑</button>
    </div>
    <div class="ai-opts">
      <select id="ai-backend" title="${L("연결 방식")}">${BACKENDS.map(([v, t]) => `<option value="${v}" ${b === v ? "selected" : ""}>${L(t)}</option>`).join("")}</select>
      <select id="ai-model" title="${L("모델과 추론 강도 선택")}" ${b === "codex" ? "disabled" : ""}>${models}</select>
      <select id="ai-effort" title="${L("추론 강도")}">${EFFORTS.map(([v, t]) => `<option value="${v}" ${A.settings.effort === v ? "selected" : ""}>${L(t)}</option>`).join("")}</select>
      <label class="hint"><input type="checkbox" id="ai-think" ${A.settings.showThinking ? "checked" : ""}/> ${L("생각 과정 보기")}</label>
    </div>`;
}

function loginButtons() {
  const row = (p, title, note, icon) => {
    const st = A.agents[p] || {};
    const badge = working(st) ? `<span class="spin"></span>` : st.state === "ready" ? `<span class="ok">✔</span>` : "";
    let extra = "";
    if (working(st)) {
      const msg = L(st.message || "");
      extra = `<div class="hint row">${esc(msg)}<span class="spacer"></span>${
        (st.message || "").includes("브라우저")
          ? `${A.agents.loginUrl ? `<button class="mini" data-reopen>${L("브라우저 다시 열기")}</button>` : ""}<button class="mini" data-cancel-login>${L("취소")}</button>`
          : ""}</div>`;
    } else if (st.state === "failed") {
      extra = `<div class="hint warn">${esc(L(st.message || ""))}</div>`;
    }
    return `<div class="ai-login"><button class="big" data-login="${p}" ${working(st) ? "disabled" : ""}>
        <span class="ic">${icon}</span><span class="tx"><b>${L(title)}</b><small>${L(note)}</small></span>${badge}</button>${extra}</div>`;
  };
  return row("claude", "Claude로 로그인", "Pro/Max 구독", "✨") + row("codex", "ChatGPT로 로그인", "Plus/Pro 구독 · Codex", "💬");
}

function bubble(it) {
  switch (it.role) {
    case "user": return `<div class="b user">${esc(it.text)}</div>`;
    case "assistant": return `<div class="b bot">${esc(it.text)}</div>`;
    case "tool": return `<div class="b tool">🪄 ${esc(L(it.text))}</div>`;
    case "error": return `<div class="b err">⚠ ${esc(L(it.text))}</div>`;
    case "thinking": return `<details class="b think"><summary>🧠 ${L("생각 과정")}</summary>${esc(it.text)}</details>`;
  }
  return "";
}

function render() {
  if (!root) return;
  const prevInput = root.querySelector("#ai-input");
  if (prevInput) A.draft = prevInput.value;
  const hadFocus = document.activeElement === prevInput;
  const b = A.settings.backend;
  let body;
  if (b !== "api" && !ready()) {
    body = `<div class="ai-pad">
      <p><b>${L("AI로 편집하려면 계정을 연결하세요")}</b></p>
      <p class="hint">${L("쓰고 있는 구독 계정으로 로그인하면 API 키 없이 바로 쓸 수 있습니다. 필요한 프로그램은 자동으로 설치됩니다.")}</p>
      ${loginButtons()}
      <hr/><button id="ai-use-api">${L("Claude API 키로 쓰기")}</button></div>`;
  } else if (b === "api" && !A.agents.hasKey) {
    body = `<div class="ai-pad">
      <p><b>${L("말로 편집하려면 Claude API 키가 필요합니다.")}</b></p>
      <p class="hint">${L("console.anthropic.com 에서 키를 만든 뒤 아래에 붙여 넣으세요. 키는 이 PC의 자격 증명 관리자에만 저장됩니다.")}</p>
      <input type="password" id="ai-key" placeholder="sk-ant-…" style="width:100%"/>
      <div class="row"><button class="primary" id="ai-key-save">${L("저장")}</button><button id="ai-key-page">${L("키 발급 페이지 열기")}</button></div>
      <hr/><p class="hint">${L("또는 구독 계정으로 로그인해서 쓸 수 있습니다.")}</p>${loginButtons()}</div>`;
  } else {
    const examples = A.items.length ? "" : `<div class="hint" style="margin-bottom:6px"><b>${L("이렇게 말해 보세요")}</b></div>` +
      EXAMPLES.map((x) => `<button class="ex" data-ex="${esc(x)}">${esc(L(x))}</button>`).join("");
    const busy = A.busy ? `<div class="row busy"><span class="spin"></span><span class="hint">${esc(L(A.status || "생각 중…"))}</span><span class="spacer"></span><button class="mini" id="ai-stop">${L("중지")}</button></div>` : "";
    const provider = b === "codex" ? "codex" : "claude";
    const login = A.agents.needsLogin ? `<div class="ai-needs"><span>🔑 ${working(A.agents[provider]) ? esc(L(A.agents[provider].message)) : L(provider === "codex" ? "ChatGPT 로그인이 필요합니다" : "Claude 로그인이 필요합니다")}</span>
        <span class="spacer"></span><button class="mini" data-login="${provider}" ${working(A.agents[provider]) ? "disabled" : ""}>${L("로그인")}</button></div>` : "";
    body = `<div class="ai-chat" id="ai-chat">${examples}${A.items.map(bubble).join("")}${busy}</div>${login}
      <div class="ai-input"><textarea id="ai-input" rows="2" placeholder="${L("무엇을 편집할까요? (Enter로 보내기, Shift+Enter 줄바꿈)")}"></textarea>
      <button class="primary" id="ai-send" ${A.busy ? "disabled" : ""}>↑</button></div>
      <div class="hint center">${L("모든 AI 편집은 Ctrl+Z로 되돌릴 수 있습니다")}</div>`;
  }
  root.innerHTML = header() + body;
  wire();
  const input = root.querySelector("#ai-input");
  if (input) {
    input.value = A.draft;
    if (hadFocus) input.focus();
  }
  const chat = root.querySelector("#ai-chat");
  if (chat) chat.scrollTop = chat.scrollHeight;
}

function wire() {
  const q = (s) => root.querySelector(s);
  q("#ai-backend").onchange = (e) => saveSettings({ backend: e.target.value });
  q("#ai-model").onchange = (e) => saveSettings({ model: e.target.value });
  q("#ai-effort").onchange = (e) => saveSettings({ effort: e.target.value });
  q("#ai-think").onchange = (e) => saveSettings({ showThinking: e.target.checked });
  q("#ai-clear").onclick = () => invoke("ai_reset");
  q("#ai-connect").onclick = connectDialog;
  root.querySelectorAll("[data-login]").forEach((b) => (b.onclick = () => login(b.dataset.login)));
  root.querySelectorAll("[data-cancel-login]").forEach((b) => (b.onclick = () => invoke("ai_cancel_login")));
  root.querySelectorAll("[data-reopen]").forEach((b) => (b.onclick = () => openUrl(A.agents.loginUrl)));
  root.querySelectorAll("[data-ex]").forEach((b) => (b.onclick = () => sendAI(b.dataset.ex)));
  if (q("#ai-use-api")) q("#ai-use-api").onclick = () => saveSettings({ backend: "api" });
  if (q("#ai-key-save")) {
    q("#ai-key-save").onclick = async () => {
      const k = q("#ai-key").value.trim();
      if (k.length < 20) return toastFn(L("키를 붙여 넣으세요."));
      try { A.agents = await invoke("ai_set_key", { key: k }); render(); } catch (e) { toastFn(L(String(e))); }
    };
    q("#ai-key-page").onclick = () => openUrl("https://console.anthropic.com/settings/keys");
  }
  if (q("#ai-stop")) q("#ai-stop").onclick = () => invoke("ai_cancel");
  const input = q("#ai-input");
  if (input) {
    const submit = () => { const t = input.value; input.value = ""; A.draft = ""; sendAI(t); };
    input.onkeydown = (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); }
      e.stopPropagation(); // 편집 단축키가 입력 중에 동작하지 않게
    };
    q("#ai-send").onclick = submit;
  }
}

async function login(provider) {
  try {
    A.agents = await invoke("ai_connect", { provider });
    render();
  } catch (e) {
    toastFn(L(String(e)));
  }
}

export function openUrl(url) {
  if (!url) return;
  invoke("open_url", { url }).catch(() => window.open(url, "_blank"));
}

// MARK: 계정 연결 관리 (앱 안 AI + 다른 AI 앱에서 EasyCut 조작)

export async function connectDialog() {
  let links = await invoke("ai_links").catch(() => ({}));
  let msg = "";
  const draw = () => {
    // 다른 창(업데이트 안내 등)으로 바뀌었거나 닫혔으면 다시 그리지 않는다
    if (drawn && (!modalBox.querySelector("#cn-close") || document.querySelector("#modal").classList.contains("hidden"))) {
      unlisten?.();
      return;
    }
    drawn = true;
    const step = (key, title) => `<div class="row"><span>${links[key] ? "✅" : "⚪"}</span><span style="flex:1">${L(title)}</span>
      <button class="mini" data-link="${key}" ${key === "code" && !links.claudeInstalled || key === "codex" && !links.codexInstalled ? "disabled" : ""}>${L(links[key] ? "다시 연결" : "연결하기")}</button></div>`;
    modalBox.innerHTML = `<h2>✨ ${L("AI 계정 연결")}</h2>
      <p class="hint">${L("버튼 하나로 로그인하면 끝입니다. 필요한 프로그램 설치와 연결은 앱이 알아서 합니다.")}</p>
      <fieldset><legend>${L("앱 안에서 AI 편집 (AI 탭)")}</legend>
        ${loginButtons()}
        <details><summary class="hint">${L("OpenAI API 키로 로그인 (구독 대신)")}</summary>
          <div class="row"><input type="password" id="oa-key" placeholder="sk-…" style="flex:1"/><button id="oa-go">${L("로그인")}</button></div></details>
        <div class="row"><span class="hint">${L("지금 쓰는 연결:")}</span><select id="cn-backend">${BACKENDS.map(([v, t]) => `<option value="${v}" ${A.settings.backend === v ? "selected" : ""}>${L(t)}</option>`).join("")}</select></div>
      </fieldset>
      <fieldset><legend>${L("다른 AI 앱에서 EasyCut 조작 (선택)")}</legend>
        ${step("desktop", "Claude 데스크톱 앱")}${step("code", "Claude Code (터미널)")}${step("codex", "Codex (터미널)")}
        <p class="hint">${L("EasyCut을 켜 둔 상태에서 \"EasyCut에서 무음 잘라줘\"처럼 말하면 됩니다. 연결은 이 PC 안에서만 이뤄집니다.")}</p>
      </fieldset>
      ${msg ? `<p class="note">${esc(L(msg))}</p>` : ""}
      <div class="btns"><button class="primary" id="cn-close">${L("닫기")}</button></div>`;
    modalBox.querySelectorAll("[data-login]").forEach((b) => (b.onclick = async () => { await login(b.dataset.login); draw(); }));
    modalBox.querySelectorAll("[data-cancel-login]").forEach((b) => (b.onclick = () => invoke("ai_cancel_login")));
    modalBox.querySelectorAll("[data-reopen]").forEach((b) => (b.onclick = () => openUrl(A.agents.loginUrl)));
    modalBox.querySelector("#oa-go").onclick = async () => {
      const k = modalBox.querySelector("#oa-key").value.trim();
      if (k.length < 20) return;
      try { A.agents = await invoke("ai_connect_codex_key", { key: k }); } catch (e) { msg = String(e); }
      draw();
    };
    modalBox.querySelector("#cn-backend").onchange = (e) => saveSettings({ backend: e.target.value });
    modalBox.querySelectorAll("[data-link]").forEach((b) => (b.onclick = async () => {
      b.disabled = true;
      try {
        links = await invoke("ai_link", { target: b.dataset.link });
        msg = {
          desktop: "Claude 데스크톱을 완전히 종료한 뒤 다시 열면 EasyCut 도구가 보입니다.",
          code: "Claude Code에 연결했습니다. 새 대화에서 EasyCut 도구를 쓸 수 있습니다.",
          codex: "Codex에 연결했습니다. 새 대화에서 EasyCut 도구를 쓸 수 있습니다.",
        }[b.dataset.link];
      } catch (e) { msg = String(e); }
      draw();
    }));
    modalBox.querySelector("#cn-close").onclick = () => { unlisten?.(); hideModal(); };
  };
  // 로그인 진행 상황이 바뀌면 창도 다시 그린다
  let unlisten = null;
  let drawn = false;
  listen("ai", (e) => { if (e.payload.type === "agents") draw(); }).then((u) => (unlisten = u));
  draw();
  showModal();
  invoke("ai_refresh_agents").then((a) => { A.agents = a; invoke("ai_links").then((l) => { links = l; draw(); }); }).catch(() => {});
}
