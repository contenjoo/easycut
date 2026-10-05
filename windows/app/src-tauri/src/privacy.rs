//! 개인정보 찾기: ffmpeg로 장면을 꺼내 윈도우 글자 인식(Windows.Media.Ocr)·얼굴 찾기로 읽는다.
//! 찾은 결과를 시간 구간으로 잇는 규칙은 easycut_core::privacy (맥과 같음).
use crate::tools;
use easycut_core::privacy::{changed, hits_in_line, step_for, thumbnail, BlurRegion, Hit, OcrWord, Options, Rect, Tracker};
use easycut_core::{MediaAsset, MediaKind};
use std::io::Read;
use std::process::Stdio;

/// OCR에 넘길 장면 크기 (긴 변 최대 1920, 짝수)
fn frame_size(a: &MediaAsset) -> (usize, usize) {
    let (aw, ah) = (a.width.max(2.0), a.height.max(2.0));
    let s = (1920.0 / aw.max(ah)).min(1.0);
    let even = |v: f64| (((v * s) / 2.0).round() as usize * 2).max(2);
    (even(aw), even(ah))
}

/// 원본 [from, to] 구간을 step초마다 BGRA 장면으로 꺼낸다. 이미지는 한 장.
fn frames(a: &MediaAsset, from: f64, to: f64, step: f64, mut each: impl FnMut(usize, &[u8]) -> bool) -> Result<(usize, usize), String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다.")?;
    let (w, h) = frame_size(a);
    let mut cmd = tools::command(&ffmpeg);
    cmd.args(["-nostdin", "-hide_banner", "-v", "error"]);
    if a.kind == MediaKind::Image {
        cmd.args(["-i", &a.path, "-frames:v", "1", "-vf", &format!("scale={w}:{h}")]);
    } else {
        cmd.args(["-ss", &format!("{from:.3}"), "-t", &format!("{:.3}", (to - from).max(0.05)), "-i", &a.path]);
        cmd.args(["-an", "-vf", &format!("fps=1/{step:.4}:round=down,scale={w}:{h}")]);
    }
    cmd.args(["-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1"]);
    let mut child = cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| format!("ffmpeg 실행 실패: {e}"))?;
    let mut out = child.stdout.take().unwrap();
    let mut buf = vec![0u8; w * h * 4];
    let mut n = 0;
    loop {
        if out.read_exact(&mut buf).is_err() {
            break;
        }
        if !each(n, &buf) {
            let _ = child.kill();
            break;
        }
        n += 1;
    }
    let _ = child.wait();
    Ok((w, h))
}

fn scan_frame(reader: &Reader, bgra: &[u8], w: usize, h: usize, opt: &Options) -> Vec<Hit> {
    let aspect = w as f64 / h.max(1) as f64;
    let mut hits = vec![];
    if opt.patterns || !opt.keywords.is_empty() {
        for line in reader.lines(bgra, w, h) {
            hits.extend(hits_in_line(&line, opt, aspect));
        }
    }
    if opt.faces {
        for r in reader.faces(bgra, w, h) {
            // 머리카락·턱까지 넉넉하게
            let g = Rect { x: r.x - r.w * 0.25, y: r.y - r.h * 0.35, w: r.w * 1.5, h: r.h * 1.7 }.clip_unit();
            hits.push(Hit { label: "얼굴".into(), text: String::new(), rect: g });
        }
    }
    hits
}

/// 미디어의 [from, to] 원본 구간을 훑어 가릴 영역 목록을 만든다
pub fn scan(a: &MediaAsset, from: f64, to: f64, opt: &Options, progress: impl Fn(f64), cancel: impl Fn() -> bool) -> Result<Vec<BlurRegion>, String> {
    let reader = Reader::new(opt.faces)?;
    if a.kind == MediaKind::Image {
        let mut hits = vec![];
        frames(a, 0.0, 0.0, 1.0, |_, f| {
            let (w, h) = frame_size(a);
            hits = scan_frame(&reader, f, w, h, opt);
            false
        })?;
        progress(1.0);
        return Ok(hits
            .into_iter()
            .map(|h| BlurRegion { x: h.rect.x, y: h.rect.y, w: h.rect.w, h: h.rect.h, start: 0.0, end: 1e6, label: h.label, text: if h.text.is_empty() { None } else { Some(h.text) }, ..Default::default() })
            .collect());
    }
    if a.kind != MediaKind::Video {
        return Ok(vec![]);
    }
    let span = (to - from).max(0.0);
    let step = step_for(span);
    let total = ((span / step).ceil() as usize).max(1);
    let (w, h) = frame_size(a);
    let mut tracker = Tracker::new(step, from, to);
    let mut last: Option<(Vec<u8>, Vec<Hit>)> = None;
    let mut cancelled = false;
    frames(a, from, to, step, |n, f| {
        if cancel() {
            cancelled = true;
            return false;
        }
        // 화면이 거의 그대로면 다시 읽지 않는다 (화면 녹화는 대부분 멈춰 있음)
        let thumb = thumbnail(f, w, h);
        let hits = match &last {
            Some((t, hits)) if !changed(t, &thumb) => hits.clone(),
            _ => scan_frame(&reader, f, w, h, opt),
        };
        tracker.add(&hits, from + n as f64 * step);
        last = Some((thumb, hits));
        progress(((n + 1) as f64 / total as f64).min(0.99));
        true
    })?;
    if cancelled {
        return Err("개인정보 찾기를 중지했습니다".into());
    }
    progress(1.0);
    Ok(tracker.finish())
}

/// 원본 시간 한 지점의 화면 글자 줄: (줄 글자, 위치)
pub fn screen_text(a: &MediaAsset, s: f64) -> Result<Vec<(String, Rect)>, String> {
    let reader = Reader::new(false)?;
    let (w, h) = frame_size(a);
    let mut lines = vec![];
    let from = if a.kind == MediaKind::Image { 0.0 } else { s };
    frames(a, from, from + 0.5, 0.5, |_, f| {
        lines = reader.lines(f, w, h);
        false
    })?;
    Ok(lines
        .into_iter()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let text = l.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
            let r = l.iter().skip(1).fold(l[0].rect, |acc, w| acc.union(&w.rect));
            (text, r)
        })
        .collect())
}

#[cfg(windows)]
pub use win::Reader;

#[cfg(windows)]
mod win {
    use easycut_core::privacy::{OcrWord, Rect};
    use windows::core::HSTRING;
    use windows::Globalization::Language;
    use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapPixelFormat, SoftwareBitmap};
    use windows::Media::FaceAnalysis::FaceDetector;
    use windows::Media::Ocr::OcrEngine;
    use windows::Security::Cryptography::CryptographicBuffer;

    pub struct Reader {
        engine: OcrEngine,
        faces: Option<FaceDetector>,
    }

    fn err(e: windows::core::Error) -> String {
        format!("윈도우 글자 인식 오류: {e}")
    }

    impl Reader {
        pub fn new(faces: bool) -> Result<Self, String> {
            unsafe {
                let _ = windows::Win32::System::WinRT::RoInitialize(windows::Win32::System::WinRT::RO_INIT_MULTITHREADED);
            }
            // 한국어 글자 인식이 설치돼 있으면 한국어(영문·숫자도 읽음), 없으면 사용자 언어
            let ko = Language::CreateLanguage(&HSTRING::from("ko")).map_err(err)?;
            let engine = if OcrEngine::IsLanguageSupported(&ko).unwrap_or(false) {
                OcrEngine::TryCreateFromLanguage(&ko).map_err(err)?
            } else {
                OcrEngine::TryCreateFromUserProfileLanguages().map_err(|_| "이 PC에 글자 인식(OCR) 언어가 없습니다. 설정 > 시간 및 언어 > 언어에서 한국어를 추가해 주세요.".to_string())?
            };
            let faces = if faces { Some(FaceDetector::CreateAsync().map_err(err)?.get().map_err(err)?) } else { None };
            Ok(Reader { engine, faces })
        }

        /// 지금 쓰는 글자 인식 언어 (예: "ko")
        pub fn language(&self) -> String {
            self.engine.RecognizerLanguage().and_then(|l| l.LanguageTag()).map(|t| t.to_string()).unwrap_or_default()
        }

        fn bitmap(bgra: &[u8], w: usize, h: usize) -> windows::core::Result<SoftwareBitmap> {
            let buf = CryptographicBuffer::CreateFromByteArray(bgra)?;
            SoftwareBitmap::CreateCopyWithAlphaFromBuffer(&buf, BitmapPixelFormat::Bgra8, w as i32, h as i32, BitmapAlphaMode::Ignore)
        }

        pub fn lines(&self, bgra: &[u8], w: usize, h: usize) -> Vec<Vec<OcrWord>> {
            let run = || -> windows::core::Result<Vec<Vec<OcrWord>>> {
                let bmp = Self::bitmap(bgra, w, h)?;
                let res = self.engine.RecognizeAsync(&bmp)?.get()?;
                let mut out = vec![];
                for line in res.Lines()? {
                    let mut words = vec![];
                    for word in line.Words()? {
                        let r = word.BoundingRect()?;
                        words.push(OcrWord {
                            text: word.Text()?.to_string(),
                            rect: Rect { x: r.X as f64 / w as f64, y: r.Y as f64 / h as f64, w: r.Width as f64 / w as f64, h: r.Height as f64 / h as f64 },
                        });
                    }
                    out.push(words);
                }
                Ok(out)
            };
            run().unwrap_or_default()
        }

        pub fn faces(&self, bgra: &[u8], w: usize, h: usize) -> Vec<Rect> {
            let Some(det) = &self.faces else { return vec![] };
            let run = || -> windows::core::Result<Vec<Rect>> {
                let bmp = Self::bitmap(bgra, w, h)?;
                let gray = SoftwareBitmap::Convert(&bmp, BitmapPixelFormat::Gray8)?;
                let found = det.DetectFacesAsync(&gray)?.get()?;
                let mut out = vec![];
                for f in found {
                    let b = f.FaceBox()?;
                    out.push(Rect { x: b.X as f64 / w as f64, y: b.Y as f64 / h as f64, w: b.Width as f64 / w as f64, h: b.Height as f64 / h as f64 });
                }
                Ok(out)
            };
            run().unwrap_or_default()
        }
    }
}

/// 윈도우가 아닌 곳(맥에서 개발할 때)에는 글자 인식이 없다
#[cfg(not(windows))]
pub struct Reader;

#[cfg(not(windows))]
impl Reader {
    pub fn new(_faces: bool) -> Result<Self, String> {
        Err("화면 글자 인식은 윈도우에서만 됩니다.".into())
    }
    pub fn language(&self) -> String {
        String::new()
    }
    pub fn lines(&self, _: &[u8], _: usize, _: usize) -> Vec<Vec<OcrWord>> {
        vec![]
    }
    pub fn faces(&self, _: &[u8], _: usize, _: usize) -> Vec<Rect> {
        vec![]
    }
}
