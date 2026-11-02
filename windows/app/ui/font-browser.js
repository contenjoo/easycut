// 설치 글꼴 조회·검색·선택. 편집 상태는 호출자가 전달하므로 app.js에 의존하지 않는다.
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
let invokeFonts;
let catalog = [], loaded = false, loading = null, lastError = null;

export function initFontBrowser({ invoke }) { invokeFonts = invoke; }

export function normalizeFonts(fonts) {
  const seen = new Set();
  return (Array.isArray(fonts) ? fonts : []).filter((f) => f && typeof f.family === "string" && f.family.trim()).map((f) => ({
    family: f.family.trim(), fontName: String(f.fontName || f.family).trim(), displayName: String(f.displayName || f.family).trim(),
  })).filter((f) => !seen.has(f.family.toLocaleLowerCase()) && seen.add(f.family.toLocaleLowerCase()))
    .sort((a, b) => a.displayName.localeCompare(b.displayName));
}

export function fontSearchAliases(font) {
  const n = `${font.family} ${font.fontName}`.toLowerCase().replace(/[\s_-]/g, "");
  const a = [];
  if (n.includes("malgun")) a.push("맑은 고딕", "맑은고딕", "맑은");
  if (n.includes("nanum")) {
    a.push("나눔");
    if (n.includes("barungothic")) a.push("나눔바른고딕", "나눔 바른 고딕");
    else if (n.includes("gothic")) a.push("나눔고딕", "나눔 고딕");
    if (n.includes("myeongjo")) a.push("나눔명조", "나눔 명조");
    if (n.includes("square")) a.push("나눔스퀘어", "나눔 스퀘어");
  }
  if (n.includes("applesdgothic")) a.push("산돌", "산돌고딕", "애플고딕", "애플 고딕");
  if (n.includes("applemyungjo")) a.push("애플명조", "애플 명조", "명조");
  if (n.includes("bmjua")) a.push("배민", "주아", "배달의민족");
  if (n.includes("bmhanna")) a.push("배민", "한나", "배달의민족");
  if (n.includes("pretendard")) a.push("프리텐다드");
  if (n.includes("spoqa")) a.push("스포카", "스포카한산스");
  if (n.includes("gmarket")) a.push("지마켓", "지마켓산스");
  if (n.includes("gulim")) a.push("굴림");
  if (n.includes("dotum")) a.push("돋움");
  if (n.includes("batang")) a.push("바탕");
  if (n.includes("gungsuh")) a.push("궁서");
  if (n.includes("notosanskr") || n.includes("notosanscjkkr")) a.push("노토산스", "노토 산스");
  if (n.includes("arial")) a.push("아리알", "에어리얼");
  if (n.includes("segoe")) a.push("시고", "시고 UI");
  if (n.includes("helvetica")) a.push("헬베티카");
  return a;
}

export function filterFonts(fonts, query) {
  const term = String(query || "").trim().toLocaleLowerCase();
  if (!term) return fonts;
  return fonts.filter((f) => [f.family, f.fontName, f.displayName, ...fontSearchAliases(f)].some((s) => String(s).toLocaleLowerCase().includes(term)));
}

export async function loadInstalledFonts(force = false) {
  if (loading) return loading;
  if (loaded && !force) return { fonts: catalog, error: lastError };
  loading = (async () => {
    try {
      if (!invokeFonts) throw new Error(L("글꼴 조회를 시작하지 못했습니다."));
      const fonts = normalizeFonts(await invokeFonts("list_fonts"));
      if (!fonts.length) throw new Error(L("설치된 글꼴 목록이 비어 있습니다."));
      catalog = fonts; loaded = true; lastError = null;
    } catch (e) {
      lastError = String(e?.message || e);
    } finally { loading = null; }
    return { fonts: catalog, error: lastError };
  })();
  return loading;
}

function applyFont(el, name) { el.style.fontFamily = name ? `"${String(name).replace(/["\\]/g, "")}", sans-serif` : '"Malgun Gothic", "Segoe UI", sans-serif'; }
function recommended(fonts) { return fonts.filter((f) => /malgun|nanum|pretendard|noto sans kr|batang|gmarket/i.test(f.family)).slice(0, 6); }

export function renderFontPicker(el, current, onSelect) {
  const selected = catalog.find((f) => f.fontName === current || f.family === current);
  el.innerHTML = `<h3>${L("글꼴")}</h3><button type="button" class="font-picker-button" data-testid="font-browser-button"><span class="font-aa">Aa</span><span class="font-picker-title"><b>${esc(selected?.displayName || current || L("시스템 글꼴"))}</b><small>${L("설치된 글꼴 모두 보기")}</small></span><span aria-hidden="true">⌄</span></button><div class="font-suggestions"></div>`;
  applyFont(el.querySelector(".font-aa"), current);
  el.querySelector(".font-picker-button").onclick = () => openFontBrowser(current, onSelect);
  const token = Symbol(); el._fontToken = token;
  loadInstalledFonts().then(({ fonts }) => {
    if (!el.isConnected || el._fontToken !== token) return;
    const target = el.querySelector(".font-suggestions");
    for (const font of recommended(fonts).slice(0, 3)) {
      const b = document.createElement("button"); b.type = "button"; b.className = "font-suggestion";
      b.innerHTML = `<span class="font-sample">가나다</span><small>${esc(font.displayName)}</small>`;
      applyFont(b.querySelector(".font-sample"), font.fontName);
      b.title = font.displayName; b.onclick = () => onSelect(font.fontName); target.appendChild(b);
    }
  });
}

export function openFontBrowser(current, onSelect) {
  document.querySelector("#font-browser")?.close();
  const dialog = document.createElement("dialog"); dialog.id = "font-browser"; dialog.className = "font-browser";
  dialog.setAttribute("aria-labelledby", "font-browser-title");
  dialog.innerHTML = `<div class="font-browser-header"><h2 id="font-browser-title">${L("글꼴 선택")}</h2><button type="button" class="font-done">${L("완료")}</button></div><label class="font-search"><span aria-hidden="true">⌕</span><input type="search" placeholder="${L("글꼴 이름 검색")}" aria-label="${L("글꼴 이름 검색")}" data-testid="font-search-field"/></label><div class="font-browser-status" role="status"></div><div class="font-results" data-testid="font-results"></div><footer>${L("이 PC에 설치된 글꼴을 사용합니다.")}</footer>`;
  document.body.appendChild(dialog); dialog.showModal();
  const search = dialog.querySelector("input"), results = dialog.querySelector(".font-results"), status = dialog.querySelector(".font-browser-status");
  let fonts = catalog;
  const row = (font, isSystem = false) => {
    const b = document.createElement("button"); b.type = "button"; b.className = "font-result";
    b.setAttribute("aria-pressed", String(current === font.fontName));
    b.dataset.family = font.family;
    b.innerHTML = `<span><small>${esc(isSystem ? L("시스템 글꼴") : font.displayName)}</small><span class="font-result-sample">가나다 Aa 123</span></span><span class="font-check" aria-hidden="true">${current === font.fontName ? "✓" : ""}</span>`;
    applyFont(b.querySelector(".font-result-sample"), font.fontName);
    b.onclick = () => { current = font.fontName; onSelect(font.fontName); draw(); };
    results.appendChild(b);
  };
  const heading = (title) => { const h = document.createElement("h3"); h.textContent = title; results.appendChild(h); };
  const draw = () => {
    results.replaceChildren();
    const query = search.value.trim(), matches = filterFonts(fonts, query);
    if (!query) {
      row({ family: "system", fontName: "", displayName: L("시스템 글꼴") }, true);
      if (recommended(fonts).length) { heading(L("추천 글꼴")); recommended(fonts).forEach((f) => row(f)); }
    }
    heading(fonts.length ? L("설치된 글꼴 {}개", matches.length) : L("기본 글꼴"));
    if (!matches.length && fonts.length) { const empty = document.createElement("p"); empty.className = "empty-note"; empty.textContent = L("검색한 글꼴이 없습니다"); results.appendChild(empty); }
    matches.forEach((f) => row(f));
  };
  const load = async (force = false) => {
    status.textContent = L("설치된 글꼴을 읽는 중…");
    const result = await loadInstalledFonts(force);
    if (!dialog.isConnected) return;
    fonts = result.fonts;
    status.replaceChildren();
    if (result.error) {
      const text = document.createElement("span"); text.textContent = L("설치된 글꼴을 불러오지 못했습니다.") + " " + result.error;
      const retry = document.createElement("button"); retry.type = "button"; retry.textContent = L("다시 시도"); retry.onclick = () => load(true);
      status.append(text, retry); status.classList.add("warn");
    } else status.classList.remove("warn");
    draw();
  };
  dialog.querySelector(".font-done").onclick = () => dialog.close();
  dialog.addEventListener("close", () => dialog.remove(), { once: true });
  search.oninput = draw; search.onkeydown = (e) => e.stopPropagation();
  draw(); load(); search.focus();
}
