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
    key: Option<tempfile::TempPath>,
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

fn tls_options(url: &tauri::Url) -> &'static [&'static str] {
    if url.scheme() == "rtmps" {
        &["-tls_verify", "1"]
    } else {
        &[]
    }
}

impl Encoder {
    fn start(ffmpeg: &std::path::Path, url: &tauri::Url, key: &str) -> Result<Self, String> {
        // FFmpeg 8 reads a preset with fgets(line, 1000): name, '=', UTF-8
        // value and newline must fit in 999 bytes, leaving room for the NUL.
        let fits_line = |name: &str, value: &str| name.len() + 1 + value.len() + 1 < 1000;
        if key.chars().any(char::is_control)
            || key.trim().is_empty()
            || !fits_line("rtmp_playpath", key.trim())
        {
            return Err("스트림 키를 확인하세요.".into());
        }
        let key = key.trim();
        let application = url.path().trim_matches('/');
        if !fits_line("rtmp_app", application) {
            return Err("RTMP 서버 경로가 너무 깁니다.".into());
        }
        let mut secret =
            tempfile::NamedTempFile::new().map_err(|_| "임시 송출 설정을 만들 수 없습니다.")?;
        // FFmpeg's preset reader supports protocol AVOptions on native RTMP as well.
        writeln!(secret, "rtmp_playpath={key}").map_err(|_| "송출 설정을 쓸 수 없습니다.")?;
        if !application.is_empty() {
            writeln!(secret, "rtmp_app={application}")
                .map_err(|_| "송출 설정을 쓸 수 없습니다.")?;
        }
        // Close the writing handle before FFmpeg reopens the preset on Windows.
        // TempPath still removes it on startup failure, disconnect or encoder drop.
        let secret = secret.into_temp_path();
        // Some custom servers include a per-user token in their application path.
        // Only the public server origin belongs in the process command line.
        let mut origin = url.clone();
        origin.set_path("/");
        let mut child = tools::command(ffmpeg)
            .env_remove("FFREPORT") // An inherited debug report could log the resolved playpath.
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
            .arg(&*secret)
            .args(tls_options(url))
            .arg(origin.as_str())
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

    // A read-only RTMP handshake uses no account, stream key or broadcast.
    fn probe_rtmps(ffmpeg: &std::path::Path, url: &tauri::Url) -> String {
        let output = tools::command(ffmpeg)
            .env_remove("FFREPORT")
            .args(["-nostdin", "-v", "debug", "-rw_timeout", "5000000"])
            .args(tls_options(url))
            .args(["-i", url.as_str(), "-t", "0", "-f", "null", "-"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&output.stderr).into_owned()
    }

    #[test]
    #[ignore = "requires network access to the public YouTube RTMPS ingest endpoint"]
    fn bundled_ffmpeg_verifies_youtube_rtmps_and_receives_handshake() {
        let url = tauri::Url::parse("rtmps://a.rtmps.youtube.com:443/live2").unwrap();
        let log = probe_rtmps(&tools::find_tool("ffmpeg").unwrap(), &url);
        // The server may refuse playback after acknowledging RTMP. Its version in
        // the response demonstrates both a verified TLS session and native RTMP.
        assert!(
            log.contains("Type answer 3") && log.contains("Server version"),
            "{log}"
        );
    }

    #[test]
    #[ignore = "requires FFmpeg, OpenSSL and permission to listen on localhost"]
    fn bundled_ffmpeg_rejects_untrusted_rtmps_before_handshake() {
        use std::net::{TcpListener, TcpStream};
        use std::time::{Duration, Instant};
        let openssl = tools::find_tool("openssl")
            .or_else(|| {
                std::env::var_os("ProgramFiles")
                    .map(std::path::PathBuf::from)
                    .map(|root| root.join("Git/usr/bin/openssl.exe"))
                    .filter(|p| p.is_file())
            })
            .expect("OpenSSL is required for the isolated certificate fixture");
        let dir = tempfile::tempdir().unwrap();
        let generate = tools::command(&openssl)
            .current_dir(dir.path())
            .args([
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                "key.pem",
                "-out",
                "cert.pem",
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
            ])
            .output()
            .unwrap();
        assert!(
            generate.status.success(),
            "{}",
            String::from_utf8_lossy(&generate.stderr)
        );
        let addr = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap();
        let mut server = tools::command(&openssl)
            .current_dir(dir.path())
            .args([
                "s_server",
                "-quiet",
                "-www",
                "-accept",
                &addr.to_string(),
                "-cert",
                "cert.pem",
                "-key",
                "key.pem",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let ready = Instant::now() + Duration::from_secs(5);
        while TcpStream::connect(addr).is_err() {
            if Instant::now() > ready || server.try_wait().unwrap().is_some() {
                let _ = server.kill();
                let _ = server.wait();
                panic!("Local TLS fixture did not start");
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let url = tauri::Url::parse(&format!("rtmps://{addr}/live")).unwrap();
        // This is an FLV output, as in the real encoder. FFmpeg must refuse the
        // untrusted peer before sending an RTMP handshake or publishing any data.
        let output = tools::command(&tools::find_tool("ffmpeg").unwrap())
            .env_remove("FFREPORT")
            .args([
                "-nostdin",
                "-v",
                "debug",
                "-f",
                "lavfi",
                "-i",
                "color=s=16x16:d=0.1",
                "-c:v",
                "libx264",
                "-f",
                "flv",
                "-rw_timeout",
                "5000000",
            ])
            .args(tls_options(&url))
            .arg(url.as_str())
            .output()
            .unwrap();
        let log = String::from_utf8_lossy(&output.stderr);
        let _ = server.kill();
        let _ = server.wait();
        let diagnostic = log.to_ascii_lowercase();
        assert!(
            diagnostic.contains("certificate")
                && (diagnostic.contains("not trusted")
                    || diagnostic.contains("verification failed")
                    || diagnostic.contains("unable to verify")
                    || diagnostic.contains("not verified")
                    || diagnostic.contains("failed to verify")
                    || diagnostic.contains("failed verification")),
            "Expected a TLS trust failure: {log}"
        );
        assert!(
            !output.status.success() && !log.contains("Handshaking..."),
            "{log}"
        );
    }

    // All data captured here belongs to the loopback synthetic publisher. The listener
    // in FFmpeg accepts an empty publish key, so decoding the movie alone cannot catch
    // versions that discard protocol AVOptions in -fpre.
    fn assert_publish_commands(wire: &[u8], endpoint: &tauri::Url, key: &str) {
        fn amf_string(value: &str) -> Vec<u8> {
            let mut bytes = vec![2]; // AMF0 String
            bytes.extend((value.len() as u16).to_be_bytes());
            bytes.extend(value.as_bytes());
            bytes
        }
        fn contains(bytes: &[u8], marker: &[u8]) -> bool {
            bytes.windows(marker.len()).any(|b| b == marker)
        }
        let messages = &wire[3073..]; // C0, C1 and C2 are unchunked.
        let connect = amf_string("connect");
        let start = messages
            .windows(connect.len())
            .position(|b| b == connect)
            .expect("RTMP connect command");
        // A new command stream starts with a 12-byte type-0 RTMP header. At
        // connection time the negotiated chunk size is still the default 128.
        let header = &messages[start - 12..start];
        assert_eq!(header[0] >> 6, 0);
        assert_eq!(header[7], 20, "Expected an AMF0 command");
        let size = u32::from_be_bytes([0, header[4], header[5], header[6]]) as usize;
        let mut command = Vec::new();
        let mut pos = start;
        while command.len() < size {
            let count = 128.min(size - command.len());
            command.extend_from_slice(&messages[pos..pos + count]);
            pos += count;
            if command.len() < size {
                assert_eq!(messages[pos], 0xc0 | header[0], "RTMP connect continuation");
                pos += 1;
            }
        }
        for (name, value) in [
            ("app", endpoint.path().trim_matches('/')),
            ("tcUrl", endpoint.as_str()),
        ] {
            let mut property = (name.len() as u16).to_be_bytes().to_vec();
            property.extend(name.as_bytes());
            property.extend(amf_string(value));
            assert!(
                contains(&command, &property),
                "RTMP connect sent the wrong {name}"
            );
        }
        let publish = amf_string("publish");
        let pos = messages
            .windows(publish.len())
            .position(|b| b == publish)
            .expect("RTMP publish command")
            + publish.len();
        assert_eq!(messages[pos], 0, "Publish transaction ID is an AMF0 number");
        assert_eq!(messages[pos + 9], 5, "Publish command object is AMF0 null");
        let mut args = amf_string(key);
        args.extend(amf_string("live"));
        assert!(
            messages[pos + 10..].starts_with(&args),
            "RTMP publish omitted or changed its stream key"
        );
    }

    /// Requires FFmpeg and ffprobe on PATH and permission to listen on localhost.
    #[test]
    #[ignore]
    fn studio_sender_delivers_webm_as_h264_aac_over_rtmp() {
        use std::io::Read;
        use std::net::{Shutdown, TcpListener, TcpStream};
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
        let relay = TcpListener::bind("127.0.0.1:0").unwrap();
        let url =
            tauri::Url::parse(&format!("rtmp://{}/live2", relay.local_addr().unwrap())).unwrap();
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
                    &format!("rtmp://{addr}/live2/fixture"),
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
        let tap = std::thread::spawn(move || {
            let (mut client, _) = relay.accept().unwrap();
            let mut server = TcpStream::connect(addr).unwrap();
            let mut replies = server.try_clone().unwrap();
            let mut downstream = client.try_clone().unwrap();
            let backwards = std::thread::spawn(move || {
                let _ = std::io::copy(&mut replies, &mut downstream);
                let _ = downstream.shutdown(Shutdown::Write);
            });
            let mut wire = Vec::new();
            let mut buffer = [0; 8192];
            while let Ok(n) = client.read(&mut buffer) {
                if n == 0 {
                    break;
                }
                let keep = n.min((32 * 1024usize).saturating_sub(wire.len()));
                wire.extend_from_slice(&buffer[..keep]);
                if server.write_all(&buffer[..n]).is_err() {
                    break;
                }
            }
            let _ = server.shutdown(Shutdown::Write);
            backwards.join().unwrap();
            wire
        });
        for bad_key in ["first\nsecond", "first\rsecond", "  "] {
            assert!(Encoder::start(&ffmpeg, &url, bad_key).is_err());
        }
        assert!(Encoder::start(&ffmpeg, &url, &"a".repeat(985)).is_err());
        let long_path =
            tauri::Url::parse(&format!("rtmp://127.0.0.1/{}", "a".repeat(990))).unwrap();
        assert!(Encoder::start(&ffmpeg, &long_path, "fixture").is_err());
        let mut sender = Encoder::start(&ffmpeg, &url, "fixture").unwrap();
        let preset = sender.key.as_ref().unwrap().to_path_buf();
        assert_eq!(
            std::fs::read_to_string(&preset).unwrap(),
            "rtmp_playpath=fixture\nrtmp_app=live2\n"
        );
        #[cfg(windows)]
        {
            let inspect = format!(
                "(Get-CimInstance Win32_Process -Filter 'ProcessId = {}').CommandLine",
                sender.child.id()
            );
            let output = std::process::Command::new("powershell.exe")
                .args(["-NoProfile", "-NonInteractive", "-Command", &inspect])
                .output()
                .unwrap();
            let command = String::from_utf8_lossy(&output.stdout);
            assert!(output.status.success() && command.contains("-fpre"));
            assert!(!command.contains("fixture") && !command.contains("/live"));
        }
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
        assert_publish_commands(&tap.join().unwrap(), &url, "fixture");
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
