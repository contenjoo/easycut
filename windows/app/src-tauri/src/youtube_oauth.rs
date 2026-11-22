//! OAuth for an installed desktop app. The browser returns only to our ephemeral loopback port.
use super::{api, http, text, Result, SCOPE};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager, Url};

const VAULT: &str =
    "EasyCut이 Windows 자격 증명 관리자에서 YouTube 인증 정보를 읽거나 저장할 수 없습니다.";
const RECONNECT: &str = "Google 계정을 다시 연결하세요.";
const EXCHANGE: &str = "Google 로그인에 실패했습니다. 계정 권한과 앱 설정을 확인하세요.";
const LOOPBACK: &str = "Google 로그인 응답을 받을 수 없습니다.";
const DENIED: &str = "Google 계정 연결을 취소했거나 YouTube 권한을 허용하지 않았습니다.";

pub(super) fn client_id() -> Option<&'static str> {
    option_env!("EASYCUT_YOUTUBE_CLIENT_ID")
        .map(str::trim)
        .filter(|v| {
            v.ends_with(".apps.googleusercontent.com")
                && v.len() <= 256
                && v.starts_with(|c: char| c.is_ascii_digit())
                && v.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'.'))
        })
}
fn vault(client: &str) -> Result<keyring::Entry> {
    keyring::Entry::new("com.contenjoo.easycut.youtube.oauth", client).map_err(|_| VAULT.into())
}

#[derive(Serialize, Deserialize)]
pub(super) struct Grant {
    refresh: String,
    pub channel: String,
    pub title: String,
}

impl Grant {
    pub fn load(client: &str) -> Result<Option<Self>> {
        match vault(client)?.get_secret() {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|_| VAULT.into()),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err(VAULT.into()),
        }
    }
    fn save(&self, client: &str) -> Result<()> {
        let bytes = serde_json::to_vec(self).map_err(|_| VAULT.to_string())?;
        vault(client)?.set_secret(&bytes).map_err(|_| VAULT.into())
    }
    fn clear(client: &str) -> Result<()> {
        match vault(client)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err(VAULT.into()),
        }
    }
}

#[derive(Deserialize)]
struct Token {
    access_token: String,
    token_type: String,
    expires_in: u32,
    scope: Option<String>,
    refresh_token: Option<String>,
}

fn exchange<'a>(client: &'a str, mut fields: Vec<(&str, &'a str)>) -> Result<Token> {
    fields.push(("client_id", client));
    if let Some(secret) = option_env!("EASYCUT_YOUTUBE_CLIENT_SECRET")
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        fields.push(("client_secret", secret));
    }
    let r = http()
        .post("https://oauth2.googleapis.com/token")
        .send_form(&fields);
    let r = match r {
        Ok(r) if r.status() == 200 => r,
        Err(ureq::Error::Status(400, r)) if fields.contains(&("grant_type", "refresh_token")) => {
            let err: Value = r.into_json().unwrap_or(Value::Null);
            if err["error"] == "invalid_grant" {
                Grant::clear(client)?;
                return Err(RECONNECT.into());
            }
            return Err(EXCHANGE.into());
        }
        _ => return Err(EXCHANGE.into()),
    };
    let token: Token = r.into_json().map_err(|_| EXCHANGE.to_string())?;
    if !token.token_type.eq_ignore_ascii_case("bearer")
        || token.access_token.is_empty()
        || token.expires_in == 0
        || token
            .scope
            .as_ref()
            .is_some_and(|s| !s.split_whitespace().any(|v| v == SCOPE))
    {
        return Err(EXCHANGE.into());
    }
    Ok(token)
}

pub(super) struct Access {
    pub token: String,
    pub channel: String,
    expires: Instant,
}
impl Access {
    pub fn valid(&self) -> bool {
        self.expires > Instant::now() + Duration::from_secs(30)
    }
    fn from(token: Token, grant: &Grant) -> Self {
        Self {
            token: token.access_token,
            channel: grant.channel.clone(),
            expires: Instant::now() + Duration::from_secs(token.expires_in.into()),
        }
    }
    pub fn renew(client: &str) -> Result<Self> {
        let mut grant = Grant::load(client)?.ok_or(RECONNECT)?;
        let token = exchange(
            client,
            vec![
                ("grant_type", "refresh_token"),
                ("refresh_token", &grant.refresh),
            ],
        )?;
        if let Some(refresh) = token.refresh_token.as_ref().filter(|v| !v.is_empty()) {
            grant.refresh = refresh.clone();
            grant.save(client)?;
        }
        Ok(Self::from(token, &grant))
    }
}

pub(super) fn disconnect(client: &str) -> Result<()> {
    let grant = Grant::load(client)?;
    Grant::clear(client)?;
    if let Some(grant) = grant {
        let revoke = http()
            .post("https://oauth2.googleapis.com/revoke")
            .send_form(&[("token", &grant.refresh)]);
        if !revoke.is_ok_and(|r| r.status() == 200) {
            return Err("이 PC에서 연결을 해제했습니다. Google 계정의 연결된 앱에서도 EasyCut 접근 권한을 해제하세요.".into());
        }
    }
    Ok(())
}

fn nonce() -> Result<String> {
    let mut random = [0; 32];
    getrandom::getrandom(&mut random).map_err(|_| LOOPBACK.to_string())?;
    Ok(URL_SAFE_NO_PAD.encode(random))
}
fn auth_url(client: &str, redirect: &str, state: &str, verifier: &str) -> Url {
    let mut url = Url::parse("https://accounts.google.com/o/oauth2/v2/auth").unwrap();
    url.query_pairs_mut().extend_pairs([
        ("client_id", client),
        ("redirect_uri", redirect),
        ("response_type", "code"),
        ("scope", SCOPE),
        ("state", state),
        (
            "code_challenge",
            &URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())),
        ),
        ("code_challenge_method", "S256"),
        ("access_type", "offline"),
        ("prompt", "consent select_account"),
    ]);
    url
}

enum Callback {
    Invalid,
    Denied,
    Code(String),
}
fn callback(headers: &str, origin: &str, state: &str) -> Callback {
    let mut lines = headers.split("\r\n");
    let line: Vec<_> = lines.next().unwrap_or("").split(' ').collect();
    let hosts: Vec<_> = lines
        .filter_map(|l| l.split_once(':'))
        .filter(|(k, _)| k.eq_ignore_ascii_case("Host"))
        .map(|(_, v)| v.trim())
        .collect();
    if hosts != [origin]
        || line.len() != 3
        || line[0] != "GET"
        || !matches!(line[2], "HTTP/1.0" | "HTTP/1.1")
        || !line[1].starts_with("/?")
        || line[1].contains('#')
    {
        return Callback::Invalid;
    }
    let Ok(target) = Url::parse(&format!("http://{origin}{}", line[1])) else {
        return Callback::Invalid;
    };
    let values = |k: &str| {
        target
            .query_pairs()
            .filter(|(key, _)| key == k)
            .map(|(_, val)| val.into_owned())
            .collect::<Vec<_>>()
    };
    let (states, codes, errors) = (values("state"), values("code"), values("error"));
    if states != [state] {
        return Callback::Invalid;
    }
    match (&codes[..], &errors[..]) {
        ([code], []) if !code.is_empty() => Callback::Code(code.clone()),
        ([], [_]) => Callback::Denied,
        _ => Callback::Invalid,
    }
}
fn receive(stream: &mut TcpStream, origin: &str, state: &str, deadline: Instant) -> Callback {
    let mut data = Vec::new();
    let mut buf = [0u8; 1024];
    let limit = deadline.min(Instant::now() + Duration::from_secs(2));
    while data.len() < 8192 && Instant::now() < limit {
        if stream
            .set_read_timeout(Some(Duration::from_millis(250)))
            .is_err()
        {
            break;
        }
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => data.extend_from_slice(&buf[..n]),
            Err(_) => break,
        }
        if let Some(end) = data.windows(4).position(|b| b == b"\r\n\r\n") {
            if let Ok(s) = std::str::from_utf8(&data[..end]) {
                return callback(s, origin, state);
            }
            break;
        }
    }
    Callback::Invalid
}

pub(super) fn connect(app: &AppHandle, client: &str) -> Result<Access> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|_| LOOPBACK.to_string())?;
    listener
        .set_nonblocking(true)
        .map_err(|_| LOOPBACK.to_string())?;
    let origin = listener
        .local_addr()
        .map_err(|_| LOOPBACK.to_string())?
        .to_string();
    let redirect = format!("http://{origin}/");
    let (state, verifier) = (nonce()?, nonce()?);
    let url = auth_url(client, &redirect, &state, &verifier);
    crate::open_url(url.into()).map_err(|_| "기본 브라우저를 열 수 없습니다.".to_string())?;
    let deadline = Instant::now() + Duration::from_secs(300);
    let code = loop {
        if app.get_webview_window("studio").is_none() {
            return Err(DENIED.into());
        }
        if Instant::now() >= deadline {
            return Err("로그인 시간이 만료되었습니다. 다시 시도하세요.".into());
        }
        let mut stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(60));
                continue;
            }
            Err(_) => return Err(LOOPBACK.into()),
        };
        let result = receive(&mut stream, &origin, &state, deadline);
        let (status, body) = match &result {
            Callback::Invalid => ("400 Bad Request", "잘못된 요청입니다."),
            _ => (
                "200 OK",
                "로그인 응답을 받았습니다. EasyCut으로 돌아가세요.",
            ),
        };
        let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
        let _ = write!(stream,"HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n{body}",body.len());
        match result {
            Callback::Invalid => continue,
            Callback::Denied => return Err(DENIED.into()),
            Callback::Code(code) => break code,
        }
    };
    drop(listener);
    let mut token = exchange(
        client,
        vec![
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("code_verifier", &verifier),
            ("redirect_uri", &redirect),
        ],
    )?;
    let root = api(
        &token.access_token,
        "channels",
        &[
            ("part", "id,snippet"),
            ("mine", "true"),
            ("fields", "items(id,snippet/title)"),
        ],
        None,
    )?;
    let channel = root["items"]
        .as_array()
        .and_then(|c| if c.len() == 1 { c.first() } else { None })
        .ok_or("로그인할 때 방송할 YouTube 채널을 선택하세요.")?;
    let refresh = token
        .refresh_token
        .take()
        .filter(|v| !v.is_empty())
        .ok_or(RECONNECT)?;
    let grant = Grant {
        refresh,
        channel: text(channel, "/id")?.into(),
        title: text(channel, "/snippet/title")?.into(),
    };
    grant.save(client)?;
    Ok(Access::from(token, &grant))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn login_requires_exact_origin_state_and_single_code() {
        let origin = "127.0.0.1:12345";
        let check = |path: &str, host: &str| {
            callback(
                &format!("GET {path} HTTP/1.1\r\nHost: {host}"),
                origin,
                "abc",
            )
        };
        assert!(
            matches!(check("/?state=abc&code=123","127.0.0.1:12345"),Callback::Code(v) if v=="123")
        );
        assert!(matches!(
            check("/?state=abc&error=access_denied", origin),
            Callback::Denied
        ));
        for invalid in [
            "/?state=other&code=s",
            "/?state=abc&code=a&code=b",
            "/?state=abc&state=no&code=a",
            "/?state=abc&error=no&code=a",
            "//outside/?state=abc&code=a",
            "/bad?state=abc&code=a",
        ] {
            assert!(matches!(check(invalid, origin), Callback::Invalid));
        }
        assert!(matches!(
            check("/?state=abc&code=s", "example.org"),
            Callback::Invalid
        ));
        assert!(matches!(
            check("/?state=abc&code=s", "127.0.0.1:12345\r\nHost: other"),
            Callback::Invalid
        ));
    }
    #[test]
    fn pkce_matches_rfc7636_vector() {
        let v = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let url = auth_url("client", "http://127.0.0.1:42/", "s", v);
        assert!(url
            .query_pairs()
            .any(|(k, v)| k == "code_challenge"
                && v == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
        assert!(!url.as_str().contains(v));
        assert_ne!(nonce().unwrap(), nonce().unwrap());
    }
}
