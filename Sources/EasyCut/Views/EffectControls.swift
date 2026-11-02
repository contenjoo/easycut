import SwiftUI
import AppKit

enum InspectorSection: String, CaseIterable, Identifiable {
    case basic, effects, layout
    var id: String { rawValue }
    var label: String { switch self { case .basic: "기본"; case .effects: "효과"; case .layout: "배치" } }
    var symbol: String { switch self { case .basic: "slider.horizontal.3"; case .effects: "sparkles"; case .layout: "rectangle.center.inset.filled" } }
}

struct InspectorTabBar: View {
    @Binding var selection: InspectorSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(InspectorSection.allCases) { section in
                Button { selection = section } label: {
                    Label(L(section.label), systemImage: section.symbol)
                        .font(.system(size: 12, weight: selection == section ? .semibold : .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(selection == section ? Theme.accentColor : .secondary)
                        .background(selection == section ? Theme.inspectorSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector-tab-\(section.rawValue)")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.inspectorInset, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("inspector-tabs")
    }
}

struct EffectChoice: Identifiable {
    let id: String
    let label: String
    let symbol: String
}

/// 효과마다 이름과 아이콘을 함께 표시하고 체크로 선택 상태를 알린다.
struct EffectCardGrid: View {
    let choices: [EffectChoice]
    let selectedID: String
    let identifier: String
    let select: (String) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 7) {
            ForEach(choices) { choice in
                let selected = selectedID == choice.id
                Button { select(choice.id) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: choice.symbol)
                            .font(.system(size: 18, weight: .regular))
                            .frame(height: 20)
                        Text(L(choice.label)).font(.system(size: 10, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(selected ? Theme.accentColor : Color.primary.opacity(0.82))
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                    .background(selected ? Theme.inspectorSelection : Theme.inspectorCard, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? Theme.accentColor.opacity(0.8) : Theme.inspectorBorder, lineWidth: selected ? 1.5 : 0.7)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                                .foregroundStyle(Theme.accentColor)
                                .padding(5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(L(choice.label))
                .accessibilityLabel(L(choice.label))
                .accessibilityIdentifier("\(identifier)-\(choice.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

struct EffectPreviewButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("효과 재생", systemImage: "play.fill").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).controlSize(.regular)
            .accessibilityIdentifier("effect-preview-button")
    }
}

struct TextEffectGallery: View {
    @Binding var style: TextStyle
    var preview: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "텍스트 효과")
                Spacer()
                Text(L((style.animation ?? TextAnimation.none).label))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if (style.animation ?? TextAnimation.none) != TextAnimation.none {
                ValueSlider(title: "효과 시간", value: Binding<Double>(
                    get: { style.animationDuration ?? 0.6 },
                    set: { style.animationDuration = $0 }
                ), range: 0.1...3) { String(format: L("%.1f초"), $0) }
                .accessibilityIdentifier("text-animation-duration")
            }
            if let preview { EffectPreviewButton(action: preview) }
            EffectCardGrid(choices: TextAnimation.allCases.map { .init(id: $0.rawValue, label: shortLabel($0), symbol: $0.symbol) },
                           selectedID: (style.animation ?? TextAnimation.none).rawValue,
                           identifier: "text-effect-gallery") { id in
                guard let effect = TextAnimation(rawValue: id) else { return }
                style.animation = effect == TextAnimation.none ? nil : effect
            }
            Text("각 텍스트와 자막이 시작할 때 적용됩니다. 짧은 구간에서는 효과 시간이 자동으로 줄어듭니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortLabel(_ effect: TextAnimation) -> String {
        switch effect {
        case .fade: "페이드"
        case .slideUp: "올라오기"
        case .slideDown: "내려오기"
        default: effect.label
        }
    }
}

struct ClipTransitionGallery: View {
    @Binding var entrance: TransitionSettings?
    @Binding var exit: TransitionSettings?
    var preview: ((Bool) -> Void)? = nil
    @State private var editingEntrance = true

    private var current: TransitionSettings? { editingEntrance ? entrance : exit }
    private var effect: ClipTransition { current?.effect ?? ClipTransition.none }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("효과 위치", selection: $editingEntrance) {
                Text("시작 효과").tag(true)
                Text("끝 효과").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("transition-edge-picker")
            HStack {
                SectionTitle(text: "전환 효과")
                Spacer()
                Text(L(effect.label)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if effect != ClipTransition.none {
                ValueSlider(title: "효과 시간", value: Binding<Double>(
                    get: { current?.duration ?? 0.5 },
                    set: { duration in
                        var value = current ?? TransitionSettings()
                        value.duration = duration
                        set(value)
                    }
                ), range: 0.1...3) { String(format: L("%.1f초"), $0) }
            }
            if let preview { EffectPreviewButton { preview(!editingEntrance) } }
            EffectCardGrid(choices: ClipTransition.allCases.map { .init(id: $0.rawValue, label: shortLabel($0), symbol: $0.symbol) },
                           selectedID: effect.rawValue, identifier: "transition-gallery") { id in
                guard let choice = ClipTransition(rawValue: id) else { return }
                var value = current ?? TransitionSettings()
                value.effect = choice
                set(choice == ClipTransition.none ? nil : value)
            }
            Text("클립의 시작과 끝에 적용됩니다. 짧은 클립에서는 각 효과가 길이의 절반을 넘지 않게 줄어듭니다.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(editingEntrance ? "clip-transition-in" : "clip-transition-out")
    }

    private func set(_ value: TransitionSettings?) {
        if editingEntrance { entrance = value } else { exit = value }
    }

    private func shortLabel(_ effect: ClipTransition) -> String {
        switch effect {
        case .slideLeft: "왼쪽 슬라이드"
        case .slideRight: "오른쪽 슬라이드"
        case .slideUp: "위로 슬라이드"
        case .slideDown: "아래로 슬라이드"
        case .wipeLeft: "왼쪽 와이프"
        case .wipeRight: "오른쪽 와이프"
        case .wipeUp: "위로 와이프"
        case .wipeDown: "아래로 와이프"
        default: effect.label
        }
    }
}

struct VisualFilterGallery: View {
    @Binding var filter: VisualFilter?
    @Binding var intensity: Double?
    var preview: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "영상 필터")
            if (filter ?? VisualFilter.none) != VisualFilter.none {
                ValueSlider(title: "강도", value: Binding<Double>(get: { intensity ?? 1 }, set: { intensity = $0 }), range: 0...1) {
                    "\(Int($0 * 100))%"
                }
            }
            if let preview { EffectPreviewButton(action: preview) }
            EffectCardGrid(choices: VisualFilter.allCases.map { .init(id: $0.rawValue, label: $0.label, symbol: $0.symbol) },
                           selectedID: (filter ?? VisualFilter.none).rawValue,
                           identifier: "visual-filter-gallery") { id in
                guard let value = VisualFilter(rawValue: id) else { return }
                filter = value == VisualFilter.none ? nil : value
            }
        }
    }
}

struct InstalledFontFamily: Identifiable, Hashable {
    let family: String
    let displayName: String
    let fontName: String
    var id: String { family }
}

enum FontList {
    /// 모든 설치된 글꼴 패밀리를 실제 PostScript 이름과 연결한다.
    static let all: [InstalledFontFamily] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.compactMap { family -> InstalledFontFamily? in
            let names = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { $0.first as? String }
            let name = names.sorted {
                let a = fontPreference($0), b = fontPreference($1)
                return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
            }.first ?? family
            guard let font = NSFont(name: name, size: 16) else { return nil }
            return InstalledFontFamily(family: family, displayName: font.familyName ?? family, fontName: font.fontName)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }()

    static let korean: [String] = {
        let wanted = ["AppleSDGothicNeo-Regular", "AppleMyungjo", "NanumGothic", "NanumMyeongjo", "NanumBarunGothic", "NanumSquareRoundB", "BMJUAOTF", "BMHANNAProOTF", "Pretendard-Regular", "SpoqaHanSansNeo-Regular", "GmarketSansBold", "Helvetica", "Avenir-Book"]
        return wanted.filter { NSFont(name: $0, size: 16) != nil }
    }()

    static let suggested: [InstalledFontFamily] = {
        var seen = Set<String>()
        return korean.compactMap { name -> InstalledFontFamily? in
            guard let font = NSFont(name: name, size: 16), let family = font.familyName,
                  seen.insert(family).inserted else { return nil }
            return InstalledFontFamily(family: family, displayName: family, fontName: font.fontName)
        }
    }()

    static func filtered(_ query: String) -> [InstalledFontFamily] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return all }
        return all.filter {
            ([$0.family, $0.displayName, $0.fontName] + searchAliases(for: $0)).contains {
                $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// 설치 글꼴의 영문 이름으로도 익숙한 한글 이름을 찾아준다.
    private static func searchAliases(for font: InstalledFontFamily) -> [String] {
        let name = (font.family + font.fontName).lowercased().filter { $0.isLetter || $0.isNumber }
        var aliases: [String] = []
        if name.contains("nanum") {
            aliases.append("나눔")
            if name.contains("barungothic") { aliases += ["나눔바른고딕", "나눔 바른 고딕"] }
            else if name.contains("gothic") { aliases += ["나눔고딕", "나눔 고딕"] }
            if name.contains("myeongjo") { aliases += ["나눔명조", "나눔 명조"] }
            if name.contains("square") { aliases += ["나눔스퀘어", "나눔 스퀘어"] }
            if name.contains("pen") { aliases += ["나눔손글씨", "나눔 펜"] }
            if name.contains("brush") { aliases += ["나눔손글씨", "나눔 붓"] }
        }
        if name.contains("applesdgothic") {
            aliases += ["애플고딕", "애플 고딕", "산돌", "산돌고딕", "산돌 고딕", "애플산돌고딕"]
        }
        if name.contains("applemyungjo") { aliases += ["애플명조", "애플 명조", "명조"] }
        if name.contains("bmjua") { aliases += ["배민", "배달의민족", "주아", "배민주아", "배민 주아"] }
        if name.contains("bmhanna") { aliases += ["배민", "배달의민족", "한나", "배민한나", "배민 한나"] }
        if name.contains("pretendard") { aliases.append("프리텐다드") }
        if name.contains("spoqa") { aliases += ["스포카", "스포카한산스", "스포카 한 산스"] }
        if name.contains("gmarket") { aliases += ["지마켓", "지마켓산스", "지마켓 산스"] }
        if name.contains("helvetica") { aliases.append("헬베티카") }
        if name.contains("arial") { aliases += ["아리알", "에어리얼"] }
        if name.contains("avenir") { aliases.append("아베니르") }
        if name.contains("futura") { aliases.append("푸투라") }
        return aliases
    }

    static func displayName(for name: String) -> String {
        guard !name.isEmpty else { return L("시스템 글꼴") }
        return NSFont(name: name, size: 16)?.familyName ?? name
    }

    private static func fontPreference(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("regular") || n.contains("roman") || n.contains("book") { return 0 }
        if n.contains("medium") { return 1 }
        if n.contains("bold") || n.contains("italic") { return 3 }
        return 2
    }
}

struct FontFamilyPicker: View {
    @Binding var fontName: String
    @State private var showingBrowser = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "글꼴")
            Button { showingBrowser = true } label: {
                HStack(spacing: 10) {
                    Text("Aa").font(fontName.isEmpty ? .system(size: 23) : .custom(fontName, size: 23))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(FontList.displayName(for: fontName)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("설치된 글꼴 모두 보기").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.inspectorCard, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.inspectorBorder, lineWidth: 0.7) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("font-browser-button")
            .sheet(isPresented: $showingBrowser) { FontBrowser(fontName: $fontName) }
            HStack(spacing: 6) {
                ForEach(FontList.suggested.prefix(3)) { font in
                    Button { fontName = font.fontName } label: {
                        VStack(spacing: 3) {
                            Text("가나다").font(.custom(font.fontName, size: 15)).lineLimit(1)
                            Text(font.displayName).font(.system(size: 9)).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, minHeight: 43)
                        .background(Theme.inspectorInset, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).help(font.displayName)
                }
            }
        }
    }
}

struct FontBrowser: View {
    @Binding var fontName: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searching: Bool

    private var results: [InstalledFontFamily] { FontList.filtered(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("글꼴 선택").font(.title3.weight(.semibold))
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(18)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("글꼴 이름 검색", text: $query).textFieldStyle(.plain).focused($searching)
                    .accessibilityIdentifier("font-search-field")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                }
            }
            .padding(11).background(Theme.inspectorInset, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 18).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { fontName = "" } label: {
                            HStack {
                                Text("시스템 글꼴").font(.system(size: 14))
                                Spacer()
                                if fontName.isEmpty { Image(systemName: "checkmark").foregroundStyle(Theme.accentColor) }
                            }.padding(11)
                        }.buttonStyle(.plain)
                        Text("자주 쓰는 한글 글꼴").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 10).padding(.horizontal, 11)
                        ForEach(FontList.suggested.prefix(8)) { row($0) }
                        Divider().padding(.vertical, 10)
                    }
                    Text("설치된 글꼴 \(results.count)개").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 11).padding(.bottom, 5)
                    if results.isEmpty {
                        Text("검색한 글꼴이 없습니다").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    } else {
                        ForEach(results) { row($0) }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 16)
            }
            .accessibilityIdentifier("font-results")
            Divider()
            Text("이 Mac에 설치된 글꼴을 사용합니다.").font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 490, height: 620)
        .onAppear { searching = true }
    }

    private func row(_ font: InstalledFontFamily) -> some View {
        let selected = fontName == font.fontName || (!fontName.isEmpty && NSFont(name: fontName, size: 14)?.familyName == font.family)
        return Button { fontName = font.fontName } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(font.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text("가나다 Aa 123").font(.custom(font.fontName, size: 20)).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentColor) }
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.inspectorSelection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("font-family-\(font.id)")
        .accessibilityLabel(font.displayName)
    }
}
