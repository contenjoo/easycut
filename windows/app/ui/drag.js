// 마우스로 끌어 옮기기 (윈도우 Tauri에서는 파일 끌어다 놓기를 켜 두면 HTML5 끌기가 동작하지 않아 직접 구현)
// startDrag(e, { label, onMove(x, y), onDrop(x, y), onCancel() }) — 4px 이상 움직여야 끌기로 본다
export function startDrag(e, o) {
  if (e.button !== 0) return;
  const sx = e.clientX, sy = e.clientY;
  let ghost = null;
  const move = (ev) => {
    if (!ghost) {
      if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 4) return;
      ghost = document.createElement("div");
      ghost.className = "drag-ghost";
      ghost.textContent = o.label || "";
      document.body.appendChild(ghost);
      document.body.classList.add("dragging");
    }
    ghost.style.left = ev.clientX + 12 + "px";
    ghost.style.top = ev.clientY + 12 + "px";
    o.onMove?.(ev.clientX, ev.clientY);
  };
  const up = (ev) => {
    window.removeEventListener("mousemove", move, true);
    window.removeEventListener("mouseup", up, true);
    window.removeEventListener("keydown", esc, true);
    document.body.classList.remove("dragging");
    if (!ghost) return;
    ghost.remove();
    o.onDrop?.(ev.clientX, ev.clientY);
  };
  const esc = (ev) => {
    if (ev.key !== "Escape") return;
    window.removeEventListener("mousemove", move, true);
    window.removeEventListener("mouseup", up, true);
    window.removeEventListener("keydown", esc, true);
    document.body.classList.remove("dragging");
    ghost?.remove();
    o.onCancel?.();
  };
  window.addEventListener("mousemove", move, true);
  window.addEventListener("mouseup", up, true);
  window.addEventListener("keydown", esc, true);
}
