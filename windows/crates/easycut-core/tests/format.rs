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
    assert_eq!(
        p.assets[0].original_path.as_deref(),
        Some("/Users/me/Movies/강의.mkv")
    );
    assert_eq!(p.captions[0].text, "안녕하세요 여러분");
    assert!(p.tracks[2].clips[0].kind == ClipKind::Text);
    assert!(p.tracks[2].clips[0].asset_id.is_none());
    assert_eq!(p.caption_style.font_name, "Apple SD Gothic Neo");
    assert!((p.duration() - 10.0).abs() < 1e-9);

    let ours: Value = serde_json::from_str(&p.to_json().unwrap()).unwrap();
    let theirs: Value = serde_json::from_str(MAC_SAMPLE).unwrap();
    assert_eq!(
        canon(ours),
        canon(theirs),
        "다시 저장한 JSON이 맥 파일과 같아야 함"
    );
}

#[test]
fn writes_uppercase_ids_and_sorted_keys() {
    let p = Project::default();
    let json = p.to_json().unwrap();
    let id = p.tracks[0].id.to_string();
    assert_eq!(id, id.to_uppercase());
    assert!(json.contains(&format!("\"id\":\"{id}\"")));
    let keys: Vec<String> = serde_json::from_str::<Value>(&json)
        .unwrap()
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    let mut sorted = keys.clone();
    sorted.sort();
    assert_eq!(keys, sorted);
    assert!(json.starts_with("{\"assets\""));
}

#[test]
fn tolerates_missing_keys() {
    let p = Project::from_json(r#"{"tracks":[{"name":"T","clips":[{"start":1,"sourceOut":2}]}]}"#)
        .unwrap();
    let c = &p.tracks[0].clips[0];
    assert_eq!((c.speed, c.volume, c.duration()), (1.0, 1.0, 2.0));
    assert_eq!(p.canvas_width, 1920.0);
    assert!(p.show_captions);
}

/// 맥 앱 1.4~1.7에서 생긴 항목(그룹, 모양, 인물 배경, 클릭 기록)은 이 코어가 몰라도 저장할 때 그대로 남아야 한다
#[test]
fn keeps_fields_from_newer_mac_versions() {
    let json = r#"{
      "version": 1,
      "assets": [{"id": "11111111-1111-1111-1111-111111111111", "path": "/a.mp4", "name": "a", "kind": "video",
                  "duration": 10, "width": 1920, "height": 1080, "hasAudio": true,
                  "clicks": [{"t": 1.5, "x": 0.2, "y": 0.3}]}],
      "tracks": [{"id": "22222222-2222-2222-2222-222222222222", "name": "트랙 1", "clips": [
          {"id": "33333333-3333-3333-3333-333333333333", "kind": "media", "assetID": "11111111-1111-1111-1111-111111111111",
           "start": 0, "sourceIn": 0, "sourceOut": 10, "groupID": "44444444-4444-4444-4444-444444444444",
           "shape": "circle", "backgroundEffect": "blur", "showClicks": true}]}],
      "captions": []
    }"#;
    let p = easycut_core::Project::from_json(json).expect("parse");
    let out: serde_json::Value = serde_json::from_str(&p.to_json().expect("save")).unwrap();
    let clip = &out["tracks"][0]["clips"][0];
    assert_eq!(clip["groupID"], "44444444-4444-4444-4444-444444444444");
    assert_eq!(clip["shape"], "circle");
    assert_eq!(clip["backgroundEffect"], "blur");
    assert_eq!(clip["showClicks"], true);
    assert_eq!(out["assets"][0]["clicks"][0]["t"], 1.5);
}
