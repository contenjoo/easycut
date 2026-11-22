//! A studio session keeps editable source recordings independent of the live encoder.
use crate::tools;
use easycut_core::{Clip, MediaAsset, Project};
use serde::Deserialize;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{sync_channel, SyncSender},
    Arc, Mutex,
};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

#[tauri::command]
pub async fn studio_open(app: AppHandle) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("studio") {
        return win.set_focus().map_err(|e| e.to_string());
    }
    let main = app
        .get_webview_window("main")
        .ok_or("편집 창을 찾을 수 없습니다.")?;
    let win = WebviewWindowBuilder::new(&app, "studio", WebviewUrl::App("studio.html".into()))
        .title("방송 스튜디오")
        .inner_size(1000., 740.)
        .min_inner_size(800., 600.)
        .content_protected(true)
        .parent(&main)
        .map_err(|e| e.to_string())?
        .build()
        .map_err(|e| e.to_string())?;
    main.set_enabled(false).map_err(|e| e.to_string())?;
    win.on_window_event(move |event| {
        if matches!(event, tauri::WindowEvent::Destroyed) {
            abort(&app);
            let _ = main.set_enabled(true);
            let _ = main.set_focus();
        }
    });
    Ok(())
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Cut {
    at: f64,
    screen: Option<[f64; 4]>,
    camera: Option<[f64; 4]>,
    #[serde(default)]
    custom: bool,
    #[serde(default)]
    screen_on_top: bool,
}

/// The supplied rectangles are the aspect-fit containers used by the 720p preview.
/// An invisible screen clip still carries the microphone audio.
pub fn insert_sources(
    p: &mut Project,
    screen: &MediaAsset,
    camera: Option<&MediaAsset>,
    cuts: &[Cut],
    start: f64,
) {
    let (w, h) = (p.canvas_width, p.canvas_height);
    let fit = (w / 1280.).min(h / 720.);
    // normalize() removes clips shorter than the editor minimum. Merge rapid switches first
    // so it cannot remove part of the screen clip carrying the microphone.
    let mut editable: Vec<Cut> = Vec::new();
    for cut in cuts {
        if screen.duration - cut.at < easycut_core::MIN_CLIP_DURATION {
            continue;
        }
        if let Some(prev) = editable.last_mut() {
            if cut.at - prev.at < easycut_core::MIN_CLIP_DURATION {
                let at = prev.at;
                *prev = cut.clone();
                prev.at = at;
                continue;
            }
        }
        editable.push(cut.clone());
    }
    editable.dedup_by(|a, b| {
        a.screen == b.screen
            && a.camera == b.camera
            && a.custom == b.custom
            && a.screen_on_top == b.screen_on_top
    });
    let cuts = &editable;
    for (i, cut) in cuts.iter().enumerate() {
        let end = cuts.get(i + 1).map_or(screen.duration, |c| c.at);
        let screen_rect = if camera.is_none() && !cut.custom {
            Some([0., 0., 1., 1.])
        } else {
            cut.screen
        };
        // The same screen source carries the microphone on either video track.
        let screen_track = usize::from(cut.screen_on_top && camera.is_some());
        for (track, is_screen, asset, rect) in [
            (screen_track, true, Some(screen), screen_rect),
            (1 - screen_track, false, camera, cut.camera),
        ] {
            let Some(asset) = asset else { continue };
            let source_out = end.min(asset.duration);
            if source_out - cut.at < easycut_core::MIN_CLIP_DURATION
                || asset.width <= 0.
                || asset.height <= 0.
            {
                continue;
            }
            let mut clip = Clip {
                start: start + cut.at,
                source_in: cut.at,
                source_out,
                asset_id: Some(asset.id),
                volume: if is_screen { 1. } else { 0. },
                ..Clip::default()
            };
            if let Some([x, y, width, height]) = rect {
                let scale = (width * 1280. / asset.width).min(height * 720. / asset.height) * fit;
                clip.scale = scale / (w / asset.width).min(h / asset.height);
                clip.offset_x = (x + width / 2. - 0.5) * 1280. * fit / w;
                clip.offset_y = (y + height / 2. - 0.5) * 720. * fit / h;
            } else {
                clip.opacity = 0.;
            }
            p.tracks[track].clips.push(clip);
        }
    }
}

pub fn valid(cuts: &[Cut]) -> bool {
    cuts.first().is_some_and(|c| c.at == 0.)
        && cuts.windows(2).all(|p| p[0].at <= p[1].at)
        && cuts.iter().all(|c| {
            c.at.is_finite()
                && [c.screen, c.camera]
                    .into_iter()
                    .flatten()
                    .all(|[x, y, w, h]| {
                        x >= 0.
                            && y >= 0.
                            && w > 0.
                            && h > 0.
                            && x + w <= 1.00001
                            && y + h <= 1.00001
                    })
        })
}

struct Encoder {
    child: Child,
    input: Option<SyncSender<Vec<u8>>>,
    connected: Arc<AtomicBool>,
    // FFmpeg reads this after parsing the input stream, not when it spawns.
    key: Option<tempfile::NamedTempFile>,
}
impl Drop for Encoder {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
#[derive(Default)]
pub struct Live(Mutex<Option<Encoder>>);

#[tauri::command]
pub fn studio_live_start(app: AppHandle, server: String, key: String) -> Result<(), String> {
    let url = tauri::Url::parse(server.trim()).map_err(|_| "RTMP(S) 서버 주소를 확인하세요.")?;
    if !matches!(url.scheme(), "rtmp" | "rtmps")
        || url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("RTMP(S) 서버 주소와 스트림 키를 따로 입력하세요.".into());
    }
    let state = app.state::<Live>();
    let mut encoder = state.0.lock().unwrap();
    if encoder.is_some() {
        return Err("이미 송출 중입니다.".into());
    }
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다.")?;
    *encoder = Some(Encoder::start(&ffmpeg, &url, &key)?);
    Ok(())
}

impl Encoder {
    fn start(ffmpeg: &std::path::Path, url: &tauri::Url, key: &str) -> Result<Self, String> {
        if key.chars().any(char::is_control) || key.trim().is_empty() || key.len() >= 2048 {
            return Err("스트림 키를 확인하세요.".into());
        }
        let key = key.trim();
        let mut secret =
            tempfile::NamedTempFile::new().map_err(|_| "임시 송출 설정을 만들 수 없습니다.")?;
        // FFmpeg's preset reader supports protocol AVOptions on native RTMP as well.
        writeln!(secret, "rtmp_playpath={key}").map_err(|_| "송출 설정을 쓸 수 없습니다.")?;
        let verify_tls: &[&str] = if url.scheme() == "rtmps" {
            &["-tls_verify", "1"]
        } else {
            &[]
        };
        let application = url.path().trim_matches('/');
        let app_args: Vec<&str> = if application.is_empty() {
            vec![]
        } else {
            vec!["-rtmp_app", application]
        };
        let mut child = tools::command(ffmpeg)
            .args([
                "-nostdin",
                "-v",
                "error",
                "-f",
                "webm",
                "-analyzeduration",
                "500000",
                "-probesize",
                "256k",
                "-i",
                "pipe:0",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-tune",
                "zerolatency",
                "-pix_fmt",
                "yuv420p",
                "-r",
                "30",
                "-g",
                "60",
                "-b:v",
                "3000k",
                "-c:a",
                "aac",
                "-ar",
                "48000",
                "-b:a",
                "128k",
                "-f",
                "flv",
                "-rw_timeout",
                "8000000",
                "-progress",
                "pipe:1",
                "-fpre",
            ])
            .arg(secret.path())
            .args(app_args)
            .args(verify_tls)
            .arg(url.as_str())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "송출 인코더를 실행할 수 없습니다.")?;
        let connected = Arc::new(AtomicBool::new(false));
        let state = connected.clone();
        let output = child.stdout.take().unwrap();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines().map_while(Result::ok) {
                if line
                    .strip_prefix("out_time_us=")
                    .and_then(|v| v.parse::<i64>().ok())
                    .is_some_and(|v| v > 0)
                {
                    state.store(true, Ordering::Relaxed);
                }
            }
        });
        let (tx, rx) = sync_channel::<Vec<u8>>(8);
        let mut input = child.stdin.take().unwrap();
        std::thread::spawn(move || {
            for packet in rx {
                if input.write_all(&packet).is_err() {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            input: Some(tx),
            connected,
            key: Some(secret),
        })
    }

    fn send(&mut self, bytes: Vec<u8>) -> Result<bool, String> {
        let active = self.child.try_wait().is_ok_and(|status| status.is_none());
        if !active
            || !self
                .input
                .as_ref()
                .is_some_and(|tx| tx.try_send(bytes).is_ok())
        {
            return Err("송출 연결이 끊겼습니다. 로컬 녹화는 계속됩니다.".into());
        }
        let connected = self.connected.load(Ordering::Relaxed);
        if connected {
            self.key.take();
        }
        Ok(connected)
    }

    fn finish(mut self) {
        self.input.take(); // Drain queued frames, then close FFmpeg stdin for its FLV trailer.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while std::time::Instant::now() < deadline {
            if !matches!(self.child.try_wait(), Ok(None)) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
    }
}

#[tauri::command]
pub fn studio_live_chunk(app: AppHandle, request: tauri::ipc::Request) -> Result<bool, String> {
    let state = app.state::<Live>();
    let mut guard = state.0.lock().unwrap();
    let encoder = guard.as_mut().ok_or("송출이 종료되었습니다.")?;
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else {
        return Err("송출 데이터 오류".into());
    };
    let result = encoder.send(bytes.to_vec());
    if result.is_err() {
        guard.take();
    }
    result
}

#[tauri::command]
pub async fn studio_live_stop(app: AppHandle) {
    let encoder = app.state::<Live>().0.lock().unwrap().take();
    if let Some(encoder) = encoder {
        let _ = tauri::async_runtime::spawn_blocking(move || encoder.finish()).await;
    }
}

pub fn abort(app: &AppHandle) {
    app.state::<Live>().0.lock().unwrap().take();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn studio_timeline_preserves_mic_and_positions_after_scene_switches() {
        let full = Some([0., 0., 1., 1.]);
        let cuts = [
            Cut {
                at: 0.,
                screen: full,
                camera: None,
                ..Cut::default()
            },
            Cut {
                at: 1.,
                screen: None,
                camera: full,
                ..Cut::default()
            },
            // Replacing a sub-frame scene must not leave an audio gap.
            Cut {
                at: 1.01,
                screen: full,
                camera: Some([0.7, 0.68, 0.28, 0.3]),
                ..Cut::default()
            },
            Cut {
                at: 2.,
                screen: Some([0., 0., 0.5, 1.]),
                camera: Some([0.5, 0., 0.5, 1.]),
                ..Cut::default()
            },
            Cut {
                at: 3.,
                screen: None,
                camera: full,
                ..Cut::default()
            },
            Cut {
                at: 3.99,
                screen: full,
                camera: None,
                ..Cut::default()
            },
        ];
        let screen = MediaAsset {
            width: 1280.,
            height: 720.,
            duration: 4.,
            has_audio: true,
            ..Default::default()
        };
        let camera = MediaAsset {
            width: 640.,
            height: 480.,
            duration: 3.9,
            ..Default::default()
        };
        let mut p = Project {
            canvas_width: 720.,
            canvas_height: 1280.,
            ..Default::default()
        };
        insert_sources(&mut p, &screen, Some(&camera), &cuts, 9.);
        p.normalize();
        let base = &p.tracks[0].clips;
        let face = &p.tracks[1].clips;
        assert_eq!((base.len(), face.len()), (4, 4));
        for (i, clip) in base.iter().enumerate() {
            let t = i as f64;
            assert_eq!(
                (clip.start, clip.source_in, clip.source_out, clip.volume),
                (9. + t, t, t + 1., 1.)
            );
            assert_eq!(face[i].source_in, clip.source_in);
            assert_eq!(face[i].volume, 0.);
        }
        assert_eq!((base[0].opacity, face[0].opacity), (1., 0.));
        assert!((face[1].offset_x - 0.34).abs() < 1e-9);
        // 720 x 405 program area centered in the existing portrait canvas.
        assert!((face[1].offset_y - 0.33 * 405. / 1280.).abs() < 1e-9);
        assert_eq!(
            (base[2].offset_x, face[2].offset_x, base[2].scale),
            (-0.25, 0.25, 0.5)
        );
        assert_eq!(
            (base[3].opacity, face[3].opacity, face[3].source_out),
            (0., 1., 3.9)
        );
        let mut recovery = Project::default();
        insert_sources(&mut recovery, &screen, None, &cuts, 0.);
        assert!(recovery.tracks[0]
            .clips
            .iter()
            .all(|c| c.opacity == 1. && c.volume == 1.));
    }

    #[test]
    fn custom_layout_reopens_with_editable_sources_and_layer_order() {
        let cuts: Vec<Cut> = serde_json::from_value(serde_json::json!([
            {"at":0, "custom":true, "screen":[0.12,0.08,0.64,0.64], "camera":[0.35,0.20,0.28,0.28]},
            {"at":2, "custom":true, "screen":[0.25,0.40,0.60,0.50], "camera":[0.04,0.03,0.30,0.40], "screenOnTop":true},
            {"at":3, "custom":true, "screen":[0.25,0.40,0.60,0.50], "camera":[0.04,0.03,0.30,0.40], "screenOnTop":true}
        ])).unwrap();
        assert!(valid(&cuts));
        let screen = MediaAsset {
            width: 160.,
            height: 90.,
            duration: 4.,
            has_audio: true,
            ..Default::default()
        };
        let camera = MediaAsset {
            width: 120.,
            height: 90.,
            duration: 4.,
            ..Default::default()
        };
        let mut p = Project {
            canvas_width: 1280.,
            canvas_height: 720.,
            assets: vec![screen.clone(), camera.clone()],
            ..Default::default()
        };
        insert_sources(&mut p, &screen, Some(&camera), &cuts, 0.);
        p.normalize();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("studio.easycut");
        std::fs::write(&path, p.to_json().unwrap()).unwrap();
        let reopened = Project::from_json(&std::fs::read_to_string(path).unwrap()).unwrap();
        let back = &reopened.tracks[0].clips;
        let front = &reopened.tracks[1].clips;
        assert_eq!((back.len(), front.len()), (2, 2));
        let geometry = |clip: &Clip, scale: f64, x: f64, y: f64| {
            assert!(
                (clip.scale - scale).abs() < 1e-8
                    && (clip.offset_x - x).abs() < 1e-8
                    && (clip.offset_y - y).abs() < 1e-8
            );
        };
        geometry(&back[0], 0.64, -0.06, -0.10);
        geometry(&front[0], 0.28, -0.01, -0.16);
        geometry(&front[1], 0.50, 0.05, 0.15);
        geometry(&back[1], 0.40, -0.31, -0.27);
        for (i, (s, c)) in [(&back[0], &front[0]), (&front[1], &back[1])]
            .into_iter()
            .enumerate()
        {
            assert_eq!(
                (s.asset_id, s.volume, c.asset_id, c.volume),
                (Some(screen.id), 1., Some(camera.id), 0.)
            );
            assert_eq!(
                (s.start, s.source_in, s.source_out),
                (i as f64 * 2., i as f64 * 2., i as f64 * 2. + 2.)
            );
        }
        let mut screen_only = Project {
            canvas_width: 1280.,
            canvas_height: 720.,
            ..Default::default()
        };
        insert_sources(&mut screen_only, &screen, None, &cuts, 0.);
        geometry(&screen_only.tracks[0].clips[0], 0.64, -0.06, -0.10);
        geometry(&screen_only.tracks[0].clips[1], 0.50, 0.05, 0.15);
    }

    /// Decode the actual editor export and sample the overlapped area on both sides of a cut.
    #[test]
    #[ignore = "requires FFmpeg and ffprobe"]
    fn custom_scene_export_pixels_follow_top_left_and_z_order() {
        let ffmpeg = tools::find_tool("ffmpeg").unwrap();
        let dir = tempfile::tempdir().unwrap();
        let source = |name: &str, pattern: &str| {
            let path = dir.path().join(format!("{name}.mp4"));
            let result = tools::command(&ffmpeg)
                .args([
                    "-v", "error", "-f", "lavfi", "-i", pattern, "-c:v", "libx264", "-pix_fmt",
                    "yuv420p",
                ])
                .arg(&path)
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
            crate::media::probe(&path).unwrap()
        };
        let screen = source("screen", "color=red:s=160x90:r=10:d=2");
        let camera = source("camera", "color=blue:s=120x90:r=10:d=2");
        let cuts = [
            Cut {
                at: 0.,
                screen: Some([0.1, 0.05, 0.70, 0.70]),
                camera: Some([0.30, 0.20, 0.25, 0.25]),
                custom: true,
                screen_on_top: false,
            },
            Cut {
                at: 1.,
                screen: Some([0.30, 0.34, 0.60, 0.60]),
                camera: Some([0.10, 0.58, 0.60, 0.40]),
                custom: true,
                screen_on_top: true,
            },
        ];
        let mut p = Project {
            canvas_width: 160.,
            canvas_height: 90.,
            fps: 10.,
            assets: vec![screen.clone(), camera.clone()],
            ..Default::default()
        };
        insert_sources(&mut p, &screen, Some(&camera), &cuts, 0.);
        let path = dir.path().join("saved.easycut");
        std::fs::write(&path, p.to_json().unwrap()).unwrap();
        let reopened = Project::from_json(&std::fs::read_to_string(path).unwrap()).unwrap();
        let video = dir.path().join("export.mp4");
        crate::export::export(
            &reopened,
            &crate::export::Options {
                path: video.to_string_lossy().into(),
                height: 0,
                format: "mp4".into(),
                burn_captions: false,
                range: None,
            },
            |_| {},
            || false,
        )
        .unwrap();
        let result = tools::command(&ffmpeg)
            .args(["-v", "error", "-i"])
            .arg(&video)
            .args(["-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let frames: Vec<_> = result.stdout.chunks_exact(160 * 90 * 3).collect();
        assert_eq!(frames.len(), 20);
        for (frame, x, y, rgb) in [
            (4, 68, 29, [0u8, 0, 255]),
            (4, 24, 10, [255, 0, 0]),
            (4, 24, 80, [0, 0, 0]),
            (15, 64, 70, [255, 0, 0]),
            (15, 43, 71, [0, 0, 255]),
            (15, 66, 17, [0, 0, 0]),
        ] {
            let offset = (160 * y + x) * 3;
            let actual = &frames[frame][offset..offset + 3];
            assert!(
                actual.iter().zip(rgb).all(|(a, b)| a.abs_diff(b) < 25),
                "frame {frame} at ({x},{y}): expected {rgb:?}, got {actual:?}"
            );
        }
    }

    /// Requires FFmpeg and ffprobe on PATH and permission to listen on localhost.
    #[test]
    #[ignore]
    fn studio_sender_delivers_webm_as_h264_aac_over_rtmp() {
        use std::net::TcpListener;
        use std::thread::sleep;
        use std::time::{Duration, Instant};

        let ffmpeg = tools::find_tool("ffmpeg").unwrap();
        let ffprobe = tools::find_tool("ffprobe").unwrap();
        let dir = tempfile::tempdir().unwrap();
        let output = dir.path().join("received.mkv");
        let fixture = tools::command(&ffmpeg)
            .args([
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=320x180:rate=30:duration=4",
                "-f",
                "lavfi",
                "-i",
                "sine=duration=4:sample_rate=48000",
                "-c:v",
                "libvpx",
                "-deadline",
                "realtime",
                "-c:a",
                "libopus",
                "-cluster_time_limit",
                "250",
                "-f",
                "webm",
                "pipe:1",
            ])
            .output()
            .unwrap();
        assert!(
            fixture.status.success(),
            "{}",
            String::from_utf8_lossy(&fixture.stderr)
        );
        let addr = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap();
        let url = tauri::Url::parse(&format!("rtmp://{addr}/live")).unwrap();
        struct Receiver(Child);
        impl Drop for Receiver {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let mut receiver = Receiver(
            tools::command(&ffmpeg)
                .args([
                    "-nostdin",
                    "-v",
                    "error",
                    "-listen",
                    "1",
                    "-i",
                    &format!("{url}/fixture"),
                    "-c",
                    "copy",
                ])
                .arg(&output)
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while TcpListener::bind(addr).is_ok() {
            assert!(
                Instant::now() < deadline && receiver.0.try_wait().unwrap().is_none(),
                "RTMP listener failed to start"
            );
            sleep(Duration::from_millis(20));
        }
        for bad_key in ["first\nsecond", "first\rsecond", "  "] {
            assert!(Encoder::start(&ffmpeg, &url, bad_key).is_err());
        }
        let mut sender = Encoder::start(&ffmpeg, &url, "fixture").unwrap();
        let preset = sender.key.as_ref().unwrap().path().to_owned();
        assert_eq!(
            std::fs::read_to_string(&preset).unwrap(),
            "rtmp_playpath=fixture\n"
        );
        for chunk in fixture.stdout.chunks(16 * 1024) {
            sender.send(chunk.to_vec()).unwrap();
            sleep(Duration::from_millis(80));
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while !sender.connected.load(Ordering::Relaxed) && Instant::now() < deadline {
            sleep(Duration::from_millis(25));
        }
        assert!(
            sender.send(Vec::new()).unwrap(),
            "No RTMP progress during capture"
        );
        assert!(
            !preset.exists(),
            "The key file should be removed once publishing starts"
        );
        sender.finish();
        let deadline = Instant::now() + Duration::from_secs(5);
        while receiver.0.try_wait().unwrap().is_none() {
            assert!(
                Instant::now() < deadline,
                "RTMP listener did not receive EOF"
            );
            sleep(Duration::from_millis(50));
        }
        let probe = tools::command(&ffprobe)
            .args([
                "-v",
                "error",
                "-show_entries",
                "stream=codec_name:format=duration",
                "-of",
                "json",
            ])
            .arg(output)
            .output()
            .unwrap();
        assert!(
            probe.status.success(),
            "{}",
            String::from_utf8_lossy(&probe.stderr)
        );
        let info: serde_json::Value = serde_json::from_slice(&probe.stdout).unwrap();
        let codecs: Vec<_> = info["streams"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["codec_name"].as_str().unwrap())
            .collect();
        assert!(codecs.contains(&"aac") && codecs.contains(&"h264"));
        assert!(
            info["format"]["duration"]
                .as_str()
                .unwrap()
                .parse::<f64>()
                .unwrap()
                >= 3.9
        );
    }
}
