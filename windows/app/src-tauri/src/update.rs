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

/// 가장 새 윈도우 릴리스 (없거나 지금 버전 이하면 null)
pub fn check() -> Result<Value, String> {
    let out = tools::command(&curl())
        .args(["-sL", "--max-time", "15", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/contenjoo/easycut/releases?per_page=30"])
        .output()
        .map_err(|e| e.to_string())?;
    let list: Value = serde_json::from_slice(&out.stdout).map_err(|_| "업데이트를 확인하지 못했습니다.".to_string())?;
    let best = list.as_array().into_iter().flatten()
        .filter(|r| r["tag_name"].as_str().is_some_and(|t| t.starts_with("win-v")))
        .filter_map(|r| {
            let tag = r["tag_name"].as_str()?;
            let asset = r["assets"].as_array()?.iter().find(|a| a["name"].as_str().is_some_and(|n| n.ends_with("setup.exe")))?;
            Some((tag.trim_start_matches("win-v").to_string(), asset["browser_download_url"].as_str()?.to_string(), r["body"].as_str().unwrap_or("").to_string()))
        })
        .max_by(|a, b| if is_newer(&a.0, &b.0) { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Less });
    Ok(match best {
        Some((v, url, notes)) if is_newer(&v, CURRENT) => json!({ "version": v, "url": url, "notes": notes, "current": CURRENT }),
        _ => Value::Null,
    })
}

/// 설치 파일을 받아 실행 (실행 후 앱은 스스로 종료)
pub fn install(url: &str) -> Result<(), String> {
    let dest = tools::temp_dir().join("EasyCut-setup.exe");
    let status = tools::command(&curl()).args(["-sL", "--fail", "-o"]).arg(&dest).arg(url).status().map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("업데이트 파일을 받지 못했습니다.".into());
    }
    std::process::Command::new(&dest).spawn().map_err(|e| format!("설치 파일을 실행하지 못했습니다: {e}"))?;
    Ok(())
}
