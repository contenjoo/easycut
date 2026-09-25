//! macOS 앱 `SelfTest.testTimelineOps`와 대본 편집 검사를 옮긴 것.

use easycut_core::*;
use std::collections::HashSet;

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-6
}

fn video(duration: f64) -> MediaAsset {
    MediaAsset {
        path: "/tmp/x.mp4".into(),
        name: "x".into(),
        kind: MediaKind::Video,
        duration,
        width: 1920.0,
        height: 1080.0,
        has_audio: true,
        ..MediaAsset::default()
    }
}

#[test]
fn timeline_ops_match_selftest() {
    let mut p = Project::default();
    let a = video(10.0);
    p.assets = vec![a.clone()];
    let id = p.insert(&a, 0, 0.0, 5.0);
    assert_eq!(p.duration(), 10.0, "클립 추가: 10초");

    let right = p.split(id, 4.0).unwrap();
    assert!(
        p.tracks[0].clips.len() == 2 && p.clip(right).unwrap().source_in == 4.0,
        "분할: 4초에서 둘로"
    );

    p.delete_clips(&HashSet::from([id]), true);
    assert!(
        close(p.duration(), 6.0) && p.tracks[0].clips[0].start == 0.0,
        "리플 삭제: 뒤 클립이 당겨짐"
    );

    p.set_speed(right, 2.0);
    assert!(close(p.duration(), 3.0), "2배속: 6초 → 3초");
    p.set_speed(right, 20.0);
    assert!(close(p.duration(), 0.3), "20배속: 6초 → 0.3초");
    p.set_speed(right, 1.0);

    p.ripple_delete(1.0, 2.0);
    assert!(
        close(p.duration(), 5.0) && p.tracks[0].clips.len() == 2,
        "구간 리플 삭제 1~2초"
    );
    let second = p.tracks[0].clips[1].clone();
    assert!(
        close(second.start, 1.0) && close(second.source_in, 6.0),
        "구간 삭제 후 원본 위치 유지"
    );

    p.trim_end(second.id, 3.0, Some(10.0));
    assert!(close(p.duration(), 3.0), "끝 트림");

    let b = p.insert(&a, 0, 1.5, 5.0);
    assert!(
        p.clip(b).unwrap().start >= 1.5 && p.tracks[0].clips.len() == 3,
        "겹침 해결: 겹친 클립 밀어내기"
    );

    let mut q = Project::default();
    q.captions = vec![
        Caption::new(0.0, 2.0, "a"),
        Caption::new(3.0, 5.0, "b"),
        Caption::new(6.0, 8.0, "c"),
    ];
    q.ripple_delete(4.0, 7.0);
    assert!(
        q.captions.len() == 3
            && close(q.captions[1].end, 4.0)
            && close(q.captions[2].start, 4.0)
            && close(q.captions[2].end, 5.0),
        "자막도 함께 잘림"
    );
}

fn abc_project() -> Project {
    let a = video(10.0);
    let mut v = Project::default();
    v.assets = vec![a.clone()];
    v.insert(&a, 0, 0.0, 5.0);
    v.captions = vec![
        Caption::new(0.0, 2.0, "A"),
        Caption::new(2.2, 5.0, "B"),
        Caption::new(5.5, 9.0, "C"),
    ];
    v
}

fn texts(p: &Project) -> Vec<&str> {
    p.captions.iter().map(|c| c.text.as_str()).collect()
}

#[test]
fn caption_move_to_front() {
    let mut v = abc_project();
    let c_id = v.captions[2].id;
    let sp = v.span_of_caption(c_id).unwrap();
    v.move_range(sp.start, sp.end, 0.0);
    assert_eq!(texts(&v), ["C", "A", "B"]);
    assert!(close(v.duration(), 10.0));
    assert!(
        close(v.tracks[0].clips[0].source_in, 5.5),
        "영상도 C 구간(5.5초~)부터 시작"
    );
}

#[test]
fn caption_delete_with_media() {
    let mut w = abc_project();
    let b_span = w.span_of_caption(w.captions[1].id).unwrap();
    w.captions.retain(|c| c.text != "B");
    w.ripple_delete_ranges(&[b_span]);
    assert!(close(w.duration(), 10.0 - 3.3), "영상 3.3초 함께 삭제");
    assert_eq!(texts(&w), ["A", "C"]);
    assert!(close(w.captions[1].start, 2.2), "뒤 자막 당겨짐");
}

#[test]
fn reorder_clip_by_drag() {
    let a = video(10.0);
    let mut r = Project::default();
    r.assets = vec![a.clone()];
    let r1 = r.insert(&a, 0, 0.0, 5.0);
    r.split(r1, 4.0);
    let first = r.tracks[0].clips[0].id;
    r.reorder(first, 9.0);
    assert!(close(r.tracks[0].clips[0].source_in, 4.0));
    assert!(close(r.tracks[0].clips[1].start, 6.0));
    assert!(close(r.duration(), 10.0));
}

/// SelfTest 4) 대본 편집 → 컷 (합성 대본: 0.7초 간격 단어 12개)
fn transcript_project() -> Project {
    let words: Vec<Word> = (0..12)
        .map(|i| {
            Word::new(
                format!("단어{i}"),
                i as f64 * 0.7 + 0.2,
                i as f64 * 0.7 + 0.7,
            )
        })
        .collect();
    let mut va = video(10.0);
    va.words = Some(words);
    let mut p = Project::default();
    p.assets = vec![va.clone()];
    p.canvas_width = 1280.0;
    p.canvas_height = 720.0;
    p.insert(&va, 0, 0.0, 5.0);
    p
}

#[test]
fn delete_words_cuts_video() {
    let mut p = transcript_project();
    let before = p.duration();
    let tw = p.timeline_words();
    let del: HashSet<String> = tw[2..=4].iter().map(TimelineWord::id).collect();
    let ranges = deletion_ranges(&del, &tw);
    p.ripple_delete_ranges(&ranges);
    let removed: f64 = ranges.iter().map(TimeRange::len).sum();
    assert!(
        ((before - p.duration()) - removed).abs() < 0.01,
        "단어 3개 삭제 → {removed:.2}초 잘림"
    );
    let tw2 = p.timeline_words();
    assert_eq!(tw2.len(), tw.len() - 3);
    assert!(
        !tw2.iter().any(|w| del.contains(&w.id())),
        "삭제된 단어가 대본에서 사라짐"
    );
}

#[test]
fn transcript_silence_and_captions() {
    let mut p = transcript_project();
    // 마지막 단어(8.4초) 뒤 클립 끝(10초)까지 1.6초 무음
    let sil = p.silence_ranges(0.8, 0.15);
    assert_eq!(sil.len(), 1);
    assert!(close(sil[0].start, 8.4 + 0.15) && close(sil[0].end, 10.0));

    p.captions = p.generated_captions_default();
    assert!(!p.captions.is_empty());
    // 20자 제한: "단어0 단어1 단어2 단어3 단어4"(3*5+4=19자) + 다음 단어면 23자 → 끊김
    // 4.5초 제한: 첫 단어 0.2초 ~ 7번째 단어 끝 4.4초 이내
    assert_eq!(p.captions[0].text, "단어0 단어1 단어2 단어3 단어4");
    let srt_text = srt::make(&p.captions);
    let back = srt::parse(&srt_text);
    assert_eq!(back.len(), p.captions.len(), "SRT 저장/읽기 왕복");
    assert_eq!(back[0].text, p.captions[0].text);
    assert!((back[0].start - p.captions[0].start).abs() < 0.001);
}

#[test]
fn filler_words() {
    let mut va = video(5.0);
    va.words = Some(vec![
        Word::new("음…", 0.0, 0.4),
        Word::new("안녕하세요.", 0.5, 1.2),
        Word::new("Um,", 1.3, 1.5),
        Word::new("그래서", 1.6, 2.0),
    ]);
    let mut p = Project::default();
    p.assets = vec![va.clone()];
    p.insert(&va, 0, 0.0, 5.0);
    let ids = p.filler_word_ids();
    let tw = p.timeline_words();
    let picked: Vec<&str> = tw
        .iter()
        .filter(|w| ids.contains(&w.id()))
        .map(|w| w.word.text.as_str())
        .collect();
    assert_eq!(picked, ["음…", "Um,"]);
}

#[test]
fn srt_parse_variants() {
    let s = "\u{feff}1\r\n00:00:00.500 --> 00:00:02,000\r\n<i>내장</i> 자막\r\n둘째 줄\r\n\r\n2\r\n00:01:06,000 --> 00:01:08,250\r\n두 번째\r\n";
    let c = srt::parse(s);
    assert_eq!(c.len(), 2);
    assert!(close(c[0].start, 0.5) && close(c[0].end, 2.0));
    assert_eq!(c[0].text, "<i>내장</i> 자막\n둘째 줄");
    assert!(close(c[1].start, 66.0) && close(c[1].end, 68.25));
    assert_eq!(srt::stamp(3723.4567), "01:02:03,457");
}

#[test]
fn audio_silence_detection() {
    // 8kHz: 1초 소리, 1.5초 무음, 1초 소리, 끝 0.8초 무음
    let mut s: Vec<i16> = vec![];
    let tone = |n: usize, s: &mut Vec<i16>| {
        for i in 0..n {
            s.push(((i as f64 * 0.3).sin() * 8000.0) as i16)
        }
    };
    let quiet = |n: usize, s: &mut Vec<i16>| s.extend(std::iter::repeat(3).take(n));
    tone(8000, &mut s);
    quiet(12000, &mut s);
    tone(8000, &mut s);
    quiet(6400, &mut s);
    let db = silence::loudness(&s);
    assert_eq!(db.len(), 430);
    let th = silence::auto_threshold(&db);
    assert!((-60.0..=-25.0).contains(&th));
    let sil = silence::silences(&db, th, 0.6, 0.1);
    assert_eq!(sil.len(), 2, "{sil:?}");
    assert!(close(sil[0].start, 1.1) && close(sil[0].end, 2.4));
    assert!(
        close(sil[1].start, 3.6) && close(sil[1].end, 4.3),
        "파일 끝은 여유 없이 끝까지"
    );

    // 프로젝트 구간으로: 2배속 클립은 minSilence·padding도 2배
    let mut a = video(4.3);
    a.duration = 4.3;
    let mut p = Project::default();
    p.assets = vec![a.clone()];
    p.insert(&a, 0, 0.0, 5.0);
    let map = std::collections::HashMap::from([(a.id, db.clone())]);
    let r = p.audio_silence_ranges(
        &map,
        &silence::SilenceSettings {
            threshold: th,
            min_silence: 0.6,
            padding: 0.1,
        },
    );
    assert_eq!(r.len(), 2);
    p.tracks[0].muted = true;
    assert!(
        p.audio_silence_ranges(&map, &silence::SilenceSettings::default())
            .is_empty(),
        "음소거 트랙 제외"
    );
}

#[test]
fn whisper_chunks_cover_all() {
    // 16kHz 10초, 3~6초 조각
    let s: Vec<i16> = (0..160_000)
        .map(|i| {
            if (i / 16000) % 4 == 3 {
                0
            } else {
                ((i % 50) * 200) as i16
            }
        })
        .collect();
    let ch = whisper::chunks(&s, 3.0, 6.0);
    assert_eq!(ch.first().unwrap().start, 0);
    assert_eq!(ch.last().unwrap().end, s.len());
    for w in ch.windows(2) {
        assert_eq!(w[0].end, w[1].start);
    }
}

#[test]
fn whisper_full_json() {
    let json = r#"{"transcription":[
      {"offsets":{"from":0,"to":2000},"text":" 안녕하세요 여러분",
       "tokens":[{"text":"[_BEG_]","t_dtw":-1,"offsets":{"from":0}},
                 {"text":" 안녕","t_dtw":40,"offsets":{"from":100}},
                 {"text":"하세요","t_dtw":80,"offsets":{"from":500}},
                 {"text":" 여러분","t_dtw":120,"offsets":{"from":1000}}]},
      {"offsets":{"from":2500,"to":4000},"text":" [음악] 좋아요 정말",
       "tokens":[{"text":" 좋아요","t_dtw":-1,"offsets":{"from":2600}}]}
    ]}"#;
    let w = whisper::fix_overlaps(whisper::parse_whisper_full(json.as_bytes()));
    let t: Vec<&str> = w.iter().map(|x| x.text.as_str()).collect();
    assert_eq!(t, ["안녕하세요", "여러분", "좋아요", "정말"]);
    assert!(
        close(w[0].start, 0.25) && close(w[0].end, 1.05),
        "DTW 시간 - 0.15"
    );
    assert!(close(w[1].start, 1.05) && close(w[1].end, 2.0));
    // 토큰 수 불일치 → 글자 수 비율 (3:2)
    assert!(close(w[2].start, 2.5) && close(w[3].start, 2.5 + 1.5 * 3.0 / 5.0));
    assert_eq!(
        whisper::parse_progress("whisper_print_progress_callback: progress =  45%"),
        Some(0.45)
    );
}

#[test]
fn whisper_words_clamped_to_audio_length() {
    // Whisper가 마지막 세그먼트 끝(14.12초)을 오디오 길이(13.14초)보다 길게 알려 준 실제 사례
    let mut w = vec![Word::new("same", 11.6, 12.07), Word::new("words", 12.07, 14.12), Word::new("ghost", 13.5, 13.9)];
    whisper::clamp_to_duration(&mut w, 13.14);
    assert!(close(w[0].end, 12.07), "안쪽 단어는 그대로");
    assert!(close(w[1].start, 12.07) && close(w[1].end, 13.14), "끝은 오디오 길이로");
    assert!(w[2].start <= 13.14 && w[2].end <= 13.14 + 1e-9 && w[2].end > w[2].start, "밖에서 시작한 단어도 안으로");

    // 자르지 않으면 가운데 시점(14.2초)이 클립(13.14초) 밖이라 대본에서 사라진다
    let mut a = video(13.14);
    a.words = Some(vec![Word::new("words", 12.07, 16.3)]);
    let mut p = Project::default();
    p.assets = vec![a.clone()];
    p.insert(&a, 0, 0.0, 5.0);
    assert!(p.timeline_words().is_empty());
    whisper::clamp_to_duration(p.assets[0].words.as_mut().unwrap(), 13.14);
    assert_eq!(p.timeline_words().len(), 1);
}
