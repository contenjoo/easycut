import Foundation

enum ClipTransition: String, Codable, CaseIterable, Identifiable {
    case none, fade, slideLeft, slideRight, slideUp, slideDown, wipeLeft, wipeRight, zoom
    case wipeUp, wipeDown, zoomOut, rotate, blur, pixelate, iris, squeeze, flip, slideDiagonal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "없음"
        case .fade: "페이드"
        case .slideLeft: "왼쪽으로 슬라이드"
        case .slideRight: "오른쪽으로 슬라이드"
        case .slideUp: "위로 슬라이드"
        case .slideDown: "아래로 슬라이드"
        case .wipeLeft: "왼쪽으로 와이프"
        case .wipeRight: "오른쪽으로 와이프"
        case .zoom: "확대·축소"
        case .wipeUp: "위로 와이프"
        case .wipeDown: "아래로 와이프"
        case .zoomOut: "멀어지기"
        case .rotate: "회전"
        case .blur: "흐림 전환"
        case .pixelate: "픽셀 전환"
        case .iris: "원형 열기"
        case .squeeze: "접었다 펼치기"
        case .flip: "카드 뒤집기"
        case .slideDiagonal: "대각선 이동"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .fade: "circle.lefthalf.filled"
        case .slideLeft: "arrow.left"
        case .slideRight: "arrow.right"
        case .slideUp: "arrow.up"
        case .slideDown: "arrow.down"
        case .wipeLeft: "rectangle.leadinghalf.filled"
        case .wipeRight: "rectangle.trailinghalf.filled"
        case .wipeUp: "rectangle.bottomhalf.filled"
        case .wipeDown: "rectangle.tophalf.filled"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .zoomOut: "arrow.down.right.and.arrow.up.left"
        case .rotate: "arrow.triangle.2.circlepath"
        case .blur: "drop.halffull"
        case .pixelate: "square.grid.3x3.fill"
        case .iris: "circle.inset.filled"
        case .squeeze: "arrow.up.and.down"
        case .flip: "rectangle.portrait.rotate"
        case .slideDiagonal: "arrow.up.left"
        }
    }

    var category: String {
        switch self {
        case .none, .fade: "기본"
        case .slideLeft, .slideRight, .slideUp, .slideDown, .slideDiagonal: "이동"
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .iris: "열기"
        case .zoom, .zoomOut, .rotate, .squeeze, .flip: "변형"
        case .blur, .pixelate: "분위기"
        }
    }
}

struct TransitionSettings: Codable, Hashable {
    var effect: ClipTransition = .none
    var duration: Double = 0.5

    /// 짧은 클립에서도 시작·끝 효과가 서로 겹치지 않게 제한한다.
    func clampedDuration(for clipDuration: Double) -> Double {
        guard effect != .none, duration.isFinite, clipDuration.isFinite else { return 0 }
        return min(max(0, duration), max(0, clipDuration) / 2)
    }
}

enum TextAnimation: String, Codable, CaseIterable, Identifiable {
    case none, fade, slideUp, slideDown, pop, typewriter
    case bounce, zoomIn, zoomOut, rotateIn, blurIn, wipeRight, wipeUp, scaleX, float, shake
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "없음"
        case .fade: "서서히 나타나기"
        case .slideUp: "아래에서 올라오기"
        case .slideDown: "위에서 내려오기"
        case .pop: "팝업"
        case .typewriter: "타이핑"
        case .bounce: "통통 튀기"
        case .zoomIn: "작게 시작하기"
        case .zoomOut: "크게 시작하기"
        case .rotateIn: "돌아 나타나기"
        case .blurIn: "선명해지기"
        case .wipeRight: "오른쪽으로 나타나기"
        case .wipeUp: "위로 나타나기"
        case .scaleX: "가로로 펼치기"
        case .float: "떠오르기"
        case .shake: "살짝 흔들기"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .fade: "sun.max"
        case .slideUp: "arrow.up"
        case .slideDown: "arrow.down"
        case .pop: "sparkles"
        case .typewriter: "keyboard"
        case .bounce: "arrow.up.and.down"
        case .zoomIn: "arrow.up.left.and.arrow.down.right"
        case .zoomOut: "arrow.down.right.and.arrow.up.left"
        case .rotateIn: "arrow.triangle.2.circlepath"
        case .blurIn: "drop.halffull"
        case .wipeRight: "arrow.right.to.line"
        case .wipeUp: "arrow.up.to.line"
        case .scaleX: "arrow.left.and.right"
        case .float: "wind"
        case .shake: "waveform.path"
        }
    }

    var category: String {
        switch self {
        case .none, .fade, .typewriter: "기본"
        case .slideUp, .slideDown, .bounce, .float, .shake: "이동"
        case .pop, .zoomIn, .zoomOut, .rotateIn, .scaleX: "변형"
        case .wipeRight, .wipeUp: "열기"
        case .blurIn: "분위기"
        }
    }
}

enum VisualFilter: String, Codable, CaseIterable, Identifiable {
    case none, warm, cool, mono, sepia, vivid, soft, vintage, dramatic, noir
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "원본"
        case .warm: "따뜻하게"
        case .cool: "시원하게"
        case .mono: "흑백"
        case .sepia: "세피아"
        case .vivid: "선명하게"
        case .soft: "부드럽게"
        case .vintage: "빈티지"
        case .dramatic: "드라마틱"
        case .noir: "느와르"
        }
    }
    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .warm: "sun.max.fill"
        case .cool: "snowflake"
        case .mono: "circle.lefthalf.filled"
        case .sepia: "camera.filters"
        case .vivid: "paintpalette.fill"
        case .soft: "cloud.fill"
        case .vintage: "camera.fill"
        case .dramatic: "bolt.fill"
        case .noir: "moon.fill"
        }
    }
    var category: String {
        switch self {
        case .none: "기본"
        case .warm, .cool, .vivid: "색감"
        case .mono, .sepia, .vintage, .noir: "필름"
        case .soft, .dramatic: "분위기"
        }
    }
}
