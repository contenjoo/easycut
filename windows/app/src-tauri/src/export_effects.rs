//! 시간 기반 FFmpeg/ASS 효과. 입력은 개인정보 가리기가 끝난 레이어다.
use easycut_core::{Clip, TextStyle, TransitionSettings};
use std::fmt::Write as _;
use unicode_segmentation::UnicodeSegmentation;

pub fn filter_chain(kind: Option<&str>, intensity: Option<f64>, short: i64) -> String {
    let value = intensity.unwrap_or(1.0);
    let s = if value.is_finite() { value.clamp(0.0, 1.0) } else { 1.0 };
    if s == 0.0 { return String::new(); }
    match kind.unwrap_or("none") {
        "warm" => format!(",colorbalance=rs={:.5}:rm={:.5}:bs={:.5}:bm={:.5}", 0.08*s,0.04*s,-0.08*s,-0.04*s),
        "cool" => format!(",colorbalance=rs={:.5}:rm={:.5}:bs={:.5}:bm={:.5}",-0.08*s,-0.04*s,0.08*s,0.04*s),
        "mono" => format!(",hue=s={:.5}",1.0-s),
        "sepia" => {
            let m = [0.393,0.769,0.189,0.349,0.686,0.168,0.272,0.534,0.131];
            let v: Vec<String> = m.iter().enumerate().map(|(i,v)| format!("{:.5}", if i%4==0 {1.0-s+v*s} else {v*s})).collect();
            format!(",colorchannelmixer=rr={}:rg={}:rb={}:gr={}:gg={}:gb={}:br={}:bg={}:bb={}",v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8])
        }
        "vivid" => format!(",eq=saturation={:.5}:contrast={:.5}:brightness={:.5}",1.0+0.45*s,1.0+0.12*s,0.01*s),
        "soft" => format!(",gblur=sigma={:.5},eq=saturation={:.5}:contrast={:.5}:brightness={:.5}",(short as f64*0.009*s).max(0.01),1.0-0.08*s,1.0-0.06*s,0.025*s),
        "vintage" => format!(",colorbalance=rs={:.5}:bs={:.5},eq=saturation={:.5}:contrast={:.5}:brightness={:.5}:gamma={:.5}",0.08*s,-0.05*s,1.0-0.2*s,1.0-0.05*s,0.02*s,1.0+0.04*s),
        "dramatic" => format!(",eq=saturation={:.5}:contrast={:.5}:brightness={:.5}",1.0-0.28*s,1.0+0.35*s,-0.025*s),
        "noir" => format!(",hue=s={:.5},eq=contrast={:.5}:gamma={:.5}",1.0-s,1.0+0.45*s,1.0-0.08*s),
        _ => String::new(),
    }
}

pub fn has_transition(c: &Clip) -> bool {
    [c.transition_in.as_ref(),c.transition_out.as_ref()].into_iter().flatten()
        .any(|s| easycut_core::effects::TRANSITIONS.contains(&s.effect.as_str()) && s.effect != "none" && s.clamped_duration(c.duration()) > 0.0)
}

/// 투명 캔버스로 배치된 레이어를 역방향 좌표 샘플링한다. alpha는 원본에서 곱하므로 가리기 영역을 되살리지 않는다.
fn transition(s: &TransitionSettings, duration: f64, entering: bool, w:i64,h:i64,cx:f64,cy:f64,bx:f64,by:f64,bw:f64,bh:f64) -> String {
    let d=s.clamped_duration(duration);
    if d<=0.0 || s.effect=="none" || !easycut_core::effects::TRANSITIONS.contains(&s.effect.as_str()) {return String::new();}
    let p=if entering {format!("min(1,max(0,T/{d:.6}))")} else {format!("min(1,max(0,({duration:.6}-T)/{d:.6}))")};
    let r=format!("pow(1-({p}),3)");
    let en=if entering {format!("lt(t,{d:.6})")} else {format!("gte(t,{:.6})",duration-d)};
    let (mut sx,mut sy)=("X".to_string(),"Y".to_string());
    let mut mask="1".to_string();
    let mut opacity="1".to_string();
    let sign=if entering {1.0} else {-1.0};
    match s.effect.as_str() {
        "fade"=>opacity=p.clone(),
        "slideLeft"=>sx=format!("X-({:.6})*({r})",if entering{(w as f64-bx).max(0.0)}else{-(bx+bw).max(0.0)}),
        "slideRight"=>sx=format!("X-({:.6})*({r})",if entering{-(bx+bw).max(0.0)}else{(w as f64-bx).max(0.0)}),
        "slideUp"=>sy=format!("Y-({:.6})*({r})",if entering{(h as f64-by).max(0.0)}else{-(by+bh).max(0.0)}),
        "slideDown"=>sy=format!("Y-({:.6})*({r})",if entering{-(by+bh).max(0.0)}else{(h as f64-by).max(0.0)}),
        "slideDiagonal"=>{sx=format!("X-({:.6})*({r})",if entering{(w as f64-bx).max(0.0)}else{-(bx+bw).max(0.0)});sy=format!("Y-({:.6})*({r})",if entering{(h as f64-by).max(0.0)}else{-(by+bh).max(0.0)});},
        "wipeLeft"=>mask=if entering {format!("gte(X,{bx:.5}+{bw:.5}*(1-({p})))")}else{format!("lte(X,{bx:.5}+{bw:.5}*({p}))")},
        "wipeRight"=>mask=if entering {format!("lte(X,{bx:.5}+{bw:.5}*({p}))")}else{format!("gte(X,{bx:.5}+{bw:.5}*(1-({p})))")},
        "wipeUp"=>mask=if entering {format!("gte(Y,{by:.5}+{bh:.5}*(1-({p})))")}else{format!("lte(Y,{by:.5}+{bh:.5}*({p}))")},
        "wipeDown"=>mask=if entering {format!("lte(Y,{by:.5}+{bh:.5}*({p}))")}else{format!("gte(Y,{by:.5}+{bh:.5}*(1-({p})))")},
        "zoom"|"zoomOut"=>{
            let factor=match(s.effect.as_str(),entering){("zoom",true)=>format!("1-0.35*({r})"),("zoom",false)=>format!("1+0.35*({r})"),("zoomOut",true)=>format!("1+0.5*({r})"),_=>format!("1-0.5*({r})")};
            sx=format!("(X-{cx:.4})/({factor})+{cx:.4}");sy=format!("(Y-{cy:.4})/({factor})+{cy:.4}");opacity=p.clone();
        }
        "rotate"=>{
            let angle=format!("({:.6})*({r})",-sign*std::f64::consts::FRAC_PI_2);
            sx=format!("(X-{cx:.4})*cos({angle})-(Y-{cy:.4})*sin({angle})+{cx:.4}");
            sy=format!("(X-{cx:.4})*sin({angle})+(Y-{cy:.4})*cos({angle})+{cy:.4}");opacity=p.clone();
        }
        "pixelate"=>{let cell=format!("max(1,{:.5}*({r}))",bw.min(bh)*0.14);sx=format!("floor(X/({cell}))*({cell})");sy=format!("floor(Y/({cell}))*({cell})");opacity=p.clone();},
        "iris"=>mask=format!("lte(hypot(X-{cx:.4},Y-{cy:.4}),{:.5}*({p}))",bw.hypot(bh)/2.0),
        "squeeze"=>{sy=format!("(Y-{cy:.4})/max(0.001,1-({r}))+{cy:.4}");opacity=p.clone();},
        "flip"=>sx=format!("(X-{cx:.4})/max(0.001,sin((1-({r}))*PI/2))+{cx:.4}"),
        "blur"=>opacity=p.clone(),
        _=>return String::new(),
    }
    let sample=|plane:&str|{
        if s.effect=="blur" {
            let radius=format!("{:.5}*({r})",bw.min(bh)*0.045);
            let mut taps=vec![];
            for yy in -1..=1{for xx in -1..=1{taps.push(format!("{plane}(X+({xx})*({radius}),Y+({yy})*({radius}))"));}}
            format!("({})/9",taps.join("+"))
        }else{format!("{plane}({sx},{sy})")}
    };
    let a=format!("alpha({sx},{sy})*between({sx},0,W-1)*between({sy},0,H-1)*({mask})*({opacity})");
    format!(",format=yuva444p,geq=lum='{}':cb='{}':cr='{}':a='{a}':interpolation=bilinear:enable='{en}'",sample("lum"),sample("cb"),sample("cr"))
}

pub fn append_layer(graph:&mut String,last:&str,chain:&str,key:&str,c:&Clip,w:i64,h:i64,fps:f64,x:f64,y:f64,cx:f64,cy:f64,bw:f64,bh:f64,click_file:Option<&str>)->String{
    let output=format!("fxo{key}");
    let mut alpha=String::new();
    if c.kind==easycut_core::ClipKind::Media{
        if c.opacity<0.999{let _=write!(alpha,",colorchannelmixer=aa={:.5}",c.opacity);}
        if c.fade_in>0.01{let _=write!(alpha,",fade=t=in:st=0:d={:.6}:alpha=1",c.fade_in.min(c.duration()/2.0));}
        if c.fade_out>0.01{let d=c.fade_out.min(c.duration()/2.0);let _=write!(alpha,",fade=t=out:st={:.6}:d={d:.6}:alpha=1",c.duration()-d);}
    }
    let (ox,oy)=if has_transition(c)||click_file.is_some(){
        let _=writeln!(graph,"{chain}[fxsrc{key}];");
        let _=writeln!(graph,"color=c=black@0:s={w}x{h}:r={fps}:d={:.6},format=yuva444p[fxblank{key}];",c.duration());
        let mut fx=String::new();
        let(bx,by)=if c.kind==easycut_core::ClipKind::Media{(x,y)}else{(0.0,0.0)};
        if let Some(s)=&c.transition_in{fx.push_str(&transition(s,c.duration(),true,w,h,cx,cy,bx,by,bw,bh));}
        if let Some(s)=&c.transition_out{fx.push_str(&transition(s,c.duration(),false,w,h,cx,cy,bx,by,bw,bh));}
        let clicks=click_file.map(|file|format!(",subtitles={file}:alpha=1")).unwrap_or_default();
        let _=writeln!(graph,"[fxblank{key}][fxsrc{key}]overlay=x={x:.4}:y={y:.4}:shortest=1:format=auto{clicks}{alpha}{fx},setpts=PTS+{:.6}/TB[fxv{key}];",c.start);
        (0.0,0.0)
    }else{
        let _=writeln!(graph,"{chain}{alpha},setpts=PTS+{:.6}/TB[fxv{key}];",c.start);(x,y)
    };
    let _=writeln!(graph,"[{last}][fxv{key}]overlay=x={ox:.4}:y={oy:.4}:eof_action=pass:enable='gte(t,{:.6})*lt(t,{:.6})'[{output}];",c.start,c.end());
    output
}

fn alpha_tag(channel:u8,opacity:f64,color_alpha:f64)->String{
    format!("\\{channel}a&H{:02X}&",((1.0-opacity.clamp(0.0,1.0)*color_alpha.clamp(0.0,1.0))*255.0).round()as u8)
}

/// 고정된 전체 문장의 글자 배치를 유지한다. ASS override는 글자 폭을 바꾸지 않으며 숨긴 뒤 글자의 외곽선도 함께 숨긴다.
pub fn ass_events(name:&str,st:&TextStyle,text:&str,start:f64,end:f64,x:f64,y:f64,w:i64,h:i64,fps:f64,layer:usize,opacity:f64,fade_in:f64,fade_out:f64)->String{
    let duration=(end-start).max(0.0);
    if duration<=0.0{return String::new();}
    let animation=st.animation.as_deref().unwrap_or("none");
    let window=if easycut_core::effects::TEXT_ANIMATIONS.contains(&animation)&&animation!="none"{st.animation_duration_for(duration)}else{0.0};
    let fi=fade_in.max(0.0).min(duration/2.0);let fo=fade_out.max(0.0).min(duration/2.0);
    let fps=if fps.is_finite(){fps.clamp(1.0,120.0)}else{30.0};
    let first=window.max(fi);let last=duration-fo;
    let mut boundaries=vec![0.0,duration];
    for (a,b) in [(0.0,first),(last,duration)]{
        if b>a{let count=((b-a)*fps).ceil()as usize;for i in 0..=count{boundaries.push((a+i as f64/fps).min(b));}}
    }
    boundaries.sort_by(f64::total_cmp);boundaries.dedup_by(|a,b|(*a-*b).abs()<0.0001);
    let glyphs:Vec<&str>=text.graphemes(true).collect();
    let size=st.font_size*w.min(h)as f64/1080.0;
    let mut events=String::new();
    for pair in boundaries.windows(2){
        let t=pair[0];if pair[1]-t<0.0001{continue;}
        let p=if window>0.0{(t/window).clamp(0.0,1.0)}else{1.0};let r=(1.0-p).powi(3);
        let(mut px,mut py,mut sx,mut sy,mut angle,mut blur)=(x,y,100.0,100.0,0.0,0.0);
        let mut alpha=opacity.clamp(0.0,1.0);
        if fi>0.0{alpha*=(t/fi).clamp(0.0,1.0);}if fo>0.0{alpha*=((duration-t)/fo).clamp(0.0,1.0);}
        let mut clip=String::new();
        if p<1.0{match animation{
            "fade"=>alpha*=p,
            "slideUp"=>{py+=size.max(h as f64*0.055)*r;alpha*=p;},
            "slideDown"=>{py-=size.max(h as f64*0.055)*r;alpha*=p;},
            "pop"=>{let q=p-1.0;sx=(1.0+2.70158*q.powi(3)+1.70158*q.powi(2)).max(0.001)*100.0;sy=sx;alpha*=(p*4.0).min(1.0);},
            "bounce"=>{py-=(p*std::f64::consts::PI*3.0).sin().abs()*(1.0-p)*size*0.7;alpha*=p;},
            "zoomIn"=>{sx=(1.0-0.65*r)*100.0;sy=sx;alpha*=p;},
            "zoomOut"=>{sx=(1.0+0.6*r)*100.0;sy=sx;alpha*=p;},
            "rotateIn"=>{angle=-36.0*r;alpha*=p;},
            "blurIn"=>{blur=size*0.18*r;alpha*=p;},
            "wipeRight"=>clip=format!("\\clip(0,0,{:.0},{h})",w as f64*p),
            "wipeUp"=>clip=format!("\\clip(0,{:.0},{w},{h})",h as f64*(1.0-p)),
            "scaleX"=>{sx=(1.0-0.95*r)*100.0;alpha*=p;},
            "float"=>{py+=h as f64*0.09*r-(p*std::f64::consts::PI*2.0).sin()*(1.0-p)*size*0.12;alpha*=p;},
            "shake"=>{px+=(p*std::f64::consts::PI*8.0).sin()*(1.0-p)*size*0.2;alpha*=p;},
            _=>{}
        }}
        let content=if animation=="typewriter"&&p<1.0{
            let count=((glyphs.len()as f64*p).floor()as usize).min(glyphs.len());
            format!("{}{{\\alpha&HFF&}}{}",super::ass_text(&glyphs[..count].concat()),super::ass_text(&glyphs[count..].concat()))
        }else{super::ass_text(text)};
        let tags=format!("\\an5\\pos({px:.3},{py:.3})\\fscx{sx:.3}\\fscy{sy:.3}\\frz{angle:.3}\\blur{blur:.3}{clip}{}{}{}",alpha_tag(1,alpha,st.text_color.a),alpha_tag(3,alpha,if st.background_color.a>0.01{st.background_color.a}else{st.outline_color.a}),alpha_tag(4,alpha,0.0));
        let _=writeln!(events,"Dialogue: {layer},{},{},{name},,0,0,0,,{{{tags}}}{content}",super::ass_time(start+t),super::ass_time(start+pair[1]));
    }
    events
}
