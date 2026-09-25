// 오른쪽 클릭 메뉴 (맥 NSMenu처럼): showMenu(x, y, [{ label, action, disabled, checked, danger } | { sep: true } | { label, items: [...] }])
let open = null;

export function closeMenu() {
  open?.remove();
  open = null;
}

export function showMenu(x, y, items, parent = null) {
  if (!parent) closeMenu();
  const m = document.createElement("div");
  m.className = "ctxmenu";
  for (const it of items) {
    if (!it) continue;
    if (it.sep) {
      m.appendChild(Object.assign(document.createElement("div"), { className: "sep" }));
      continue;
    }
    const row = document.createElement("div");
    row.className = "it" + (it.disabled ? " off" : "") + (it.danger ? " danger" : "");
    row.innerHTML = `<span class="ck">${it.checked ? "✓" : ""}</span><span class="lb"></span><span class="kb"></span>${it.items ? '<span class="ar">▸</span>' : ""}`;
    row.querySelector(".lb").textContent = it.label;
    row.querySelector(".kb").textContent = it.key || "";
    if (it.items) {
      row.onmouseenter = () => {
        m.querySelector(".ctxmenu")?.remove();
        const r = row.getBoundingClientRect();
        const sub = showMenu(r.right - 4, r.top - 4, it.items, m);
        m.appendChild(sub);
      };
    } else {
      row.onmouseenter = () => m.querySelector(".ctxmenu")?.remove();
      if (!it.disabled) row.onclick = (e) => { e.stopPropagation(); closeMenu(); it.action?.(); };
    }
    m.appendChild(row);
  }
  if (parent) {
    m.style.left = x + "px";
    m.style.top = y + "px";
    requestAnimationFrame(() => fit(m));
    return m;
  }
  document.body.appendChild(m);
  m.style.left = x + "px";
  m.style.top = y + "px";
  fit(m);
  open = m;
  return m;
}

// 화면 밖으로 나가지 않게
function fit(m) {
  const r = m.getBoundingClientRect();
  if (r.right > innerWidth) m.style.left = Math.max(4, parseFloat(m.style.left) - (r.right - innerWidth) - 4) + "px";
  if (r.bottom > innerHeight) m.style.top = Math.max(4, parseFloat(m.style.top) - (r.bottom - innerHeight) - 4) + "px";
}

window.addEventListener("mousedown", (e) => { if (open && !open.contains(e.target)) closeMenu(); }, true);
window.addEventListener("keydown", (e) => { if (e.key === "Escape") closeMenu(); }, true);
window.addEventListener("blur", closeMenu);
