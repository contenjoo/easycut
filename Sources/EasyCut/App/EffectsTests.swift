import AppKit
import AVFoundation
import CoreImage
import ImageIO

extension SelfTest {
    /// 합성 프레임과 H.264 결과를 같은 RGBA 색 공간에서 비교한다.
    private static func effectPixels(_ image: CIImage, size: CGSize) -> [UInt8] {
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            RenderCache.context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return bytes
    }

    private static func effectDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0.0
        for i in a.indices where i % 4 != 3 { sum += abs(Double(a[i]) - Double(b[i])) }
        return sum / Double(a.count / 4 * 3) / 255
    }

    private static func finiteEffectExtent(_ image: CIImage) -> Bool {
        let extent = image.extent
        return !extent.isInfinite && !extent.isNull && extent.minX.isFinite && extent.minY.isFinite
            && extent.width.isFinite && extent.height.isFinite
    }

    private static func writeEffectPNG(_ image: CIImage, size: CGSize, to url: URL) throws {
        guard let cg = RenderCache.context.createCGImage(image, from: CGRect(origin: .zero, size: size)),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw MediaError.failed("효과 검증 이미지 저장 실패")
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.failed("효과 검증 이미지 저장 실패") }
    }

    private static func effectModelTests() throws {
        let asset = MediaAsset(path: "/tmp/easycut-effect-model.mp4", name: "전환 검증", kind: .video,
                               duration: 4, width: 320, height: 180, hasAudio: true)
        var project = Project()
        project.assets = [asset]
        let id = project.insert(asset: asset, track: 0, at: 0)
        project.tracks[0].clips[0].transitionIn = TransitionSettings(effect: .wipeRight, duration: 0.4)
        project.tracks[0].clips[0].transitionOut = TransitionSettings(effect: .slideLeft, duration: 0.6)
        project.tracks[0].clips[0].visualFilter = .vintage
        project.tracks[0].clips[0].filterIntensity = 0.65
        project.tracks[0].clips[0].textStyle.animation = .typewriter
        project.tracks[0].clips[0].textStyle.animationDuration = 0.7
        project.captionStyle.animation = .pop
        project.captionStyle.animationDuration = 0.3
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        check(decoded == project, "전환·필터·텍스트·자막 효과 저장/열기 왕복")

        func legacyJSON(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { !["transitionIn", "transitionOut", "animation", "animationDuration", "visualFilter", "filterIntensity"].contains($0.key) }
                    .mapValues(legacyJSON)
            }
            if let array = value as? [Any] { return array.map(legacyJSON) }
            return value
        }
        let oldData = try JSONSerialization.data(withJSONObject: legacyJSON(JSONSerialization.jsonObject(with: encoded)))
        let old = try JSONDecoder().decode(Project.self, from: oldData)
        check(old.tracks[0].clips[0].transitionIn == nil && old.tracks[0].clips[0].transitionOut == nil
              && old.captionStyle.animation == nil && old.captionStyle.animationDuration == nil
              && old.tracks[0].clips[0].textStyle.animation == nil
              && old.tracks[0].clips[0].visualFilter == nil && old.tracks[0].clips[0].filterIntensity == nil,
              "기존 프로젝트: 효과 키 없이 열기·기본 효과 없음")

        check(TransitionSettings(effect: .fade, duration: 3).clampedDuration(for: 0.2) == 0.1,
              "짧은 클립: 시작·끝 전환을 길이 절반으로 제한")
        check(TransitionSettings(effect: .fade, duration: -.infinity).clampedDuration(for: 2) == 0
              && TransitionSettings(effect: .fade, duration: -1).clampedDuration(for: 2) == 0,
              "유효하지 않은 전환 길이: 안전하게 효과 생략")

        let before = project
        let right = project.split(clip: id, at: 2)!
        check(project.clip(id)?.transitionOut == nil && project.clip(right)?.transitionIn == nil,
              "클립 분할: 새 내부 경계에는 전환을 복제하지 않음")
        check(project.clip(id)?.transitionIn == before.clip(id)?.transitionIn
              && project.clip(right)?.transitionOut == before.clip(id)?.transitionOut,
              "클립 분할: 원래 시작·끝 전환 보존")
        check(project.clip(id)?.visualFilter == .vintage && project.clip(right)?.visualFilter == .vintage
              && project.clip(id)?.filterIntensity == 0.65 && project.clip(right)?.filterIntensity == 0.65,
              "클립 분할: 양쪽 조각의 필터·강도 보존")
        let joined = project.join([id, right])
        check(joined.merged == 1 && project.clip(id)?.transitionIn == before.clip(id)?.transitionIn
              && project.clip(id)?.transitionOut == before.clip(id)?.transitionOut,
              "분할 뒤 합치기: 바깥쪽 시작·끝 전환 복원")
        var separated = before
        let next = separated.split(clip: id, at: 2)!
        if let loc = separated.locate(clip: next) {
            separated.tracks[loc.track].clips[loc.index].transitionIn = TransitionSettings(effect: .fade, duration: 0.2)
        }
        check(separated.join([id, next]).merged == 0, "효과가 있는 내부 경계: 합치기로 효과를 잃지 않음")
        separated = before
        let different = separated.split(clip: id, at: 2)!
        if let loc = separated.locate(clip: different) { separated.tracks[loc.track].clips[loc.index].visualFilter = .cool }
        check(separated.join([id, different]).merged == 0, "필터가 다른 조각: 합치기로 색감을 잃지 않음")

        var textStyle = TextStyle.title
        textStyle.animation = .typewriter
        textStyle.animationDuration = 5
        check(MotionEffects.textProgress(style: textStyle, elapsed: 0.1, duration: 0.2) == 1,
              "짧은 자막: 등장 효과가 끝나고 전체 글자를 읽을 시간 확보")
        check(MotionEffects.visibleCharacters(text: "한👩‍🏫글", progress: 0) == 0
              && MotionEffects.visibleCharacters(text: "한👩‍🏫글", progress: 1) == 3,
              "타이핑: 한글·결합 이모지를 완성된 글자 단위로 표시")
    }

    @MainActor
    private static func effectFontTests() {
        let manager = NSFontManager.shared
        let installed = Set(manager.availableFontFamilies.filter { family in
            let names = (manager.availableMembers(ofFontFamily: family) ?? []).compactMap { $0.first as? String } + [family]
            return names.contains { NSFont(name: $0, size: 16) != nil }
        })
        let catalog = FontList.all
        check(!catalog.isEmpty && Set(catalog.map(\.family)) == installed,
              "글꼴 목록: 사용 가능한 설치 글꼴 전체 수록 (\(catalog.count)개 계열)")
        check(catalog.allSatisfy { NSFont(name: $0.fontName, size: 16) != nil }
              && FontList.suggested.allSatisfy { NSFont(name: $0.fontName, size: 16) != nil },
              "글꼴 목록·추천: 저장되는 실제 글꼴 이름으로 렌더링 가능")
        check(FontList.filtered(" \n ") == catalog && FontList.filtered("__easycut_no_such_font_98c41__").isEmpty,
              "글꼴 검색: 공백은 전체 목록·없는 검색어는 빈 결과")
        if let font = catalog.first {
            check(FontList.filtered("  " + font.family.uppercased() + "  ").contains(font)
                  && FontList.filtered(font.fontName).contains(font),
                  "글꼴 검색: 대소문자·앞뒤 공백 무시 및 글꼴 이름 검색")
        }
        if let nanum = catalog.first(where: { $0.family.lowercased().contains("nanum") }) {
            check(FontList.filtered("나눔").contains(nanum), "글꼴 검색: 한글 나눔으로 영문 Nanum 글꼴 찾기")
        }
        let regularFont = ["Helvetica", "AppleSDGothicNeo-Regular", "ArialMT"]
            .compactMap { NSFont(name: $0, size: 36) }
            .first { manager.traits(of: manager.convert($0, toHaveTrait: .boldFontMask)).contains(.boldFontMask) }
        if let regularFont {
            var style = TextStyle.title
            style.fontName = regularFont.fontName
            style.bold = true
            let boldFont = TextRenderer.resolvedFont(style: style, size: 36)
            style.fontName = boldFont.fontName
            style.bold = false
            let plainFont = TextRenderer.resolvedFont(style: style, size: 36)
            check(boldFont.familyName == regularFont.familyName && plainFont.familyName == regularFont.familyName
                  && manager.traits(of: boldFont).contains(.boldFontMask)
                  && !manager.traits(of: plainFont).contains(.boldFontMask),
                  "글꼴 굵게: 선택한 계열을 유지하며 켜기·끄기 모두 실제 렌더링 글꼴에 반영")
        } else {
            check(false, "글꼴 굵게 검증용 기본 계열 사용 가능")
        }
        var missingStyle = TextStyle.title
        missingStyle.fontName = "__easycut_missing_font_98c41__"
        missingStyle.bold = true
        let fallback = TextRenderer.resolvedFont(style: missingStyle, size: 36)
        check(fallback.fontName == NSFont.systemFont(ofSize: 36, weight: .bold).fontName && fallback.pointSize == 36,
              "설치되지 않은 글꼴: 지정한 크기·굵기의 시스템 글꼴로 안전하게 대체")
    }

    @MainActor
    private static func effectAITests() async {
        // 이 프로세스에서만 자동 저장을 끈다. 실제 앱의 환경설정·복구 파일은 건드리지 않는다.
        let defaults = UserDefaults.standard
        let priorDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var testDomain = priorDomain
        testDomain["autosave"] = false
        defaults.setVolatileDomain(testDomain, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(priorDomain, forName: UserDefaults.argumentDomain) }
        let store = EditorStore()
        var base = Project()
        let asset = MediaAsset(path: "/dev/null/easycut-filter-model.png", name: "필터 명령 검증", kind: .image,
                               duration: 3, width: 320, height: 180, hasAudio: false)
        base.assets = [asset]
        let mediaID = base.insert(asset: asset, track: 0, at: 0, imageDuration: 3)
        let id = base.insertText("효과 명령 검증", track: 1, at: 0, duration: 3)
        store.apply { $0 = base }
        let changed = await AITools.execute("set_clip_properties", [
            "clip_id": id.uuidString,
            "transition_in": "wipeLeft", "transition_in_duration": 0.4,
            "transition_out": "zoom", "transition_out_duration": 0.3,
            "text_animation": "typewriter", "animation_duration": 0.7
        ], store: store)
        let edited = store.project
        check(!changed.1 && edited.clip(id)?.transitionIn == TransitionSettings(effect: .wipeLeft, duration: 0.4)
              && edited.clip(id)?.transitionOut == TransitionSettings(effect: .zoom, duration: 0.3)
              && edited.clip(id)?.textStyle.animation == .typewriter
              && edited.clip(id)?.textStyle.animationDuration == 0.7,
              "AI 명령: 클립 시작·끝 전환과 글자 등장 효과 적용")
        store.undo()
        check(store.project == base, "AI 효과 명령 실행 취소: 원래 프로젝트 복원")
        store.redo()
        check(store.project == edited, "AI 효과 명령 다시 실행: 효과 복원")
        for invalid in [["transition_in": "unknown"], ["text_animation": "unknown"],
                        ["animation_duration": -1], ["transition_out_duration": 11],
                        ["transition_in_duration": Double.nan], ["visual_filter": "unknown"],
                        ["filter_intensity": -0.1], ["filter_intensity": 1.1], ["filter_intensity": Double.nan]] as [[String: Any]] {
            var command = invalid
            command["clip_id"] = id.uuidString
            command["opacity"] = 0.2
            let result = await AITools.execute("set_clip_properties", command, store: store)
            check(result.1 && store.project == edited,
                  "AI 명령: 잘못된 효과 입력 \(invalid.keys.first!) 거부·프로젝트 유지")
        }
        let filtered = await AITools.execute("set_clip_properties", ["clip_id": mediaID.uuidString,
                                                                   "visual_filter": "vintage", "filter_intensity": 0.65], store: store)
        let filterProject = store.project
        check(!filtered.1 && store.project.clip(mediaID)?.visualFilter == .vintage
              && store.project.clip(mediaID)?.filterIntensity == 0.65, "AI 명령: 영상 필터·강도 적용")
        store.undo()
        check(store.project == edited, "AI 필터 명령 실행 취소: 원래 색감 복원")
        store.redo()
        check(store.project == filterProject, "AI 필터 명령 다시 실행: 색감·강도 복원")
        let cleared = await AITools.execute("set_clip_properties", ["clip_id": mediaID.uuidString, "visual_filter": "none"], store: store)
        check(!cleared.1 && store.project.clip(mediaID)?.visualFilter == nil, "AI 명령: 원본 선택으로 필터 해제")
        let caption = await AITools.execute("set_caption_style", ["text_animation": "blurIn", "animation_duration": 0.2], store: store)
        check(!caption.1 && store.project.captionStyle.animation == .blurIn
              && store.project.captionStyle.animationDuration == 0.2,
              "AI 명령: 전체 자막 등장 효과 적용")
        let added = await AITools.execute("add_text", ["text": "새 텍스트", "start": 3.0,
                                                     "text_animation": "bounce", "animation_duration": 0.4], store: store)
        let newText = store.project.tracks.flatMap(\.clips).first { $0.text == "새 텍스트" }
        check(!added.1 && newText?.textStyle.animation == .bounce && newText?.textStyle.animationDuration == 0.4,
              "AI 명령: 새 텍스트에 등장 효과 지정")
        let removed = await AITools.execute("set_clip_properties", ["clip_id": id.uuidString,
                                                                  "transition_in": "none", "text_animation": "none"], store: store)
        check(!removed.1 && store.project.clip(id)?.transitionIn == nil && store.project.clip(id)?.textStyle.animation == nil,
              "AI 명령: 없음 선택으로 전환·텍스트 효과 해제")

        @MainActor
        func waitForPreview(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return condition()
        }
        let previewStore = EditorStore()
        defer { previewStore.player.clear() }
        var previewProject = Project()
        previewProject.canvasWidth = 320
        previewProject.canvasHeight = 180
        let first = previewProject.insertText("첫 클립", track: 1, at: 0, duration: 4)
        let second = previewProject.insertText("다음 클립", track: 1, at: 4, duration: 1)
        let previewCaption = Caption(start: 1, end: 3, text: "자막 효과 미리보기")
        previewProject.captions = [previewCaption]
        previewStore.apply { $0 = previewProject }
        previewStore.selection = [first]
        // 합성 대기 중 선택을 바꾼다. 그 사이에는 MainActor를 양보하지 않는다.
        previewStore.previewSelectedEffect()
        previewStore.selection = [second]
        let ready = await waitForPreview {
            previewStore.player.duration > 4.9 && previewStore.player.player.currentItem?.status == .readyToPlay
        }
        // 합성 완료를 기다리던 미리보기 작업에도 실행 기회를 준 뒤 확인한다.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(ready && !previewStore.player.isPlaying,
              "효과 미리보기: 합성 대기 중 선택이 바뀌면 이전 클립을 자동 재생하지 않음")
        previewStore.player.pause()
        previewStore.selection = [first]
        previewStore.selectedCaption = previewCaption.id
        previewStore.seek(0)
        previewStore.previewSelectedEffect(captionsOnly: true)
        let playing = await waitForPreview { previewStore.player.isPlaying }
        let startTime = previewStore.time
        previewStore.player.pause()
        check(ready && playing && abs(startTime - previewCaption.start) < 0.15
              && previewStore.selection == [first],
              "자막 효과 미리보기: 클립 선택을 유지한 채 자막 시작 1초부터 재생")
    }

    static func testEffects(_ dir: URL) async throws {
        print("전환·텍스트 효과: 저장 호환성·분할·프레임 합성·실제 내보내기")
        try effectModelTests()
        await effectFontTests()
        await effectAITests()
        let size = CGSize(width: 320, height: 180)
        let canvas = CGRect(origin: .zero, size: size)
        let fixture = CIImage(color: CIColor(red: 0.15, green: 0.5, blue: 0.9)).cropped(to: canvas)
        let stripe = CIImage(color: CIColor(red: 1, green: 0.7, blue: 0.1))
            .cropped(to: CGRect(x: 40, y: 30, width: 80, height: 120))
        var source = stripe.composited(over: fixture)
        // 흐림·픽셀화도 단색 패널과 확실히 구별되도록 작은 격자를 함께 넣는다.
        for row in 0..<12 {
            for column in 0..<16 {
                let color = (row + column) % 2 == 0 ? CIColor.white : CIColor.black
                let cell = CGRect(x: 150 + column * 8, y: 38 + row * 8, width: 8, height: 8)
                source = CIImage(color: color).cropped(to: cell).composited(over: source)
            }
        }
        let imageURL = dir.appendingPathComponent("effects-source.png")
        try writeEffectPNG(source, size: size, to: imageURL)
        guard let flattened = RenderCache.image(imageURL.path) else { throw MediaError.failed("효과 검증 이미지 읽기 실패") }
        let baseLayer = RenderLayer(content: .image(path: imageURL.path), start: 0, end: 2,
                                    opacity: 1, scale: 1, offsetX: 0, offsetY: 0, fadeIn: 0, fadeOut: 0)
        func pixels(layer: RenderLayer, at time: Double) -> [UInt8] {
            let scene = RenderScene(layers: [layer], captions: [], captionStyle: .caption,
                                    showCaptions: false, background: .black)
            return effectPixels(EasyCompositor.compose(scene: scene, time: time, size: size) { _ in nil }, size: size)
        }
        let settled = pixels(layer: baseLayer, at: 1)
        for effect in ClipTransition.allCases where effect != .none {
            var layer = baseLayer
            layer.transitionIn = TransitionSettings(effect: effect, duration: 0.5)
            layer.transitionOut = TransitionSettings(effect: effect, duration: 0.5)
            let early = pixels(layer: layer, at: 0.1)
            let middle = pixels(layer: layer, at: 1)
            let late = pixels(layer: layer, at: 1.9)
            check(effectDifference(early, settled) > 0.01 && effectDifference(late, settled) > 0.01,
                  "\(effect.label): 시작·끝 전환이 실제 픽셀을 바꿈")
            check(effectDifference(middle, settled) < 0.001, "\(effect.label): 전환 완료 후 원래 화면 복원")
            for entering in [true, false] {
                let transformed = MotionEffects.transition(flattened, settings: TransitionSettings(effect: effect, duration: 0.5),
                                                           elapsed: 0.1, duration: 2, entering: entering, canvas: canvas)
                check(finiteEffectExtent(transformed), "\(effect.label): \(entering ? "시작" : "끝") 변환 결과의 좌표·크기 유효")
            }
        }

        let originalPixels = effectPixels(flattened, size: size)
        for filter in VisualFilter.allCases where filter != .none {
            let output = MotionEffects.filter(flattened, kind: filter)
            let outputPixels = effectPixels(output, size: size)
            let zero = MotionEffects.filter(flattened, kind: filter, intensity: 0)
            check(finiteEffectExtent(output) && output.extent == flattened.extent,
                  "\(filter.label): 필터 적용 후 유효한 원본 프레임 크기 유지")
            check(effectDifference(outputPixels, originalPixels) > 0.001, "\(filter.label): 필터가 실제 화면 픽셀을 바꿈")
            check(effectDifference(effectPixels(zero, size: size), originalPixels) == 0,
                  "\(filter.label): 강도 0이면 원본과 정확히 같음")
            var layer = baseLayer
            layer.visualFilter = filter
            layer.filterIntensity = 1
            check(effectDifference(pixels(layer: layer, at: 1), outputPixels) < 0.001,
                  "\(filter.label): 클립 속성에서 실제 합성까지 필터 전달")
        }
        let clampedNegative = MotionEffects.filter(flattened, kind: .sepia, intensity: -1)
        let clampedHigh = MotionEffects.filter(flattened, kind: .sepia, intensity: 2)
        let fullSepia = MotionEffects.filter(flattened, kind: .sepia, intensity: 1)
        check(effectDifference(effectPixels(clampedNegative, size: size), originalPixels) == 0
              && effectDifference(effectPixels(clampedHigh, size: size), effectPixels(fullSepia, size: size)) == 0,
              "필터 강도: 범위를 벗어난 값도 0~1로 안전하게 제한")

        for animation in TextAnimation.allCases where animation != .none {
            var style = TextStyle.title
            style.fontSize = 170
            style.outline = false
            style.animation = animation
            style.animationDuration = 0.6
            let layer = RenderLayer(content: .text("한글 효과 👩‍🏫", style), start: 0, end: 2,
                                    opacity: 1, scale: 1, offsetX: 0, offsetY: 0, fadeIn: 0, fadeOut: 0)
            let early = pixels(layer: layer, at: 0.02)
            let middle = pixels(layer: layer, at: 1)
            check(effectDifference(early, middle) > 0.001, "\(animation.label): 텍스트 등장 중·완료 프레임 구별")
            var staticStyle = style
            staticStyle.animation = nil
            var staticLayer = layer
            staticLayer.content = .text("한글 효과 👩‍🏫", staticStyle)
            check(effectDifference(middle, pixels(layer: staticLayer, at: 1)) < 0.001,
                  "\(animation.label): 완료 후 원래 텍스트 위치·크기 복원")
            if let textImage = RenderCache.text("한글 효과 👩‍🏫", style: style, unit: 1.0 / 6, maxWidth: 288, scale: 1) {
                let transformed = MotionEffects.text(textImage, style: style, elapsed: 0.1, duration: 2, canvas: canvas)
                check(finiteEffectExtent(transformed), "\(animation.label): 텍스트 변환 결과의 좌표·크기 유효")
            }
        }
        var colorTextStyle = TextStyle.title
        colorTextStyle.fontSize = 170
        colorTextStyle.textColor = .yellow
        let colorText = RenderLayer(content: .text("텍스트 색상", colorTextStyle), start: 0, end: 2,
                                    opacity: 1, scale: 1, offsetX: 0, offsetY: 0, fadeIn: 0, fadeOut: 0)
        var filteredText = colorText
        filteredText.visualFilter = .mono
        filteredText.filterIntensity = 1
        check(effectDifference(pixels(layer: colorText, at: 1), pixels(layer: filteredText, at: 1)) == 0,
              "영상 필터: 텍스트의 지정한 글자색에 적용하지 않음")
        let text = "한글 👩‍🏫 효과\n줄바꿈도 유지"
        let full = RenderCache.text(text, style: .title, unit: 0.2, maxWidth: 280, scale: 1)
        let partial = RenderCache.text(text, style: .title, unit: 0.2, maxWidth: 280, scale: 1, visibleCharacters: 3)
        check(full != nil && partial != nil && full?.extent == partial?.extent,
              "타이핑: 한글·이모지·여러 줄 텍스트의 박스·줄바꿈 고정")
        if let hidden = RenderCache.text("한👩‍🏫글", style: .title, unit: 0.2, maxWidth: 280, scale: 1, visibleCharacters: 0) {
            let bytes = effectPixels(hidden, size: hidden.extent.size)
            check(bytes.indices.filter { $0 % 4 == 3 }.allSatisfy { bytes[$0] == 0 },
                  "타이핑 첫 프레임: 한글·색상 이모지·외곽선 모두 숨김")
        } else {
            check(false, "타이핑 첫 프레임: 전체 레이아웃 렌더링 성공")
        }
        var resetStyle = TextStyle.caption
        resetStyle.fontSize = 130
        resetStyle.animation = .fade
        resetStyle.animationDuration = 0.6
        let resetScene = RenderScene(layers: [], captions: [Caption(start: 0, end: 1, text: "반복 자막"),
                                                           Caption(start: 1.5, end: 2.5, text: "반복 자막")],
                                     captionStyle: resetStyle, showCaptions: true, background: .black)
        let firstCaption = effectPixels(EasyCompositor.compose(scene: resetScene, time: 0.1, size: size) { _ in nil }, size: size)
        let secondCaption = effectPixels(EasyCompositor.compose(scene: resetScene, time: 1.6, size: size) { _ in nil }, size: size)
        let completeCaption = effectPixels(EasyCompositor.compose(scene: resetScene, time: 0.8, size: size) { _ in nil }, size: size)
        check(effectDifference(firstCaption, secondCaption) < 0.001
              && effectDifference(secondCaption, completeCaption) > 0.001,
              "자막 등장 효과: 각 자막의 시작 시간부터 다시 재생")

        var project = Project()
        project.canvasWidth = size.width
        project.canvasHeight = size.height
        project.fps = 30
        let asset = MediaAsset(path: imageURL.path, name: "효과 검증 이미지", kind: .image,
                               duration: 3, width: size.width, height: size.height, hasAudio: false)
        project.assets = [asset]
        project.insert(asset: asset, track: 0, at: 0, imageDuration: 3)
        project.tracks[0].clips[0].transitionIn = TransitionSettings(effect: .iris, duration: 0.7)
        project.tracks[0].clips[0].transitionOut = TransitionSettings(effect: .flip, duration: 0.7)
        project.tracks[0].clips[0].visualFilter = .vintage
        project.tracks[0].clips[0].filterIntensity = 0.65
        project.insertText("전환 효과 테스트", track: 1, at: 0.2, duration: 2.6)
        project.tracks[1].clips[0].textStyle.fontSize = 130
        project.tracks[1].clips[0].textStyle.positionY = 0.35
        project.tracks[1].clips[0].textStyle.animation = .bounce
        project.tracks[1].clips[0].textStyle.animationDuration = 1
        project.captionStyle.fontSize = 90
        project.captionStyle.animation = .blurIn
        project.captionStyle.animationDuration = 0.5
        project.captions = [Caption(start: 0.2, end: 1.4, text: "첫 자막"),
                            Caption(start: 1.5, end: 2.9, text: "다음 자막")]
        try JSONEncoder().encode(project).write(to: dir.appendingPathComponent("effects.easycut"))
        let built = try await CompositionBuilder.build(project: project, renderSize: size)
        check(built.scene.layers.first?.transitionIn?.effect == .iris
              && built.scene.layers.first?.transitionOut?.effect == .flip
              && built.scene.layers.first?.visualFilter == .vintage && built.scene.layers.first?.filterIntensity == 0.65,
              "프로젝트 → 합성: 시작·끝 전환·필터·강도 전달")
        let output = dir.appendingPathComponent("effects-export.mp4")
        try await Exporter.export(project: project, format: .mp4H264, size: size, burnCaptions: true,
                                  to: output, cancel: Exporter.Box()) { _ in }
        let exported = AVURLAsset(url: output)
        let duration = try await exported.load(.duration).seconds
        let track = try await exported.loadTracks(withMediaType: .video).first
        let resolution = try await track?.load(.naturalSize)
        check(abs(duration - 3) < 0.06 && resolution == size, "실제 MP4: 3초·320×180 해상도 유지")
        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for t in [0.1, 0.4, 1.0, 1.6, 2.8] {
            let (cg, actual) = try await generator.image(at: CompositionBuilder.ct(t))
            let encoded = effectPixels(CIImage(cgImage: cg), size: size)
            let preview = EasyCompositor.compose(scene: built.scene, time: actual.seconds, size: size) { _ in nil }
            let difference = effectDifference(encoded, effectPixels(preview, size: size))
            check(difference < 0.035, String(format: "실제 MP4 %.1f초: 미리보기와 평균 RGB 오차 %.3f", t, difference))
            if t == 0.4 || t == 1.0 {
                try writeEffectPNG(CIImage(cgImage: cg), size: size,
                                   to: dir.appendingPathComponent(t == 0.4 ? "effects-early.png" : "effects-settled.png"))
            }
        }
        print("효과 검증 결과: \(dir.path)")
    }
}
