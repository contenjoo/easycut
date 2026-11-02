//! 타임라인 → ffmpeg 필터 그래프로 내보내기
use crate::tools;
use easycut_core::{ClipKind, MediaKind, Project, Rgba, TextStyle};
use std::fmt::Write as _;
use std::io::{BufRead, BufReader};
use std::process::Stdio;
#[path = "export_effects.rs"]
mod effects;
#[cfg(test)]
#[path = "export_effect_tests.rs"]
mod tests;

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
    let mac_only = f.is_empty() || (cfg!(windows) && (f.starts_with("AppleSDGothic") || f.starts_with("Apple SD") || f.starts_with('.')));
    if mac_only { font_name().to_string() } else { f.replace([',', '\n', '\r'], " ") }
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
    let styles = vec![style_line("Cap", &p.caption_style, unit)];
    let mut n = 0;
    if captions && p.show_captions {
        for c in &p.captions {
            let y = p.caption_style.position_y * h as f64;
            events.push_str(&effects::ass_events("Cap",&p.caption_style,&c.text,c.start,c.end,w as f64/2.0,y,w,h,p.fps,0,1.0,0.0,0.0));
            n += 1;
        }
    }
    if n == 0 {
        return None;
    }
    Some(ass_document(&styles,&events,w,h))
}

/// 클릭은 그 원본 클립의 투명 레이어에 그려 같은 전환·불투명도와 트랙 순서를 따른다.
fn build_click_ass(p:&Project,c:&easycut_core::Clip,w:i64,h:i64)->Option<String>{
    if c.extra.get("showClicks").and_then(|v|v.as_bool())!=Some(true){return None;}
    let a=p.asset(c.asset_id)?;
    let marks=a.extra.get("clicks")?.as_array()?;
    if a.width<=0.0||a.height<=0.0{return None;}
    let circle_shape=c.extra.get("shape").and_then(|v|v.as_str())==Some("circle");
    let (aw,ah)=if circle_shape{let side=a.width.min(a.height);(side,side)}else{(a.width,a.height)};
    let fit=(w as f64/aw).min(h as f64/ah)*c.scale;
    let(vw,vh)=(a.width*fit,a.height*fit);
    let(x0,y0)=((w as f64-vw)/2.0+c.offset_x*w as f64,(h as f64-vh)/2.0+c.offset_y*h as f64);
    let r=0.02*(aw*fit).min(ah*fit);let k=0.5523*r;
    let circle=format!("m {r:.1} 0 b {r:.1} {k:.1} {k:.1} {r:.1} 0 {r:.1} b -{k:.1} {r:.1} -{r:.1} {k:.1} -{r:.1} 0 b -{r:.1} -{k:.1} -{k:.1} -{r:.1} 0 -{r:.1} b {k:.1} -{r:.1} {r:.1} -{k:.1} {r:.1} 0");
    let mut events=String::new();
    for m in marks{
        let(Some(t),Some(x),Some(y))=(m["t"].as_f64(),m["x"].as_f64(),m["y"].as_f64())else{continue;};
        if t<c.source_in||t>c.source_out{continue;}
        let t0=(t-c.source_in)/c.speed;let duration=0.7/c.speed;let ms=(duration*1000.0).round()as i64;
        let _=writeln!(events,"Dialogue: 0,{},{},Click,,0,0,0,,{{\\an5\\pos({:.1},{:.1})\\blur{:.1}\\1a&H59&\\t(0,{ms},\\fscx250\\fscy250\\1a&HFF&)\\p1}}{circle}{{\\p0}}",ass_time(t0),ass_time((t0+duration).min(c.duration())),x0+x*vw,y0+y*vh,(r*0.35).max(1.0));
    }
    if events.is_empty(){return None;}
    Some(ass_document(&["Style: Click,Arial,20,&H001AD6FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1".into()],&events,w,h))
}

fn ass_document(styles:&[String],events:&str,w:i64,h:i64)->String{
    format!(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: {w}\nPlayResY: {h}\nWrapStyle: 0\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n{}\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n{events}",
        styles.join("\n")
    )
}

/// 구간만 남긴 프로젝트 (앞뒤를 잘라 내고 0초부터)
fn slice(p: &Project, a: f64, b: f64) -> Project {
    let mut q = p.clone();
    // 앞부터 자른다: 뒤를 먼저 자르면 남은 꼬리가 짧아(장면 한 장은 1프레임) 나눌 수 없어 앞이 안 잘린다
    if a > 0.0 {
        q.ripple_delete(0.0, a);
    }
    let end = q.duration() + 1.0;
    if b - a < end {
        q.ripple_delete(b - a, end);
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
    #[cfg(test)]
    let ffmpeg = std::env::var_os("EASYCUT_EFFECT_FFMPEG").map(std::path::PathBuf::from).or_else(||tools::find_tool("ffmpeg")).ok_or("ffmpeg를 찾을 수 없습니다.")?;
    #[cfg(not(test))]
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
    let has_text = p.tracks.iter().filter(|t| !t.hidden).flat_map(|t| &t.clips).any(|c| c.kind == ClipKind::Text && !c.text.trim().is_empty());
    if opts.format != "m4a" && (has_text || (opts.burn_captions && p.show_captions && !p.captions.is_empty())) && !has_subtitles_filter(&ffmpeg) {
        return Err("텍스트·자막을 내보내려면 subtitles(libass)를 지원하는 ffmpeg가 필요합니다.".into());
    }
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

    for (ti,tr) in p.tracks.iter().enumerate() {
        let mut clips:Vec<_>=tr.clips.iter().collect();
        clips.sort_by(|a,b|a.start.total_cmp(&b.start));
        for c in clips {
            if c.kind==ClipKind::Text {
                if !audio_only&&!tr.hidden&&!c.text.trim().is_empty()&&c.duration()>0.01 {
                    let x=w as f64/2.0+c.offset_x*w as f64;
                    let y=(c.text_style.position_y+c.offset_y)*h as f64;
                    let events=effects::ass_events("Text",&c.text_style,&c.text,0.0,c.duration(),x,y,w,h,fps,ti,c.opacity,c.fade_in,c.fade_out);
                    let ass=ass_document(&[style_line("Text",&c.text_style,w.min(h)as f64/1080.0*c.scale)],&events,w,h);
                    let file=format!("text-{k}.ass");
                    std::fs::write(work.join(&file),ass).map_err(|e|e.to_string())?;
                    let chain=format!("color=c=black@0:s={w}x{h}:r={fps}:d={:.6},format=rgba,subtitles={file}:alpha=1,format=yuva444p",c.duration());
                    last=effects::append_layer(&mut graph,&last,&chain,&format!("t{k}"),c,w,h,fps,0.0,0.0,x,y,w as f64,h as f64,None);
                    k+=1;
                }
                continue;
            }
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
                let mut head = format!("[{i}:v]setpts=(PTS-STARTPTS)/{speed:.6},fps={fps},");
                // 가리기는 원본 크기에서 다른 효과보다 먼저 (맥과 같음)
                let blurs = c.blurs();
                if !blurs.is_empty() {
                    let mut cur = format!("bl{k}_0");
                    let (sw, sh) = (even(a.width), even(a.height));
                    let _ = writeln!(graph, "{head}scale={sw}:{sh}[{cur}];");
                    for (j, r) in blurs.iter().enumerate() {
                        let (ta, tb) = ((r.start - c.source_in) / speed, (r.end - c.source_in) / speed);
                        if tb <= 0.0 || ta >= dur {
                            continue;
                        }
                        let rx = ((r.x * sw as f64).floor() as i64).clamp(0, sw - 2);
                        let ry = ((r.y * sh as f64).floor() as i64).clamp(0, sh - 2);
                        let rw = ((r.w * sw as f64).ceil() as i64).clamp(2, sw - rx);
                        let rh = ((r.h * sh as f64).ceil() as i64).clamp(2, sh - ry);
                        let en = format!("enable='between(t,{:.4},{:.4})'", ta.max(0.0), tb.min(dur + 1.0));
                        let next = format!("bl{k}_{}", j + 1);
                        if r.style == easycut_core::privacy::BlurStyle::Box {
                            let _ = writeln!(graph, "[{cur}]drawbox=x={rx}:y={ry}:w={rw}:h={rh}:color=black:t=fill:{en}[{next}];");
                        } else {
                            let mosaic = r.style == easycut_core::privacy::BlurStyle::Mosaic;
                            let cell = if mosaic { (rw.min(rh) / 5).max(6) } else { (rw.min(rh) / 3).max(4) };
                            let (dw, dh) = ((rw / cell).max(1), (rh / cell).max(1));
                            // 모자이크 위에 흐림을 겹쳐 글자를 되살릴 수 없게 한다
                            let soft = if mosaic { String::new() } else { format!(",gblur=sigma={:.1}", cell as f64 * 0.8) };
                            let _ = writeln!(graph, "[{cur}]split=2[m{next}][c{next}];");
                            let _ = writeln!(graph, "[c{next}]crop={rw}:{rh}:{rx}:{ry},scale={dw}:{dh}:flags=area,scale={rw}:{rh}:flags=neighbor{soft}[b{next}];");
                            let _ = writeln!(graph, "[m{next}][b{next}]overlay={rx}:{ry}:{en}[{next}];");
                        }
                        cur = next;
                    }
                    head = format!("[{cur}]");
                }
                // 필터 혼합에는 가리기가 끝난 레이어만 사용한다.
                let color = effects::filter_chain(c.visual_filter.as_deref(), c.filter_intensity, vw.min(vh));
                let mut chain = format!("{head}{crop}scale={vw}:{vh}{color},format=yuva420p");
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
                let clicks=if has_subtitles_filter(&ffmpeg){build_click_ass(p,c,w,h)}else{None};
                let click_file=if let Some(ass)=clicks{
                    let file=format!("click-{k}.ass");
                    std::fs::write(work.join(&file),ass).map_err(|e|e.to_string())?;Some(file)
                }else{None};
                last=effects::append_layer(&mut graph,&last,&chain,&format!("m{k}"),c,w,h,fps,x,y,x+vw as f64/2.0,y+vh as f64/2.0,vw as f64,vh as f64,click_file.as_deref());
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

    // 전체 자막은 클릭·텍스트·모든 영상 트랙을 합성한 뒤 항상 맨 위에 그린다.
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
