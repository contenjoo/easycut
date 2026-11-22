const menuButton = document.querySelector(".nav-toggle");
const mobileNav = document.querySelector("#mobile-nav");
function setMenu(open) {
  mobileNav.hidden = !open;
  menuButton.setAttribute("aria-expanded", String(open));
  menuButton.setAttribute("aria-label", open ? "메뉴 닫기" : "메뉴 열기");
}
menuButton.addEventListener("click", () => setMenu(mobileNav.hidden));
mobileNav.addEventListener("click", event => {
  const link = event.target.closest("a");
  if (!link) return;
  setMenu(false);
  const target = document.querySelector(link.hash);
  if (target) { target.tabIndex = -1; target.focus({preventScroll: true}); }
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && !mobileNav.hidden) { setMenu(false); menuButton.focus(); }
});
matchMedia("(min-width:801px)").addEventListener("change", () => setMenu(false));

const demo = document.querySelector("easycut-studio-demo");
document.querySelectorAll("[data-room]").forEach(link => {
  link.addEventListener("click", event => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || typeof demo.showBackground !== "function") return;
    event.preventDefault();
    demo.showBackground(link.dataset.room);
    const monitor = document.querySelector("#studio-monitor");
    monitor.focus({preventScroll:true});
    monitor.scrollIntoView({block:"center"});
  });
});
function openLinkedDetails() {
  if (location.hash === "#create") document.getElementById("create").open = true;
}
window.addEventListener("hashchange", openLinkedDetails);
openLinkedDetails();
