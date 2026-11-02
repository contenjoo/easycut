//! macOS와 공유하는 효과 식별자. 모델은 알 수 없는 미래 문자열도 손실 없이 보존한다.
pub const TRANSITIONS: &[&str] = &["none", "fade", "slideLeft", "slideRight", "slideUp", "slideDown", "wipeLeft", "wipeRight", "zoom", "wipeUp", "wipeDown", "zoomOut", "rotate", "blur", "pixelate", "iris", "squeeze", "flip", "slideDiagonal"];
pub const TEXT_ANIMATIONS: &[&str] = &["none", "fade", "slideUp", "slideDown", "pop", "typewriter", "bounce", "zoomIn", "zoomOut", "rotateIn", "blurIn", "wipeRight", "wipeUp", "scaleX", "float", "shake"];
pub const VISUAL_FILTERS: &[&str] = &["none", "warm", "cool", "mono", "sepia", "vivid", "soft", "vintage", "dramatic", "noir"];

#[cfg(test)]
mod tests {
    use crate::*;
    use std::collections::HashSet;

    #[test]
    fn optional_effects_roundtrip_future_fields_and_split_join() {
        let mut p = Project::default();
        let asset = MediaAsset { duration: 4.0, ..MediaAsset::default() };
        p.assets.push(asset.clone());
        let id = p.insert(&asset, 0, 0.0, 5.0);
        let c = p.clip_mut(id).unwrap();
        c.transition_in = Some(TransitionSettings { effect: "iris".into(), duration: 0.4, ..Default::default() });
        c.transition_out = Some(TransitionSettings { effect: "flip".into(), duration: 0.3, ..Default::default() });
        c.visual_filter = Some("vintage".into()); c.filter_intensity = Some(0.7);
        c.text_style.animation = Some("typewriter".into()); c.text_style.animation_duration = Some(0.6);
        c.text_style.extra.insert("futureStyle".into(), serde_json::json!({"a":1}));
        c.transition_in.as_mut().unwrap().extra.insert("futureTransition".into(), serde_json::json!(true));
        let original = p.clone();
        assert_eq!(Project::from_json(&p.to_json().unwrap()).unwrap(), p);
        let right = p.split(id, 2.0).unwrap();
        assert!(p.clip(id).unwrap().transition_out.is_none());
        assert!(p.clip(right).unwrap().transition_in.is_none());
        assert_eq!(p.clip(right).unwrap().transition_out, original.clip(id).unwrap().transition_out);
        assert_eq!(p.join(&HashSet::from([id, right])).0, 1);
        assert_eq!(p.clip(id), original.clip(id));
        let right = p.split(id, 2.0).unwrap();
        p.clip_mut(right).unwrap().visual_filter = Some("cool".into());
        assert_eq!(p.join(&HashSet::from([id, right])).0, 0);
        let old: TextStyle = serde_json::from_str("{}").unwrap();
        assert_eq!(old.animation, None); assert_eq!(old.animation_duration, None);
        let future: TextStyle = serde_json::from_str(r#"{"animation":"futureEffect","futureKey":9}"#).unwrap();
        let value = serde_json::to_value(future).unwrap();
        assert_eq!(value["animation"], "futureEffect"); assert_eq!(value["futureKey"], 9);
    }
}
