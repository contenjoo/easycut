//! `.easycut` 파일을 읽어 다시 저장한다 (맥 앱과의 호환성 확인용).
//! 사용: cargo run --example roundtrip -- 입력.easycut 출력.easycut

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read_to_string(&args[1]).expect("read");
    let p = easycut_core::Project::from_json(&data).expect("decode");
    std::fs::write(&args[2], p.to_json().expect("encode")).expect("write");
    println!("assets={} clips={} captions={} dur={}", p.assets.len(), p.tracks.iter().map(|t| t.clips.len()).sum::<usize>(), p.captions.len(), p.duration());
}
