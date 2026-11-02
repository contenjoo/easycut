use super::*;
use easycut_core::{Clip,MediaAsset,TransitionSettings};
use std::path::{Path,PathBuf};
use std::process::Command;

fn difference(a:&[u8],b:&[u8])->f64{
    assert_eq!(a.len(),b.len());
    a.iter().zip(b).map(|(a,b)|(*a as f64-*b as f64).abs()).sum::<f64>()/a.len()as f64/255.0
}
fn render(p:&Project,dir:&Path,key:&str,ffmpeg:&Path)->Vec<Vec<u8>>{
    let path=dir.join(format!("{key}.mp4"));
    export(p,&Options{path:path.to_string_lossy().into_owned(),height:0,burn_captions:true,format:"mp4".into(),range:None},|_|{},||false).unwrap_or_else(|e|panic!("{key}: {e}"));
    let out=Command::new(ffmpeg).args(["-v","error","-i"]).arg(path).args(["-f","rawvideo","-pix_fmt","rgb24","pipe:1"]).output().unwrap();
    assert!(out.status.success(),"{key}: {}",String::from_utf8_lossy(&out.stderr));
    let frames:Vec<_>=out.stdout.chunks_exact(160*90*3).map(|f|f.to_vec()).collect();
    assert_eq!(frames.len(),12,"{key}: output duration/fps");
    frames
}

#[test]
fn ass_layout_keeps_grapheme_clusters_and_all_effect_names_are_handled(){
    let mut style=TextStyle::title();style.animation=Some("typewriter".into());
    let events=effects::ass_events("T",&style,"한👩‍🏫글",0.0,2.0,80.0,45.0,160,90,10.0,0,1.0,0.0,0.0);
    assert!(events.contains("한👩‍🏫{\\alpha&HFF&}글"));
    assert!(!events.contains("👩{\\alpha&HFF&}"));
    assert!(!events.contains("👩‍{\\alpha&HFF&}"));
    assert_eq!(style_font(&TextStyle{font_name:"Source-Sans-3".into(),..Default::default()}),"Source-Sans-3");
    for name in easycut_core::effects::VISUAL_FILTERS.iter().filter(|n|**n!="none"){
        assert!(!effects::filter_chain(Some(name),None,90).is_empty(),"{name}");
        assert!(effects::filter_chain(Some(name),Some(0.0),90).is_empty(),"{name}");
    }
}

/// Opt in on a host with FFmpeg/libass. Actual output pixels, duration, completed states and intensity0 are checked.
#[test]
fn real_ffmpeg_exports_all_effects(){
    let Some(ffmpeg)=std::env::var_os("EASYCUT_EFFECT_FFMPEG").map(PathBuf::from) else{eprintln!("set EASYCUT_EFFECT_FFMPEG for real export verification");return;};
    assert!(has_subtitles_filter(&ffmpeg),"test FFmpeg must include libass");
    let dir=std::env::temp_dir().join(format!("easycut-export-effects-{}",std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let source=dir.join("fixture.png");
    let result=Command::new(&ffmpeg).args(["-y","-v","error","-f","lavfi","-i","testsrc2=s=160x90:r=10","-frames:v","1"]).arg(&source).output().unwrap();
    assert!(result.status.success(),"fixture: {}",String::from_utf8_lossy(&result.stderr));
    let mut project=Project::default();project.canvas_width=160.0;project.canvas_height=90.0;project.fps=10.0;
    let asset=MediaAsset{path:source.to_string_lossy().into_owned(),kind:MediaKind::Image,width:160.0,height:90.0,..Default::default()};
    project.assets.push(asset.clone());project.insert(&asset,0,0.0,1.2);
    let baseline=render(&project,&dir,"baseline",&ffmpeg);
    for name in easycut_core::effects::TRANSITIONS.iter().filter(|n|**n!="none"){
        let mut p=project.clone();let c=&mut p.tracks[0].clips[0];
        let settings=TransitionSettings{effect:(*name).into(),duration:0.4,..Default::default()};
        c.transition_in=Some(settings.clone());c.transition_out=Some(settings);
        let frames=render(&p,&dir,&format!("transition-{name}"),&ffmpeg);
        assert!(difference(&frames[1],&baseline[1])>0.005,"{name}: entrance must alter real pixels");
        assert!(difference(&frames[11],&baseline[11])>0.005,"{name}: exit must alter real pixels");
        assert!(difference(&frames[7],&baseline[7])<0.02,"{name}: completed state");
    }
    for name in easycut_core::effects::VISUAL_FILTERS.iter().filter(|n|**n!="none"){
        let mut p=project.clone();p.tracks[0].clips[0].visual_filter=Some((*name).into());
        let frames=render(&p,&dir,&format!("filter-{name}"),&ffmpeg);
        assert!(difference(&frames[7],&baseline[7])>0.001,"{name}: real color difference");
        p.tracks[0].clips[0].filter_intensity=Some(0.0);
        let zero=render(&p,&dir,&format!("filter-zero-{name}"),&ffmpeg);
        assert_eq!(zero,baseline,"{name}: intensity0 is exact original");
    }
    let mut text=Project{canvas_width:160.0,canvas_height:90.0,fps:10.0,..Default::default()};
    let id=text.insert_text("한글 👩‍🏫 효과",0,0.0,1.2);text.clip_mut(id).unwrap().text_style.font_size=240.0;
    let plain=render(&text,&dir,"text-baseline",&ffmpeg);
    for name in easycut_core::effects::TEXT_ANIMATIONS.iter().filter(|n|**n!="none"){
        let mut p=text.clone();p.clip_mut(id).unwrap().text_style.animation=Some((*name).into());
        let frames=render(&p,&dir,&format!("text-{name}"),&ffmpeg);
        assert!(difference(&frames[1],&plain[1])>0.0004,"{name}: actual text entrance");
        assert!(difference(&frames[7],&plain[7])<0.02,"{name}: settled text");
    }
    // A real text transition uses the same FFmpeg compositor, not ASS-only fallback.
    let mut mixed=text.clone();let c=mixed.clip_mut(id).unwrap();
    c.transition_in=Some(TransitionSettings{effect:"iris".into(),duration:0.4,..Default::default()});
    c.transition_out=Some(TransitionSettings{effect:"flip".into(),duration:0.4,..Default::default()});
    let frames=render(&mixed,&dir,"text-transitions",&ffmpeg);
    assert!(difference(&frames[1],&plain[1])>0.0004);
    assert!(difference(&frames[11],&plain[11])>0.0004);

    // 원본 트랙 순서: 아래 텍스트는 위의 불투명 이미지가 완전히 가려야 한다.
    let mut ordered=project.clone();
    let image=ordered.tracks[0].clips.remove(0);
    let mut title=Clip{kind:ClipKind::Text,text:"겹침 검증".into(),source_out:1.2,..Default::default()};
    title.text_style.font_size=240.0;
    ordered.tracks[0].clips.push(title);
    ordered.tracks[1].clips.push(image);
    let covered=render(&ordered,&dir,"order-text-under-image",&ffmpeg);
    assert!(difference(&covered[7],&baseline[7])<0.015,"higher opaque media covers lower text");
    ordered.tracks.swap(0,1);
    let visible=render(&ordered,&dir,"order-text-over-image",&ffmpeg);
    assert!(difference(&visible[7],&baseline[7])>0.001,"higher text covers lower media");
    ordered.tracks[1].hidden=true;
    let hidden=render(&ordered,&dir,"order-hidden-text",&ffmpeg);
    assert!(difference(&hidden[7],&baseline[7])<0.015,"hidden text contributes no pixels");

    // 클릭은 원본 클립 안에서 움직이며 전체 자막을 덮지 않는다.
    let mut clicked=project.clone();
    clicked.assets[0].extra.insert("clicks".into(),serde_json::json!([{"t":0.1,"x":0.5,"y":0.5}]));
    clicked.tracks[0].clips[0].extra.insert("showClicks".into(),serde_json::json!(true));
    clicked.caption_style.font_size=280.0;clicked.caption_style.position_y=0.5;
    clicked.caption_style.background_color=Rgba::CLEAR;clicked.caption_style.outline=false;
    clicked.captions.push(easycut_core::Caption::new(0.0,1.2,"██████"));
    let with_click=render(&clicked,&dir,"caption-over-click",&ffmpeg);
    clicked.tracks[0].clips[0].extra.remove("showClicks");
    let caption_only=render(&clicked,&dir,"caption-without-click",&ffmpeg);
    let mut checked=0;
    for y in 36..54{for x in 66..94{
        let i=(y*160+x)*3;
        let a=&caption_only[3][i..i+3];let b=&with_click[3][i..i+3];
        if a.iter().all(|v|*v>245){assert!(b.iter().all(|v|*v>230),"click must remain below opaque caption");checked+=1;}
    }}
    assert!(checked>10,"caption test must cover click center with opaque glyphs");

    // 작은 PIP는 전체 캔버스가 아닌 자신의 경계부터 와이프/원형 전환이 시작한다.
    let mut pip=project.clone();let c=&mut pip.tracks[0].clips[0];
    c.scale=0.25;c.offset_x=0.33;c.offset_y=0.32;
    let settled_pip=render(&pip,&dir,"pip-static",&ffmpeg);
    let energy=|frame:&[u8]|frame.iter().map(|v|*v as f64).sum::<f64>()/frame.len()as f64/255.0;
    pip.tracks[0].clips[0].transition_in=Some(TransitionSettings{effect:"wipeRight".into(),duration:0.4,..Default::default()});
    let wipe=render(&pip,&dir,"pip-wipe",&ffmpeg);
    assert!(energy(&wipe[1])>0.0008,"PIP wipe reveals its own left edge before canvas wipe would reach it");
    pip.tracks[0].clips[0].transition_in.as_mut().unwrap().effect="iris".into();
    let iris=render(&pip,&dir,"pip-iris",&ffmpeg);
    assert!(energy(&iris[1])<energy(&settled_pip[1])*0.5,"PIP iris radius follows PIP size");
    eprintln!("real FFmpeg effects outputs: {}",dir.display());
}
