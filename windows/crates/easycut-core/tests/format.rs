//! `.easycut` 파일 형식 호환성 (맥 앱이 저장한 파일 기준)

use easycut_core::*;
use serde_json::Value;

const MAC_SAMPLE: &str = include_str!("fixtures/mac-sample.easycut");

/// 숫자 표현 차이(10 vs 10.0)를 없애 비교한다
fn canon(v: Value) -> Value {
    match v {
        Value::Number(n) => serde_json::json!(n.as_f64().unwrap()),
        Value::Array(a) => Value::Array(a.into_iter().map(canon).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, canon(v))).collect()),
        other => other,
    }
}

#[test]
fn reads_mac_file_and_writes_identical_json() {
    let p = Project::from_json(MAC_SAMPLE).unwrap();
    assert_eq!(p.assets.len(), 2);
    assert_eq!(p.assets[0].words.as_ref().unwrap().len(), 2);
    assert_eq!(p.assets[0].original_path.as_deref(), Some("/Users/me/Movies/강의.mkv"));
    assert_eq!(p.captions[0].text, "안녕하세요 여러분");
    assert!(p.tracks[2].clips[0].kind == ClipKind::Text);
    assert!(p.tracks[2].clips[0].asset_id.is_none());
    assert_eq!(p.caption_style.font_name, "Apple SD Gothic Neo");
    assert!((p.duration() - 10.0).abs() < 1e-9);

    let ours: Value = serde_json::from_str(&p.to_json().unwrap()).unwrap();
    let theirs: Value = serde_json::from_str(MAC_SAMPLE).unwrap();
    assert_eq!(canon(ours), canon(theirs), "다시 저장한 JSON이 맥 파일과 같아야 함");
}

#[test]
fn writes_uppercase_ids_and_sorted_keys() {
    let p = Project::default();
    let json = p.to_json().unwrap();
    let id = p.tracks[0].id.to_string();
    assert_eq!(id, id.to_uppercase());
    assert!(json.contains(&format!("\"id\":\"{id}\"")));
    let keys: Vec<String> = serde_json::from_str::<Value>(&json).unwrap().as_object().unwrap().keys().cloned().collect();
    let mut sorted = keys.clone();
    sorted.sort();
    assert_eq!(keys, sorted);
    assert!(json.starts_with("{\"assets\""));
}

#[test]
fn tolerates_missing_keys() {
    let p = Project::from_json(r#"{"tracks":[{"name":"T","clips":[{"start":1,"sourceOut":2}]}]}"#).unwrap();
    let c = &p.tracks[0].clips[0];
    assert_eq!((c.speed, c.volume, c.duration()), (1.0, 1.0, 2.0));
    assert_eq!(p.canvas_width, 1920.0);
    assert!(p.show_captions);
}
