import SwiftUI

private enum LayoutSource: CaseIterable {
    case screen, camera

    var title: String { self == .screen ? L("화면") : L("카메라") }
    var symbol: String { self == .screen ? "display" : "video" }
}

private enum LayoutCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var right: Bool { self == .topRight || self == .bottomRight }
    var bottom: Bool { self == .bottomLeft || self == .bottomRight }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: right ? rect.maxX : rect.minX, y: bottom ? rect.maxY : rect.minY)
    }
}

private struct LayoutDrag {
    let source: LayoutSource
    let frame: CGRect
    let corner: LayoutCorner?
}

/// Positions use the renderer's normalized top-left coordinates. Drag scaling is projected in display points.
private enum LayoutEditGeometry {
    static func boundedBox(_ image: CGRect) -> CGRect {
        let width = min(1, max(0.05, image.width))
        let height = min(1, max(0.05, image.height))
        return CGRect(x: min(max(image.midX - width / 2, 0), 1 - width),
                      y: min(max(image.midY - height / 2, 0), 1 - height), width: width, height: height)
    }

    static func resized(_ image: CGRect, from corner: LayoutCorner, delta: CGSize, in canvas: CGSize) -> CGRect {
        let anchorX = corner.right ? image.minX : image.maxX
        let anchorY = corner.bottom ? image.minY : image.maxY
        let dx = image.width * canvas.width * (corner.right ? 1 : -1)
        let dy = image.height * canvas.height * (corner.bottom ? 1 : -1)
        let scale = 1 + (delta.width * dx + delta.height * dy) / max(dx * dx + dy * dy, 0.0001)
        let limit = min((corner.right ? 1 - anchorX : anchorX) / image.width,
                        (corner.bottom ? 1 - anchorY : anchorY) / image.height)
        let factor = min(limit, max(0.05 / max(image.width, image.height), scale))
        let width = image.width * factor, height = image.height * factor
        return boundedBox(CGRect(x: corner.right ? anchorX : anchorX - width,
                                 y: corner.bottom ? anchorY : anchorY - height, width: width, height: height))
    }

    static func scaledAroundCenter(_ image: CGRect, by factor: CGFloat) -> CGRect {
        let scale = min(1 / max(image.width, image.height), max(0.05 / max(image.width, image.height), factor))
        let w = image.width * scale, h = image.height * scale
        return boundedBox(CGRect(x: image.midX - w / 2, y: image.midY - h / 2, width: w, height: h))
    }
}

@MainActor
struct StudioCustomLayoutEditor: View {
    @ObservedObject var rec: RecordController
    let screenAspect: CGFloat
    let cameraAspect: CGFloat

    @State private var draft: StudioCustomLayout
    @State private var source: LayoutSource = .screen
    @State private var drag: LayoutDrag?
    @State private var preferSelectedInOverlap = false
    @FocusState private var canvasFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(rec: RecordController, screenAspect: CGFloat, cameraAspect: CGFloat) {
        self.rec = rec
        self.screenAspect = screenAspect
        self.cameraAspect = cameraAspect
        _draft = State(initialValue: rec.studioCustomLayout)
    }

    private var cameraAvailable: Bool { rec.useCamera && !rec.cameras.isEmpty }
    private var tint: Color { colorScheme == .dark ? Theme.accentColor : Color(nsColor: Theme.videoClip) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group").font(.title2).foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text("내 배치 편집").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Text("편집할 소스").font(.subheadline.weight(.semibold))
                        ForEach(LayoutSource.allCases, id: \.self) { item in sourceButton(item) }
                    }
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { GeometryReader { proxy in canvas(size: proxy.size) } }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("배치 캔버스"))
                        .accessibilityValue(Text(verbatim: source.title))
                        .accessibilityHint(Text("방향키로 이동하고 더하기와 빼기 키로 크기를 조절합니다."))
                        .focusable().focused($canvasFocused).focusEffectDisabled()
                        .onMoveCommand { direction in
                            switch direction {
                            case .left: move(dx: -0.01)
                            case .right: move(dx: 0.01)
                            case .up: move(dy: -0.01)
                            case .down: move(dy: 0.01)
                            default: break
                            }
                        }
                        .onKeyPress(characters: CharacterSet(charactersIn: "+=-"), phases: [.down, .repeat]) { key in
                            guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                            resize(key.characters == "-" ? 1 / 1.08 : 1.08)
                            return .handled
                        }
                    Text(verbatim: canvasHint)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { movementControls; sizeControls }
                        VStack(alignment: .leading, spacing: 7) { movementControls; sizeControls }
                    }
                    if !cameraAvailable {
                        Label("카메라를 켜면 카메라 배치도 편집할 수 있습니다.", systemImage: "video.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
            Divider()
            HStack {
                Button("기본 배치로") { draft = .standard; drag = nil }
                    .accessibilityIdentifier("studio-custom-reset")
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("적용") {
                    rec.applyCustomLayout(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("studio-custom-apply")
            }
            .padding(.horizontal, 20).padding(.vertical, 11)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 420, idealWidth: 548, maxWidth: 680,
               minHeight: 280, idealHeight: 510, maxHeight: 620)
        .tint(tint)
        .onChange(of: cameraAvailable) { _, available in
            if !available, source == .camera { source = .screen; drag = nil }
        }
    }

    private var canvasHint: String {
        if let selected = frame(for: source), selected.width >= 0.9999 && selected.height >= 0.9999 {
            return L("선택한 소스가 캔버스를 채우고 있습니다. 모서리를 안쪽으로 끌어 줄인 뒤 이동하세요.")
        }
        return L("소스를 끌어 이동하고 모서리를 끌어 크기를 조절하세요.")
    }

    private func sourceButton(_ item: LayoutSource) -> some View {
        Button {
            source = item
            preferSelectedInOverlap = true
            canvasFocused = true
        } label: {
            Label { Text(verbatim: item.title) } icon: { Image(systemName: item.symbol) }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(source == item ? Theme.inspectorSelection : Theme.inspectorInset,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(source == item ? tint : Theme.inspectorBorder, lineWidth: source == item ? 1.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(item == .camera && !cameraAvailable)
        .accessibilityAddTraits(source == item ? .isSelected : [])
        .accessibilityIdentifier(item == .screen ? "studio-custom-screen" : "studio-custom-camera")
    }

    private var movementControls: some View {
        HStack(spacing: 4) {
            Text("위치").font(.callout.weight(.semibold)).padding(.trailing, 2)
            control("arrow.left", "왼쪽으로 이동") { move(dx: -0.01) }
            control("arrow.right", "오른쪽으로 이동") { move(dx: 0.01) }
            control("arrow.up", "위로 이동") { move(dy: -0.01) }
            control("arrow.down", "아래로 이동") { move(dy: 0.01) }
        }
    }

    private var sizeControls: some View {
        HStack(spacing: 4) {
            Text("크기").font(.callout.weight(.semibold)).padding(.trailing, 2)
            control("minus", "소스 축소") { resize(1 / 1.08) }
            control("plus", "소스 확대") { resize(1.08) }
        }
    }

    private func control(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 16, height: 16)
        }
        .controlSize(.small).accessibilityLabel(Text(verbatim: L(label))).help(L(label))
    }

    private func frame(for target: LayoutSource) -> CGRect? {
        let frames = StudioScene.custom.frames(screenAspect: screenAspect, cameraAspect: cameraAspect, customLayout: draft)
        return target == .screen ? frames.screen : (cameraAvailable ? frames.camera : nil)
    }

    private func setBox(_ box: CGRect, for target: LayoutSource) {
        switch target {
        case .screen: draft = StudioCustomLayout(screen: box, camera: draft.camera)
        case .camera: draft = StudioCustomLayout(screen: draft.screen, camera: box)
        }
    }

    private func move(dx: CGFloat = 0, dy: CGFloat = 0) {
        guard let frame = frame(for: source) else { return }
        setBox(LayoutEditGeometry.boundedBox(frame.offsetBy(dx: dx, dy: dy)), for: source)
    }

    private func resize(_ factor: CGFloat) {
        guard let frame = frame(for: source) else { return }
        setBox(LayoutEditGeometry.scaledAroundCenter(frame, by: factor), for: source)
    }

    private func canvas(size: CGSize) -> some View {
        let transform = CGAffineTransform(scaleX: size.width, y: size.height)
        let selected = frame(for: source)?.applying(transform)
        return ZStack(alignment: .topLeading) {
            StudioSchematic(scene: .custom, screenAspect: screenAspect, cameraAspect: cameraAspect,
                            guides: true, customLayout: draft, showsCamera: cameraAvailable)
            if let selected {
                Path { $0.addRect(selected) }
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                ForEach(LayoutCorner.allCases, id: \.self) { corner in
                    let point = handlePoint(corner, rect: selected, size: size)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white).strokeBorder(Color.black.opacity(0.7), lineWidth: 1)
                        .frame(width: 9, height: 9).position(point)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(canvasFocused ? tint : Theme.inspectorBorder, lineWidth: canvasFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    drag = hitTest(point: value.startLocation, size: size)
                    if let drag { source = drag.source; canvasFocused = true }
                }
                guard let drag, size.width > 0, size.height > 0, value.translation != .zero else { return }
                let box: CGRect
                if let corner = drag.corner {
                    box = LayoutEditGeometry.resized(drag.frame, from: corner, delta: value.translation, in: size)
                } else {
                    box = LayoutEditGeometry.boundedBox(drag.frame.offsetBy(dx: value.translation.width / size.width,
                                                                          dy: value.translation.height / size.height))
                }
                setBox(box, for: drag.source)
            }
            .onEnded { value in
                if drag?.corner == nil, hypot(value.translation.width, value.translation.height) < 3,
                   let tapped = sourceAt(value.startLocation, size: size, preferSelected: false) {
                    source = tapped
                    preferSelectedInOverlap = false
                }
                drag = nil
            })
    }

    private func handlePoint(_ corner: LayoutCorner, rect: CGRect, size: CGSize) -> CGPoint {
        let p = corner.point(in: rect)
        // Keep corner grips fully visible even when a source touches the edge of the canvas.
        return CGPoint(x: min(max(p.x, 5), max(5, size.width - 5)), y: min(max(p.y, 5), max(5, size.height - 5)))
    }

    private func hitTest(point: CGPoint, size: CGSize) -> LayoutDrag? {
        let transform = CGAffineTransform(scaleX: size.width, y: size.height)
        if let selected = frame(for: source) {
            let visible = selected.applying(transform)
            let nearest = LayoutCorner.allCases.min {
                let a = handlePoint($0, rect: visible, size: size), b = handlePoint($1, rect: visible, size: size)
                return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
            }
            if let nearest {
                let grip = handlePoint(nearest, rect: visible, size: size)
                if hypot(grip.x - point.x, grip.y - point.y) <= 11 {
                    return LayoutDrag(source: source, frame: selected, corner: nearest)
                }
            }
        }
        guard let target = sourceAt(point, size: size, preferSelected: preferSelectedInOverlap),
              let frame = frame(for: target) else { return nil }
        return LayoutDrag(source: target, frame: frame, corner: nil)
    }

    private func sourceAt(_ point: CGPoint, size: CGSize, preferSelected: Bool) -> LayoutSource? {
        guard size.width > 0, size.height > 0 else { return nil }
        let p = CGPoint(x: point.x / size.width, y: point.y / size.height)
        if preferSelected, frame(for: source)?.contains(p) == true { return source }
        if frame(for: .camera)?.contains(p) == true { return .camera }
        if frame(for: .screen)?.contains(p) == true { return .screen }
        return nil
    }
}
