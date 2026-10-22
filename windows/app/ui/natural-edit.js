import { S, U, run, switchTab, toast } from './app.js';
import { sendAI, aiIsBusy } from './ai.js';
import { modalBox, showModal, hideModal } from './shell.js';
import { spokenCommands, filenameRequest, rules } from './natural-edit-core.js';
const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function naturalEditDialog() {
  if (aiIsBusy()) return toast('AI 편집이 끝난 뒤 사용하세요.');
  const words = U.clips().flatMap(({c}) => (U.asset(c.assetID)?.words || []).filter(w => (w.start + w.end) / 2 >= c.sourceIn && (w.start + w.end) / 2 < c.sourceOut).map(w => ({text:w.text, start:c.start + (w.start-c.sourceIn)/c.speed, end:c.start + (w.end-c.sourceIn)/c.speed, clip:c.id}))).sort((a,b) => a.start-b.start);
  const candidates = spokenCommands(words);
  const asset = U.asset(U.clips().find(({c}) => S.sel.has(c.id))?.c.assetID) || S.project?.assets[0];
  const box = modalBox();
  box.innerHTML = `<h2>말·파일명으로 편집</h2><p>녹화 중 ‘편집아, …’라고 말하세요. 음성 인식 후 지시를 골라 AI로 초안을 만듭니다. AI 연결이 필요합니다.</p>
    <label><input id="ne-auto" type="checkbox" ${localStorage.getItem('spokenEditEnabled')==='1'?'checked':''}> 녹화 후 음성 지시 검토 열기</label>
    <div style="max-height:180px;overflow:auto">${candidates.length ? candidates.map((c,i)=>`<p><label><input type="checkbox" data-ne="${i}" checked> ${U.fmt(c.start)}–${U.fmt(c.end)} ${esc(c.text)}</label></p>`).join('') : '<p>인식된 지시가 없습니다. 먼저 음성 인식을 실행하세요.</p>'}</div>
    <label><input id="ne-file-on" type="checkbox"> 파일명에서 편집 요청 읽기</label><input id="ne-filename" style="width:100%" value="${esc(asset?.name || '')}" placeholder="강의_말줄이고_3분.mp4"><p id="ne-request"></p>
    <p class="hint">첫 밑줄 앞은 제목, 뒤는 요청입니다. 원본 파일명은 바꾸지 않습니다. 적용 전 프로젝트를 보관해 한 번에 복원할 수 있습니다.</p>
    <div class="btns"><button id="ne-restore">초안 이전 복원</button><button id="ne-cancel">취소</button><button id="ne-go" class="primary">AI로 초안 만들기</button></div>`;
  const q = s => box.querySelector(s);
  q('#ne-auto').onchange = e => localStorage.setItem('spokenEditEnabled', e.target.checked?'1':'0');
  const update = () => { const req = q('#ne-file-on').checked ? filenameRequest(q('#ne-filename').value):''; q('#ne-request').textContent = '편집 요청: ' + req; q('#ne-go').disabled = !req && !box.querySelector('[data-ne]:checked'); };
  q('#ne-file-on').onchange = update; q('#ne-filename').oninput = update;
  box.querySelectorAll('[data-ne]').forEach(el => el.onchange = update);
  q('#ne-cancel').onclick = hideModal;
  q('#ne-restore').onclick = async () => { const v = await run('natural_edit_restore'); if (v) hideModal(); };
  q('#ne-go').onclick = async () => {
    if (aiIsBusy()) return toast('AI 편집이 끝난 뒤 사용하세요.');
    const selected = [...box.querySelectorAll('[data-ne]:checked')].map(el => candidates[+el.dataset.ne]);
    const request = q('#ne-file-on').checked ? filenameRequest(q('#ne-filename').value):'';
    q('#ne-go').disabled = true;
    try {
      await invoke('natural_edit_backup');
      hideModal(); switchTab('ai');
      sendAI(rules + '\n대상 클립(없으면 프로젝트 전체): ' + [...S.sel].join(', ') + '\n파일명 편집 요청: ' + request + '\n' + selected.map(c=>`타임라인 ${c.start.toFixed(3)}~${c.end.toFixed(3)}초 음성 지시: ${c.text}`).join('\n'));
    } catch(e) { toast(String(e)); q('#ne-go').disabled = false; }
  };
  update(); showModal();
}
