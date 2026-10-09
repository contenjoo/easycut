//! 개인정보 가리기: 맥 `PrivacyScanner.swift`·`BlurRegion`과 같은 규칙.
//! 화면 글자(OCR 결과)에서 전화번호·주민번호 등을 찾고, 여러 장면의 결과를 시간 구간으로 잇는다.
//! OCR·영상 디코딩은 플랫폼 쪽(앱)에서 하고 여기는 순수 로직만 둔다.

use crate::model::{Clip, Id};
use fancy_regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// 맥 파일 형식의 클립 키
pub const BLURS_KEY: &str = "blurs";
/// 직접 그린 영역 (다시 찾아도 남는다)
pub const MANUAL_LABEL: &str = "직접 지정";
/// 자동 찾기가 붙이는 이름. 다시 찾으면 이 영역들만 새 결과로 바뀌고, 직접 그렸거나 AI가 추가한 영역은 남는다
pub const AUTO_LABELS: &[&str] = &["전화번호", "주민등록번호", "이메일", "카드번호", "계좌번호", "여권번호", "지정한 글자", "얼굴"];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum BlurStyle {
    #[default]
    Blur,
    Mosaic,
    Box,
}

impl BlurStyle {
    pub fn parse(s: &str) -> BlurStyle {
        match s {
            "mosaic" => BlurStyle::Mosaic,
            "box" => BlurStyle::Box,
            _ => BlurStyle::Blur,
        }
    }
}

/// 화면 일부 가리기. 좌표는 원본 화면 비율(왼쪽 위 원점), 시간은 원본 미디어 기준 초.
/// 맥 디코더는 기본값을 쓰지 않으므로 `text` 말고는 항상 기록한다.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct BlurRegion {
    pub id: Id,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub start: f64,
    pub end: f64,
    pub style: BlurStyle,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

impl Default for BlurRegion {
    fn default() -> Self {
        BlurRegion { id: Id::new(), x: 0.0, y: 0.0, w: 0.0, h: 0.0, start: 0.0, end: 0.0, style: BlurStyle::Blur, label: String::new(), text: None }
    }
}

impl BlurRegion {
    pub fn is_auto_found(&self) -> bool {
        AUTO_LABELS.contains(&self.label.as_str())
    }

    pub fn is_active(&self, s: f64) -> bool {
        s >= self.start - 0.0001 && s < self.end
    }

    /// 화면 밖으로 나가지 않게, 너무 작지 않게
    pub fn clamped(mut self) -> Self {
        self.w = self.w.clamp(0.005, 1.0);
        self.h = self.h.clamp(0.005, 1.0);
        self.x = self.x.clamp(0.0, 1.0 - self.w);
        self.y = self.y.clamp(0.0, 1.0 - self.h);
        if self.end < self.start + 0.05 {
            self.end = self.start + 0.05;
        }
        self
    }
}

impl Clip {
    pub fn blurs(&self) -> Vec<BlurRegion> {
        self.extra.get(BLURS_KEY).and_then(|v| serde_json::from_value(v.clone()).ok()).unwrap_or_default()
    }

    pub fn set_blurs(&mut self, list: Vec<BlurRegion>) {
        if list.is_empty() {
            self.extra.remove(BLURS_KEY);
        } else {
            self.extra.insert(BLURS_KEY.into(), serde_json::to_value(list).unwrap_or_default());
        }
    }
}

// MARK: 글자 형태

#[derive(Clone, Debug, Default)]
pub struct Options {
    /// 전화번호·주민번호·이메일·카드·계좌·여권 번호
    pub patterns: bool,
    pub faces: bool,
    /// 이 글자가 들어간 곳도 가린다 (띄어쓰기 무시)
    pub keywords: Vec<String>,
}

struct Pattern {
    label: &'static str,
    regex: Regex,
    digits: Option<(usize, usize)>,
}

fn patterns() -> &'static [Pattern] {
    static P: OnceLock<Vec<Pattern>> = OnceLock::new();
    P.get_or_init(|| {
        let re = |s: &str| Regex::new(&format!("(?i){s}")).unwrap();
        vec![
            Pattern { label: "주민등록번호", regex: re(r"(?<![0-9])[0-9]{6}\s?[-–]\s?[1-8][0-9*●•xX]{6}(?![0-9])"), digits: None },
            Pattern { label: "주민등록번호", regex: re(r"(?<![0-9])[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[1-8][0-9]{6}(?![0-9])"), digits: None },
            Pattern { label: "이메일", regex: re(r"[A-Z0-9._%+\-]+\s?@\s?[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"), digits: None },
            Pattern {
                label: "전화번호",
                regex: re(r"(?<![0-9])(?:\+?82[\s\-]?\(?0?|\(?0)(?:1[016789]|2|[3-6][1-5]|70|50[0-9]?)\)?[\s\-.]?[0-9]{3,4}[\s\-.]?[0-9]{4}(?![0-9])"),
                digits: Some((9, 13)),
            },
            Pattern { label: "카드번호", regex: re(r"(?<![0-9])[0-9]{4}[\s\-][0-9*]{4}[\s\-][0-9*]{4}[\s\-][0-9]{3,4}(?![0-9])"), digits: None },
            Pattern { label: "계좌번호", regex: re(r"(?<![0-9])[0-9]{2,6}-[0-9]{2,6}-[0-9]{2,7}(?:-[0-9]{1,3})?(?![0-9\-])"), digits: Some((10, 16)) },
            Pattern { label: "여권번호", regex: re(r"(?<![A-Z0-9])[MSROD][0-9]{3}[A-Z0-9][0-9]{4}(?![A-Z0-9])"), digits: None },
        ]
    })
}

/// OCR이 숫자를 글자로 잘못 읽는 경우(O→0, l→1)를 고친 같은 길이의 글자 배열
pub fn digit_fixed(s: &str) -> Vec<char> {
    let mut out: Vec<char> = s.chars().collect();
    // 숫자 옆 글자부터 고치고, 고친 글자 옆도 이어서 고친다 (Ol0 → 010)
    let mut changed = true;
    while changed {
        changed = false;
        for i in 0..out.len() {
            let fix = match out[i] {
                'O' | 'o' => '0',
                'l' | 'I' | '|' => '1',
                _ => continue,
            };
            let near = (i > 0 && out[i - 1].is_ascii_digit()) || (i + 1 < out.len() && out[i + 1].is_ascii_digit());
            if near {
                out[i] = fix;
                changed = true;
            }
        }
    }
    out
}

/// 한 줄에서 개인정보에 해당하는 글자 범위 (글자 단위 오프셋)
pub fn matches(line: &str, opt: &Options) -> Vec<(&'static str, std::ops::Range<usize>)> {
    let mut out: Vec<(&'static str, std::ops::Range<usize>)> = vec![];
    if opt.patterns {
        let fixed: String = digit_fixed(line).into_iter().collect();
        for p in patterns() {
            for m in p.regex.find_iter(&fixed).flatten() {
                let found = m.as_str();
                if let Some((lo, hi)) = p.digits {
                    let n = found.chars().filter(|c| c.is_ascii_digit()).count();
                    if n < lo || n > hi {
                        continue;
                    }
                }
                let a = fixed[..m.start()].chars().count();
                let b = a + found.chars().count();
                // 같은 자리를 이미 다른 형태로 찾았으면 건너뛴다 (주민번호 ⊂ 계좌번호 등)
                if out.iter().any(|(_, r)| r.start < b && a < r.end) {
                    continue;
                }
                out.push((p.label, a..b));
            }
        }
    }
    // 지정한 글자: 띄어쓰기를 무시하고 찾는다
    let packed: Vec<(usize, char)> = line.chars().enumerate().filter(|(_, c)| !c.is_whitespace()).collect();
    let hay: Vec<char> = packed.iter().flat_map(|(_, c)| c.to_lowercase()).collect();
    if hay.len() == packed.len() {
        for k in &opt.keywords {
            let key: Vec<char> = k.chars().filter(|c| !c.is_whitespace()).flat_map(|c| c.to_lowercase()).collect();
            if key.is_empty() || key.len() > hay.len() {
                continue;
            }
            let mut i = 0;
            while i + key.len() <= hay.len() {
                if hay[i..i + key.len()] == key[..] {
                    out.push(("지정한 글자", packed[i].0..packed[i + key.len() - 1].0 + 1));
                    i += key.len();
                } else {
                    i += 1;
                }
            }
        }
    }
    out
}

// MARK: 장면 → 영역

/// 화면 비율 사각형 (왼쪽 위 원점)
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn union(&self, o: &Rect) -> Rect {
        let (x, y) = (self.x.min(o.x), self.y.min(o.y));
        Rect { x, y, w: (self.x + self.w).max(o.x + o.w) - x, h: (self.y + self.h).max(o.y + o.h) - y }
    }

    pub fn clip_unit(&self) -> Rect {
        let (x0, y0) = (self.x.max(0.0), self.y.max(0.0));
        let (x1, y1) = ((self.x + self.w).min(1.0), (self.y + self.h).min(1.0));
        Rect { x: x0, y: y0, w: (x1 - x0).max(0.0), h: (y1 - y0).max(0.0) }
    }

    /// 글자 상자를 조금 넓힌다 (OCR 상자는 글자에 딱 붙어 있다). aspect = 화면 가로/세로
    pub fn padded(&self, aspect: f64) -> Rect {
        let dy = self.h * 0.3;
        let dx = dy / aspect.max(0.01);
        Rect { x: self.x - dx, y: self.y - dy, w: self.w + 2.0 * dx, h: self.h + 2.0 * dy }.clip_unit()
    }

    pub fn iou(&self, o: &Rect) -> f64 {
        let ix = (self.x + self.w).min(o.x + o.w) - self.x.max(o.x);
        let iy = (self.y + self.h).min(o.y + o.h) - self.y.max(o.y);
        if ix <= 0.0 || iy <= 0.0 {
            return 0.0;
        }
        let i = ix * iy;
        i / (self.w * self.h + o.w * o.h - i)
    }
}

/// OCR 단어 하나 (줄 안의 글자 범위와 위치)
#[derive(Clone, Debug)]
pub struct OcrWord {
    pub text: String,
    pub rect: Rect,
}

/// 한 장면에서 찾은 것
#[derive(Clone, Debug)]
pub struct Hit {
    pub label: String,
    pub text: String,
    pub rect: Rect,
}

/// OCR 줄(단어 목록)에서 개인정보 자리 찾기. 단어를 띄어쓰기로 이어 한 줄로 보고, 걸린 단어들의 상자를 합친다.
pub fn hits_in_line(words: &[OcrWord], opt: &Options, aspect: f64) -> Vec<Hit> {
    let mut line = String::new();
    let mut spans = vec![];
    for (i, w) in words.iter().enumerate() {
        if i > 0 {
            line.push(' ');
        }
        let a = line.chars().count();
        line.push_str(&w.text);
        spans.push(a..line.chars().count());
    }
    let chars: Vec<char> = line.chars().collect();
    let mut out = vec![];
    for (label, r) in matches(&line, opt) {
        let mut rect: Option<Rect> = None;
        for (i, s) in spans.iter().enumerate() {
            if s.start < r.end && r.start < s.end {
                rect = Some(match rect { Some(x) => x.union(&words[i].rect), None => words[i].rect });
            }
        }
        if let Some(rect) = rect {
            out.push(Hit { label: label.into(), text: chars[r].iter().collect(), rect: rect.padded(aspect) });
        }
    }
    out
}

/// 연속된 장면에서 같은 자리의 같은 정보를 하나의 영역으로 잇는다
pub struct Tracker {
    step: f64,
    from: f64,
    to: f64,
    open: Vec<(Hit, Rect, f64, f64)>,
    done: Vec<BlurRegion>,
}

impl Tracker {
    pub fn new(step: f64, from: f64, to: f64) -> Self {
        Tracker { step, from, to, open: vec![], done: vec![] }
    }

    pub fn add(&mut self, hits: &[Hit], t: f64) {
        let mut pool = std::mem::take(&mut self.open);
        let mut next = vec![];
        for h in hits {
            if let Some(i) = pool.iter().position(|o| o.0.label == h.label && o.0.rect.iou(&h.rect) > 0.3) {
                let mut o = pool.remove(i);
                o.1 = o.1.union(&h.rect);
                o.0 = h.clone();
                o.3 = t;
                next.push(o);
            } else {
                next.push((h.clone(), h.rect, t, t));
            }
        }
        for o in pool {
            self.close(o);
        }
        self.open = next;
    }

    fn close(&mut self, (hit, rect, first, last): (Hit, Rect, f64, f64)) {
        // 앞뒤로 한 간격씩 넉넉하게 (읽은 시점 사이에 나타나고 사라질 수 있다)
        let a = (first - self.step).max(self.from);
        let b = (last + self.step).min(self.to);
        self.done.push(BlurRegion {
            x: rect.x,
            y: rect.y,
            w: rect.w,
            h: rect.h,
            start: a,
            end: b.max(a + 0.1),
            label: hit.label,
            text: if hit.text.is_empty() { None } else { Some(hit.text) },
            ..Default::default()
        });
    }

    pub fn finish(mut self) -> Vec<BlurRegion> {
        for o in std::mem::take(&mut self.open) {
            self.close(o);
        }
        self.done.sort_by(|a, b| a.start.total_cmp(&b.start));
        self.done
    }
}

/// 장면 바뀜 비교용 작은 회색 그림 (320×180). bgra: 4바이트 화소
pub fn thumbnail(bgra: &[u8], w: usize, h: usize) -> Vec<u8> {
    const TW: usize = 320;
    const TH: usize = 180;
    let mut out = vec![0u8; TW * TH];
    if w == 0 || h == 0 || bgra.len() < w * h * 4 {
        return out;
    }
    for ty in 0..TH {
        let y = ty * h / TH;
        for tx in 0..TW {
            let x = tx * w / TW;
            let i = (y * w + x) * 4;
            let (b, g, r) = (bgra[i] as u32, bgra[i + 1] as u32, bgra[i + 2] as u32);
            out[ty * TW + tx] = ((r * 77 + g * 150 + b * 29) >> 8) as u8;
        }
    }
    out
}

/// 작은 글자 하나가 새로 나타나도 알아채도록 뚜렷하게 바뀐 점의 수로 판단한다
pub fn changed(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() || a.is_empty() {
        return true;
    }
    a.iter().zip(b).filter(|(x, y)| (**x as i32 - **y as i32).abs() > 28).take(3).count() >= 3
}

/// 맥과 같은 간격: 최소 0.5초, 긴 영상은 최대 1500장
pub fn step_for(span: f64) -> f64 {
    (span / 1500.0).max(0.5)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(s: &str) -> Vec<&'static str> {
        matches(s, &Options { patterns: true, ..Default::default() }).into_iter().map(|m| m.0).collect()
    }

    #[test]
    fn patterns_match_like_mac() {
        assert_eq!(kinds("연락처: 010-1234-5678"), ["전화번호"]);
        assert_eq!(kinds("tel 02)123-4567"), ["전화번호"]);
        assert_eq!(kinds("+82 10 1234 5678"), ["전화번호"]);
        assert_eq!(kinds("주민번호 900101-1234567"), ["주민등록번호"]);
        assert_eq!(kinds("900101-1******"), ["주민등록번호"]);
        assert_eq!(kinds("메일 Hong.Gil@example.co.kr 로"), ["이메일"]);
        assert_eq!(kinds("카드 1234-5678-9012-3456"), ["카드번호"]);
        assert_eq!(kinds("국민 123456-78-901234"), ["계좌번호"]);
        assert_eq!(kinds("Ol0-1234-5678"), ["전화번호"]);
        assert!(kinds("2024-01-15 회의, 버전 1.8.2, 3,000원, 12:30").is_empty());
    }

    #[test]
    fn keywords_ignore_spaces() {
        let o = Options { keywords: vec!["홍길동".into()], ..Default::default() };
        let m = matches("작성자 홍 길동 님", &o);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].1, 4..8);
    }

    #[test]
    fn hits_union_words_and_track_over_time() {
        let r = |x: f64| Rect { x, y: 0.5, w: 0.1, h: 0.05 };
        let words = vec![
            OcrWord { text: "Call".into(), rect: r(0.1) },
            OcrWord { text: "010-2345-6789".into(), rect: r(0.25) },
        ];
        let o = Options { patterns: true, ..Default::default() };
        let hits = hits_in_line(&words, &o, 16.0 / 9.0);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].label, "전화번호");
        assert!(hits[0].rect.x > 0.2 && hits[0].rect.x < 0.25);
        let mut t = Tracker::new(0.5, 0.0, 6.0);
        for i in 0..6 {
            t.add(&hits, i as f64 * 0.5);
        }
        t.add(&[], 3.0);
        let out = t.finish();
        assert_eq!(out.len(), 1);
        assert_eq!((out[0].start, out[0].end), (0.0, 3.0));
    }

    #[test]
    fn blurs_round_trip_in_mac_format() {
        let mut c = Clip::default();
        c.set_blurs(vec![BlurRegion { x: 0.1, y: 0.2, w: 0.3, h: 0.1, start: 1.0, end: 2.0, label: "전화번호".into(), ..Default::default() }]);
        let v = serde_json::to_value(&c).unwrap();
        let b = &v["blurs"][0];
        for k in ["id", "x", "y", "w", "h", "start", "end", "style", "label"] {
            assert!(b.get(k).is_some(), "{k}");
        }
        assert_eq!(b["style"], "blur");
        assert!(b.get("text").is_none());
        let back: Clip = serde_json::from_value(v).unwrap();
        assert_eq!(back.blurs()[0].label, "전화번호");
        c.set_blurs(vec![]);
        assert!(c.extra.get("blurs").is_none());
    }

    #[test]
    fn change_detection_sees_small_text() {
        let a = vec![0u8; 320 * 180];
        let mut b = a.clone();
        assert!(!changed(&a, &b));
        b[100] = 200;
        b[101] = 200;
        b[102] = 200;
        assert!(changed(&a, &b));
    }
}
