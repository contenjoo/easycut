import Foundation
import CoreGraphics
import AppKit

enum MediaKind: String, Codable {
    case video, audio, image
}

struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
    static let yellow = RGBA(r: 1, g: 0.86, b: 0.2, a: 1)
    static let captionBG = RGBA(r: 0, g: 0, b: 0, a: 0.6)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        r = Double(c.redComponent); g = Double(c.greenComponent)
        b = Double(c.blueComponent); a = Double(c.alphaComponent)
    }
}

/// 한 단어(어절) 단위 인식 결과. 시간은 원본 미디어 기준 초.
struct Word: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

struct MediaAsset: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var name: String
    var kind: MediaKind
    var duration: Double
    var width: Double
    var height: Double
    var hasAudio: Bool
    var words: [Word]?

    var url: URL { URL(fileURLWithPath: path) }
    var isMissing: Bool { !FileManager.default.fileExists(atPath: path) }
}

struct TextStyle: Codable, Hashable {
    /// 1080p 기준 글자 크기
    var fontSize: Double = 54
    var bold: Bool = true
    var textColor: RGBA = .white
    var backgroundColor: RGBA = .captionBG
    var outline: Bool = false
    var outlineColor: RGBA = .black
    /// 텍스트 박스 중심의 세로 위치 (0 = 위, 1 = 아래)
    var positionY: Double = 0.88
    var fontName: String = ""

    static let caption = TextStyle()
    static let title = TextStyle(fontSize: 96, bold: true, textColor: .white,
                                 backgroundColor: .clear, outline: true, outlineColor: .black,
                                 positionY: 0.5)
}

enum ClipKind: String, Codable {
    case media, text
}

struct Clip: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ClipKind = .media
    var assetID: UUID?
    var text: String = ""
    var textStyle: TextStyle = .title
    /// 타임라인 시작 (초)
    var start: Double
    /// 원본 구간 (초). 이미지/텍스트는 0...길이
    var sourceIn: Double
    var sourceOut: Double
    var speed: Double = 1
    var volume: Double = 1
    var opacity: Double = 1
    var scale: Double = 1
    /// 캔버스 대비 위치 이동 (-1...1, 캔버스 폭/높이의 비율)
    var offsetX: Double = 0
    var offsetY: Double = 0
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    var duration: Double { max(0, (sourceOut - sourceIn) / speed) }
    var end: Double { start + duration }

    /// 타임라인 시간 → 원본 시간
    func sourceTime(atTimeline t: Double) -> Double { sourceIn + (t - start) * speed }
    /// 원본 시간 → 타임라인 시간
    func timelineTime(atSource s: Double) -> Double { start + (s - sourceIn) / speed }
}

struct Track: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var clips: [Clip] = []
    var muted: Bool = false
    var hidden: Bool = false
}

struct Caption: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct Project: Codable, Hashable {
    var version: Int = 1
    var assets: [MediaAsset] = []
    /// 0번이 맨 아래(기본) 트랙. 위 트랙이 아래 트랙을 덮는다.
    var tracks: [Track] = [Track(name: "트랙 1"), Track(name: "트랙 2"), Track(name: "트랙 3")]
    var captions: [Caption] = []
    var captionStyle: TextStyle = .caption
    var showCaptions: Bool = true
    var canvasWidth: Double = 1920
    var canvasHeight: Double = 1080
    var fps: Double = 30
    var background: RGBA = .black

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }

    var duration: Double {
        tracks.flatMap(\.clips).map(\.end).max() ?? 0
    }

    func asset(_ id: UUID?) -> MediaAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }

    func locate(clip id: UUID) -> (track: Int, index: Int)? {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    func clip(_ id: UUID) -> Clip? {
        guard let loc = locate(clip: id) else { return nil }
        return tracks[loc.track].clips[loc.index]
    }
}
