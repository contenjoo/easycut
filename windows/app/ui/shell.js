// 앱 틀: 메뉴 막대, 단축키 보기, 링크로 가져오기, 업데이트, 복구, 창 닫기 확인
const tauri = window.__TAURI__;
const invoke = (cmd, args) => tauri.core.invoke(cmd, args);
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

let api; // app.js가 넘겨주는 명령·상태

export function modalBox() {
  return $("#modal-box");
}
export function showModal() {
  $("#modal").classList.remove("hidden");
}
export function hideModal() {
  $("#modal").classList.add("hidden");
}

/// 버튼 여러 개인 확인 창. 누른 버튼의 값(없으면 null)
export function ask(title, text, buttons) {
  return new Promise((resolve) => {
    const box = modalBox();
    box.innerHTML = `<h2>${esc(title)}</h2><p class="hint" style="white-space:pre-line">${esc(text)}</p><div class="btns"></div>`;
    const row = box.querySelector(".btns");
    for (const b of buttons) {
      const el = document.createElement("button");
      el.textContent = b.label;
      if (b.primary) el.className = "primary";
      if (b.danger) el.className = "danger";
      el.onclick = () => { hideModal(); resolve(b.value); };
      row.appendChild(el);
    }
    showModal();
  });
}

export async function initShell(a) {
  api = a;
  await buildMenu();
  guardClose();
  const rec = await invoke("recovery_check").catch(() => null);
  if (rec && !api.S.path && !api.S.project?.assets.length) await offerRecovery(rec);
  // 시작할 때, 그리고 6시간마다 새 버전 확인
  setTimeout(() => checkUpdate(false), 4000);
  setInterval(() => checkUpdate(false), 6 * 3600 * 1000);
}

// MARK: 메뉴 막대 (가속키는 등록하지 않는다: 글자 입력칸의 Ctrl+C/V/Z를 가로채지 않도록. 단축키는 app.js가 처리)

export async function buildMenu() {
  const M = tauri.menu;
  if (!M) return;
  const item = (text, action, key) => M.MenuItem.new({ text: key ? `${L(text)}\t${key}` : L(text), action });
  const sep = () => M.PredefinedMenuItem.new({ item: "Separator" });
  const prefs = await invoke("get_prefs").catch(() => ({}));
  const c = api.commands;
  const speeds = [0.25, 0.5, 1, 1.25, 1.5, 2, 3, 4, 8, 16];
  const lang = (() => { try { return localStorage.getItem("uiLang") || ""; } catch (_) { return ""; } })();
  const langItem = (v, name) => item((lang === v ? "✓ " : "   ") + name, () => { try { localStorage.setItem("uiLang", v); } catch (_) {} location.reload(); });

  const file = await M.Submenu.new({
    text: L("파일"),
    items: await Promise.all([
      item("새 프로젝트", c.newProject, "Ctrl+N"),
      item("프로젝트 열기…", c.open, "Ctrl+O"),
      M.Submenu.new({ text: L("최근 프로젝트"), items: await Promise.all((prefs.recent || []).length
        ? [...prefs.recent.map((p) => item(p.split(/[\\/]/).pop().replace(/\.easycut$/, "") + "   —   " + p, () => c.openPath(p))), sep(), item("목록 지우기", async () => { await invoke("set_pref", { key: "recent", value: [] }); buildMenu(); })]
        : [M.MenuItem.new({ text: L("없음"), enabled: false })]) }),
      sep(),
      item("미디어 가져오기…", c.import, "Ctrl+I"),
      item("링크로 가져오기 (유튜브 등)…", linkDialog, "Ctrl+Shift+I"),
      ...(c.record ? [item("화면·얼굴 녹화…", c.record, "Ctrl+Alt+R")] : []),
      sep(),
      item("저장", c.save, "Ctrl+S"),
      item("다른 이름으로 저장…", c.saveAs, "Ctrl+Shift+S"),
      M.CheckMenuItem.new({ text: L("자동 저장"), checked: prefs.autosave !== false, action: async (id) => {
        const p = await invoke("get_prefs");
        await invoke("set_pref", { key: "autosave", value: !(p.autosave !== false) });
        buildMenu();
      } }),
      sep(),
      item("영상 내보내기…", c.export, "Ctrl+E"),
      item("SRT 자막 내보내기…", c.exportSrt),
      ...(c.exportTranscript ? [item("대본 텍스트 내보내기…", c.exportTranscript)] : []),
      ...(c.snapshot ? [item("현재 장면 PNG로 저장…", c.snapshot)] : []),
      sep(),
      item("SRT 자막 가져오기…", c.importSrt),
      sep(),
      item("끝내기", () => tauri.window.getCurrentWindow().close(), "Alt+F4"),
    ]),
  });
  const edit = await M.Submenu.new({
    text: L("편집"),
    items: await Promise.all([
      item("실행 취소", c.undo, "Ctrl+Z"),
      item("다시 실행", c.redo, "Ctrl+Y"),
      sep(),
      ...(c.cut ? [item("잘라내기", c.cut, "Ctrl+X"), item("복사", c.copy, "Ctrl+C"), item("붙여넣기", c.paste, "Ctrl+V")] : []),
      ...(c.duplicate ? [item("복제", c.duplicate, "Ctrl+D")] : []),
      ...(c.selectAll ? [item("모두 선택", c.selectAll, "Ctrl+A")] : []),
      item("선택 해제", c.deselect, "Esc"),
    ]),
  });
  const timeline = await M.Submenu.new({
    text: L("타임라인"),
    items: await Promise.all([
      item("재생헤드에서 분할", c.split, "S / Ctrl+T"),
      ...(c.splitAll ? [item("모든 트랙 분할", c.splitAll, "Ctrl+Shift+T")] : []),
      sep(),
      item("삭제", c.deleteSel, "Delete"),
      item("삭제 후 빈틈 메우기", c.delete, "Ctrl+Delete"),
      ...(c.group ? [sep(), item("그룹으로 묶기", c.group, "Ctrl+G"), item("그룹 해제", c.ungroup, "Ctrl+Shift+G"), item("하나로 합치기", c.join, "Ctrl+J")] : []),
      sep(),
      item("구간 시작", c.markIn, "I"),
      item("구간 끝", c.markOut, "O"),
      item("구간 해제", c.clearMarks, "X"),
      sep(),
      item("텍스트(제목) 추가", c.text, "T"),
      ...(c.addTrack ? [item("트랙 추가", c.addTrack), item("빈 트랙 정리", c.cleanTracks)] : []),
      sep(),
      item("확대", c.zoomIn, "Ctrl+="),
      item("축소", c.zoomOut, "Ctrl+-"),
      item("전체 보기", c.fit, "Shift+Z"),
      ...(c.toggleSnap ? [item("스냅(자석) 켜기/끄기", c.toggleSnap, "N")] : []),
    ]),
  });
  const play = await M.Submenu.new({
    text: L("재생"),
    items: await Promise.all([
      item("재생 / 일시정지", c.play, "Space"),
      item("빠르게", c.faster, "L"),
      item("느리게", c.slower, "J"),
      item("정지", c.stop, "K"),
      sep(),
      M.Submenu.new({ text: L("재생 속도"), items: await Promise.all(speeds.map((s) => item(`${s}x`, () => c.setRate(s)))) }),
      sep(),
      item("처음으로", c.start, "Home"),
      item("끝으로", c.end, "End"),
      ...(c.prevEdit ? [item("이전 편집점", c.prevEdit, "↑"), item("다음 편집점", c.nextEdit, "↓")] : []),
    ]),
  });
  const tools = await M.Submenu.new({
    text: L("도구"),
    items: await Promise.all([
      item("음성 인식 (STT)", c.transcribe, "Ctrl+Shift+R"),
      item("대본으로 자막 만들기", c.captions, "Ctrl+Shift+C"),
      item("무음 컷 (원클릭)…", c.silence, "Ctrl+Shift+X"),
      item("군더더기 말 제거", c.fillers),
      ...(c.addCaption ? [sep(), item("자막 추가", c.addCaption, "C")] : []),
      sep(),
      item("AI 편집", c.ai, "Ctrl+4"),
      item("AI 계정 연결…", c.aiConnect),
    ]),
  });
  const help = await M.Submenu.new({
    text: L("도움말"),
    items: await Promise.all([
      item("단축키 보기", shortcutsDialog, "Ctrl+/"),
      item("업데이트 확인…", () => checkUpdate(true)),
      M.Submenu.new({ text: "언어 / Language", items: await Promise.all([langItem("", L("자동 (Windows 언어)")), langItem("ko", "한국어"), langItem("en", "English")]) }),
      sep(),
      item(`EasyCut ${prefs.version || ""}`, () => invoke("open_url", { url: "https://github.com/contenjoo/easycut" })),
    ]),
  });
  const menu = await M.Menu.new({ items: [file, edit, timeline, play, tools, help] });
  await menu.setAsAppMenu();
}

// MARK: 단축키 보기 (맥 Sheets.swift ShortcutsSheet)

export function shortcutsDialog() {
  const sections = [
    ["재생", [
      ["Space", "재생 / 일시정지"], ["L", "빠르게 (누를 때마다 2·4·8·16배)"], ["J", "느리게"], ["K", "정지"],
      [", / .", "이전 / 다음 프레임"], ["← / →", "1초 뒤로 / 앞으로"], ["Shift+← / →", "5초 뒤로 / 앞으로"],
      ["↑ / ↓", "이전 / 다음 편집점"], ["Home / End", "처음 / 끝"],
    ]],
    ["편집", [
      ["S 또는 Ctrl+T", "재생헤드에서 분할"], ["Ctrl+Shift+T", "모든 트랙 분할"], ["I / O", "구간 시작 / 끝"],
      ["Delete", "선택한 클립 또는 구간 삭제"], ["Ctrl+Delete", "삭제 후 빈틈 메우기"], ["X", "구간 해제"],
      ["Ctrl+C / X / V", "클립 복사 / 잘라내기 / 붙여넣기"], ["Ctrl+D", "복제"], ["Ctrl+A", "모두 선택"], ["Esc", "선택 해제"],
      ["Ctrl+Z / Ctrl+Y", "실행 취소 / 다시 실행"],
    ]],
    ["대본 · 자막", [
      ["Ctrl+Shift+R", "음성 인식 (STT)"], ["Ctrl+Shift+X", "무음 컷"], ["대본에서 Delete", "선택한 말을 영상에서 잘라내기"],
      ["Ctrl+Shift+C", "대본으로 자막 만들기"], ["C", "재생헤드에 자막 추가"],
      ["트랙 1 클립 끌기", "끼워 넣어 순서 바꾸기 (Alt+끌기 = 자유 이동)"], ["빈 곳 끌기", "클립 여러 개 선택 (Shift/Ctrl = 기존 선택에 더하기)"],
      ["눈금자 끌기", "시간 구간 선택 → Delete 잘라내기 (Alt+끌기 = 재생헤드만 이동)"],
      ["Ctrl+G / Ctrl+Shift+G", "선택한 클립 그룹으로 묶기 / 풀기"], ["Ctrl+J", "하나로 합치기"], ["T", "재생헤드에 텍스트(제목) 추가"],
    ]],
    ["타임라인 · 파일", [
      ["Ctrl+= / Ctrl+-", "타임라인 확대 / 축소 (Ctrl+휠)"], ["Shift+Z", "타임라인 전체 보기"], ["N", "스냅(자석) 켜기/끄기"],
      ["Ctrl+I / Ctrl+Shift+I", "미디어 가져오기 / 링크(유튜브)로 가져오기"], ["Ctrl+Alt+R", "화면·얼굴 녹화"], ["Ctrl+E", "내보내기"],
      ["Ctrl+S / Ctrl+Shift+S", "저장 / 다른 이름으로 저장"], ["Ctrl+O / Ctrl+N", "열기 / 새 프로젝트"],
      ["Ctrl+1 ~ 4", "미디어 / 대본 / 자막 / AI 탭"], ["Ctrl+/", "단축키 보기"],
    ]],
  ];
  const box = modalBox();
  box.innerHTML = `<h2>${L("단축키")}</h2><div class="shortcuts">${sections.map(([t, rows]) =>
    `<h3>${L(t)}</h3><table>${rows.map(([k, d]) => `<tr><td><kbd>${esc(L(k))}</kbd></td><td>${esc(L(d))}</td></tr>`).join("")}</table>`).join("")}</div>
    <div class="btns"><button class="primary" id="sc-close">${L("닫기")}</button></div>`;
  box.classList.add("wide");
  box.querySelector("#sc-close").onclick = () => { box.classList.remove("wide"); hideModal(); };
  showModal();
}

// MARK: 링크로 가져오기 (맥 Sheets.swift LinkSheet)

export async function linkDialog() {
  const box = modalBox();
  let clip = "";
  try { clip = (await navigator.clipboard.readText()) || ""; } catch (_) {}
  const isLink = (s) => /^https?:\/\/\S+$/i.test(s.trim());
  const status = await invoke("ytdlp_status").catch(() => ({ installed: false }));
  let quality = (() => { try { return localStorage.getItem("linkQuality") || "1080p"; } catch (_) { return "1080p"; } })();
  box.innerHTML = `<h2>${L("링크로 가져오기")}</h2>
    <p class="hint">${L("유튜브 등 영상 페이지 주소를 붙여 넣으세요. 내가 올렸거나 쓸 권한이 있는 영상만 받으세요.")}</p>
    <input id="lk-url" style="width:100%" placeholder="https://www.youtube.com/watch?v=…" value="${isLink(clip) ? esc(clip.trim()) : ""}"/>
    <div class="row"><label>${L("화질")}</label><select id="lk-q">
      ${[["720p", "720p"], ["1080p", "1080p"], ["best", "최고 화질"], ["audio", "소리만 (M4A)"]].map(([v, t]) => `<option value="${v}" ${quality === v ? "selected" : ""}>${L(t)}</option>`).join("")}
    </select></div>
    <div class="row"><label><input type="checkbox" id="lk-part"/> ${L("일부만 받기")}</label>
      <input id="lk-a" placeholder="${L("시작 (예: 1:30)")}" size="9" disabled/> ~ <input id="lk-b" placeholder="${L("끝 (예: 3:00)")}" size="9" disabled/></div>
    <p class="hint">${status.installed ? "" : L("처음 한 번 유튜브 도구(yt-dlp)를 받습니다.")}</p>
    <div class="btns"><button id="lk-upd">${L(status.installed ? "유튜브 도구 업데이트" : "유튜브 도구 설치")}</button><span class="spacer"></span>
      <button id="lk-cancel">${L("취소")}</button><button class="primary" id="lk-go">${L("받기")}</button></div>`;
  showModal();
  const q = (s) => box.querySelector(s);
  q("#lk-url").focus();
  q("#lk-part").onchange = (e) => { q("#lk-a").disabled = q("#lk-b").disabled = !e.target.checked; };
  q("#lk-cancel").onclick = hideModal;
  q("#lk-upd").onclick = async () => {
    q("#lk-upd").disabled = true;
    try { await invoke("ytdlp_update"); api.toast(L("유튜브 도구를 최신으로 바꿨습니다")); } catch (e) { api.toast(L(String(e))); }
    q("#lk-upd").disabled = false;
  };
  const parse = (s) => {
    const t = s.trim();
    if (!t) return null;
    let total = 0;
    for (const p of t.split(":")) { const v = parseFloat(p); if (isNaN(v)) return null; total = total * 60 + v; }
    return total;
  };
  q("#lk-go").onclick = async () => {
    const url = q("#lk-url").value.trim();
    if (!isLink(url)) return api.toast(L("올바른 링크가 필요합니다"));
    quality = q("#lk-q").value;
    try { localStorage.setItem("linkQuality", quality); } catch (_) {}
    const part = q("#lk-part").checked;
    const start = part ? parse(q("#lk-a").value) : null;
    const end = part ? parse(q("#lk-b").value) : null;
    hideModal();
    api.switchTab("media");
    try {
      const name = await invoke("import_link", { url, quality, start, end });
      api.toast(L("가져옴: {}", name));
    } catch (e) {
      await ask(L("가져오기 실패"), L(String(e)), [{ label: L("확인"), value: 1, primary: true }]);
    }
  };
}

// MARK: 업데이트 (맥 Updater.swift: 업데이트 / 나중에 / 이 버전 건너뛰기)

let checking = false;
export async function checkUpdate(userInitiated) {
  if (checking) return;
  checking = true;
  try {
    const u = await invoke("check_update");
    if (!u) {
      if (userInitiated) await ask(L("최신 버전입니다"), L("지금 쓰는 EasyCut이 가장 새 버전입니다."), [{ label: L("확인"), value: 1, primary: true }]);
      return;
    }
    let skipped = "";
    try { skipped = localStorage.getItem("skipUpdate") || ""; } catch (_) {}
    if (!userInitiated && skipped === u.version) return;
    const notes = (u.notes || "").slice(0, 700);
    const choice = await ask(`${L("새 버전이 나왔습니다")}: EasyCut ${u.version}`, `${L("지금 쓰는 버전:")} ${u.current}\n\n${notes}`,
      [{ label: L("이 버전 건너뛰기"), value: "skip" }, { label: L("나중에"), value: "later" }, { label: L("업데이트"), value: "update", primary: true }]);
    if (choice === "skip") { try { localStorage.setItem("skipUpdate", u.version); } catch (_) {} return; }
    if (choice !== "update") return;
    api.toast(L("업데이트를 받는 중입니다. 받은 뒤 앱이 다시 열립니다."));
    await invoke("install_update", { url: u.url });
  } catch (e) {
    if (userInitiated) await ask(L("업데이트를 확인하지 못했습니다"), L(String(e)), [{ label: L("확인"), value: 1, primary: true }]);
  } finally {
    checking = false;
  }
}

// MARK: 복구 · 창 닫기

async function offerRecovery(rec) {
  const when = rec.savedAt ? new Date(rec.savedAt).toLocaleString() : "";
  const choice = await ask(L("저장하지 않은 프로젝트가 있습니다"),
    L("{}에 자동으로 보관된 작업(미디어 {}개, 길이 {})을 다시 열까요?", when, rec.assets, api.U.fmt(rec.duration)),
    [{ label: L("버리기"), value: "discard" }, { label: L("복구"), value: "restore", primary: true }]);
  if (choice === "restore") {
    await api.run("recovery_restore");
    api.toast(L("복구했습니다. Ctrl+S로 저장하세요"));
  } else {
    invoke("recovery_discard");
  }
}

/// 저장 / 저장 안 함 / 취소. 계속해도 되면 true
export async function confirmDiscard() {
  const S = api.S;
  if (!S.dirty || !(S.project?.assets.length || S.project?.tracks.some((t) => t.clips.length))) return true;
  const choice = await ask(L("저장하지 않은 변경 사항이 있습니다."), L("저장하지 않고 계속할까요?"),
    [{ label: L("취소"), value: "cancel" }, { label: L("저장 안 함"), value: "discard" }, { label: L("저장"), value: "save", primary: true }]);
  if (choice === "save") return await api.commands.save();
  return choice === "discard";
}

function guardClose() {
  const w = tauri.window?.getCurrentWindow?.();
  if (!w) return;
  w.onCloseRequested(async (e) => {
    e.preventDefault();
    if (api.isBusyRecording?.()) return api.toast(L("녹화 중에는 닫을 수 없습니다"));
    if (await confirmDiscard()) invoke("quit_app");
  });
}
