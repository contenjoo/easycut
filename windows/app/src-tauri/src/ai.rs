//! 앱 안 AI 편집 도우미 (맥 AIAssistant.swift + AgentLink.swift).
//! 연결 방식 3가지: Claude 플랜(Claude Code CLI), ChatGPT(Codex CLI), Claude API 키.
//! CLI 방식은 `EasyCut.exe --mcp`(control.rs)로 편집 도구를 쓰고, API 방식은 ai_tools를 직접 호출한다.
use crate::{ai_tools, control, tools, update};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

pub const SYSTEM: &str = "당신은 Windows 영상 편집 앱 EasyCut 안에서 일하는 편집 도우미입니다. 사용자의 한국어 요청을 도구 호출로 실제 편집에 반영합니다.

작업 방식:
- 편집하기 전에 get_project_state로 현재 구조를 확인합니다. 특정 말을 찾거나 지울 때는 대본 전체를 읽지 말고 search_transcript로 찾습니다. 대본 전체 흐름이 필요할 때만 get_transcript를 범위를 나눠 읽습니다.
- 도구 호출 횟수를 최소로 하고, 여러 구간 편집은 한 번의 호출에 모아서 보냅니다.
- 시간은 모두 타임라인 기준 초입니다. 대본의 [번호]는 삭제할 때마다 바뀌므로, 여러 구간을 지울 때는 delete_words에 한 번에 넣습니다.
- \"무음/공백 없애기\"는 remove_silences, \"음·어 같은 말 빼기\"는 remove_fillers, 특정 말이나 구간을 지우는 요청은 delete_words 또는 delete_time_ranges를 씁니다.
- 대본이 없는데 말 내용 기반 편집이 필요하면 transcribe를 먼저 실행합니다.
- 모든 편집은 사용자가 Ctrl+Z로 되돌릴 수 있습니다. 요청이 분명하면 되묻지 말고 실행하고, 정말 모호할 때만 짧게 확인합니다.
- 할 수 있는 도구가 없으면 추측하지 말고 할 수 없다고 말합니다.
- 끝나면 무엇을 바꿨는지 한두 문장으로 간단히 알려 줍니다. 사용자가 쓴 언어로 답합니다(영어로 물으면 영어로).";

/// 고를 수 있는 Claude 모델 (id "" = 계정 기본값, 플랜 방식에서만)
pub const MODELS: &[(&str, &str, &str)] = &[
    ("claude-fable-5-1", "Claude Fable 5.1", "가장 뛰어남 · 느리고 사용량 많음"),
    ("claude-opus-5-5", "Claude Opus 5.5", "최신 Opus"),
    ("claude-opus-5", "Claude Opus 5", "균형 · 추천"),
    ("claude-sonnet-5", "Claude Sonnet 5", "빠름 · 사용량 적음"),
    ("claude-haiku-4-5", "Claude Haiku 4.5", "가장 빠름 · 간단한 편집"),
];
const DEFAULT_API_MODEL: &str = "claude-opus-5";

fn supports_effort(model: &str) -> bool {
    model != "claude-haiku-4-5"
}
fn uses_fallback(model: &str) -> bool {
    ["claude-opus-5", "claude-opus-5-5", "claude-fable-5-1"].contains(&model)
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// "plan" | "codex" | "api"
    pub backend: String,
    pub model: String,
    /// "" | low | medium | high | xhigh | max
    pub effort: String,
    pub show_thinking: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { backend: "plan".into(), model: String::new(), effort: String::new(), show_thinking: false }
    }
}

fn settings_path() -> PathBuf {
    tools::app_data().join("ai-settings.json")
}

pub fn load_settings() -> Settings {
    std::fs::read_to_string(settings_path()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

// MARK: API 키 보관 (윈도우 자격 증명 관리자 / 맥 키체인)

fn keyring_entry() -> Option<keyring::Entry> {
    keyring::Entry::new("com.contenjoo.easycut.anthropic", "api-key").ok()
}

pub fn load_key() -> Option<String> {
    keyring_entry()?.get_password().ok().filter(|k| !k.is_empty())
}

pub fn save_key(key: &str) -> Result<(), String> {
    let e = keyring_entry().ok_or("자격 증명 저장소를 열 수 없습니다.")?;
    let k = key.trim();
    if k.is_empty() {
        let _ = e.delete_credential();
        return Ok(());
    }
    e.set_password(k).map_err(|e| format!("API 키를 저장하지 못했습니다: {e}"))
}

// MARK: 상태

#[derive(Default)]
struct Chat {
    busy: bool,
    messages: Vec<Value>,
    plan_session: Option<String>,
    codex_thread: Option<String>,
    last_error: String,
    last_assistant: String,
    needs_login: bool,
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(tag = "state", content = "message", rename_all = "camelCase")]
pub enum AgentState {
    Unknown,
    NotInstalled,
    LoggedOut,
    Working(String),
    Ready,
    Failed(String),
}

pub struct Ai {
    pub settings: Mutex<Settings>,
    chat: Mutex<Chat>,
    child: Mutex<Option<Child>>,
    cancel: Arc<AtomicBool>,
    /// 대화를 지우면 늘어난다. 지우기 전 실행이 보낸 늦은 이벤트를 버리기 위해
    generation: AtomicU64,
    claude: Mutex<AgentState>,
    codex: Mutex<AgentState>,
    login_child: Mutex<Option<Child>>,
    login_url: Mutex<Option<String>>,
}

impl Default for Ai {
    fn default() -> Self {
        Ai {
            settings: Mutex::new(load_settings()),
            chat: Mutex::default(),
            child: Mutex::default(),
            cancel: Arc::default(),
            generation: AtomicU64::new(0),
            claude: Mutex::new(AgentState::Unknown),
            codex: Mutex::new(AgentState::Unknown),
            login_child: Mutex::default(),
            login_url: Mutex::default(),
        }
    }
}

fn ai(app: &AppHandle) -> &Ai {
    app.state::<Ai>().inner()
}

/// 화면으로 보내는 대화 이벤트
fn item(app: &AppHandle, role: &str, text: &str) {
    let _ = app.emit("ai", json!({ "type": "item", "role": role, "text": text }));
}
fn status(app: &AppHandle, text: &str) {
    let _ = app.emit("ai", json!({ "type": "status", "text": text }));
}
fn set_busy(app: &AppHandle, busy: bool) {
    ai(app).chat.lock().unwrap().busy = busy;
    let _ = app.emit("ai", json!({ "type": "busy", "value": busy }));
    if !busy {
        status(app, "");
    }
}
fn emit_agents(app: &AppHandle) {
    let _ = app.emit("ai", json!({ "type": "agents", "agents": agents_json(app) }));
}

pub fn agents_json(app: &AppHandle) -> Value {
    let a = ai(app);
    json!({
        "claude": *a.claude.lock().unwrap(),
        "codex": *a.codex.lock().unwrap(),
        "loginUrl": *a.login_url.lock().unwrap(),
        "hasKey": load_key().is_some(),
        "claudeInstalled": claude_binary().is_some(),
        "codexInstalled": codex_binary().is_some(),
        "needsLogin": a.chat.lock().unwrap().needs_login,
        "busy": a.chat.lock().unwrap().busy,
    })
}

pub fn settings_json(app: &AppHandle) -> Value {
    let s = ai(app).settings.lock().unwrap().clone();
    json!({ "settings": s, "models": MODELS.iter().map(|(id, name, note)| json!({ "id": id, "name": name, "note": note })).collect::<Vec<_>>() })
}

pub fn set_settings(app: &AppHandle, s: Settings) {
    let a = ai(app);
    let old = a.settings.lock().unwrap().clone();
    let _ = std::fs::write(settings_path(), serde_json::to_string_pretty(&s).unwrap_or_default());
    let reset_needed = old.backend != s.backend || old.model != s.model;
    *a.settings.lock().unwrap() = s;
    if reset_needed {
        reset(app);
    }
}

pub fn reset(app: &AppHandle) {
    cancel(app);
    let a = ai(app);
    a.generation.fetch_add(1, Ordering::SeqCst);
    *a.chat.lock().unwrap() = Chat::default();
    let _ = app.emit("ai", json!({ "type": "reset" }));
}

pub fn cancel(app: &AppHandle) {
    let a = ai(app);
    a.cancel.store(true, Ordering::SeqCst);
    if let Some(mut c) = a.child.lock().unwrap().take() {
        let _ = c.kill();
    }
    set_busy(app, false);
}

// MARK: 보내기

pub fn send(app: &AppHandle, text: &str) {
    let t = text.trim().to_string();
    let a = ai(app);
    if t.is_empty() || a.chat.lock().unwrap().busy {
        return;
    }
    let backend = a.settings.lock().unwrap().backend.clone();
    a.cancel.store(false, Ordering::SeqCst);
    let app = app.clone();
    std::thread::spawn(move || match backend.as_str() {
        "codex" => send_codex(&app, &t),
        "api" => send_api(&app, &t),
        _ => send_plan(&app, &t),
    });
}

fn work_dir() -> PathBuf {
    let d = tools::app_data().join("ai-work");
    let _ = std::fs::create_dir_all(&d);
    d
}

fn send_plan(app: &AppHandle, text: &str) {
    let Some(bin) = claude_binary() else {
        item(app, "error", "Claude Code가 설치되어 있지 않습니다. [Claude로 로그인]을 눌러 주세요.");
        return;
    };
    item(app, "user", text);
    set_busy(app, true);
    ai(app).chat.lock().unwrap().needs_login = false;
    status(app, "Claude에 연결 중…");
    let work = work_dir();
    let mcp = json!({ "mcpServers": { "easycut": { "command": control::app_binary(), "args": ["--mcp"] } } });
    let mcp_file = work.join("mcp.json");
    let sys_file = work.join("system.txt");
    let _ = std::fs::write(&mcp_file, mcp.to_string());
    let _ = std::fs::write(&sys_file, format!("{SYSTEM}\n편집 도구 이름은 mcp__easycut__ 로 시작합니다. 이 앱 편집 외의 작업(파일 수정, 명령 실행)은 하지 않습니다."));
    let s = ai(app).settings.lock().unwrap().clone();
    let mut args: Vec<String> = vec![
        "-p".into(), "--output-format".into(), "stream-json".into(), "--verbose".into(),
        "--tools".into(), "".into(),
        // 사용자의 개인 Claude Code 설정(플러그인·훅)은 앱 AI에 섞지 않는다
        "--setting-sources".into(), "project".into(),
        "--strict-mcp-config".into(), "--mcp-config".into(), mcp_file.to_string_lossy().into(),
        "--allowedTools".into(), "mcp__easycut".into(),
        "--append-system-prompt-file".into(), sys_file.to_string_lossy().into(),
    ];
    if !s.model.is_empty() {
        args.extend(["--model".into(), s.model.clone()]);
    }
    if !s.effort.is_empty() && supports_effort(&s.model) {
        args.extend(["--effort".into(), s.effort.clone()]);
    }
    if let Some(sid) = ai(app).chat.lock().unwrap().plan_session.clone() {
        args.extend(["--resume".into(), sid]);
    }
    ai(app).chat.lock().unwrap().last_assistant.clear();
    run_cli(app, &bin, &args, &work, text, "Claude Code", handle_plan_event);
}

fn send_codex(app: &AppHandle, text: &str) {
    let Some(bin) = codex_binary() else {
        item(app, "error", "Codex가 설치되어 있지 않습니다. [ChatGPT로 로그인]을 눌러 주세요.");
        return;
    };
    item(app, "user", text);
    set_busy(app, true);
    {
        let mut c = ai(app).chat.lock().unwrap();
        c.needs_login = false;
        c.last_error.clear();
    }
    status(app, "ChatGPT에 연결 중…");
    let s = ai(app).settings.lock().unwrap().clone();
    // TOML 리터럴 문자열(작은따옴표)이라 윈도우 경로의 역슬래시를 그대로 쓸 수 있다
    let mut cfg = vec![
        format!("mcp_servers.easycut.command='{}'", control::app_binary()),
        "mcp_servers.easycut.args=[\"--mcp\"]".to_string(),
        "mcp_servers.easycut.default_tools_approval_mode=\"approve\"".to_string(),
        "sandbox_mode=\"read-only\"".to_string(),
    ];
    // 명령 실행·브라우저 등 편집과 상관없는 기본 도구는 끈다
    for f in ["shell_tool", "unified_exec", "apps", "plugins", "browser_use", "in_app_browser", "computer_use", "image_generation"] {
        cfg.push(format!("features.{f}=false"));
    }
    if !s.effort.is_empty() {
        cfg.push(format!("model_reasoning_effort=\"{}\"", if s.effort == "max" { "xhigh" } else { &s.effort }));
    }
    let thread = ai(app).chat.lock().unwrap().codex_thread.clone();
    let mut args: Vec<String> = vec!["exec".into()];
    if thread.is_some() {
        args.push("resume".into());
    }
    args.extend(["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"].map(String::from));
    for c in cfg {
        args.extend(["-c".into(), c]);
    }
    let prompt = match &thread {
        Some(tid) => {
            args.push(tid.clone());
            text.to_string()
        }
        None => format!("{SYSTEM}\n편집 도구는 easycut MCP 서버의 도구입니다. 이 앱 편집 외의 작업(파일 수정, 명령 실행)은 하지 않습니다.\n\n사용자 요청:\n{text}"),
    };
    args.push("-".into());
    run_cli(app, &bin, &args, &work_dir(), &prompt, "Codex", handle_codex_event);
}

/// CLI를 띄워 한 줄씩 나오는 JSON 이벤트를 넘긴다. 프롬프트는 stdin으로
fn run_cli(app: &AppHandle, bin: &Path, args: &[String], work: &Path, prompt: &str, name: &str, on_event: fn(&AppHandle, &Value)) {
    let gen = ai(app).generation.load(Ordering::SeqCst);
    let mut child = match agent_command(bin).args(args).current_dir(work).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(e) => {
            item(app, "error", &format!("{name} 실행 실패: {e}"));
            set_busy(app, false);
            return;
        }
    };
    if let Some(mut inp) = child.stdin.take() {
        let _ = inp.write_all(prompt.as_bytes());
    }
    let out = child.stdout.take().unwrap();
    let mut err = child.stderr.take().unwrap();
    *ai(app).child.lock().unwrap() = Some(child);
    let err_buf = Arc::new(Mutex::new(String::new()));
    let eb = err_buf.clone();
    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = err.read_to_string(&mut s);
        *eb.lock().unwrap() = s;
    });
    let mut log = std::fs::File::create(work.join("last-run.log")).ok();
    for line in BufReader::new(out).lines().map_while(Result::ok) {
        if let Some(l) = log.as_mut() {
            let _ = writeln!(l, "{line}");
        }
        if ai(app).generation.load(Ordering::SeqCst) != gen {
            break;
        }
        if let Ok(v) = serde_json::from_str::<Value>(&line) {
            on_event(app, &v);
        }
    }
    let _ = err_thread.join();
    let code = ai(app).child.lock().unwrap().take().and_then(|mut c| c.wait().ok()).and_then(|s| s.code());
    if ai(app).generation.load(Ordering::SeqCst) != gen || ai(app).cancel.load(Ordering::SeqCst) {
        return;
    }
    if code.is_some_and(|c| c != 0) && ai(app).chat.lock().unwrap().busy {
        let e = err_buf.lock().unwrap().clone();
        let lines: Vec<&str> = e.lines().filter(|l| !l.trim().is_empty() && !is_timestamped(l)).collect();
        let msg = lines[lines.len().saturating_sub(4)..].join("\n");
        if !msg.trim().is_empty() {
            report(app, msg.trim());
        }
    }
    set_busy(app, false);
}

fn is_timestamped(l: &str) -> bool {
    let b = l.as_bytes();
    b.len() > 11 && b[..4].iter().all(u8::is_ascii_digit) && b[4] == b'-' && b[10] == b'T'
}

fn handle_plan_event(app: &AppHandle, e: &Value) {
    let show_thinking = ai(app).settings.lock().unwrap().show_thinking;
    match e["type"].as_str() {
        Some("system") => {
            if let Some(sid) = e["session_id"].as_str() {
                ai(app).chat.lock().unwrap().plan_session = Some(sid.into());
            }
            status(app, "생각 중…");
        }
        Some("assistant") => {
            for b in e["message"]["content"].as_array().into_iter().flatten() {
                match b["type"].as_str() {
                    Some("thinking") => {
                        let t = b["thinking"].as_str().unwrap_or("").trim();
                        if show_thinking && !t.is_empty() {
                            item(app, "thinking", t);
                        }
                    }
                    Some("text") => {
                        let t = b["text"].as_str().unwrap_or("").trim();
                        if t.is_empty() {
                            continue;
                        }
                        if is_auth_error(t) {
                            report(app, t);
                            continue;
                        }
                        ai(app).chat.lock().unwrap().last_assistant = t.into();
                        item(app, "assistant", t);
                    }
                    Some("tool_use") => {
                        let name = b["name"].as_str().unwrap_or("").replace("mcp__easycut__", "");
                        status(app, &format!("실행: {}", ai_tools::label(&name)));
                        if !name.starts_with("get_") && !name.starts_with("search_") {
                            item(app, "tool", &ai_tools::label(&name));
                        }
                    }
                    _ => {}
                }
            }
        }
        Some("user") => status(app, "생각 중…"),
        Some("result") => {
            if let Some(sid) = e["session_id"].as_str() {
                ai(app).chat.lock().unwrap().plan_session = Some(sid.into());
            }
            let text = e["result"].as_str().unwrap_or("").trim().to_string();
            let (last, needs_login) = {
                let c = ai(app).chat.lock().unwrap();
                (c.last_assistant.clone(), c.needs_login)
            };
            if e["is_error"].as_bool() == Some(true) {
                let dup_auth = is_auth_error(&text) && needs_login;
                if !dup_auth && text != last {
                    report(app, if text.is_empty() { "Claude 오류" } else { &text });
                }
            } else if !text.is_empty() && text != last {
                item(app, "assistant", &text);
            }
            set_busy(app, false);
        }
        _ => {}
    }
}

fn handle_codex_event(app: &AppHandle, e: &Value) {
    let show_thinking = ai(app).settings.lock().unwrap().show_thinking;
    let it = &e["item"];
    match e["type"].as_str() {
        Some("thread.started") => {
            if let Some(tid) = e["thread_id"].as_str() {
                ai(app).chat.lock().unwrap().codex_thread = Some(tid.into());
            }
            status(app, "생각 중…");
        }
        Some("item.started") if it["type"] == "mcp_tool_call" => {
            let name = it["tool"].as_str().unwrap_or("");
            status(app, &format!("실행: {}", ai_tools::label(name)));
            if !name.starts_with("get_") && !name.starts_with("search_") {
                item(app, "tool", &ai_tools::label(name));
            }
        }
        Some("item.completed") => match it["type"].as_str() {
            Some("agent_message") => {
                let t = it["text"].as_str().unwrap_or("").trim();
                if !t.is_empty() {
                    item(app, "assistant", t);
                }
                status(app, "생각 중…");
            }
            Some("reasoning") => {
                let t = it["text"].as_str().unwrap_or("").trim();
                if show_thinking && !t.is_empty() {
                    item(app, "thinking", t);
                }
            }
            Some("mcp_tool_call") => status(app, "생각 중…"),
            _ => {}
        },
        Some("turn.completed") => set_busy(app, false),
        Some("turn.failed") => {
            let msg = e["error"]["message"].as_str().unwrap_or("Codex 오류").to_string();
            let last = ai(app).chat.lock().unwrap().last_error.clone();
            if msg != last {
                report(app, &msg);
            }
            ai(app).chat.lock().unwrap().last_error = msg;
            set_busy(app, false);
        }
        Some("error") => {
            let msg = e["message"].as_str().unwrap_or("").to_string();
            if msg.to_lowercase().contains("reconnecting") {
                status(app, "다시 연결 중…");
                return;
            }
            let last = ai(app).chat.lock().unwrap().last_error.clone();
            if !msg.is_empty() && msg != last {
                report(app, &msg);
            }
            ai(app).chat.lock().unwrap().last_error = msg;
        }
        _ => {}
    }
}

pub fn is_auth_error(t: &str) -> bool {
    let l = t.to_lowercase();
    ["authenticate", "oauth", "/login", "not logged in", "invalid api key", "401 unauthorized", "codex login"].iter().any(|k| l.contains(k))
}

fn report(app: &AppHandle, t: &str) {
    if is_auth_error(t) {
        let codex = ai(app).settings.lock().unwrap().backend == "codex";
        {
            let mut c = ai(app).chat.lock().unwrap();
            c.needs_login = true;
            c.plan_session = None;
            c.codex_thread = None;
        }
        if codex {
            *ai(app).codex.lock().unwrap() = AgentState::LoggedOut;
            item(app, "error", "ChatGPT 로그인이 필요합니다. [로그인]을 눌러 주세요.");
        } else {
            *ai(app).claude.lock().unwrap() = AgentState::LoggedOut;
            item(app, "error", "Claude 로그인이 필요합니다. [로그인]을 눌러 주세요.");
        }
        emit_agents(app);
    } else {
        item(app, "error", t);
    }
}

// MARK: API 키 방식

fn send_api(app: &AppHandle, text: &str) {
    let Some(key) = load_key() else {
        item(app, "error", "Claude API 키를 먼저 설정하세요.");
        return;
    };
    item(app, "user", text);
    ai(app).chat.lock().unwrap().messages.push(json!({ "role": "user", "content": text }));
    set_busy(app, true);
    api_loop(app, &key);
    set_busy(app, false);
}

fn api_loop(app: &AppHandle, key: &str) {
    let show_thinking = ai(app).settings.lock().unwrap().show_thinking;
    for _ in 0..25 {
        if ai(app).cancel.load(Ordering::SeqCst) {
            return;
        }
        status(app, "생각 중…");
        let resp = match api_request(app, key) {
            Ok(r) => r,
            Err(e) => {
                if !ai(app).cancel.load(Ordering::SeqCst) {
                    item(app, "error", &e);
                }
                // 실패한 요청의 마지막 user 메시지는 지워 다음 요청이 꼬이지 않게
                let mut c = ai(app).chat.lock().unwrap();
                if c.messages.last().is_some_and(|m| m["role"] == "user" && m["content"].is_string()) {
                    c.messages.pop();
                }
                return;
            }
        };
        let stop = resp["stop_reason"].as_str().unwrap_or("").to_string();
        let content = resp["content"].as_array().cloned().unwrap_or_default();
        if stop == "refusal" {
            let why = resp["stop_details"]["explanation"].as_str().unwrap_or("");
            item(app, "error", &format!("요청이 거절되었습니다. {why}"));
            ai(app).chat.lock().unwrap().messages.pop();
            return;
        }
        ai(app).chat.lock().unwrap().messages.push(json!({ "role": "assistant", "content": content }));
        for block in &content {
            match block["type"].as_str() {
                Some("thinking") if show_thinking => {
                    let t = block["thinking"].as_str().unwrap_or("").trim();
                    if !t.is_empty() {
                        item(app, "thinking", t);
                    }
                }
                Some("text") => {
                    let t = block["text"].as_str().unwrap_or("").trim();
                    if !t.is_empty() {
                        item(app, "assistant", t);
                    }
                }
                _ => {}
            }
        }
        let uses: Vec<&Value> = content.iter().filter(|b| b["type"] == "tool_use").collect();
        if stop == "max_tokens" && uses.is_empty() {
            item(app, "error", "응답이 너무 길어 중간에 끊겼습니다.");
            return;
        }
        if stop != "tool_use" || uses.is_empty() {
            return;
        }
        let mut results = vec![];
        for u in uses {
            let name = u["name"].as_str().unwrap_or("");
            status(app, &format!("실행: {}", ai_tools::label(name)));
            let (out, is_err) = ai_tools::execute(app, name, &u["input"]);
            if !name.starts_with("get_") && !name.starts_with("search_") {
                item(app, "tool", &format!("{} — {}", ai_tools::label(name), out.lines().next().unwrap_or("")));
            }
            let mut r = json!({ "type": "tool_result", "tool_use_id": u["id"], "content": out });
            if is_err {
                r["is_error"] = json!(true);
            }
            results.push(r);
        }
        ai(app).chat.lock().unwrap().messages.push(json!({ "role": "user", "content": results }));
    }
    item(app, "error", "작업 단계가 너무 많아 멈췄습니다. 요청을 나눠 주세요.");
}

fn api_request(app: &AppHandle, key: &str) -> Result<Value, String> {
    let s = ai(app).settings.lock().unwrap().clone();
    let model = if MODELS.iter().any(|m| m.0 == s.model) { s.model.clone() } else { DEFAULT_API_MODEL.to_string() };
    let messages = ai(app).chat.lock().unwrap().messages.clone();
    let mut body = json!({
        "model": model,
        "max_tokens": 16000,
        "cache_control": { "type": "ephemeral" },
        "system": SYSTEM,
        "tools": ai_tools::definitions(),
        "messages": messages,
    });
    if supports_effort(&model) {
        body["thinking"] = if s.show_thinking { json!({ "type": "adaptive", "display": "summarized" }) } else { json!({ "type": "adaptive" }) };
        if !s.effort.is_empty() {
            body["output_config"] = json!({ "effort": s.effort });
        }
    } else if s.show_thinking {
        body["thinking"] = json!({ "type": "enabled", "budget_tokens": 4000 });
    }
    let mut req = ureq::post("https://api.anthropic.com/v1/messages")
        .timeout(Duration::from_secs(600))
        .set("content-type", "application/json")
        .set("x-api-key", key)
        .set("anthropic-version", "2023-06-01");
    if uses_fallback(&model) {
        // 안전 분류기가 거절하면 서버가 권장 모델로 자동 재시도
        req = req.set("anthropic-beta", "server-side-fallback-2026-07-01");
        body["fallbacks"] = json!("default");
    }
    match req.send_json(body) {
        Ok(r) => r.into_json::<Value>().map_err(|_| "Claude 응답을 읽지 못했습니다".to_string()),
        Err(ureq::Error::Status(code, r)) => {
            let msg = r.into_json::<Value>().ok().and_then(|v| v["error"]["message"].as_str().map(str::to_string)).unwrap_or_else(|| format!("HTTP {code}"));
            Err(match code {
                401 => "API 키가 올바르지 않습니다. AI 설정에서 다시 입력하세요.".into(),
                429 => format!("요청이 너무 많습니다. 잠시 후 다시 시도하세요. ({msg})"),
                500..=599 => format!("Claude 서버가 혼잡합니다. 잠시 후 다시 시도하세요. ({msg})"),
                _ => format!("Claude 오류: {msg}"),
            })
        }
        Err(e) => Err(format!("Claude에 연결하지 못했습니다: {e}")),
    }
}

// MARK: CLI 찾기·실행 환경

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default())
}

fn agent_bin_dir() -> PathBuf {
    let d = tools::app_data().join("bin");
    let _ = std::fs::create_dir_all(&d);
    d
}

pub fn claude_binary() -> Option<PathBuf> {
    let h = home();
    let mut c = vec![h.join(".local/bin").join(tools::exe("claude")), h.join(".claude/local").join(tools::exe("claude"))];
    if cfg!(windows) {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            c.push(PathBuf::from(appdata).join("npm").join("claude.cmd"));
        }
    } else {
        c.extend(["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map(PathBuf::from));
    }
    c.into_iter().find(|p| p.is_file())
}

pub fn codex_binary() -> Option<PathBuf> {
    let h = home();
    let mut c = vec![agent_bin_dir().join(tools::exe("codex")), h.join(".local/bin").join(tools::exe("codex"))];
    if cfg!(windows) {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            c.push(PathBuf::from(appdata).join("npm").join("codex.cmd"));
        }
    } else {
        c.extend(["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map(PathBuf::from));
    }
    c.into_iter().find(|p| p.is_file())
}

/// 사용자 로그인만 쓰도록: 다른 세션 변수·API 키는 빼고, 설치 위치를 PATH 앞에 둔다
pub fn agent_command(bin: &Path) -> Command {
    let mut c = tools::command(bin);
    for (k, _) in std::env::vars_os() {
        let k = k.to_string_lossy().to_string();
        let u = k.to_uppercase();
        if u.starts_with("CLAUDE") || u.starts_with("ANTHROPIC_") || u == "OPENAI_API_KEY" || u.starts_with("CODEX_") {
            c.env_remove(&k);
        }
    }
    let mut paths = vec![home().join(".local/bin"), agent_bin_dir()];
    if let Some(p) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&p));
    }
    if !cfg!(windows) {
        paths.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map(PathBuf::from));
    }
    if let Ok(p) = std::env::join_paths(paths) {
        c.env("PATH", p);
    }
    c
}

/// 명령 실행 (출력은 stdout+stderr), 제한 시간 초과면 (-2, "시간이 초과되었습니다.")
pub fn run(bin: &Path, args: &[&str], stdin: Option<&str>, timeout: Duration) -> (i32, String) {
    let mut child = match agent_command(bin).args(args).current_dir(tools::temp_dir()).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(e) => return (-1, e.to_string()),
    };
    if let Some(mut i) = child.stdin.take() {
        if let Some(s) = stdin {
            let _ = i.write_all(s.as_bytes());
        }
    }
    let mut out = child.stdout.take().unwrap();
    let mut err = child.stderr.take().unwrap();
    let o = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = out.read_to_string(&mut s);
        s
    });
    let e = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = err.read_to_string(&mut s);
        s
    });
    let start = Instant::now();
    let code = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s.code().unwrap_or(-1),
            Ok(None) if start.elapsed() > timeout => {
                let _ = child.kill();
                let _ = child.wait();
                return (-2, "시간이 초과되었습니다.".into());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => return (-1, e.to_string()),
        }
    };
    (code, o.join().unwrap_or_default() + &e.join().unwrap_or_default())
}

fn claude_logged_in() -> bool {
    let Some(bin) = claude_binary() else { return false };
    let (code, out) = run(&bin, &["auth", "status", "--json"], None, Duration::from_secs(30));
    code == 0 && out.find('{').and_then(|i| serde_json::from_str::<Value>(&out[i..]).ok()).is_some_and(|v| v["loggedIn"].as_bool() == Some(true))
}

fn codex_logged_in() -> bool {
    let Some(bin) = codex_binary() else { return false };
    let (code, out) = run(&bin, &["login", "status"], None, Duration::from_secs(30));
    code == 0 && out.to_lowercase().contains("logged in")
}

// MARK: 원클릭 연결 (설치 → 브라우저 로그인 → 확인)

fn agent_state(app: &AppHandle, codex: bool) -> &Mutex<AgentState> {
    let a = ai(app);
    if codex { &a.codex } else { &a.claude }
}

fn set_state(app: &AppHandle, codex: bool, s: AgentState) {
    *agent_state(app, codex).lock().unwrap() = s;
    emit_agents(app);
}

pub fn refresh_agents(app: &AppHandle) {
    let c = if claude_binary().is_none() { AgentState::NotInstalled } else if claude_logged_in() { AgentState::Ready } else { AgentState::LoggedOut };
    let x = if codex_binary().is_none() { AgentState::NotInstalled } else if codex_logged_in() { AgentState::Ready } else { AgentState::LoggedOut };
    if !matches!(*agent_state(app, false).lock().unwrap(), AgentState::Working(_)) {
        *agent_state(app, false).lock().unwrap() = c;
    }
    if !matches!(*agent_state(app, true).lock().unwrap(), AgentState::Working(_)) {
        *agent_state(app, true).lock().unwrap() = x;
    }
    emit_agents(app);
}

/// 설치 → 로그인 → 확인. 성공하면 연결 방식을 그 계정으로 바꾼다
pub fn connect(app: &AppHandle, codex: bool) -> Result<(), String> {
    if matches!(*agent_state(app, codex).lock().unwrap(), AgentState::Working(_)) {
        return Err("이미 진행 중입니다".into());
    }
    let r = (|| {
        let installed = if codex { codex_binary() } else { claude_binary() };
        if installed.is_none() {
            set_state(app, codex, AgentState::Working(if codex { "Codex 설치 중…" } else { "Claude Code 설치 중…" }.into()));
            if codex { install_codex()? } else { install_claude()? }
        }
        if if codex { codex_logged_in() } else { claude_logged_in() } {
            return Ok(());
        }
        set_state(app, codex, AgentState::Working("브라우저에서 로그인을 마쳐 주세요…".into()));
        login(app, codex)
    })();
    match r {
        Ok(()) => {
            set_state(app, codex, AgentState::Ready);
            ai(app).chat.lock().unwrap().needs_login = false;
            let mut s = ai(app).settings.lock().unwrap().clone();
            let want = if codex { "codex" } else { "plan" };
            if s.backend != want {
                s.backend = want.into();
                set_settings(app, s);
                let _ = app.emit("ai", json!({ "type": "settings", "value": settings_json(app) }));
            }
            emit_agents(app);
            Ok(())
        }
        Err(e) => {
            set_state(app, codex, AgentState::Failed(e.clone()));
            Err(e)
        }
    }
}

pub fn cancel_login(app: &AppHandle) {
    if let Some(mut c) = ai(app).login_child.lock().unwrap().take() {
        let _ = c.kill();
    }
}

fn login(app: &AppHandle, codex: bool) -> Result<(), String> {
    let bin = if codex { codex_binary() } else { claude_binary() }.ok_or("설치를 확인할 수 없습니다.")?;
    let args: &[&str] = if codex { &["login"] } else { &["auth", "login", "--claudeai"] };
    let mut child = agent_command(&bin)
        .args(args)
        .current_dir(tools::temp_dir())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("로그인을 시작하지 못했습니다: {e}"))?;
    *ai(app).login_url.lock().unwrap() = None;
    // CLI가 브라우저를 연다. 출력에 나온 주소는 [브라우저 다시 열기]용으로 보관
    for stream in [child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>), child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>)].into_iter().flatten() {
        let app = app.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                if let Some(i) = line.find("https://") {
                    let url: String = line[i..].chars().take_while(|c| !c.is_whitespace() && !"\"'<>".contains(*c)).collect();
                    let a = ai(&app);
                    let mut u = a.login_url.lock().unwrap();
                    if u.is_none() {
                        *u = Some(url);
                        drop(u);
                        emit_agents(&app);
                    }
                }
            }
        });
    }
    *ai(app).login_child.lock().unwrap() = Some(child);
    let deadline = Instant::now() + Duration::from_secs(300);
    let result = loop {
        std::thread::sleep(Duration::from_secs(2));
        if if codex { codex_logged_in() } else { claude_logged_in() } {
            break Ok(());
        }
        let mut guard = ai(app).login_child.lock().unwrap();
        let Some(c) = guard.as_mut() else { break Err("로그인을 취소했습니다.".to_string()) };
        if let Ok(Some(s)) = c.try_wait() {
            if !s.success() {
                break Err("로그인을 마치지 못했습니다. 다시 눌러 주세요.".into());
            }
        }
        if Instant::now() > deadline {
            break Err("로그인 시간이 초과되었습니다. 다시 눌러 주세요.".into());
        }
    };
    if let Some(mut c) = ai(app).login_child.lock().unwrap().take() {
        let _ = c.kill();
    }
    *ai(app).login_url.lock().unwrap() = None;
    result
}

/// OpenAI API 키로 Codex 로그인
pub fn connect_codex_with_key(app: &AppHandle, key: &str) -> Result<(), String> {
    let r = (|| {
        if codex_binary().is_none() {
            set_state(app, true, AgentState::Working("Codex 설치 중…".into()));
            install_codex()?;
        }
        let bin = codex_binary().ok_or("Codex를 설치하지 못했습니다.")?;
        set_state(app, true, AgentState::Working("API 키 확인 중…".into()));
        let (code, out) = run(&bin, &["login", "--with-api-key"], Some(key.trim()), Duration::from_secs(60));
        if code != 0 {
            return Err(format!("API 키로 로그인하지 못했습니다: {}", tail(&out, 200)));
        }
        if !codex_logged_in() {
            return Err("API 키로 로그인하지 못했습니다.".into());
        }
        Ok(())
    })();
    match &r {
        Ok(()) => {
            set_state(app, true, AgentState::Ready);
            let mut s = ai(app).settings.lock().unwrap().clone();
            s.backend = "codex".into();
            set_settings(app, s);
            let _ = app.emit("ai", json!({ "type": "settings", "value": settings_json(app) }));
        }
        Err(e) => set_state(app, true, AgentState::Failed(e.clone())),
    }
    r
}

fn tail(s: &str, n: usize) -> String {
    let v: Vec<char> = s.chars().collect();
    v[v.len().saturating_sub(n)..].iter().collect()
}

/// Claude Code 공식 설치 스크립트
fn install_claude() -> Result<(), String> {
    let (code, out) = if cfg!(windows) {
        let ps = PathBuf::from(std::env::var_os("SystemRoot").unwrap_or("C:\\Windows".into())).join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
        run(&ps, &["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm https://claude.ai/install.ps1 | iex"], None, Duration::from_secs(600))
    } else {
        run(Path::new("/bin/bash"), &["-c", "curl -fsSL https://claude.ai/install.sh | bash"], None, Duration::from_secs(600))
    };
    if code != 0 || claude_binary().is_none() {
        return Err(format!("Claude Code를 설치하지 못했습니다. 인터넷 연결을 확인하세요.\n{}", tail(&out, 200)));
    }
    Ok(())
}

/// Codex 공식 배포본(GitHub openai/codex)을 받아 앱 전용 폴더에 설치
fn install_codex() -> Result<(), String> {
    let dest = agent_bin_dir().join(tools::exe("codex"));
    let tmp = dest.with_extension("download");
    if cfg!(windows) {
        let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
        update::download(&format!("https://github.com/openai/codex/releases/latest/download/codex-{arch}-pc-windows-msvc.exe"), &tmp)
            .map_err(|_| "Codex를 받지 못했습니다.".to_string())?;
    } else {
        let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
        let tgz = tmp.with_extension("tar.gz");
        update::download(&format!("https://github.com/openai/codex/releases/latest/download/codex-{arch}-apple-darwin.tar.gz"), &tgz)
            .map_err(|_| "Codex를 받지 못했습니다.".to_string())?;
        let work = tools::temp_dir().join("codex-install");
        let _ = std::fs::remove_dir_all(&work);
        let _ = std::fs::create_dir_all(&work);
        let (code, out) = run(Path::new("/usr/bin/tar"), &["-xzf", &tgz.to_string_lossy(), "-C", &work.to_string_lossy()], None, Duration::from_secs(120));
        if code != 0 {
            return Err(format!("Codex 압축을 풀지 못했습니다: {}", tail(&out, 200)));
        }
        let bin = std::fs::read_dir(&work).into_iter().flatten().flatten().map(|e| e.path()).find(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("codex")))
            .ok_or("받은 파일에 Codex가 없습니다.")?;
        std::fs::rename(bin, &tmp).map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(&tgz);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755));
        }
    }
    let _ = std::fs::remove_file(&dest);
    std::fs::rename(&tmp, &dest).map_err(|e| format!("Codex를 설치하지 못했습니다: {e}"))?;
    Ok(())
}

// MARK: 다른 AI 앱에서 EasyCut 조작 (MCP 연결)

fn desktop_config() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(std::env::var_os("APPDATA").unwrap_or_default()).join("Claude").join("claude_desktop_config.json")
    } else {
        home().join("Library/Application Support/Claude/claude_desktop_config.json")
    }
}

fn command_matches(v: &Value) -> bool {
    v["command"].as_str().is_some_and(|c| Path::new(c) == Path::new(&control::app_binary()))
}

pub fn links_json() -> Value {
    let desktop = std::fs::read_to_string(desktop_config()).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok()).is_some_and(|v| command_matches(&v["mcpServers"]["easycut"]));
    let code = std::fs::read_to_string(home().join(".claude.json")).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok()).is_some_and(|v| command_matches(&v["mcpServers"]["easycut"]));
    let codex = std::fs::read_to_string(home().join(".codex").join("config.toml")).is_ok_and(|s| {
        s.contains("[mcp_servers.easycut]") && (s.contains(&control::app_binary()) || s.contains(&control::app_binary().replace('\\', "\\\\")))
    });
    json!({ "desktop": desktop, "code": code, "codex": codex, "claudeInstalled": claude_binary().is_some(), "codexInstalled": codex_binary().is_some() })
}

/// Claude 데스크톱 설정에 EasyCut 연결을 추가 (기존 설정은 백업 후 보존)
pub fn link_desktop() -> Result<(), String> {
    let path = desktop_config();
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    let mut obj = json!({});
    if let Ok(s) = std::fs::read_to_string(&path) {
        obj = serde_json::from_str(&s).map_err(|_| format!("Claude 데스크톱 설정 파일을 읽을 수 없습니다. 직접 확인해 주세요:\n{}", path.display()))?;
        let _ = std::fs::write(path.with_extension("backup.json"), s);
    }
    if !obj["mcpServers"].is_object() {
        obj["mcpServers"] = json!({});
    }
    obj["mcpServers"]["easycut"] = json!({ "command": control::app_binary(), "args": ["--mcp"] });
    std::fs::write(&path, serde_json::to_string_pretty(&obj).unwrap()).map_err(|e| e.to_string())
}

pub fn link_code() -> Result<(), String> {
    let bin = claude_binary().ok_or("Claude Code가 설치되어 있지 않습니다.")?;
    let exe = control::app_binary();
    let _ = run(&bin, &["mcp", "remove", "-s", "user", "easycut"], None, Duration::from_secs(30));
    let (code, out) = run(&bin, &["mcp", "add", "-s", "user", "easycut", "--", &exe, "--mcp"], None, Duration::from_secs(60));
    if code != 0 {
        return Err(format!("연결 실패: {}", tail(&out, 300)));
    }
    Ok(())
}

pub fn link_codex() -> Result<(), String> {
    let bin = codex_binary().ok_or("Codex가 설치되어 있지 않습니다.")?;
    let exe = control::app_binary();
    let _ = run(&bin, &["mcp", "remove", "easycut"], None, Duration::from_secs(30));
    let (code, out) = run(&bin, &["mcp", "add", "easycut", "--", &exe, "--mcp"], None, Duration::from_secs(60));
    if code != 0 {
        return Err(format!("연결 실패: {}", tail(&out, 300)));
    }
    Ok(())
}
