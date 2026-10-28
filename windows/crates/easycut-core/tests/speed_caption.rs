use easycut_core::*;
use std::collections::HashSet;

fn fixture() -> (Project, Id) {
    let mut p = Project::default();
    let a = MediaAsset { duration: 12.0, has_audio: true, kind: MediaKind::Video, ..Default::default() };
    p.assets.push(a.clone());
    let first = p.insert(&a, 0, 0.0, 5.0);
    let middle = p.split(first, 4.0).unwrap();
    p.split(middle, 8.0);
    p.captions = vec![Caption::new(1.0, 1.4, "before"), Caption::new(4.5, 4.9, "inside"), Caption::new(8.5, 8.9, "after")];
    (p, middle)
}
fn near(a: f64, b: f64) { assert!((a-b).abs()<1e-8, "{a} != {b}"); }

#[test]
fn partial_speed_maps_captions_and_restores() {
    let (mut p, id) = fixture();
    let original = p.clone();
    p.set_speed(id, 2.0);
    near(p.duration(), 10.0); near(p.captions[0].start, 1.0);
    near(p.captions[1].start, 4.25); near(p.captions[1].end, 4.45);
    near(p.captions[2].start, 6.5); near(p.captions[2].end, 6.9);
    assert_eq!(p.captions[1].id, original.captions[1].id);
    p.set_speed(id, 1.0);
    for (a,b) in p.captions.iter().zip(&original.captions) { near(a.start,b.start); near(a.end,b.end); }
    p.set_speed(id, 0.5);
    near(p.captions[1].start,5.0); near(p.captions[2].start,12.5);
}
#[test]
fn captions_crossing_boundaries_are_continuous() {
    let (mut p, id) = fixture();
    p.captions = vec![Caption::new(3.0,5.0,"a"),Caption::new(7.0,9.0,"b")];
    p.set_speed(id,2.0);
    near(p.captions[0].start,3.0); near(p.captions[0].end,4.5);
    near(p.captions[1].start,5.5); near(p.captions[1].end,7.0);
}
#[test]
fn batch_speed_is_order_independent() {
    let (mut p,_) = fixture();
    let original=p.captions.clone();
    let ids:HashSet<Id>=p.tracks[0].clips.iter().map(|c| c.id).collect();
    p.set_speeds(&ids,2.0);
    for (a,b) in p.captions.iter().zip(original) { near(a.start,b.start/2.0); near(a.end,b.end/2.0); }
}
#[test]
fn overlapping_tracks_do_not_double_retime_captions() {
    let (mut p,id)=fixture();
    let mut other=p.tracks[0].clips[1].clone(); other.id=Id::new();
    p.tracks[1].clips.push(other.clone());
    p.set_speeds(&HashSet::from([id,other.id]),2.0);
    near(p.captions[1].start,4.25); near(p.captions[2].start,6.5);
}
#[test]
fn silent_overlay_and_noop_leave_captions_unchanged() {
    let (mut p,id)=fixture(); let original=p.clone();
    p.set_speed(id,1.0); p.set_speed(id,f64::NAN); assert_eq!(p,original);
    let mut silent=p.assets[0].clone(); silent.id=Id::new(); silent.has_audio=false;
    let mut overlay=p.tracks[0].clips[1].clone(); overlay.id=Id::new(); overlay.asset_id=Some(silent.id);
    p.assets.push(silent); p.tracks[1].clips.push(overlay.clone());
    p.set_speed(overlay.id,2.0); assert_eq!(p.captions,original.captions);
}
