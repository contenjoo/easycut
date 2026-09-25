// 화면 문구: 윈도우 언어가 한국어면 한국어, 아니면 영어
(function () {
  const ko = {
    import: "가져오기", undo: "실행 취소 (Ctrl+Z)", redo: "다시 실행 (Ctrl+Y)", split: "분할", delete: "삭제", text: "텍스트",
    silence: "무음 컷", transcribe: "음성 인식", makeCaptions: "자막 생성", save: "저장", export: "내보내기",
    media: "미디어", transcript: "대본", captionsTab: "자막", dropHint: "영상, 오디오, 사진을 여기로 끌어다 놓으세요",
    fit: "전체", newProject: "새 프로젝트", edited: "편집됨", items: "개", addToTimeline: "타임라인에 추가", remove: "제거",
    video: "영상", audio: "오디오", image: "사진", noMedia: "가져오기를 누르거나 파일을 끌어다 놓으세요.",
    noTranscript: "아직 대본이 없습니다. 영상을 타임라인에 올리고 [음성 인식]을 누르세요.\n단어를 선택하고 Delete를 누르면 그 부분이 영상에서 잘립니다.",
    deleteSel: "선택 삭제", fillers: "군더더기", language: "언어", korean: "한국어", english: "영어",
    noCaptions: "자막이 없습니다. 음성 인식 후 [자막 생성]을 누르세요.", importSrt: "SRT 가져오기", exportSrt: "SRT 내보내기",
    captionStyle: "자막 스타일", size: "크기", color: "글자", background: "배경", outline: "외곽선", position: "위치", showCaptions: "자막 표시",
    clip: "클립", speed: "속도", volume: "볼륨", scale: "크기", posX: "가로", posY: "세로", opacity: "불투명도", fadeIn: "페이드 인", fadeOut: "페이드 아웃",
    project: "프로젝트", canvas: "화면 크기", fps: "프레임", selectClipHint: "클립을 선택하면 속도·볼륨·크기를 조절할 수 있습니다.",
    clipsSelected: "개 클립 선택됨", textContent: "내용", saved: "저장했습니다", exported: "내보내기 완료!",
    exportTitle: "영상 내보내기", resolution: "해상도", original: "원본", burnCaptions: "자막을 영상에 입히기", cancel: "취소", start: "시작",
    silenceTitle: "무음 컷", silenceHint: "말이 없는 부분을 찾아 한 번에 잘라냅니다. 잘릴 곳은 타임라인에 빨간색으로 표시됩니다.",
    auto: "자동", minSilence: "최소 무음", padding: "앞뒤 여유", preview: "미리 보기", cutSilences: "무음 잘라내기", noSilences: "잘라낼 무음이 없습니다",
    whisperTitle: "Whisper 음성 인식 모델", whisperHint: "처음 한 번 인식 모델(약 574MB)을 받아야 합니다. 받은 뒤에는 인터넷 없이 이 PC에서 처리됩니다.",
    download: "받기", noAudio: "음성이 있는 영상/오디오를 먼저 타임라인에 올려 주세요.", range: "구간", rangeHint: "Delete 잘라내기 · 빈 곳 클릭/X/Esc 해제 · Alt+끌기 = 재생헤드만 이동",
    cutRange: "구간 잘라내기", engineMissing: "Whisper 엔진이나 ffmpeg를 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.",
    unsaved: "저장하지 않은 변경 사항이 있습니다. 계속할까요?", open: "열기", newProj: "새로 만들기", enterText: "텍스트를 입력하세요",
    track: "트랙", captionsRow: "자막", newVersion: "새 버전이 나왔습니다: EasyCut", currentVersion: "지금 쓰는 버전:", update: "업데이트", reordered: "순서를 바꿨습니다 (Alt를 누른 채 끌면 자유 이동)",
  };
  const en = {
    import: "Import", undo: "Undo (Ctrl+Z)", redo: "Redo (Ctrl+Y)", split: "Split", delete: "Delete", text: "Text",
    silence: "Silence Cut", transcribe: "Transcribe", makeCaptions: "Captions", save: "Save", export: "Export",
    media: "Media", transcript: "Transcript", captionsTab: "Captions", dropHint: "Drop video, audio or photos here",
    fit: "Fit", newProject: "New Project", edited: "Edited", items: " items", addToTimeline: "Add to Timeline", remove: "Remove",
    video: "Video", audio: "Audio", image: "Photo", noMedia: "Click Import or drop files here.",
    noTranscript: "No transcript yet. Put a video on the timeline and click [Transcribe].\nSelect words and press Delete to cut them from the video.",
    deleteSel: "Delete Selection", fillers: "Fillers", language: "Language", korean: "Korean", english: "English",
    noCaptions: "No captions. Transcribe, then click [Captions].", importSrt: "Import SRT", exportSrt: "Export SRT",
    captionStyle: "Caption style", size: "Size", color: "Text", background: "Background", outline: "Outline", position: "Position", showCaptions: "Show captions",
    clip: "Clip", speed: "Speed", volume: "Volume", scale: "Size", posX: "Horizontal", posY: "Vertical", opacity: "Opacity", fadeIn: "Fade in", fadeOut: "Fade out",
    project: "Project", canvas: "Canvas size", fps: "Frame rate", selectClipHint: "Select a clip to adjust speed, volume and size.",
    clipsSelected: " clips selected", textContent: "Content", saved: "Saved", exported: "Export complete!",
    exportTitle: "Export Video", resolution: "Resolution", original: "Original", burnCaptions: "Burn captions into the video", cancel: "Cancel", start: "Start",
    silenceTitle: "Silence Cut", silenceHint: "Finds the parts with no talking and cuts them at once. What will be cut is shown in red on the timeline.",
    auto: "Auto", minSilence: "Min silence", padding: "Padding", preview: "Preview", cutSilences: "Cut Silences", noSilences: "No silences to cut",
    whisperTitle: "Whisper speech model", whisperHint: "The recognition model (about 574 MB) must be downloaded once. After that it runs offline on this PC.",
    download: "Download", noAudio: "Put a video/audio clip with speech on the timeline first.", range: "Range", rangeHint: "Delete to cut · click empty space/X/Esc to clear · Alt+drag = move playhead only",
    cutRange: "Cut Range", engineMissing: "Whisper or ffmpeg not found. Please reinstall EasyCut.",
    unsaved: "You have unsaved changes. Continue?", open: "Open", newProj: "New", enterText: "Enter text",
    track: "Track", captionsRow: "Captions", newVersion: "A new version is available: EasyCut", currentVersion: "You have:", update: "Update", reordered: "Reordered (hold Alt while dragging to move freely)",
  };
  // 언어 메뉴에서 고른 값이 있으면 그것, 아니면 윈도우 언어
  let pick = "";
  try { pick = localStorage.getItem("uiLang") || ""; } catch (_) {}
  const lang = pick === "ko" || pick === "en" ? pick : (navigator.language || "ko").toLowerCase().startsWith("ko") ? "ko" : "en";
  const dict = lang === "ko" ? ko : en;
  window.LANG = lang;
  window.T = (k) => dict[k] ?? ko[k] ?? k;
  // 한국어 원문을 키로 쓰는 문구 (맥 앱 LocTable과 같은 방식). {}는 차례로 값이 들어간다
  window.L = (k, ...args) => {
    let s = lang === "ko" ? k : (window.EN?.[k] ?? k);
    for (const a of args) s = s.replace("{}", a);
    return s;
  };
  window.applyI18n = () => {
    document.querySelectorAll("[data-i18n]").forEach((el) => (el.textContent = T(el.dataset.i18n)));
    document.querySelectorAll("[data-i18n-title]").forEach((el) => (el.title = T(el.dataset.i18nTitle)));
    document.querySelectorAll("[data-l]").forEach((el) => (el.textContent = L(el.dataset.l)));
    document.documentElement.lang = lang;
  };
})();
