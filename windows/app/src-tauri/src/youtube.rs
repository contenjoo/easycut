//! Manage only EasyCut broadcasts created for this signed-in YouTube channel.
#[path = "youtube_oauth.rs"]
mod oauth;

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::{LazyLock, Mutex},
    time::Duration,
};
use tauri::{AppHandle, Manager, Url};

type Result<T> = std::result::Result<T, String>;
const SCOPE: &str = "https://www.googleapis.com/auth/youtube.force-ssl";
const INVALID: &str = "YouTube 응답을 확인할 수 없습니다. 방송 목록을 새로 고치세요.";
const MISSING: &str = "이 채널에서 EasyCut으로 만든 방송을 찾을 수 없습니다.";
const BINDING: &str = "예약의 전용 스트림 연결이 바뀌었습니다. YouTube Studio에서 확인하세요.";
const STORE: &str = "이 PC에 저장된 EasyCut 방송 목록을 읽거나 저장할 수 없습니다.";
const BROADCAST: &str = "id,snippet,status,contentDetails";
const STREAM: &str = "id,snippet,cdn,contentDetails";

fn http() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(25))
        .redirects(0)
        .build()
}
fn api_error(status: u16, body: &Value) -> String {
    let reasons = body
        .pointer("/error/errors")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| v["reason"].as_str())
        .collect::<Vec<_>>();
    if reasons
        .iter()
        .any(|s| matches!(*s, "liveStreamingNotEnabled" | "livePermissionBlocked"))
    {
        return "YouTube Studio에서 채널의 실시간 스트리밍 사용 가능 여부를 확인하세요.".into();
    }
    if reasons.contains(&"invalidScheduledStartTime") {
        return "YouTube에서 예약 시간을 허용하지 않았습니다. 미래의 시작 시간을 선택하세요."
            .into();
    }
    if reasons.contains(&"quotaExceeded") || status == 429 {
        return "YouTube 요청 한도에 도달했습니다. 잠시 후 다시 시도하세요.".into();
    }
    if reasons.contains(&"accessNotConfigured") {
        return "EasyCut의 Google Cloud 프로젝트에서 YouTube Data API v3를 활성화해야 합니다."
            .into();
    }
    match status {
        401 | 403 => "YouTube 채널 접근 권한을 확인하고 Google 계정을 다시 연결하세요.".into(),
        404 => MISSING.into(),
        _ => format!("YouTube에서 요청을 처리하지 못했습니다 (HTTP {status})."),
    }
}
// Some(Null) is an empty POST (bind and transition). GET never carries a request body.
fn api(token: &str, resource: &str, query: &[(&str, &str)], body: Option<Value>) -> Result<Value> {
    let agency = http();
    let method = if body.is_some() { "POST" } else { "GET" };
    let mut req = agency
        .request(
            method,
            &format!("https://www.googleapis.com/youtube/v3/{resource}"),
        )
        .set("Authorization", &format!("Bearer {token}"));
    for &(k, v) in query {
        req = req.query(k, v);
    }
    let response = match body {
        None | Some(Value::Null) => req.call(),
        Some(data) => req.send_json(data),
    };
    match response {
        Ok(r) if (200..300).contains(&r.status()) => r.into_json().map_err(|_| INVALID.into()),
        Err(ureq::Error::Status(code, response)) => {
            let details = response.into_json().unwrap_or(Value::Null);
            Err(api_error(code, &details))
        }
        Err(_) if resource == "liveBroadcasts" && method == "POST" => {
            Err("예약 결과가 불확실합니다. 다시 예약하기 전에 YouTube Studio를 확인하세요.".into())
        }
        _ => Err("YouTube 서버에 연결하지 못했습니다. 네트워크 상태를 확인하세요.".into()),
    }
}
fn text<'a>(v: &'a Value, pointer: &str) -> Result<&'a str> {
    v.pointer(pointer)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| INVALID.into())
}

#[derive(Default)]
struct Session {
    access: Option<oauth::Access>,
}
impl Session {
    fn access(&mut self) -> Result<&oauth::Access> {
        if !self.access.as_ref().is_some_and(oauth::Access::valid) {
            self.access = None;
            self.access = Some(oauth::Access::renew(client()?)?);
        }
        Ok(self.access.as_ref().unwrap())
    }
}
static SESSION: LazyLock<Mutex<Session>> = LazyLock::new(|| Mutex::new(Session::default()));
// Serialize account changes and irreversible remote operations on a blocking worker. Double-clicks
// on an in-flight operation fail immediately, rather than silently creating a second reservation.
async fn work<T, F>(f: F) -> Result<T>
where
    T: Send + 'static,
    F: FnOnce(&mut Session) -> Result<T> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(move || {
        let mut state = SESSION
            .try_lock()
            .map_err(|_| "진행 중인 YouTube 작업을 마친 뒤 다시 시도하세요.".to_string())?;
        f(&mut state)
    })
    .await
    .map_err(|_| "YouTube 작업을 완료하지 못했습니다.".to_string())?
}
fn client() -> Result<&'static str> {
    oauth::client_id().ok_or_else(|| "이 EasyCut 빌드에 Google 로그인 설정이 없습니다.".into())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountStatus {
    configured: bool,
    connected: bool,
    channel_title: Option<String>,
}
fn status() -> Result<AccountStatus> {
    let client = oauth::client_id();
    let grant = match client {
        Some(id) => oauth::Grant::load(id)?,
        None => None,
    };
    Ok(AccountStatus {
        configured: client.is_some(),
        connected: grant.is_some(),
        channel_title: grant.map(|v| v.title),
    })
}
#[tauri::command]
pub async fn youtube_account_status() -> Result<AccountStatus> {
    work(|_| status()).await
}
#[tauri::command]
pub async fn youtube_connect(app: AppHandle) -> Result<AccountStatus> {
    work(move |s| {
        let client = client()?;
        if oauth::Grant::load(client)?.is_none() {
            s.access = Some(oauth::connect(&app, client)?);
        }
        status()
    })
    .await
}
#[tauri::command]
pub async fn youtube_disconnect() -> Result<()> {
    work(|s| {
        s.access = None;
        oauth::disconnect(client()?)
    })
    .await
}

#[derive(Deserialize, Serialize, Default)]
#[serde(transparent)]
struct Registry(BTreeMap<String, BTreeMap<String, Option<String>>>);
impl Registry {
    fn path(app: &AppHandle) -> Result<PathBuf> {
        Ok(app
            .path()
            .app_data_dir()
            .map_err(|_| STORE)?
            .join("youtube-broadcasts.json"))
    }
    fn read(path: &Path) -> Result<Self> {
        match fs::File::open(path) {
            Ok(file) => serde_json::from_reader(file).map_err(|_| STORE.into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(_) => Err(STORE.into()),
        }
    }
    fn write(&self, path: &Path) -> Result<()> {
        let dir = path.parent().ok_or(STORE)?;
        fs::create_dir_all(dir).map_err(|_| STORE)?;
        let mut tmp = tempfile::NamedTempFile::new_in(dir).map_err(|_| STORE)?;
        serde_json::to_writer(tmp.as_file_mut(), self).map_err(|_| STORE)?;
        tmp.as_file().sync_all().map_err(|_| STORE)?;
        tmp.persist(path).map_err(|_| STORE)?;
        Ok(())
    }
    fn pending(&self, channel: &str, id: &str) -> Result<Option<String>> {
        self.0
            .get(channel)
            .and_then(|entries| entries.get(id))
            .cloned()
            .ok_or_else(|| MISSING.into())
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Event {
    id: String,
    title: String,
    scheduled_at: String,
    privacy: String,
}
fn event(row: &Value) -> Result<Event> {
    Ok(Event {
        id: text(row, "/id")?.into(),
        title: text(row, "/snippet/title")?.into(),
        scheduled_at: text(row, "/snippet/scheduledStartTime")?.into(),
        privacy: text(row, "/status/privacyStatus")?.into(),
    })
}
fn privacy_allowed(privacy: &str) -> bool {
    matches!(privacy, "private" | "unlisted" | "public")
}
fn launchable(row: &Value, privacy: &str) -> Result<()> {
    if !matches!(text(row, "/status/lifeCycleStatus")?, "ready" | "created") {
        return Err("이 방송은 이미 시작되었거나 종료되었습니다.".into());
    }
    if !privacy_allowed(privacy) || text(row, "/status/privacyStatus")? != privacy {
        return Err("방송의 공개 범위가 바뀌었습니다. 목록을 새로 고치세요.".into());
    }
    if row.pointer("/contentDetails/enableAutoStart") != Some(&Value::Bool(true))
        || row.pointer("/contentDetails/enableAutoStop") != Some(&Value::Bool(true))
    {
        return Err("YouTube Studio에서 이 방송의 자동 시작과 자동 종료를 켜세요.".into());
    }
    Ok(())
}
fn broadcasts(ctx: &oauth::Access, ids: &[&str]) -> Result<Vec<Value>> {
    let ids_csv = ids.join(",");
    let mut page = String::new();
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    loop {
        let mut query = vec![("part", BROADCAST), ("id", &ids_csv), ("maxResults", "50")];
        if !page.is_empty() {
            query.push(("pageToken", &page));
        }
        let res = api(&ctx.token, "liveBroadcasts", &query, None)?;
        for row in res["items"].as_array().ok_or(INVALID)? {
            if row["snippet"]["channelId"] == ctx.channel
                && row["id"].as_str().is_some_and(|id| ids.contains(&id))
            {
                result.push(row.clone());
            }
        }
        match res["nextPageToken"].as_str().filter(|s| !s.is_empty()) {
            Some(next) if seen.insert(next.to_string()) => page = next.to_string(),
            Some(_) => return Err(INVALID.into()),
            None => return Ok(result),
        }
    }
}
fn owned(ctx: &oauth::Access, registry: &Registry, id: &str) -> Result<Value> {
    registry.pending(&ctx.channel, id)?;
    broadcasts(ctx, &[id])?.pop().ok_or_else(|| MISSING.into())
}
fn schedule_body(
    title: &str,
    scheduled_at: Option<&str>,
    privacy: &str,
    kids: bool,
) -> Result<Value> {
    let title = title.trim();
    if title.is_empty() || title.encode_utf16().count() > 100 || title.contains(['<', '>']) {
        return Err("방송 제목은 꺾쇠 기호 없이 1~100자로 입력하세요.".into());
    }
    if !privacy_allowed(privacy) {
        return Err("방송 공개 범위를 선택하세요.".into());
    }
    let now = Utc::now();
    let when = if let Some(v) = scheduled_at {
        let date = DateTime::parse_from_rfc3339(v)
            .map_err(|_| "예약 날짜와 시간을 확인하세요.")?
            .with_timezone(&Utc);
        if date <= now {
            return Err("미래의 예약 시간을 선택하세요.".into());
        }
        date
    } else {
        now + chrono::Duration::seconds(30)
    };
    Ok(
        json!({"snippet":{"title":title,"scheduledStartTime":when.to_rfc3339_opts(SecondsFormat::Secs,true)},
        "status":{"privacyStatus":privacy,"selfDeclaredMadeForKids":kids},
        "contentDetails":{"enableAutoStart":true,"enableAutoStop":true}}),
    )
}
#[tauri::command]
pub async fn youtube_schedule(
    app: AppHandle,
    title: String,
    scheduled_at: Option<String>,
    privacy: String,
    made_for_kids: bool,
) -> Result<Event> {
    let body = schedule_body(&title, scheduled_at.as_deref(), &privacy, made_for_kids)?;
    work(move |session| {
        let ctx = session.access()?;
        let path = Registry::path(&app)?;
        let mut registry = Registry::read(&path)?;
        // Verify the directory before requesting a non-idempotent remote insert.
        registry.write(&path)?;
        let inserted = api(&ctx.token, "liveBroadcasts", &[("part", BROADCAST)], Some(body))?;
        let id = text(&inserted, "/id")?.to_owned();
        registry.0.entry(ctx.channel.clone()).or_default().insert(id.clone(), None);
        if registry.write(&path).is_err() {
            return Err("YouTube에 예약했습니다. 이 PC에 예약을 저장할 수 없어 YouTube Studio에서 확인해야 합니다.".into());
        }
        let row = if inserted["snippet"]["channelId"] == ctx.channel && event(&inserted).is_ok() {
            inserted
        } else {
            owned(ctx, &registry, &id)?
        };
        let event = event(&row)?;
        if event.privacy != privacy {
            return Err("예약되었지만 YouTube가 공개 범위를 변경했습니다. 목록에서 확인하세요.".into());
        }
        Ok(event)
    })
    .await
}
#[tauri::command]
pub async fn youtube_upcoming(app: AppHandle) -> Result<Vec<Event>> {
    work(move |s| {
        let ctx = s.access()?;
        let reg = Registry::read(&Registry::path(&app)?)?;
        let ids: Vec<_> = reg
            .0
            .get(&ctx.channel)
            .into_iter()
            .flat_map(|v| v.keys())
            .map(String::as_str)
            .collect();
        let mut events = Vec::new();
        for batch in ids.chunks(50) {
            for row in broadcasts(ctx, batch)? {
                if matches!(
                    row["status"]["lifeCycleStatus"].as_str(),
                    Some("created" | "ready")
                ) {
                    events.push(event(&row)?);
                }
            }
        }
        events.sort_by(|a, b| (&a.scheduled_at, &a.id).cmp(&(&b.scheduled_at, &b.id)));
        Ok(events)
    })
    .await
}
fn secure_ingest(stream: &Value, channel: &str, marker: &str) -> Result<(String, String)> {
    if stream["snippet"]["channelId"] != channel
        || stream["snippet"]["description"] != marker
        || stream["contentDetails"]["isReusable"] != Value::Bool(false)
    {
        return Err(BINDING.into());
    }
    let address = text(stream, "/cdn/ingestionInfo/rtmpsIngestionAddress")?;
    let key = text(stream, "/cdn/ingestionInfo/streamName")?;
    let url = Url::parse(address).map_err(|_| INVALID)?;
    if url.scheme() != "rtmps"
        || !url
            .host_str()
            .is_some_and(|h| h == "rtmps.youtube.com" || h.ends_with(".rtmps.youtube.com"))
        || !matches!(url.port(), None | Some(443))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || key.trim() != key
        || key.chars().any(char::is_control)
    {
        return Err("YouTube의 보안 송출 주소를 확인할 수 없습니다.".into());
    }
    Ok((address.into(), key.into()))
}
#[tauri::command]
pub async fn youtube_start(app: AppHandle, id: String, privacy: String) -> Result<()> {
    work(move |s| {
        let ctx = s.access()?;
        let path = Registry::path(&app)?;
        let mut reg = Registry::read(&path)?;
        let current = owned(ctx, &reg, &id)?;
        launchable(&current, &privacy)?;
        let marker = format!("EasyCut broadcast {id}");
        let stream_id = if let Some(bound) = current
            .pointer("/contentDetails/boundStreamId")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        {
            bound.to_string()
        } else {
            let pending = reg.pending(&ctx.channel, &id)?;
            let existing = if let Some(pending) = pending {
                let page = api(
                    &ctx.token,
                    "liveStreams",
                    &[("id", &pending), ("part", "id")],
                    None,
                )?;
                page["items"]
                    .as_array()
                    .ok_or(INVALID)?
                    .iter()
                    .any(|v| v["id"] == pending)
                    .then_some(pending)
            } else {
                None
            };
            let stream_id = if let Some(stream_id) = existing {
                stream_id
            } else {
                let stream = api(
                    &ctx.token,
                    "liveStreams",
                    &[("part", STREAM)],
                    Some(json!({
                    "snippet":{"title":text(&current,"/snippet/title")?,"description":marker},
                    "cdn":{"ingestionType":"rtmp","resolution":"variable","frameRate":"variable"},
                    "contentDetails":{"isReusable":false}})),
                )?;
                let stream_id = text(&stream, "/id")?.to_string();
                reg.0
                    .get_mut(&ctx.channel)
                    .ok_or(MISSING)?
                    .insert(id.clone(), Some(stream_id.clone()));
                reg.write(&path)?;
                stream_id
            };
            let latest = owned(ctx, &reg, &id)?;
            launchable(&latest, &privacy)?;
            if let Some(bound) = latest
                .pointer("/contentDetails/boundStreamId")
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
            {
                if bound != stream_id {
                    return Err(BINDING.into());
                }
            } else {
                let bound = api(
                    &ctx.token,
                    "liveBroadcasts/bind",
                    &[("id", &id), ("streamId", &stream_id), ("part", BROADCAST)],
                    Some(Value::Null),
                )?;
                if bound["id"] != id || bound["contentDetails"]["boundStreamId"] != stream_id {
                    return Err(BINDING.into());
                }
            }
            stream_id
        };
        let streams = api(
            &ctx.token,
            "liveStreams",
            &[("id", &stream_id), ("part", STREAM)],
            None,
        )?;
        let stream = streams["items"]
            .as_array()
            .ok_or(INVALID)?
            .iter()
            .find(|v| v["id"] == stream_id)
            .ok_or(BINDING)?;
        let (server, key) = secure_ingest(stream, &ctx.channel, &marker)?;
        let confirmed = owned(ctx, &reg, &id)?;
        launchable(&confirmed, &privacy)?;
        if confirmed["contentDetails"]["boundStreamId"] != stream_id {
            return Err(BINDING.into());
        }
        if app.get_webview_window("studio").is_none() {
            return Err("방송 스튜디오 창이 닫혔습니다.".into());
        }
        crate::studio::studio_live_start(app, server, key)
    })
    .await
}
#[tauri::command]
pub async fn youtube_broadcast_status(app: AppHandle, id: String) -> Result<String> {
    work(move |s| {
        let info = owned(s.access()?, &Registry::read(&Registry::path(&app)?)?, &id)?;
        Ok(text(&info, "/status/lifeCycleStatus")?.to_string())
    })
    .await
}
#[tauri::command]
pub async fn youtube_complete(app: AppHandle, id: String) -> Result<()> {
    work(move |s| {
        let ctx = s.access()?;
        let reg = Registry::read(&Registry::path(&app)?)?;
        let current = owned(ctx, &reg, &id)?;
        match text(&current, "/status/lifeCycleStatus")? {
            "complete" => return Ok(()),
            "live" => {}
            _ => return Err("YouTube가 방송을 라이브로 표시한 뒤에 종료할 수 있습니다.".into()),
        }
        let res = api(
            &ctx.token,
            "liveBroadcasts/transition",
            &[
                ("id", &id),
                ("broadcastStatus", "complete"),
                ("part", "id,status"),
            ],
            Some(Value::Null),
        );
        match res {
            Ok(v) if v["id"] == id && v["status"]["lifeCycleStatus"] == "complete" => Ok(()),
            _ if owned(ctx, &reg, &id)
                .is_ok_and(|v| v["status"]["lifeCycleStatus"] == "complete") =>
            {
                Ok(())
            }
            Err(e) => Err(e),
            _ => Err(INVALID.into()),
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_immediate_and_scheduled_privacy_and_audience() {
        let body = schedule_body(" 방송 ", None, "private", true).unwrap();
        assert_eq!(body["status"]["privacyStatus"], "private");
        assert_eq!(body["status"]["selfDeclaredMadeForKids"], true);
        assert_eq!(body["contentDetails"]["enableAutoStart"], true);
        assert_eq!(body["snippet"]["title"], "방송");
        assert!(
            DateTime::parse_from_rfc3339(text(&body, "/snippet/scheduledStartTime").unwrap())
                .unwrap()
                > Utc::now()
        );
        assert!(schedule_body("방송", Some("2020-01-01T00:00:00Z"), "private", false).is_err());
        assert!(schedule_body("<방송>", None, "private", false).is_err());
        assert!(schedule_body("방송", None, "other", false).is_err());
    }
    #[test]
    fn private_launch_rejects_changed_visibility_lifecycle_or_autostart() {
        let mut b = json!({"status":{"privacyStatus":"private","lifeCycleStatus":"ready"},
            "contentDetails":{"enableAutoStart":true,"enableAutoStop":true}});
        assert!(launchable(&b, "private").is_ok());
        assert!(launchable(&b, "public").is_err());
        b["contentDetails"]["enableAutoStop"] = false.into();
        assert!(launchable(&b, "private").is_err());
        b["contentDetails"]["enableAutoStop"] = true.into();
        b["status"]["lifeCycleStatus"] = "complete".into();
        assert!(launchable(&b, "private").is_err());
    }
    #[test]
    fn ingest_belongs_to_channel_event_and_tls_host() {
        let mut stream = json!({"snippet":{"channelId":"ch","description":"event"},"contentDetails":{"isReusable":false},
            "cdn":{"ingestionInfo":{"rtmpsIngestionAddress":"rtmps://a.rtmps.youtube.com/live2","streamName":"test-key"}}});
        assert!(secure_ingest(&stream, "ch", "event").is_ok());
        assert!(secure_ingest(&stream, "other", "event").is_err());
        assert!(secure_ingest(&stream, "ch", "other").is_err());
        for address in [
            "rtmp://a.rtmps.youtube.com/live2",
            "rtmps://a.rtmps.youtube.com.other/live2",
            "rtmps://u@a.rtmps.youtube.com/live2",
        ] {
            stream["cdn"]["ingestionInfo"]["rtmpsIngestionAddress"] = address.into();
            assert!(secure_ingest(&stream, "ch", "event").is_err());
        }
    }
    #[test]
    fn recover_pending_stream_only_for_own_channel_after_restart() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("events.json");
        let mut registry = Registry::read(&path).unwrap();
        registry
            .0
            .entry("ch".into())
            .or_default()
            .insert("event".into(), None);
        registry.write(&path).unwrap();
        registry
            .0
            .get_mut("ch")
            .unwrap()
            .insert("event".into(), Some("stream".into()));
        registry.write(&path).unwrap();
        let reopened = Registry::read(&path).unwrap();
        assert_eq!(
            reopened.pending("ch", "event").unwrap(),
            Some("stream".into())
        );
        assert!(reopened.pending("another", "event").is_err());
    }
}
