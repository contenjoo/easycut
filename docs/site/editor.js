(() => {
  const section = document.getElementById("features");
  if (!section || !section.classList.contains("ec-editor")) return;

  const preview = section.querySelector(".ec-editor__full");
  const image = preview.querySelector("img");
  const caption = section.querySelector(".ec-editor__caption");
  const views = [...section.querySelectorAll(".ec-editor__views a")];
  for (const view of views) {
    view.addEventListener("click", event => {
      if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      for (const link of views) link.removeAttribute("aria-current");
      view.setAttribute("aria-current", "true");
      image.src = view.href;
      image.alt = view.dataset.alt;
      caption.textContent = view.dataset.caption;
      preview.href = view.href;
      preview.setAttribute("aria-label", view.textContent + " 화면을 원본 크기로 보기");
    });
  }

  // Durations are in tenths of seconds so repeated cuts keep an exact time.
  const script = [
    ["안녕하세요", 8], ["음", 5, "filler"], ["오늘은", 6], ["무음", 14, "silence"],
    ["EasyCut으로", 9], ["어", 4, "filler"], ["영상을", 6], ["편집하는", 7], ["방법을", 6],
    ["그", 3, "filler"], ["알려", 5], ["드릴게요.", 8], ["무음", 18, "silence"],
    ["말을", 5], ["지우면", 6], ["음", 4, "filler"], ["영상도", 6], ["같이", 5], ["잘립니다.", 9],
  ];
  const play = section.querySelector(".ec-editor__play");
  const words = play.querySelector(".ec-editor__words");
  const track = play.querySelector(".ec-editor__timeline");
  const duration = play.querySelector("output");
  const undo = play.querySelector('[data-cut="undo"]');
  const groups = [...play.querySelectorAll('[data-cut]:not([data-cut="undo"])')];
  const total = script.reduce((sum, item) => sum + item[1], 0);
  const history = [];
  let removed = new Set();
  const segments = script.map(([word, length, kind = "word"], index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.kind = kind;
    button.textContent = kind === "silence" ? word + " " + (length / 10).toFixed(1) + "초" : word;
    button.setAttribute("aria-label", button.textContent + " 구간 빼기");
    button.addEventListener("click", () => {
      history.push(new Set(removed));
      if (removed.has(index)) removed.delete(index);
      else removed.add(index);
      render();
    });
    words.append(button);
    const bar = document.createElement("i");
    bar.style.width = (100 * length / total) + "%";
    bar.dataset.kind = kind;
    track.append(bar);
    return {button, bar, kind, length, index};
  });
  function render() {
    let length = 0;
    for (const segment of segments) {
      const cut = removed.has(segment.index);
      segment.button.setAttribute("aria-pressed", String(cut));
      segment.bar.hidden = cut;
      if (!cut) length += segment.length;
    }
    duration.textContent = (length / 10).toFixed(1) + "초";
    undo.disabled = history.length === 0;
    for (const action of groups) action.disabled = segments.every(s => s.kind !== action.dataset.cut || removed.has(s.index));
  }
  for (const group of groups) {
    group.addEventListener("click", () => {
      history.push(new Set(removed));
      for (const segment of segments) if (segment.kind === group.dataset.cut) removed.add(segment.index);
      render();
    });
  }
  undo.addEventListener("click", () => {
    if (!history.length) return;
    removed = history.pop();
    render();
  });
  render();
  play.hidden = false;
})();
