//! 설치된 실제 글꼴 계열. 다운로드나 사용 권한 요청 없이 시스템 목록만 읽는다.
use serde::Serialize;
use std::collections::BTreeSet;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FontFamily {
    pub family: String,
    pub font_name: String,
    pub display_name: String,
}

fn catalog(names: BTreeSet<String>) -> Vec<FontFamily> {
    names.into_iter().filter(|name| !name.trim().is_empty() && !name.starts_with('@'))
        .map(|family| FontFamily { font_name: family.clone(), display_name: family.clone(), family }).collect()
}

#[cfg(windows)]
pub fn installed() -> Result<Vec<FontFamily>, String> {
    use windows_sys::Win32::Graphics::Gdi::*;
    unsafe extern "system" fn collect(font: *const LOGFONTW, _: *const TEXTMETRICW, _: u32, data: isize) -> i32 {
        if !font.is_null() {
            let face = &(*font).lfFaceName;
            let length = face.iter().position(|&c| c == 0).unwrap_or(face.len());
            let name = String::from_utf16_lossy(&face[..length]);
            (*(data as *mut BTreeSet<String>)).insert(name);
        }
        1
    }
    let mut names = BTreeSet::new();
    unsafe {
        let dc = GetDC(std::ptr::null_mut());
        if dc.is_null() { return Err("설치된 글꼴 목록을 읽지 못했습니다. 다시 시도하세요.".into()); }
        let mut query: LOGFONTW = std::mem::zeroed();
        query.lfCharSet = DEFAULT_CHARSET;
        EnumFontFamiliesExW(dc, &query, Some(collect), &mut names as *mut _ as isize, 0);
        ReleaseDC(std::ptr::null_mut(), dc);
    }
    if names.is_empty() { return Err("설치된 글꼴 목록이 비어 있습니다. 다시 시도하세요.".into()); }
    Ok(catalog(names))
}

/// macOS/Linux의 개발·검사에서는 fontconfig가 보고하는 실제 계열을 사용한다.
#[cfg(not(windows))]
pub fn installed() -> Result<Vec<FontFamily>, String> {
    let output = std::process::Command::new("fc-list").args(["--format", "%{family}\\n"]).output()
        .map_err(|_| "이 개발 환경에서 설치 글꼴 목록을 읽을 수 없습니다.".to_string())?;
    if !output.status.success() { return Err("설치 글꼴 목록을 읽지 못했습니다.".into()); }
    let names = String::from_utf8_lossy(&output.stdout).lines().flat_map(|line| line.split(','))
        .map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect();
    Ok(catalog(names))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn families_are_real_names_sorted_and_vertical_faces_excluded() {
        let fonts = catalog(["맑은 고딕", "@맑은 고딕", "", "Pretendard", "맑은 고딕"].into_iter().map(str::to_string).collect());
        assert_eq!(fonts.len(), 2);
        assert!(fonts.iter().all(|f| f.family == f.font_name && f.family == f.display_name));
        assert_eq!(fonts[0].family, "Pretendard");
    }
    #[test]
    fn windows_system_font_catalog_is_not_a_preset_list() {
        if cfg!(windows) {
            let fonts = installed().expect("Windows font enumeration");
            assert!(!fonts.is_empty());
            assert!(fonts.iter().any(|f| f.family.contains("Segoe") || f.family.contains("Arial") || f.family.contains("고딕")));
        }
    }
}
