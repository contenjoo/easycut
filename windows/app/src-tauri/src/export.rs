//! 타임라인 → ffmpeg 필터 그래프로 내보내기
use crate::tools;
use easycut_core::{ClipKind, MediaKind, Project, Rgba, TextStyle};
use std::fmt::Write as _;
use std::io::{BufRead, BufReader};
use std::process::Stdio;

pub struct Options {
    pub path: String,
    /// 출력 해상도: 짧은 변 기준 (0 = 프로젝트 크기). 맥과 같이 세로 영상의 1080p는 1080×1920
    pub height: u32,
    pub burn_captions: bool,
    /// "mp4" (H.264) | "hevc" | "prores" | "m4a" (소리만) | "png" (한 장면)
    pub format: String,
    /// 이 구간만 (초)
    pub range: Option<(f64, f64)>,
}

fn even(v: f64) -> i64 {
    ((v / 2.0).round() as i64 * 2).max(2)
}

/// atempo는 한 번에 0.5~2배만 확실하므로 나눠서 잇는다
fn atempo_chain(speed: f64) -> String {
    let mut s = speed;
    let mut parts = vec![];
    while s > 2.0 {
        parts.push("atempo=2.0".to_string());
        s /= 2.0;
    }
    while s < 0.5 {
        parts.push("atempo=0.5".to_string());
        s /= 0.5;
    }
    if (s - 1.0).abs() > 1e-6 {
        parts.push(format!("atempo={s:.6}"));
    }
    parts.join(",")
}

fn ass_color(c: &Rgba) -> String {
    let a = ((1.0 - c.a).clamp(0.0, 1.0) * 255.0).round() as u8;
    let (r, g, b) = ((c.r * 255.0).round() as u8, (c.g * 255.0).round() as u8, (c.b * 255.0).round() as u8);
    format!("&H{a:02X}{b:02X}{g:02X}{r:02X}")
}

fn ass_time(t: f64) -> String {
    let cs = (t.max(0.0) * 100.0).round() as i64;
    format!("{}:{:02}:{:02}.{:02}", cs / 360000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
}

fn ass_text(s: &str) -> String {
    s.replace('\\', "\\\\").replace('{', "(").replace('}', ")").replace('\n', "\\N")
}

/// 이 ffmpeg에 자막(libass) 필터가 있는지
pub fn has_subtitles_filter(ffmpeg: &std::path::Path) -> bool {
    static CACHE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *CACHE.get_or_init(|| {
        tools::command(ffmpeg)
            .args(["-hide_banner", "-filters"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains(" subtitles "))
            .unwrap_or(false)
    })
}

pub fn font_name() -> &'static str {
    if cfg!(windows) { "Malgun Gothic" } else { "Apple SD Gothic Neo" }
}

/// 스타일의 글꼴 (맥에서 만든 프로젝트의 맥 전용 글꼴은 기본 글꼴로)
fn style_font(st: &TextStyle) -> String {
    let f = st.font_name.trim();
    let mac_only = f.is_empty() || f.starts_with("AppleSDGothic") || f.starts_with("Apple SD") || f.starts_with(".") || f.contains("-");
    if mac_only { font_name().to_string() } else { f.to_string() }
}

fn style_line(name: &str, st: &TextStyle, unit: f64) -> String {
    let boxed = st.background_color.a > 0.01;
    let (border, outline_col, outline) = if boxed {
        (3, ass_color(&st.background_color), (st.font_size * unit * 0.12).max(2.0))
    } else if st.outline {
        (1, ass_color(&st.outline_color), (st.font_size * unit * 0.06).max(1.0))
    } else {
        (1, "&H00000000".to_string(), 0.0)
    };
    format!(
        "Style: {name},{font},{size:.0},{fg},&H000000FF,{oc},&H00000000,{bold},0,0,0,100,100,0,0,{border},{outline:.1},0,5,20,20,20,1",
        font = style_font(st),
        size = st.font_size * unit,
        fg = ass_color(&st.text_color),
        oc = outline_col,
        bold = if st.bold { -1 } else { 0 },
    )
}

/// 자막과 텍스트 클립을 ASS 파일로
fn build_ass(p: &Project, w: i64, h: i64, captions: bool) -> Option<String> {
    let unit = (w.min(h) as f64) / 1080.0;
    let mut events = String::new();
    let mut styles = vec![style_line("Cap", &p.caption_style, unit)];
    let mut n = 0;
    if captions && p.show_captions {
        for c in &p.captions {
            let y = p.caption_style.position_y * h as f64;
            let _ = writeln!(events, "Dialogue: 0,{},{},Cap,,0,0,0,,{{\\an5\\pos({},{:.0})}}{}", ass_time(c.start), ass_time(c.end), w / 2, y, ass_text(&c.text));
            n += 1;
        }
    }
    for (ti, tr) in p.tracks.iter().enumerate() {
        if tr.hidden {
            continue;
        }
        for c in tr.clips.iter().filter(|c| c.kind == ClipKind::Text) {
            let name = format!("T{ti}_{n}");
            styles.push(style_line(&name, &c.text_style, unit * c.scale));
            let x = w as f64 / 2.0 + c.offset_x * w as f64;
            let y = (c.text_style.position_y + c.offset_y) * h as f64;
            let _ = writeln!(events, "Dialogue: {},{},{},{name},,0,0,0,,{{\\an5\\pos({x:.0},{y:.0})}}{}", 1 + ti, ass_time(c.start), ass_time(c.end()), ass_text(&c.text));
            n += 1;
        }
    }
    // 마우스 클릭 강조: 노란 원이 0.7초 동안 커지며 사라짐 (맥과 같은 모양)
    styles.push("Style: Click,Arial,20,&H001AD6FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1".into());
    for tr in p.tracks.iter().filter(|t| !t.hidden) {
        for c in tr.clips.iter().filter(|c| c.kind == ClipKind::Media && c.extra.get("showClicks").and_then(|v| v.as_bool()) == Some(true)) {
            let Some(a) = p.asset(c.asset_id) else { continue };
            let Some(marks) = a.extra.get("clicks").and_then(|v| v.as_array()) else { continue };
            if a.width <= 0.0 || a.height <= 0.0 {
                continue;
            }
            let fit = (w as f64 / a.width).min(h as f64 / a.height) * c.scale;
            let (vw, vh) = (a.width * fit, a.height * fit);
            let (x0, y0) = ((w as f64 - vw) / 2.0 + c.offset_x * w as f64, (h as f64 - vh) / 2.0 + c.offset_y * h as f64);
            let r = 0.02 * vw.min(vh);
            let k = 0.5523 * r;
            let circle = format!("m {r:.1} 0 b {r:.1} {k:.1} {k:.1} {r:.1} 0 {r:.1} b -{k:.1} {r:.1} -{r:.1} {k:.1} -{r:.1} 0 b -{r:.1} -{k:.1} -{k:.1} -{r:.1} 0 -{r:.1} b {k:.1} -{r:.1} {r:.1} -{k:.1} {r:.1} 0");
            for m in marks {
                let (Some(mt), Some(mx), Some(my)) = (m["t"].as_f64(), m["x"].as_f64(), m["y"].as_f64()) else { continue };
                if mt < c.source_in || mt > c.source_out {
                    continue;
                }
                let t0 = c.start + (mt - c.source_in) / c.speed;
                let dur = 0.7 / c.speed;
                let ms = (dur * 1000.0).round() as i64;
                let _ = writeln!(
                    events,
                    "Dialogue: 9,{},{},Click,,0,0,0,,{{\\an5\\pos({:.0},{:.0})\\blur{:.1}\\1a&H59&\\t(0,{ms},\\fscx250\\fscy250\\1a&HFF&)\\p1}}{circle}{{\\p0}}",
                    ass_time(t0),
                    ass_time(t0 + dur),
                    x0 + mx * vw,
                    y0 + my * vh,
                    (r * 0.35).max(1.0),
                );
                n += 1;
            }
        }
    }
    if n == 0 {
        return None;
    }
    Some(format!(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: {w}\nPlayResY: {h}\nWrapStyle: 0\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n{}\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n{events}",
        styles.join("\n")
    ))
}

/// 구간만 남긴 프로젝트 (앞뒤를 잘라 내고 0초부터)
fn slice(p: &Project, a: f64, b: f64) -> Project {
    let mut q = p.clone();
    let end = q.duration() + 1.0;
    if b < end {
        q.ripple_delete(b, end);
    }
    if a > 0.0 {
        q.ripple_delete(0.0, a);
    }
    q
}

/// 출력 크기: 짧은 변 기준 (0 = 프로젝트 크기)
pub fn out_size(p: &Project, short: u32) -> (i64, i64) {
    let (cw, ch) = (p.canvas_width.max(2.0), p.canvas_height.max(2.0));
    if short == 0 {
        return (even(cw), even(ch));
    }
    let s = short as f64 / cw.min(ch);
    (even(cw * s), even(ch * s))
}

pub fn export(p: &Project, opts: &Options, progress: impl Fn(f64), cancel: impl Fn() -> bool) -> Result<(), String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다.")?;
    let sliced;
    let p = match opts.range {
        Some((a, b)) if b > a => {
            sliced = slice(p, a, b);
            &sliced
        }
        _ => p,
    };
    let total = p.duration();
    if total <= 0.01 {
        return Err("타임라인이 비어 있습니다.".into());
    }
    let (w, h) = out_size(p, opts.height);
    let fps = if p.fps > 0.0 { p.fps } else { 30.0 };
    let work = tools::temp_dir().join(format!("export-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&work);

    let mut args: Vec<String> = vec!["-y".into(), "-nostdin".into(), "-hide_banner".into(), "-v".into(), "error".into()];
    let mut graph = String::new();
    let bg = &p.background;
    let audio_only = opts.format == "m4a";
    let _ = if audio_only { Ok(()) } else { writeln!(
        graph,
        "color=c=0x{:02X}{:02X}{:02X}:s={w}x{h}:r={fps}:d={total:.3}[base0];",
        (bg.r * 255.0) as u8, (bg.g * 255.0) as u8, (bg.b * 255.0) as u8
    ) };
    let mut last = "base0".to_string();
    let mut audio_labels = vec![];
    let mut input = 0usize;
    let mut k = 0usize;

    for tr in &p.tracks {
        for c in tr.clips.iter().filter(|c| c.kind == ClipKind::Media) {
            let Some(a) = p.asset(c.asset_id) else { continue };
            let dur = c.duration();
            if dur <= 0.01 {
                continue;
            }
            let src_len = c.source_out - c.source_in;
            let visual = !tr.hidden && matches!(a.kind, MediaKind::Video | MediaKind::Image);
            let audible = opts.format != "png" && !tr.muted && c.volume > 0.001 && a.has_audio && a.kind != MediaKind::Image;
            if !visual && !audible {
                continue;
            }
            if a.kind == MediaKind::Image {
                args.extend(["-loop".into(), "1".into(), "-t".into(), format!("{dur:.3}"), "-i".into(), a.path.clone()]);
            } else {
                args.extend(["-ss".into(), format!("{:.3}", c.source_in), "-t".into(), format!("{src_len:.3}"), "-i".into(), a.path.clone()]);
            }
            let i = input;
            input += 1;
            if visual && a.width > 0.0 && a.height > 0.0 && opts.format != "m4a" {
                // 모양: 원은 가운데 정사각형으로 잘라 원 + 흰 테두리, 둥근 사각형은 모서리 8%
                let shape = c.extra.get("shape").and_then(|v| v.as_str()).unwrap_or("none");
                let (aw, ah) = if shape == "circle" { let s = a.width.min(a.height); (s, s) } else { (a.width, a.height) };
                let fit = (w as f64 / aw).min(h as f64 / ah) * c.scale;
                let (vw, vh) = (even(aw * fit), even(ah * fit));
                let x = (w - vw) as f64 / 2.0 + c.offset_x * w as f64;
                let y = (h - vh) as f64 / 2.0 + c.offset_y * h as f64;
                let speed = if a.kind == MediaKind::Image { 1.0 } else { c.speed };
                let crop = if shape == "circle" { "crop='min(iw,ih)':'min(iw,ih)'," } else { "" };
                let mut chain = format!("[{i}:v]setpts=(PTS-STARTPTS)/{speed:.6},fps={fps},{crop}scale={vw}:{vh},format=yuva420p");
                match shape {
                    "circle" => {
                        let rim = (vw as f64 * 0.018).max(2.0);
                        let d = "hypot(X-W/2,Y-H/2)";
                        let _ = write!(chain, ",format=yuva444p,geq=lum='if(lte({d},W/2-{rim:.1}),lum(X,Y),235)':cb='if(lte({d},W/2-{rim:.1}),cb(X,Y),128)':cr='if(lte({d},W/2-{rim:.1}),cr(X,Y),128)':a='if(lte({d},W/2),if(lte({d},W/2-{rim:.1}),alpha(X,Y),242),0)',format=yuva420p");
                    }
                    "rounded" => {
                        let r = (vw.min(vh) as f64 * 0.08).max(2.0);
                        let _ = write!(chain, ",format=yuva444p,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(gt(abs(X-W/2),W/2-{r:.1})*gt(abs(Y-H/2),H/2-{r:.1}),if(lte(hypot(abs(X-W/2)-(W/2-{r:.1}),abs(Y-H/2)-(H/2-{r:.1})),{r:.1}),alpha(X,Y),0),alpha(X,Y))',format=yuva420p");
                    }
                    _ => {}
                }
                if c.opacity < 0.999 {
                    let _ = write!(chain, ",colorchannelmixer=aa={:.3}", c.opacity);
                }
                if c.fade_in > 0.01 {
                    let _ = write!(chain, ",fade=t=in:st=0:d={:.3}:alpha=1", c.fade_in.min(dur / 2.0));
                }
                if c.fade_out > 0.01 {
                    let fo = c.fade_out.min(dur / 2.0);
                    let _ = write!(chain, ",fade=t=out:st={:.3}:d={fo:.3}:alpha=1", dur - fo);
                }
                let _ = writeln!(graph, "{chain},setpts=PTS+{:.4}/TB[v{k}];", c.start);
                let _ = writeln!(graph, "[{last}][v{k}]overlay=x={x:.0}:y={y:.0}:eof_action=pass:enable='between(t,{:.4},{:.4})'[o{k}];", c.start, c.end());
                last = format!("o{k}");
            }
            if audible {
                let mut chain = format!("[{i}:a]asetpts=PTS-STARTPTS");
                let tempo = atempo_chain(c.speed);
                if !tempo.is_empty() {
                    let _ = write!(chain, ",{tempo}");
                }
                let _ = write!(chain, ",volume={:.3}", c.volume.min(4.0));
                if c.fade_in > 0.01 {
                    let _ = write!(chain, ",afade=t=in:st=0:d={:.3}", c.fade_in.min(dur / 2.0));
                }
                if c.fade_out > 0.01 {
                    let fo = c.fade_out.min(dur / 2.0);
                    let _ = write!(chain, ",afade=t=out:st={:.3}:d={fo:.3}", dur - fo);
                }
                let ms = (c.start * 1000.0).round() as i64;
                let _ = writeln!(graph, "{chain},atrim=0:{dur:.3},adelay={ms}:all=1[a{k}];");
                audio_labels.push(format!("[a{k}]"));
            }
            k += 1;
        }
    }

    // 자막·텍스트
    let ass = if !audio_only && has_subtitles_filter(&ffmpeg) { build_ass(p, w, h, opts.burn_captions) } else { None };
    if let Some(ass) = ass {
        std::fs::write(work.join("subs.ass"), ass).map_err(|e| e.to_string())?;
        let _ = writeln!(graph, "[{last}]subtitles=subs.ass[vsub];");
        last = "vsub".into();
    }
    if !audio_only {
        let _ = writeln!(graph, "[{last}]format={}[vout];", if opts.format == "prores" { "yuv422p10le" } else { "yuv420p" });
    }
    if opts.format == "png" {
        // 장면 한 장: 소리 없음
    } else if audio_labels.is_empty() {
        let _ = writeln!(graph, "anullsrc=r=48000:cl=stereo,atrim=0:{total:.3}[aout]");
    } else {
        let _ = writeln!(graph, "{}amix=inputs={}:normalize=0:dropout_transition=0,atrim=0:{total:.3}[aout]", audio_labels.join(""), audio_labels.len());
    }
    let script = work.join("graph.txt");
    std::fs::write(&script, &graph).map_err(|e| e.to_string())?;

    args.extend(["-/filter_complex".into(), "graph.txt".into()]);
    let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    match opts.format.as_str() {
        "m4a" => args.extend(a(&["-map", "[aout]", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"])),
        "png" => args.extend(a(&["-map", "[vout]", "-frames:v", "1", "-update", "1"])),
        "prores" => args.extend(a(&["-map", "[vout]", "-map", "[aout]", "-c:v", "prores_ks", "-profile:v", "2", "-c:a", "pcm_s16le"])),
        "hevc" => args.extend(a(&["-map", "[vout]", "-map", "[aout]", "-c:v", "libx265", "-preset", "fast", "-crf", "24", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"])),
        _ => args.extend(a(&["-map", "[vout]", "-map", "[aout]", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"])),
    }
    if !audio_only && opts.format != "png" {
        args.push("-r".into());
        args.push(format!("{fps}"));
    }
    args.push("-t".into());
    args.push(format!("{total:.3}"));
    args.extend(["-progress".into(), "pipe:1".into(), "-nostats".into(), opts.path.clone()]);

    if std::env::var_os("EASYCUT_DEBUG").is_some() {
        eprintln!("ffmpeg {}\n{graph}", args.join(" "));
    }
    let mut child = tools::command(&ffmpeg)
        .args(&args)
        .current_dir(&work)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("ffmpeg 실행 실패: {e}"))?;
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
        if let Some(us) = line.strip_prefix("out_time_us=").and_then(|v| v.parse::<f64>().ok()) {
            progress((us / 1e6 / total).clamp(0.0, 0.99));
        }
        if cancel() {
            let _ = child.kill();
            break;
        }
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let _ = std::fs::remove_dir_all(&work);
    if cancel() {
        let _ = std::fs::remove_file(&opts.path);
        return Err("내보내기를 취소했습니다.".into());
    }
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("내보내기 실패: {}", err.lines().rev().take(3).collect::<Vec<_>>().join(" / ")));
    }
    progress(1.0);
    Ok(())
}
