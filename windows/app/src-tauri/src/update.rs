//! GitHub 릴리스(win-v* 태그)에서 새 윈도우 버전 확인 → 설치 파일 받아 실행
use crate::tools;
use serde_json::{json, Value};
use std::path::PathBuf;

pub const CURRENT: &str = env!("CARGO_PKG_VERSION");

fn parts(v: &str) -> Vec<u64> {
    v.trim_start_matches(|c: char| !c.is_ascii_digit()).split('.').map(|p| p.chars().take_while(char::is_ascii_digit).collect::<String>().parse().unwrap_or(0)).collect()
}

pub fn is_newer(a: &str, b: &str) -> bool {
    let (x, y) = (parts(a), parts(b));
    for i in 0..x.len().max(y.len()) {
        let (l, r) = (x.get(i).copied().unwrap_or(0), y.get(i).copied().unwrap_or(0));
        if l != r {
            return l > r;
        }
    }
    false
}

fn curl() -> PathBuf {
    if cfg!(windows) { PathBuf::from("curl.exe") } else { PathBuf::from("/usr/bin/curl") }
}

/// 받아도 되는 설치 파일 주소: 이 저장소의 win-v* 릴리스에 올린 *_x64-setup.exe 만
const INSTALLER_PREFIX: &str = "https://github.com/contenjoo/easycut/releases/download/win-v";

pub fn is_valid_installer_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix(INSTALLER_PREFIX) else { return false };
    let mut parts = rest.split('/');
    let (Some(tag), Some(file), None) = (parts.next(), parts.next(), parts.next()) else { return false };
    let safe = |s: &str, extra: &[char]| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || extra.contains(&c));
    safe(tag, &[]) && tag.starts_with(|c: char| c.is_ascii_digit()) && !tag.contains("..")
        && safe(file, &['_']) && !file.contains("..") && file.ends_with("_x64-setup.exe") && file.len() > "_x64-setup.exe".len()
}

/// check()가 본 설치 파일의 sha256 (GitHub 릴리스 asset의 "digest": "sha256:...") — 주소 → 16진수
fn digests() -> &'static std::sync::Mutex<std::collections::HashMap<String, String>> {
    static D: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, String>>> = std::sync::OnceLock::new();
    D.get_or_init(Default::default)
}

/// 릴리스 목록(JSON)에서 지금보다 새 윈도우 정식 버전을 고른다 (없으면 null, 목록이 아니면 Err)
pub fn pick_release(list: &Value, current: &str) -> Result<Value, String> {
    let Some(releases) = list.as_array() else {
        let why = list["message"].as_str().map(|m| format!(" ({m})")).unwrap_or_default();
        return Err(format!("업데이트를 확인하지 못했습니다.{why}"));
    };
    let best = releases.iter()
        .filter(|r| r["tag_name"].as_str().is_some_and(|t| t.starts_with("win-v")))
        .filter(|r| r["prerelease"].as_bool() != Some(true) && r["draft"].as_bool() != Some(true))
        .filter_map(|r| {
            let tag = r["tag_name"].as_str()?;
            let asset = r["assets"].as_array()?.iter().find(|a| {
                a["name"].as_str().is_some_and(|n| n.ends_with("_x64-setup.exe"))
                    && a["browser_download_url"].as_str().is_some_and(is_valid_installer_url)
            })?;
            let digest = asset["digest"].as_str().and_then(|d| d.strip_prefix("sha256:")).map(str::to_ascii_lowercase);
            Some((tag.trim_start_matches("win-v").to_string(), asset["browser_download_url"].as_str()?.to_string(), r["body"].as_str().unwrap_or("").to_string(), digest))
        })
        .max_by(|a, b| if is_newer(&a.0, &b.0) { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Less });
    Ok(match best {
        Some((v, url, notes, digest)) if is_newer(&v, current) => {
            if let Some(d) = digest {
                digests().lock().unwrap().insert(url.clone(), d);
            }
            json!({ "version": v, "url": url, "notes": notes, "current": current })
        }
        _ => Value::Null,
    })
}

/// 가장 새 윈도우 릴리스 (없거나 지금 버전 이하면 null)
pub fn check() -> Result<Value, String> {
    let out = tools::command(&curl())
        .args(["-sL", "--max-time", "15", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/contenjoo/easycut/releases?per_page=30"])
        .output()
        .map_err(|e| e.to_string())?;
    let list: Value = serde_json::from_slice(&out.stdout).map_err(|_| "업데이트를 확인하지 못했습니다.".to_string())?;
    pick_release(&list, CURRENT)
}

fn sha256_hex(path: &std::path::Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut h = Sha256::new();
    std::io::copy(&mut f, &mut h).map_err(|e| e.to_string())?;
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// 파일 받기 (curl: 윈도우 10 이상에 기본으로 들어 있다)
pub fn download(url: &str, dest: &std::path::Path) -> Result<(), String> {
    if let Some(d) = dest.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let status = tools::command(&curl()).args(["-sL", "--fail", "--retry", "3", "-o"]).arg(dest).arg(url).status().map_err(|e| e.to_string())?;
    if !status.success() || std::fs::metadata(dest).map_or(0, |m| m.len()) == 0 {
        let _ = std::fs::remove_file(dest);
        return Err(format!("받지 못했습니다: {url}"));
    }
    Ok(())
}

/// 설치 파일을 받아 둔다 (이 저장소의 릴리스 주소인지, 윈도우 실행 파일인지, sha256이 릴리스와 같은지 확인)
pub fn fetch_installer(url: &str) -> Result<PathBuf, String> {
    if !is_valid_installer_url(url) {
        return Err("업데이트 주소가 올바르지 않습니다.".into());
    }
    let dest = tools::temp_dir().join("EasyCut-setup.exe");
    let _ = std::fs::remove_file(&dest);
    download(url, &dest).map_err(|_| "업데이트 파일을 받지 못했습니다.".to_string())?;
    let mut head = [0u8; 2];
    let ok = std::fs::File::open(&dest).and_then(|mut f| std::io::Read::read_exact(&mut f, &mut head)).is_ok();
    if !ok || &head != b"MZ" {
        let _ = std::fs::remove_file(&dest);
        return Err("받은 업데이트 파일이 올바르지 않습니다.".into());
    }
    let expected = digests().lock().unwrap().get(url).cloned();
    if let Some(expected) = expected {
        if sha256_hex(&dest).ok().as_deref() != Some(expected.as_str()) {
            let _ = std::fs::remove_file(&dest);
            return Err("받은 업데이트 파일이 릴리스와 다릅니다 (sha256 불일치).".into());
        }
    }
    Ok(dest)
}

/// 앱이 끝나기를 기다렸다가 조용히 설치하고 다시 연다 (reopen: 다시 열 프로젝트)
pub fn install_and_relaunch(setup: &std::path::Path, reopen: Option<&str>) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let q = |s: &str| s.replace('\'', "''");
    let args = reopen.map(|p| format!(" -ArgumentList '\"{}\"'", q(p))).unwrap_or_default();
    let script = format!(
        "Wait-Process -Id {pid} -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; \
         $p = Start-Process -FilePath '{setup}' -ArgumentList '/S' -Wait -PassThru; \
         Start-Process -FilePath '{exe}'{args}",
        pid = std::process::id(),
        setup = q(&setup.to_string_lossy()),
        exe = q(&exe.to_string_lossy()),
    );
    if cfg!(windows) {
        let ps = PathBuf::from(std::env::var_os("SystemRoot").unwrap_or("C:\\Windows".into())).join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
        tools::command(&ps)
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-Command", &script])
            .spawn()
            .map_err(|e| format!("업데이트를 시작하지 못했습니다: {e}"))?;
    } else {
        // 맥에서 개발할 때는 설치 파일을 실행할 수 없으므로 여기까지만 확인
        return Err("윈도우에서만 설치할 수 있습니다.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installer_url_must_be_official_x64_setup() {
        assert!(is_valid_installer_url("https://github.com/contenjoo/easycut/releases/download/win-v1.12.4/EasyCut_1.12.4_x64-setup.exe"));
        for bad in [
            "https://evil.example/EasyCut_1.0_x64-setup.exe",
            "http://github.com/contenjoo/easycut/releases/download/win-v1.0/EasyCut_1.0_x64-setup.exe",
            "https://github.com/contenjoo/easycut/releases/download/v1.0/EasyCut_1.0_x64-setup.exe",
            "https://github.com/contenjoo/easycut/releases/download/win-v1.0/EasyCut_1.0_x64.msi",
            "https://github.com/contenjoo/easycut/releases/download/win-v1.0/../../x/EasyCut_x64-setup.exe",
            "https://github.com/contenjoo/easycut/releases/download/win-v1.0/EasyCut_x64-setup.exe?x=1",
            "https://github.com/contenjoo/easycut/releases/download/win-v1.0/a/EasyCut_x64-setup.exe",
            "https://github.com/contenjoo/easycut/releases/download/win-v1.0/_x64-setup.exe",
            "https://github.com/contenjoo/easycut/releases/download/win-v1.0@evil.example/EasyCut_x64-setup.exe",
        ] {
            assert!(!is_valid_installer_url(bad), "{bad}");
        }
    }

    #[test]
    fn non_array_response_is_an_error_and_prereleases_are_skipped() {
        let limited = json!({ "message": "API rate limit exceeded" });
        assert!(pick_release(&limited, "1.0.0").unwrap_err().contains("rate limit"));
        let base = "https://github.com/contenjoo/easycut/releases/download/win-v";
        let rel = |v: &str, pre: bool| json!({ "tag_name": format!("win-v{v}"), "prerelease": pre, "body": "",
            "assets": [{ "name": format!("EasyCut_{v}_x64-setup.exe"), "browser_download_url": format!("{base}{v}/EasyCut_{v}_x64-setup.exe"), "digest": "sha256:ABCD" }] });
        let list = json!([rel("2.0.0", true), rel("1.5.0", false), rel("0.9.0", false)]);
        let r = pick_release(&list, "1.0.0").unwrap();
        assert_eq!(r["version"], "1.5.0");
        assert_eq!(digests().lock().unwrap().get(r["url"].as_str().unwrap()).map(String::as_str), Some("abcd"));
        assert!(pick_release(&list, "1.5.0").unwrap().is_null());
    }
}
