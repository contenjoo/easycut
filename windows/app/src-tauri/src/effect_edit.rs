//! UI와 AI/MCP가 함께 쓰는 효과 입력 검증. 모든 필드를 확인한 복사본만 편집기에 반영한다.
use easycut_core::{Clip, ClipKind, Id, MediaKind, Project, TextStyle, TransitionSettings};
use easycut_core::effects::{TRANSITIONS, TEXT_ANIMATIONS, VISUAL_FILTERS};
use serde_json::Value;
use std::collections::HashMap;

fn duration(value: &Value, label: &str, max: f64) -> Result<Option<f64>, String> {
    if value.is_null() { return Ok(None); }
    let v = value.as_f64().filter(|v| v.is_finite() && (0.0..=max).contains(v))
        .ok_or_else(|| format!("{label}: 0~{max} 범위로 입력하세요"))?;
    Ok(Some(v))
}

fn choice(value: &Value, allowed: &[&str], label: &str) -> Result<Option<String>, String> {
    if value.is_null() { return Ok(None); }
    let value = value.as_str().filter(|v| allowed.contains(v))
        .ok_or_else(|| format!("{label}: 지원하지 않는 효과입니다"))?;
    Ok((value != "none").then(|| value.to_string()))
}

pub fn prepare_style(current: &TextStyle, value: &Value) -> Result<TextStyle, String> {
    let fields = value.as_object().ok_or("글자 스타일은 객체로 입력하세요")?;
    if let Some(v) = fields.get("animation") { choice(v, TEXT_ANIMATIONS, "텍스트 효과")?; }
    if let Some(v) = fields.get("animationDuration") { duration(v, "효과 시간", 10.0)?; }
    let mut merged = serde_json::to_value(current).map_err(|e| e.to_string())?;
    for (key, value) in fields { merged.as_object_mut().unwrap().insert(key.clone(), value.clone()); }
    let mut style: TextStyle = serde_json::from_value(merged).map_err(|e| format!("글자 스타일 오류: {e}"))?;
    if style.animation.as_deref() == Some("none") { style.animation = None; }
    Ok(style)
}

fn transition(value: &Value) -> Result<Option<TransitionSettings>, String> {
    if value.is_null() { return Ok(None); }
    let settings: TransitionSettings = serde_json::from_value(value.clone()).map_err(|e| format!("전환 설정 오류: {e}"))?;
    if !TRANSITIONS.contains(&settings.effect.as_str()) { return Err("지원하지 않는 전환 효과입니다".into()); }
    if !settings.duration.is_finite() || !(0.0..=10.0).contains(&settings.duration) { return Err("전환 시간은 0~10초로 입력하세요".into()); }
    Ok((settings.effect != "none").then_some(settings))
}

pub fn prepare_clip(project: &Project, id: Id, props: &HashMap<String, Value>) -> Result<Clip, String> {
    let mut clip = project.clip(id).cloned().ok_or("클립을 찾지 못했습니다")?;
    let visual = clip.kind == ClipKind::Text || project.asset(clip.asset_id).is_some_and(|a| a.kind != MediaKind::Audio);
    let media_visual = clip.kind == ClipKind::Media && project.asset(clip.asset_id).is_some_and(|a| a.kind != MediaKind::Audio);
    for (key, value) in props {
        let number = value.as_f64().filter(|v| v.is_finite());
        match key.as_str() {
            "transitionIn" | "transitionOut" => {
                let settings = transition(value)?;
                if settings.is_some() && !visual { return Err("전환은 영상·사진·텍스트에 적용할 수 있습니다".into()); }
                if key == "transitionIn" { clip.transition_in = settings; } else { clip.transition_out = settings; }
            }
            "visualFilter" => {
                let filter = choice(value, VISUAL_FILTERS, "색감 필터")?;
                if filter.is_some() && !media_visual { return Err("색감 필터는 영상과 사진에 적용할 수 있습니다".into()); }
                clip.visual_filter = filter;
            }
            "filterIntensity" => {
                if !media_visual { return Err("색감 필터는 영상과 사진에 적용할 수 있습니다".into()); }
                clip.filter_intensity = duration(value, "필터 강도", 1.0)?;
            }
            "textStyle" => { clip.text_style = prepare_style(&clip.text_style, value)?; }
            "volume" => { if let Some(v) = number { clip.volume = v.clamp(0.0, 4.0); } }
            "opacity" => { if let Some(v) = number { clip.opacity = v.clamp(0.0, 1.0); } }
            "scale" => { if let Some(v) = number { clip.scale = v.clamp(0.05, 8.0); } }
            "offsetX" => { if let Some(v) = number { clip.offset_x = v; } }
            "offsetY" => { if let Some(v) = number { clip.offset_y = v; } }
            "fadeIn" => { if let Some(v) = number { clip.fade_in = v.max(0.0); } }
            "fadeOut" => { if let Some(v) = number { clip.fade_out = v.max(0.0); } }
            "text" => { clip.text = value.as_str().unwrap_or("").to_string(); }
            "shape" | "backgroundEffect" | "showClicks" => {
                if value.is_null() || value.as_str() == Some("none") || value.as_bool() == Some(false) { clip.extra.remove(key); }
                else { clip.extra.insert(key.clone(), value.clone()); }
            }
            _ => {}
        }
    }
    Ok(clip)
}

/// AI 입력을 UI와 같은 JSON 필드로 변환한다. 생략한 필드는 변경하지 않는다.
pub fn ai_props(input: &Value, current: &Clip) -> HashMap<String, Value> {
    let mut props = HashMap::new();
    for (from, to) in [("volume","volume"),("opacity","opacity"),("scale","scale"),("offset_x","offsetX"),("offset_y","offsetY"),("fade_in","fadeIn"),("fade_out","fadeOut"),("text","text"),("visual_filter","visualFilter"),("filter_intensity","filterIntensity")] {
        if let Some(value) = input.get(from) { props.insert(to.into(), value.clone()); }
    }
    for (effect_key, duration_key, key, current) in [("transition_in","transition_in_duration","transitionIn",&current.transition_in),("transition_out","transition_out_duration","transitionOut",&current.transition_out)] {
        if input.get(effect_key).is_some() || input.get(duration_key).is_some() {
            let mut value = serde_json::to_value(current.clone().unwrap_or_default()).unwrap();
            if let Some(effect) = input.get(effect_key) { value["effect"] = effect.clone(); }
            if let Some(duration) = input.get(duration_key) { value["duration"] = duration.clone(); }
            props.insert(key.into(), value);
        }
    }
    if current.kind == ClipKind::Text && (input.get("text_animation").is_some() || input.get("animation_duration").is_some()) {
        props.insert("textStyle".into(), ai_style_props(input));
    }
    props
}

pub fn ai_style_props(input: &Value) -> Value {
    let mut props = serde_json::Map::new();
    if let Some(value) = input.get("text_animation") { props.insert("animation".into(), value.clone()); }
    if let Some(value) = input.get("animation_duration") { props.insert("animationDuration".into(), value.clone()); }
    Value::Object(props)
}

pub fn validate_ai(input: &Value) -> Result<(), String> {
    for key in ["transition_in", "transition_out"] {
        if let Some(value) = input.get(key) { choice(value, TRANSITIONS, key)?; }
    }
    if let Some(value) = input.get("text_animation") { choice(value, TEXT_ANIMATIONS, "text_animation")?; }
    if let Some(value) = input.get("visual_filter") { choice(value, VISUAL_FILTERS, "visual_filter")?; }
    for key in ["transition_in_duration", "transition_out_duration", "animation_duration"] {
        if let Some(value) = input.get(key) { duration(value, key, 10.0)?; }
    }
    if let Some(value) = input.get("filter_intensity") { duration(value, "filter_intensity", 1.0)?; }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn props(value: Value) -> HashMap<String, Value> { serde_json::from_value(value).unwrap() }

    #[test]
    fn validates_the_entire_clip_edit_before_mutation() {
        let mut project = Project::default();
        let id = project.insert_text("한글 👩‍🏫", 1, 0.0, 3.0);
        let before = project.clone();
        for invalid in [json!({"opacity":0.2,"transitionIn":{"effect":"missing","duration":0.5}}),
                        json!({"opacity":0.2,"transitionOut":{"effect":"fade","duration":-1}}),
                        json!({"opacity":0.2,"textStyle":{"animation":"missing"}}),
                        json!({"opacity":0.2,"textStyle":{"animationDuration":11}})] {
            assert!(prepare_clip(&project, id, &props(invalid)).is_err());
            assert_eq!(project, before);
        }
        let updated = prepare_clip(&project, id, &props(json!({"transitionIn":{"effect":"iris","duration":0.5},
            "transitionOut":{"effect":"flip","duration":0.4},"textStyle":{"animation":"typewriter","animationDuration":0.6}}))).unwrap();
        assert_eq!(updated.text_style.font_size, before.clip(id).unwrap().text_style.font_size);
        assert_eq!(updated.transition_in.unwrap().effect, "iris");
        assert_eq!(updated.text_style.animation.as_deref(), Some("typewriter"));
    }

    #[test]
    fn text_style_partial_updates_preserve_font_and_future_fields_and_clear_effects() {
        let style: TextStyle = serde_json::from_value(json!({"fontName":"Pretendard", "fontSize":72,"futureText":{"enabled":true},"animation":"bounce"})).unwrap();
        let updated = prepare_style(&style, &json!({"animation":null,"bold":false})).unwrap();
        assert_eq!(updated.font_name, "Pretendard");
        assert_eq!(updated.font_size, 72.0);
        assert!(!updated.bold);
        assert_eq!(updated.animation, None);
        assert_eq!(serde_json::to_value(updated).unwrap()["futureText"]["enabled"], true);
    }

    #[test]
    fn media_filter_validation_and_null_clear_match_the_ui() {
        let mut project = Project::default();
        let mut asset = easycut_core::MediaAsset::default();
        asset.kind = MediaKind::Image;
        project.assets.push(asset.clone());
        let id = project.insert(&asset, 0, 0.0, 3.0);
        for invalid in [json!({"visualFilter":"invalid"}),json!({"filterIntensity":-0.1}),json!({"filterIntensity":1.1})] {
            assert!(prepare_clip(&project,id,&props(invalid)).is_err());
        }
        let filtered = prepare_clip(&project,id,&props(json!({"visualFilter":"vintage","filterIntensity":0.65}))).unwrap();
        assert_eq!(filtered.visual_filter.as_deref(),Some("vintage"));
        *project.clip_mut(id).unwrap() = filtered;
        let clear = prepare_clip(&project,id,&props(json!({"visualFilter":null,"filterIntensity":null}))).unwrap();
        assert!(clear.visual_filter.is_none() && clear.filter_intensity.is_none());
        let text = project.insert_text("색상 유지",1,0.0,3.0);
        assert!(prepare_clip(&project,text,&props(json!({"visualFilter":"mono"}))).is_err());
    }

    #[test]
    fn ai_uses_the_same_validated_effect_properties() {
        let mut project=Project::default();
        let id=project.insert_text("한글",1,0.0,3.0);
        let input=json!({"transition_in":"rotate","transition_in_duration":0.4,"text_animation":"bounce","animation_duration":0.6});
        validate_ai(&input).unwrap();
        let updated=prepare_clip(&project,id,&ai_props(&input,project.clip(id).unwrap())).unwrap();
        assert_eq!(updated.transition_in.unwrap().effect,"rotate");
        assert_eq!(updated.text_style.animation.as_deref(),Some("bounce"));
        for invalid in [json!({"text_animation":"bad"}),json!({"filter_intensity":2}),json!({"transition_out_duration":-1})] {
            assert!(validate_ai(&invalid).is_err());
        }
    }
}
