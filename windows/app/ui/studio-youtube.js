// Ingest credentials and Google tokens stay in the native process.
export function mountYouTube(invoke, refresh) {
  const $ = id => document.getElementById(id);
  let account = null, broadcasts = [], busy = false, active = null, pendingEnd = null;
  const setNotice = s => { $("notice").textContent = s; };
  const selected = () => broadcasts.find(item => item.id === $("broadcasts").value);
  const privacyName = value => L(({private:"비공개",unlisted:"일부 공개",public:"공개"})[value] || value);
  function drawOptions(id) {
    const list = $("broadcasts");
    list.replaceChildren();
    for (const item of broadcasts) {
      const when = item.scheduledAt ? new Date(item.scheduledAt).toLocaleString(document.documentElement.lang) : "";
      list.add(new Option([item.title,privacyName(item.privacy),when].filter(Boolean).join(" · "),item.id));
    }
    if (!broadcasts.length) list.add(new Option(L("예약된 방송이 없습니다"),""));
    if (broadcasts.some(b => b.id === id)) list.value = id;
  }
  async function load(id) {
    broadcasts = await invoke("youtube_upcoming");
    drawOptions(id);
  }
  function validateNew(scheduled) {
    const title = $("broadcast-title").value.trim();
    if (!title) throw Error(L("방송 제목을 입력하세요."));
    let scheduledAt = null;
    if (scheduled) {
      const date = new Date($("schedule-time").value);
      if (!Number.isFinite(date.getTime()) || date.getTime() <= Date.now()) throw Error(L("현재보다 늦은 예약 일시를 선택하세요."));
      scheduledAt = date.toISOString();
    }
    return {title,scheduledAt,privacy:$("privacy").value,madeForKids:$("kids").checked};
  }
  function remember(item) {
    broadcasts = [item,...broadcasts.filter(b => b.id !== item.id)];
    $("broadcast-mode").value = "existing"; drawOptions(item.id);
  }
  async function syncAccount() {
    const previous = account;
    account = await invoke("youtube_account_status");
    if (!account.connected || previous?.channelTitle !== account.channelTitle) {
      broadcasts = []; drawOptions(); $("broadcast-mode").value = "now";
    }
  }
  async function task(fn) {
    if (busy) return;
    busy = true; setNotice(""); refresh();
    try { await fn(); }
    catch (error) {
      setNotice(L(String(error.message || error)));
      await syncAccount().catch(() => {});
    }
    finally { busy = false; refresh(); }
  }
  $("connect").onclick = () => task(async () => { account = await invoke("youtube_connect"); });
  $("disconnect").onclick = () => task(async () => {
    await invoke("youtube_disconnect"); await syncAccount();
  });
  $("broadcast-mode").onchange = () => {
    if ($("broadcast-mode").value === "existing") task(() => load());
    refresh();
  };
  $("reload").onclick = () => task(() => load($("broadcasts").value));
  $("schedule").onclick = () => task(async () => {
    const item = await invoke("youtube_schedule",validateNew(true));
    remember(item); setNotice(L("예약했습니다. {}",item.title));
  });
  return {
    get busy() { return busy; },
    get active() { return active; },
    get pendingEnd() { return pendingEnd; },
    selected,
    async inspect() {
      await task(syncAccount);
    },
    render() {
      const connected = account?.connected === true;
      $("channel-state").textContent = busy ? L("YouTube에 연결 중…")
        : connected ? (account.channelTitle || L("YouTube 계정 연결됨"))
        : account && !account.configured ? L("이 설치본에는 Google 로그인이 구성되지 않았습니다.")
        : L("YouTube 채널을 연결하세요.");
      $("connect").hidden = connected;
      $("connect").disabled = busy || account?.configured === false;
      $("disconnect").hidden = !connected;
      $("disconnect").disabled = busy;
      $("broadcast-fields").hidden = !connected;
      const mode = $("broadcast-mode").value;
      $("new-broadcast").hidden = mode === "existing";
      $("schedule-fields").hidden = mode !== "schedule";
      $("existing-fields").hidden = mode !== "existing";
      for (const el of $("broadcast-fields").querySelectorAll("input,button,select")) el.disabled = busy;
    },
    validate() {
      if (!account?.connected) throw Error(L("먼저 Google 계정을 연결하세요."));
      switch ($("broadcast-mode").value) {
        case "schedule": throw Error(L("방송을 먼저 예약하세요."));
        case "existing": if (!selected()) throw Error(L("송출할 예약 방송을 선택하세요.")); break;
        default: validateNew(false);
      }
    },
    async start() {
      let item = selected();
      if ($("broadcast-mode").value === "now") {
        item = await invoke("youtube_schedule",validateNew(false));
        remember(item); // Retain the created event if encoder start fails and the user retries.
      }
      await invoke("youtube_start",{id:item.id,privacy:item.privacy});
      active = item.id; pendingEnd = item.id;
    },
    async status(id) { return invoke("youtube_broadcast_status",{id}); },
    async finish() {
      if (!pendingEnd) return;
      const id = pendingEnd;
      active = null;
      await invoke("youtube_complete",{id});
      if (pendingEnd === id) pendingEnd = null;
      broadcasts = broadcasts.filter(item => item.id !== id); drawOptions();
    },
  };
}
