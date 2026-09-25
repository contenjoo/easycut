//! 미디어 정보 읽기와 오디오 추출 (ffprobe / ffmpeg)
use crate::tools;
use easycut_core::{Id, MediaAsset, MediaKind};
use std::io::Read;
use std::path::Path;
use std::process::Stdio;

const IMAGE_EXT: &[&str] = &["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "webp"];
const AUDIO_EXT: &[&str] = &["mp3", "wav", "m4a", "aac", "aif", "aiff", "flac", "ogg", "opus", "wma"];

pub fn probe(path: &Path) -> Result<MediaAsset, String> {
    let ffprobe = tools::find_tool("ffprobe").ok_or("ffprobe를 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")?;
    let out = tools::command(&ffprobe)
        .args(["-v", "error", "-show_entries", "stream=codec_type,width,height:stream_tags=rotate:stream_side_data=rotation:format=duration", "-of", "json"])
        .arg(path)
        .output()
        .map_err(|e| format!("ffprobe 실행 실패: {e}"))?;
    if !out.status.success() {
        return Err(format!("지원하지 않는 파일 형식입니다: {}", name_of(path)));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    let streams = v["streams"].as_array().cloned().unwrap_or_default();
    let video = streams.iter().find(|s| s["codec_type"] == "video");
    let has_audio = streams.iter().any(|s| s["codec_type"] == "audio");
    let duration = v["format"]["duration"].as_str().and_then(|d| d.parse::<f64>().ok()).unwrap_or(0.0);
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let kind = if IMAGE_EXT.contains(&ext.as_str()) {
        MediaKind::Image
    } else if video.is_some() && duration > 0.0 && !AUDIO_EXT.contains(&ext.as_str()) {
        MediaKind::Video
    } else if has_audio {
        MediaKind::Audio
    } else if video.is_some() {
        MediaKind::Image
    } else {
        return Err(format!("영상/오디오 트랙을 찾을 수 없습니다: {}", name_of(path)));
    };
    // 휴대폰 세로 영상: 회전 정보가 90/270도면 가로·세로를 바꾼다
    let rotation = video
        .and_then(|s| {
            s["tags"]["rotate"].as_str().and_then(|r| r.parse::<f64>().ok()).or_else(|| {
                s["side_data_list"].as_array().and_then(|l| l.iter().find_map(|d| d["rotation"].as_f64()))
            })
        })
        .unwrap_or(0.0);
    let (mut vw, mut vh) = (video.and_then(|s| s["width"].as_f64()).unwrap_or(0.0), video.and_then(|s| s["height"].as_f64()).unwrap_or(0.0));
    if (rotation.abs() as i64 % 180) == 90 {
        std::mem::swap(&mut vw, &mut vh);
    }
    Ok(MediaAsset {
        id: Id::new(),
        path: path.to_string_lossy().to_string(),
        name: name_of(path),
        kind,
        duration: if kind == MediaKind::Image { 0.0 } else { duration },
        width: vw,
        height: vh,
        has_audio: has_audio && kind != MediaKind::Image,
        ..Default::default()
    })
}

pub fn name_of(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
}

/// 모노 16bit PCM으로 오디오를 꺼낸다 (음성 인식 16kHz, 무음 분석 8kHz)
pub fn pcm(path: &Path, rate: u32) -> Result<Vec<i16>, String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")?;
    let mut child = tools::command(&ffmpeg)
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", &rate.to_string(), "-f", "s16le", "-"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("ffmpeg 실행 실패: {e}"))?;
    let mut bytes = vec![];
    child.stdout.take().unwrap().read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    let _ = child.wait();
    if bytes.is_empty() {
        return Err("오디오를 읽을 수 없습니다".into());
    }
    Ok(bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

/// 16kHz 모노 WAV 파일 쓰기
pub fn write_wav(path: &Path, samples: &[i16]) -> std::io::Result<()> {
    let data_len = (samples.len() * 2) as u32;
    let mut b = Vec::with_capacity(44 + data_len as usize);
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + data_len).to_le_bytes());
    b.extend_from_slice(b"WAVEfmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&16000u32.to_le_bytes());
    b.extend_from_slice(&32000u32.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        b.extend_from_slice(&s.to_le_bytes());
    }
    std::fs::write(path, b)
}

// MARK: 변환 (맥 MediaConverter.swift): WebView2가 직접 못 여는 형식은 H.264 MP4로 바꿔 가져온다

/// 포장만 바꾸거나 H.264로 바꿔야 하는 확장자
const CONVERTIBLE: &[&str] = &["mkv", "webm", "avi", "flv", "wmv", "ts", "mts", "m2ts", "ogv", "mpg", "mpeg", "vob", "3gp", "divx", "f4v", "rmvb", "asf"];

struct Info {
    video_codec: Option<String>,
    has_audio: bool,
    text_subtitle: bool,
    duration: f64,
}

fn info(path: &Path) -> Result<Info, String> {
    let ffprobe = tools::find_tool("ffprobe").ok_or("ffprobe를 찾을 수 없습니다.")?;
    let out = tools::command(&ffprobe)
        .args(["-v", "error", "-show_entries", "stream=codec_type,codec_name:format=duration", "-of", "json"])
        .arg(path)
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("파일을 읽을 수 없습니다: {}", name_of(path)));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    let mut i = Info { video_codec: None, has_audio: false, text_subtitle: false, duration: 0.0 };
    for st in v["streams"].as_array().into_iter().flatten() {
        let name = st["codec_name"].as_str().unwrap_or("");
        match st["codec_type"].as_str() {
            Some("video") if i.video_codec.is_none() && name != "mjpeg" && name != "png" => i.video_codec = Some(name.to_string()),
            Some("audio") => i.has_audio = true,
            Some("subtitle") if ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"].contains(&name) => i.text_subtitle = true,
            _ => {}
        }
    }
    i.duration = v["format"]["duration"].as_str().and_then(|d| d.parse().ok()).unwrap_or(0.0);
    Ok(i)
}

/// 가져오기 전에 바꿔야 하나: 위 확장자, 또는 H.264가 아닌 영상(HEVC·VP9·AV1 등, 윈도우에서 재생이 안 되거나 맥과 호환이 안 됨)
pub fn needs_conversion(path: &Path) -> bool {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if CONVERTIBLE.contains(&ext.as_str()) {
        return true;
    }
    if IMAGE_EXT.contains(&ext.as_str()) || AUDIO_EXT.contains(&ext.as_str()) {
        return false;
    }
    matches!(info(path), Ok(Info { video_codec: Some(c), .. }) if c != "h264")
}

fn converted_dir() -> std::path::PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(std::path::PathBuf::from).unwrap_or_else(tools::app_data);
    let d = base.join("EasyCut").join("converted");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// 변환 결과 파일 (원본 경로·크기·수정 시각이 같으면 다시 쓰기)
pub fn cached_path(path: &Path) -> std::path::PathBuf {
    let meta = std::fs::metadata(path).ok();
    let key = format!(
        "{}|{}|{}",
        path.to_string_lossy(),
        meta.as_ref().map_or(0, |m| m.len()),
        meta.and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs())
    );
    // FNV-1a
    let mut h: u64 = 0xcbf29ce484222325;
    for b in key.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    let base = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "video".into());
    converted_dir().join(format!("{base}-{:08x}.mp4", h as u32))
}

pub fn strip_tags(s: &str) -> String {
    let mut out = String::new();
    let (mut angle, mut brace) = (false, false);
    for ch in s.chars() {
        match ch {
            '<' => angle = true,
            '>' if angle => angle = false,
            '{' => brace = true,
            '}' if brace => brace = false,
            _ if !angle && !brace => out.push(ch),
            _ => {}
        }
    }
    out
}

/// 바꾸기. (결과 파일, 안에 들어 있던 첫 텍스트 자막)
pub fn convert(path: &Path, progress: impl Fn(f64, String), cancel: impl Fn() -> bool) -> Result<(std::path::PathBuf, Vec<easycut_core::Caption>), String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")?;
    let i = info(path)?;
    if i.video_codec.is_none() && !i.has_audio {
        return Err(format!("영상/오디오 트랙을 찾을 수 없습니다: {}", name_of(path)));
    }
    let out = cached_path(path);
    let srt = out.with_extension("srt");
    if !out.is_file() {
        let tmp = out.with_extension("part.mp4");
        let _ = std::fs::remove_file(&tmp);
        let copy = i.video_codec.as_deref() == Some("h264");
        let mut args: Vec<String> = vec!["-y".into(), "-v".into(), "error".into(), "-i".into(), path.to_string_lossy().into(), "-map".into(), "0:v:0?".into(), "-map".into(), "0:a:0?".into()];
        if i.video_codec.is_some() {
            if copy {
                args.extend(["-c:v", "copy"].map(String::from));
            } else {
                args.extend(["-c:v", "libx264", "-crf", "18", "-preset", "veryfast", "-pix_fmt", "yuv420p"].map(String::from));
            }
        }
        if i.has_audio {
            args.extend(["-c:a", "aac", "-b:a", "192k", "-ac", "2"].map(String::from));
        }
        args.extend(["-sn", "-dn", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats"].map(String::from));
        args.push(tmp.to_string_lossy().into());
        progress(0.0, if copy { "포장 변환 중…".into() } else { "영상 변환 중…".into() });
        let mut child = tools::command(&ffmpeg).args(&args).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
        {
            use std::io::BufRead;
            let out = child.stdout.take().unwrap();
            for l in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                if let Some(us) = l.strip_prefix("out_time_us=").and_then(|v| v.parse::<f64>().ok()) {
                    progress((us / 1e6 / i.duration.max(0.1)).clamp(0.0, 0.99), format!("{} {}", name_of(path), if copy { "포장 변환 중…" } else { "영상 변환 중…" }));
                }
                if cancel() {
                    let _ = child.kill();
                    break;
                }
            }
        }
        let res = child.wait_with_output().map_err(|e| e.to_string())?;
        if cancel() {
            let _ = std::fs::remove_file(&tmp);
            return Err("변환을 취소했습니다.".into());
        }
        if !res.status.success() {
            let _ = std::fs::remove_file(&tmp);
            let err = String::from_utf8_lossy(&res.stderr);
            return Err(format!("{} 변환 실패: {}", name_of(path), err.lines().last().unwrap_or("")));
        }
        std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
        // 안에 든 첫 텍스트 자막도 꺼내 둔다
        if i.text_subtitle {
            let _ = tools::command(&ffmpeg).args(["-y", "-v", "error", "-i"]).arg(path).args(["-map", "0:s:0", "-c:s", "srt"]).arg(&srt).status();
        }
    }
    let caps = std::fs::read_to_string(&srt)
        .map(|t| easycut_core::transcript_ops::srt::parse(&t).into_iter().map(|mut c| { c.text = strip_tags(&c.text); c }).collect())
        .unwrap_or_default();
    progress(1.0, "완료".into());
    Ok((out, caps))
}

// MARK: 미리보기 그림 · 파형 (타임라인과 미디어 칸)

/// 영상에서 작은 장면 그림 여러 장 (시간, 파일). 이미 있으면 그대로
pub fn thumbnails(id: &str, path: &Path, duration: f64, count: usize) -> Vec<(f64, std::path::PathBuf)> {
    let Some(ffmpeg) = tools::find_tool("ffmpeg") else { return vec![] };
    let dir = tools::app_data().join("thumbs").join(id);
    let _ = std::fs::create_dir_all(&dir);
    let n = count.max(1);
    let mut out = vec![];
    for i in 0..n {
        // 가운데쯤에서 뽑는다 (맨 앞은 검은 화면인 경우가 많다)
        let t = if duration > 0.0 { duration * (i as f64 + 0.5) / n as f64 } else { 0.0 };
        let f = dir.join(format!("t{i:03}-{n}.jpg"));
        if !f.is_file() {
            let _ = tools::command(&ffmpeg)
                .args(["-y", "-v", "error", "-ss", &format!("{t:.2}"), "-i"])
                .arg(path)
                .args(["-frames:v", "1", "-vf", "scale=-2:90", "-q:v", "6"])
                .arg(&f)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        if f.is_file() {
            out.push((t, f));
        }
    }
    out
}

/// 파형: 50ms마다 0~1 크기 (8kHz로 읽어 계산)
pub fn peaks(path: &Path) -> Result<Vec<f32>, String> {
    let s = pcm(path, 8000)?;
    Ok(s.chunks(400).map(|c| c.iter().map(|v| (*v as f32).abs()).fold(0.0, f32::max) / 32768.0).collect())
}
