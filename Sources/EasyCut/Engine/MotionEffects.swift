import CoreImage
import Foundation

/// 미리보기와 내보내기에서 공유하는 시간 기반 등장·퇴장 효과. 캔버스 배치가 끝난 이미지에 적용한다.
enum MotionEffects {
    static func textProgress(style: TextStyle, elapsed: Double, duration: Double) -> Double {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return 1 }
        let requested = style.animationDuration ?? 0.6
        guard requested.isFinite, requested > 0 else { return 1 }
        // 짧은 자막도 적어도 절반은 전체 문장을 보여 준다.
        let window = min(requested, duration / 2)
        return min(1, max(0, elapsed / window))
    }

    static func visibleCharacters(text: String, progress: Double) -> Int {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        let p = progress.isFinite ? min(1, max(0, progress)) : 1
        return min(count, Int(floor(Double(count) * p)))
    }

    static func alpha(_ image: CIImage, _ value: Double) -> CIImage {
        let a = min(1, max(0, value))
        if a >= 1 { return image }
        if a <= 0 { return CIImage.empty() }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a))
        ])
    }

    private static func scaled(_ image: CIImage, by scale: Double) -> CIImage {
        scaled(image, x: scale, y: scale)
    }

    private static func scaled(_ image: CIImage, x: Double, y: Double) -> CIImage {
        let center = image.extent
        let transform = CGAffineTransform(translationX: -center.midX, y: -center.midY)
            .concatenating(CGAffineTransform(scaleX: max(0.001, x), y: max(0.001, y)))
            .concatenating(CGAffineTransform(translationX: center.midX, y: center.midY))
        return image.transformed(by: transform)
    }

    private static func rotated(_ image: CIImage, angle: Double) -> CIImage {
        let center = image.extent
        let transform = CGAffineTransform(translationX: -center.midX, y: -center.midY)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.midX, y: center.midY))
        return image.transformed(by: transform)
    }

    /// 필터는 개인정보 가리기가 끝난 영상·이미지에만 호출한다. 강도 0은 원본과 정확히 같다.
    static func filter(_ image: CIImage, kind: VisualFilter, intensity: Double? = nil) -> CIImage {
        let requested = intensity ?? 1
        let strength = requested.isFinite ? min(1, max(0, requested)) : 1
        let extent = image.extent
        guard kind != .none, strength > 0, !extent.isEmpty, !extent.isInfinite else { return image }
        let filtered: CIImage
        switch kind {
        case .none:
            return image
        case .warm:
            filtered = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.04, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.9, w: 0),
                "inputBiasVector": CIVector(x: 0.035, y: 0.01, z: 0, w: 0)])
        case .cool:
            filtered = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.08, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0.01, z: 0.035, w: 0)])
        case .mono:
            filtered = image.applyingFilter("CIPhotoEffectMono")
        case .sepia:
            filtered = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
        case .vivid:
            filtered = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.45, kCIInputBrightnessKey: 0.01, kCIInputContrastKey: 1.12])
        case .soft:
            filtered = image.clampedToExtent().applyingGaussianBlur(sigma: Double(min(extent.width, extent.height)) * 0.009)
                .cropped(to: extent).applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.92, kCIInputBrightnessKey: 0.025, kCIInputContrastKey: 0.94])
        case .vintage:
            filtered = image.applyingFilter("CIPhotoEffectTransfer")
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.2])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.8, kCIInputBrightnessKey: 0.02, kCIInputContrastKey: 0.95])
        case .dramatic:
            filtered = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.72, kCIInputBrightnessKey: -0.025, kCIInputContrastKey: 1.35])
        case .noir:
            filtered = image.applyingFilter("CIPhotoEffectNoir")
        }
        let output = filtered.cropped(to: extent)
        if strength >= 1 { return output }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: output, kCIInputTimeKey: strength]).cropped(to: extent)
    }

    static func text(_ image: CIImage, style: TextStyle, elapsed: Double, duration: Double, canvas: CGRect) -> CIImage {
        let progress = textProgress(style: style, elapsed: elapsed, duration: duration)
        guard progress < 1 else { return image }
        let ease = 1 - pow(1 - progress, 3)
        switch style.animation ?? .none {
        case .none, .typewriter:
            return image
        case .fade:
            return alpha(image, progress)
        case .slideUp, .slideDown:
            let direction: CGFloat = style.animation == .slideUp ? -1 : 1
            let offset = direction * max(image.extent.height * 0.6, canvas.height * 0.055) * CGFloat(1 - ease)
            return alpha(image.transformed(by: CGAffineTransform(translationX: 0, y: offset)), progress)
        case .pop:
            let x = progress - 1
            let factor = 1 + 2.70158 * pow(x, 3) + 1.70158 * pow(x, 2)
            return alpha(scaled(image, by: factor), min(1, progress * 4))
        case .bounce:
            let offset = abs(sin(progress * .pi * 3)) * (1 - progress) * image.extent.height * 0.7
            return alpha(image.transformed(by: CGAffineTransform(translationX: 0, y: offset)), progress)
        case .zoomIn:
            return alpha(scaled(image, by: 0.35 + 0.65 * ease), progress)
        case .zoomOut:
            return alpha(scaled(image, by: 1 + 0.6 * (1 - ease)), progress)
        case .rotateIn:
            return alpha(rotated(image, angle: -.pi / 5 * (1 - ease)), progress)
        case .blurIn:
            let extent = image.extent
            let sigma = Double(min(extent.width, extent.height)) * 0.18 * (1 - ease)
            let softened = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            return alpha(softened, progress)
        case .wipeRight:
            let extent = image.extent
            guard progress > 0 else { return CIImage.empty() }
            return image.cropped(to: CGRect(x: extent.minX, y: extent.minY,
                                           width: extent.width * progress, height: extent.height))
        case .wipeUp:
            let extent = image.extent
            guard progress > 0 else { return CIImage.empty() }
            return image.cropped(to: CGRect(x: extent.minX, y: extent.minY,
                                           width: extent.width, height: extent.height * progress))
        case .scaleX:
            return alpha(scaled(image, x: 0.05 + 0.95 * ease, y: 1), progress)
        case .float:
            let offset = -canvas.height * 0.09 * (1 - ease)
                + sin(progress * .pi * 2) * (1 - progress) * image.extent.height * 0.12
            return alpha(image.transformed(by: CGAffineTransform(translationX: 0, y: offset)), progress)
        case .shake:
            let offset = sin(progress * .pi * 8) * (1 - progress) * image.extent.height * 0.2
            return alpha(image.transformed(by: CGAffineTransform(translationX: offset, y: 0)), progress)
        }
    }

    /// elapsed는 입장 시 시작부터 지난 시간, 퇴장 시 끝까지 남은 시간이다.
    static func transition(_ image: CIImage, settings: TransitionSettings, elapsed: Double,
                           duration: Double, entering: Bool, canvas: CGRect) -> CIImage {
        guard settings.effect != .none, elapsed.isFinite else { return image }
        let window = settings.clampedDuration(for: duration)
        guard window > 0 else { return image }
        let progress = min(1, max(0, elapsed / window))
        guard progress < 1 else { return image }
        if progress <= 0 { return CIImage.empty() }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }
        let ease = 1 - pow(1 - progress, 3)
        let remaining = CGFloat(1 - ease)
        switch settings.effect {
        case .none:
            return image
        case .fade:
            return alpha(image, progress)
        case .slideLeft:
            let travel = entering ? max(0, canvas.maxX - extent.minX) : -max(0, extent.maxX - canvas.minX)
            return image.transformed(by: CGAffineTransform(translationX: travel * remaining, y: 0))
        case .slideRight:
            let travel = entering ? -max(0, extent.maxX - canvas.minX) : max(0, canvas.maxX - extent.minX)
            return image.transformed(by: CGAffineTransform(translationX: travel * remaining, y: 0))
        case .slideUp:
            let travel = entering ? -max(0, extent.maxY - canvas.minY) : max(0, canvas.maxY - extent.minY)
            return image.transformed(by: CGAffineTransform(translationX: 0, y: travel * remaining))
        case .slideDown:
            let travel = entering ? max(0, canvas.maxY - extent.minY) : -max(0, extent.maxY - canvas.minY)
            return image.transformed(by: CGAffineTransform(translationX: 0, y: travel * remaining))
        case .wipeLeft, .wipeRight:
            let visible = extent.width * CGFloat(progress)
            let fromRight = (settings.effect == .wipeLeft) == entering
            let crop = CGRect(x: fromRight ? extent.maxX - visible : extent.minX,
                              y: extent.minY, width: visible, height: extent.height)
            return image.cropped(to: crop)
        case .zoom:
            let factor = entering ? 0.65 + 0.35 * ease : 1 + 0.35 * (1 - ease)
            return alpha(scaled(image, by: factor), progress)
        case .wipeUp, .wipeDown:
            let visible = extent.height * progress
            let fromBottom = (settings.effect == .wipeUp) == entering
            return image.cropped(to: CGRect(x: extent.minX, y: fromBottom ? extent.minY : extent.maxY - visible,
                                           width: extent.width, height: visible))
        case .zoomOut:
            let factor = entering ? 1 + 0.5 * (1 - ease) : 0.5 + 0.5 * ease
            return alpha(scaled(image, by: factor), progress)
        case .rotate:
            let angle = (entering ? -1 : 1) * .pi / 2 * (1 - ease)
            return alpha(rotated(image, angle: angle), progress)
        case .blur:
            let sigma = Double(min(extent.width, extent.height)) * 0.08 * (1 - ease)
            let softened = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            return alpha(softened, progress)
        case .pixelate:
            let cell = max(1, Double(min(extent.width, extent.height)) * 0.14 * (1 - ease))
            let pixels = image.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: cell, kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)]).cropped(to: extent)
            return alpha(pixels, progress)
        case .iris:
            let radius = hypot(extent.width, extent.height) / 2 * progress
            guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": max(0, radius - 1), "inputRadius1": max(0.001, radius),
                "inputColor0": CIColor.white, "inputColor1": CIColor.clear])?.outputImage else { return image }
            return image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask.cropped(to: extent)]).cropped(to: extent)
        case .squeeze:
            return alpha(scaled(image, x: 1, y: ease), progress)
        case .flip:
            let width = extent.width * sin(ease * .pi / 2)
            let skew = extent.height * 0.2 * (1 - ease) * (entering ? 1 : -1)
            return image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(x: extent.midX - width / 2, y: extent.maxY - skew),
                "inputTopRight": CIVector(x: extent.midX + width / 2, y: extent.maxY + skew),
                "inputBottomRight": CIVector(x: extent.midX + width / 2, y: extent.minY - skew),
                "inputBottomLeft": CIVector(x: extent.midX - width / 2, y: extent.minY + skew)])
        case .slideDiagonal:
            let dx = entering ? max(0, canvas.maxX - extent.minX) : -max(0, extent.maxX - canvas.minX)
            let dy = entering ? -max(0, extent.maxY - canvas.minY) : max(0, canvas.maxY - extent.minY)
            return image.transformed(by: CGAffineTransform(translationX: dx * remaining, y: dy * remaining))
        }
    }
}
