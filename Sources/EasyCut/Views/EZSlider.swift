import SwiftUI

/// macOS 기본 슬라이더(NSSlider) 대신 직접 그리는 슬라이더.
/// macOS 27에서 NSSlider를 다시 그리다 앱이 꺼지는 일이 있어(AppKit 안에서 Observation 접근 중 크래시) 피한다.
struct EZSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var editing = false

    init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, step: Double? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    private var knob: CGFloat { controlSize == .small || controlSize == .mini ? 12 : 16 }
    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }

    private func fraction(_ v: Double) -> Double { min(1, max(0, (v - range.lowerBound) / span)) }

    private func set(_ f: Double) {
        var v = range.lowerBound + min(1, max(0, f)) * span
        if let step, step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        v = min(range.upperBound, max(range.lowerBound, v))
        if v != value { value = v }
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - knob)
            let x = CGFloat(fraction(value)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .padding(.horizontal, knob / 2)
                Capsule().fill(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: x + 2, height: 4)
                    .padding(.leading, knob / 2 - 1)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(editing ? 0.35 : 0.2), radius: editing ? 2 : 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !editing { editing = true; onEditingChanged(true) }
                    set(Double((g.location.x - knob / 2) / w))
                }
                .onEnded { g in
                    set(Double((g.location.x - knob / 2) / w))
                    editing = false
                    onEditingChanged(false)
                })
        }
        .frame(height: knob + 4)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { dir in
            let d = step ?? span / 20
            switch dir {
            case .increment: set(fraction(value + d))
            case .decrement: set(fraction(value - d))
            @unknown default: break
            }
        }
    }
}
