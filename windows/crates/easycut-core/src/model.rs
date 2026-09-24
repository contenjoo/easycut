//! `.easycut` 프로젝트 데이터 모델. macOS 앱 `Sources/EasyCut/Model/Model.swift`와 JSON 호환.
//!
//! 호환 규칙:
//! - 키 이름은 Swift 프로퍼티명 그대로 (camelCase).
//! - UUID는 대문자 문자열 (Swift `UUID` 인코딩과 동일).
//! - Swift 디코더는 기본값을 쓰지 않으므로, Optional이 아닌 필드는 저장 시 항상 기록한다.
//!   (생략 가능: `MediaAsset.words`, `MediaAsset.originalPath`, `Clip.assetID`)
//! - 읽을 때는 빠진 키를 기본값으로 채워 관대하게 받아들인다.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use uuid::Uuid;

/// Swift `UUID`와 같은 형식(대문자, 하이픈)으로 직렬화되는 ID
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct Id(pub Uuid);

impl Id {
    pub fn new() -> Self {
        Id(Uuid::new_v4())
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            self.0.hyphenated().encode_upper(&mut Uuid::encode_buffer())
        )
    }
}

impl fmt::Debug for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl Serialize for Id {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for Id {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Uuid::parse_str(&s)
            .map(Id)
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    #[default]
    Video,
    Audio,
    Image,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Default for Rgba {
    fn default() -> Self {
        Rgba::WHITE
    }
}

impl Rgba {
    pub const WHITE: Rgba = Rgba {
        r: 1.0,
        g: 1.0,
        b: 1.0,
        a: 1.0,
    };
    pub const BLACK: Rgba = Rgba {
        r: 0.0,
        g: 0.0,
        b: 0.0,
        a: 1.0,
    };
    pub const YELLOW: Rgba = Rgba {
        r: 1.0,
        g: 0.86,
        b: 0.2,
        a: 1.0,
    };
    pub const CAPTION_BG: Rgba = Rgba {
        r: 0.0,
        g: 0.0,
        b: 0.0,
        a: 0.6,
    };
    pub const CLEAR: Rgba = Rgba {
        r: 0.0,
        g: 0.0,
        b: 0.0,
        a: 0.0,
    };
}

/// 한 단어(어절) 단위 인식 결과. 시간은 원본 미디어 기준 초.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Word {
    pub id: Id,
    pub text: String,
    pub start: f64,
    pub end: f64,
}

impl Default for Word {
    fn default() -> Self {
        Word {
            id: Id::new(),
            text: String::new(),
            start: 0.0,
            end: 0.0,
        }
    }
}

impl Word {
    pub fn new(text: impl Into<String>, start: f64, end: f64) -> Self {
        Word {
            id: Id::new(),
            text: text.into(),
            start,
            end,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct MediaAsset {
    pub id: Id,
    /// 절대 경로
    pub path: String,
    pub name: String,
    pub kind: MediaKind,
    pub duration: f64,
    pub width: f64,
    pub height: f64,
    pub has_audio: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<Word>>,
    /// MKV 등 변환해서 가져온 경우 원본 파일 경로
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_path: Option<String>,
    /// 이 버전이 모르는 항목(맥 앱의 그룹·모양·클릭 기록 등)도 그대로 보존한다
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for MediaAsset {
    fn default() -> Self {
        MediaAsset {
            id: Id::new(),
            path: String::new(),
            name: String::new(),
            kind: MediaKind::Video,
            duration: 0.0,
            width: 0.0,
            height: 0.0,
            has_audio: false,
            words: None,
            original_path: None,
            extra: Default::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TextStyle {
    /// 1080p 기준 글자 크기
    pub font_size: f64,
    pub bold: bool,
    pub text_color: Rgba,
    pub background_color: Rgba,
    pub outline: bool,
    pub outline_color: Rgba,
    /// 텍스트 박스 중심의 세로 위치 (0 = 위, 1 = 아래)
    pub position_y: f64,
    /// 빈 문자열 = 시스템 기본 글꼴
    pub font_name: String,
}

impl Default for TextStyle {
    fn default() -> Self {
        TextStyle::caption()
    }
}

impl TextStyle {
    pub fn caption() -> Self {
        TextStyle {
            font_size: 54.0,
            bold: true,
            text_color: Rgba::WHITE,
            background_color: Rgba::CAPTION_BG,
            outline: false,
            outline_color: Rgba::BLACK,
            position_y: 0.88,
            font_name: String::new(),
        }
    }

    pub fn title() -> Self {
        TextStyle {
            font_size: 96.0,
            background_color: Rgba::CLEAR,
            outline: true,
            position_y: 0.5,
            ..TextStyle::caption()
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ClipKind {
    #[default]
    Media,
    Text,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Clip {
    pub id: Id,
    pub kind: ClipKind,
    #[serde(rename = "assetID", skip_serializing_if = "Option::is_none")]
    pub asset_id: Option<Id>,
    pub text: String,
    pub text_style: TextStyle,
    /// 타임라인 시작 (초)
    pub start: f64,
    /// 원본 구간 (초). 이미지/텍스트는 0...길이
    pub source_in: f64,
    pub source_out: f64,
    pub speed: f64,
    pub volume: f64,
    pub opacity: f64,
    pub scale: f64,
    /// 캔버스 대비 위치 이동 (-1...1, 캔버스 폭/높이의 비율)
    pub offset_x: f64,
    pub offset_y: f64,
    pub fade_in: f64,
    pub fade_out: f64,
    /// 이 버전이 모르는 항목(맥 앱의 그룹·모양·클릭 기록 등)도 그대로 보존한다
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for Clip {
    fn default() -> Self {
        Clip {
            id: Id::new(),
            kind: ClipKind::Media,
            asset_id: None,
            text: String::new(),
            text_style: TextStyle::title(),
            start: 0.0,
            source_in: 0.0,
            source_out: 0.0,
            speed: 1.0,
            volume: 1.0,
            opacity: 1.0,
            scale: 1.0,
            offset_x: 0.0,
            offset_y: 0.0,
            fade_in: 0.0,
            fade_out: 0.0,
            extra: Default::default(),
        }
    }
}

impl Clip {
    pub fn duration(&self) -> f64 {
        ((self.source_out - self.source_in) / self.speed).max(0.0)
    }

    pub fn end(&self) -> f64 {
        self.start + self.duration()
    }

    /// 타임라인 시간 → 원본 시간
    pub fn source_time(&self, t: f64) -> f64 {
        self.source_in + (t - self.start) * self.speed
    }

    /// 원본 시간 → 타임라인 시간
    pub fn timeline_time(&self, s: f64) -> f64 {
        self.start + (s - self.source_in) / self.speed
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Track {
    pub id: Id,
    pub name: String,
    pub clips: Vec<Clip>,
    pub muted: bool,
    pub hidden: bool,
    /// 이 버전이 모르는 항목(맥 앱의 그룹·모양·클릭 기록 등)도 그대로 보존한다
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for Track {
    fn default() -> Self {
        Track::named("")
    }
}

impl Track {
    pub fn named(name: impl Into<String>) -> Self {
        Track {
            id: Id::new(),
            name: name.into(),
            clips: vec![],
            muted: false,
            hidden: false,
            extra: Default::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Caption {
    pub id: Id,
    pub start: f64,
    pub end: f64,
    pub text: String,
    /// 이 버전이 모르는 항목(맥 앱의 그룹·모양·클릭 기록 등)도 그대로 보존한다
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for Caption {
    fn default() -> Self {
        Caption {
            id: Id::new(),
            start: 0.0,
            end: 0.0,
            text: String::new(),
            extra: Default::default(),
        }
    }
}

impl Caption {
    pub fn new(start: f64, end: f64, text: impl Into<String>) -> Self {
        Caption {
            id: Id::new(),
            start,
            end,
            text: text.into(),
            extra: Default::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Project {
    pub version: i64,
    pub assets: Vec<MediaAsset>,
    /// 0번이 맨 아래(기본) 트랙. 위 트랙이 아래 트랙을 덮는다.
    pub tracks: Vec<Track>,
    pub captions: Vec<Caption>,
    pub caption_style: TextStyle,
    pub show_captions: bool,
    pub canvas_width: f64,
    pub canvas_height: f64,
    pub fps: f64,
    pub background: Rgba,
    /// 이 버전이 모르는 항목(맥 앱의 그룹·모양·클릭 기록 등)도 그대로 보존한다
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl Default for Project {
    fn default() -> Self {
        Project {
            version: 1,
            assets: vec![],
            tracks: vec![
                Track::named("트랙 1"),
                Track::named("트랙 2"),
                Track::named("트랙 3"),
            ],
            captions: vec![],
            caption_style: TextStyle::caption(),
            show_captions: true,
            canvas_width: 1920.0,
            canvas_height: 1080.0,
            fps: 30.0,
            background: Rgba::BLACK,
            extra: Default::default(),
        }
    }
}

impl Project {
    pub fn duration(&self) -> f64 {
        self.tracks
            .iter()
            .flat_map(|t| t.clips.iter())
            .map(Clip::end)
            .fold(0.0, f64::max)
    }

    pub fn asset(&self, id: Option<Id>) -> Option<&MediaAsset> {
        let id = id?;
        self.assets.iter().find(|a| a.id == id)
    }

    pub fn locate(&self, clip: Id) -> Option<(usize, usize)> {
        self.tracks
            .iter()
            .enumerate()
            .find_map(|(ti, t)| t.clips.iter().position(|c| c.id == clip).map(|ci| (ti, ci)))
    }

    pub fn clip(&self, id: Id) -> Option<&Clip> {
        let (ti, ci) = self.locate(id)?;
        Some(&self.tracks[ti].clips[ci])
    }

    pub fn clip_mut(&mut self, id: Id) -> Option<&mut Clip> {
        let (ti, ci) = self.locate(id)?;
        Some(&mut self.tracks[ti].clips[ci])
    }

    /// `.easycut` 파일 읽기
    pub fn from_json(data: &str) -> serde_json::Result<Project> {
        serde_json::from_str(data)
    }

    /// `.easycut` 파일 쓰기. 맥 앱(`.sortedKeys`)과 같이 키를 정렬한다.
    pub fn to_json(&self) -> serde_json::Result<String> {
        // serde_json::Value의 Map은 기본적으로 BTreeMap이라 키가 정렬된다
        let v = serde_json::to_value(self)?;
        serde_json::to_string(&v)
    }
}
