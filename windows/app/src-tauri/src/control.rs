//! 외부 Claude/Codex가 MCP로 앱을 조작하게 하는 로컬 전용 제어 서버와 `EasyCut.exe --mcp` 다리 (맥 ControlServer.swift).
//! 127.0.0.1에만 열고, 앱 데이터 폴더의 비밀 토큰을 가진 요청만 받는다.
use crate::{ai_tools, tools};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::time::Duration;
use tauri::AppHandle;

const PORT: u16 = 47_821;

/// 포트 (개발할 때 같은 컴퓨터의 맥 앱과 겹치지 않게 EASYCUT_CONTROL_PORT로 바꿀 수 있다)
fn port() -> u16 {
    std::env::var("EASYCUT_CONTROL_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(PORT)
}

fn token_path() -> PathBuf {
    tools::app_data().join("control-token")
}

pub fn token() -> String {
    if let Ok(t) = std::fs::read_to_string(token_path()) {
        if t.trim().len() >= 32 {
            return t.trim().to_string();
        }
    }
    let t: String = (0..4).map(|_| easycut_core::Id::new().to_string().replace('-', "")).collect();
    let _ = std::fs::write(token_path(), &t);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(token_path(), std::fs::Permissions::from_mode(0o600));
    }
    t
}

/// 이 앱 실행 파일 경로 (외부 AI가 `--mcp`로 실행)
pub fn app_binary() -> String {
    std::env::current_exe().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
}

pub fn start(app: AppHandle) {
    let token = token();
    std::thread::spawn(move || {
        let Ok(listener) = TcpListener::bind(("127.0.0.1", port())) else { return };
        for conn in listener.incoming().flatten() {
            let app = app.clone();
            let token = token.clone();
            std::thread::spawn(move || handle(conn, &app, &token));
        }
    });
}

fn handle(mut conn: TcpStream, app: &AppHandle, token: &str) {
    let _ = conn.set_read_timeout(Some(Duration::from_secs(30)));
    let reply = match read_request(&mut conn) {
        Some((headers, body)) => {
            let auth = headers.iter().find(|(k, _)| k == "authorization").map(|(_, v)| v.as_str()).unwrap_or("");
            if auth != format!("Bearer {token}") {
                json!({ "error": "unauthorized" })
            } else if let Some(name) = serde_json::from_slice::<Value>(&body).ok().filter(|b| b["name"].is_string()) {
                let (text, is_err) = ai_tools::execute(app, name["name"].as_str().unwrap(), &name["input"]);
                json!({ "text": text, "is_error": is_err })
            } else {
                json!({ "error": "bad body" })
            }
        }
        None => json!({ "error": "bad request" }),
    };
    let body = reply.to_string();
    let _ = write!(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
}

/// HTTP 요청 하나를 끝까지 읽는다 (Content-Length 기준). 헤더 이름은 소문자
fn read_request(conn: &mut TcpStream) -> Option<(Vec<(String, String)>, Vec<u8>)> {
    let mut r = BufReader::new(conn);
    let mut line = String::new();
    r.read_line(&mut line).ok()?;
    let mut headers = vec![];
    loop {
        line.clear();
        r.read_line(&mut line).ok()?;
        let l = line.trim_end();
        if l.is_empty() {
            break;
        }
        let (k, v) = l.split_once(':')?;
        headers.push((k.trim().to_lowercase(), v.trim().to_string()));
    }
    let len: usize = headers.iter().find(|(k, _)| k == "content-length").and_then(|(_, v)| v.parse().ok()).unwrap_or(0);
    if len > 8 << 20 {
        return None;
    }
    let mut body = vec![0; len];
    r.read_exact(&mut body).ok()?;
    Some((headers, body))
}

/// 실행 중인 앱으로 도구 호출을 보낸다
fn call(name: &str, args: &Value) -> (String, bool) {
    let Ok(token) = std::fs::read_to_string(token_path()) else {
        return ("EasyCut 앱이 실행 중이 아닙니다. 앱을 먼저 여세요.".into(), true);
    };
    let fail = || ("EasyCut 앱에 연결할 수 없습니다. 앱이 실행 중인지 확인하세요.".to_string(), true);
    let Ok(mut s) = TcpStream::connect(("127.0.0.1", port())) else { return fail() };
    let _ = s.set_read_timeout(Some(Duration::from_secs(1500)));
    let body = json!({ "name": name, "input": args }).to_string();
    let req = format!(
        "POST /tool HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        token.trim(),
        body.len()
    );
    if s.write_all(req.as_bytes()).is_err() {
        return fail();
    }
    let mut resp = String::new();
    if s.read_to_string(&mut resp).is_err() {
        return fail();
    }
    let Some((_, json_body)) = resp.split_once("\r\n\r\n") else { return fail() };
    match serde_json::from_str::<Value>(json_body) {
        Ok(v) if v["text"].is_string() => (v["text"].as_str().unwrap().to_string(), v["is_error"].as_bool().unwrap_or(false)),
        Ok(v) if v["error"].is_string() => (format!("오류: {}", v["error"].as_str().unwrap()), true),
        _ => fail(),
    }
}

/// `EasyCut.exe --mcp` : MCP(stdio) 서버. 도구 호출은 실행 중인 앱으로 전달한다
pub fn run_mcp() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines().map_while(Result::ok) {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = msg.get("id").cloned() else { continue }; // 알림은 응답하지 않는다
        let method = msg["method"].as_str().unwrap_or("");
        let params = &msg["params"];
        let mut reply = json!({ "jsonrpc": "2.0", "id": id });
        match method {
            "initialize" => {
                reply["result"] = json!({
                    "protocolVersion": params["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                    "capabilities": { "tools": {} },
                    "serverInfo": { "name": "easycut", "version": env!("CARGO_PKG_VERSION") },
                    "instructions": "EasyCut 영상 편집 앱을 조작합니다. 앱이 실행 중이어야 합니다. 먼저 get_project_state로 상태를 확인하세요.",
                })
            }
            "ping" => reply["result"] = json!({}),
            "tools/list" => {
                let tools: Vec<Value> = ai_tools::definitions()
                    .into_iter()
                    .map(|d| json!({ "name": d["name"], "description": d["description"], "inputSchema": d["input_schema"] }))
                    .collect();
                reply["result"] = json!({ "tools": tools });
            }
            "tools/call" => {
                let (text, is_err) = call(params["name"].as_str().unwrap_or(""), &params["arguments"]);
                reply["result"] = json!({ "content": [{ "type": "text", "text": text }], "isError": is_err });
            }
            _ => reply["error"] = json!({ "code": -32601, "message": format!("Method not found: {method}") }),
        }
        let _ = writeln!(out, "{reply}");
        let _ = out.flush();
    }
}
