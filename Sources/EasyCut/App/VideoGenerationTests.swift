import AppKit
import AVFoundation

extension SelfTest {
    /// Technical fixtures only: these never generate or render the user's creative brief.
    static func testVideoGeneration(_ dir: URL) async throws {
        try await testVideoGenerationAPI(dir)
        print("영상 생성: 설정·Claude 응답·코드 계약")
        func request(renderer: VideoGenerator.Renderer = .canvas, prompt: String = "이지컷 기술 검증",
                     duration: Double = 2, width: Int = 640, height: Int = 640, fps: Int = 30,
                     automaticSkills: Bool = true) -> VideoGenerationRequest {
            VideoGenerationRequest(renderer: renderer, prompt: prompt, duration: duration, width: width, height: height, fps: fps,
                                   automaticSkills: automaticSkills)
        }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, label) }
            catch { check(true, label) }
        }
        func json(_ object: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        }
        func response(_ source: String, title: String = "기술 검증") throws -> String {
            try json(["title": title, "source": source])
        }

        print("영상 생성: 관리 도구의 부분 설치·버전 복구 판정")
        let runtimeFixture = dir.appendingPathComponent("managed-runtime-fixture-\(UUID().uuidString)", isDirectory: true)
        let fixtureModules = runtimeFixture.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeFixture) }
        let runtimePackage = try JSONSerialization.jsonObject(with: Data(VideoGenerationRuntime.package.utf8)) as! [String: Any]
        let pinnedDependencies = runtimePackage["dependencies"] as! [String: String]
        func writeFixturePackage(_ name: String, version: String) throws {
            let package = fixtureModules.appendingPathComponent("\(name)/package.json")
            try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json(["name": name, "version": version]).utf8).write(to: package)
        }
        try writeFixturePackage("puppeteer-core", version: pinnedDependencies["puppeteer-core"]!)
        check(!VideoGenerationJob.managedRuntimeReady(modules: fixtureModules),
              "puppeteer만 남은 부분 설치는 완료로 취급하지 않음")
        for (name, version) in pinnedDependencies { try writeFixturePackage(name, version: version) }
        try Data("// CLI fixture".utf8).write(to: fixtureModules.appendingPathComponent("@remotion/cli/remotion-cli.js"))
        check(VideoGenerationJob.managedRuntimeReady(modules: fixtureModules),
              "선언된 모든 고정 버전과 CLI 파일이 있으면 관리 도구 준비 완료")
        try writeFixturePackage("react", version: pinnedDependencies["react"]! + "-mismatch")
        check(!VideoGenerationJob.managedRuntimeReady(modules: fixtureModules),
              "직접 의존성 버전이 다르면 관리 도구 복구 대상으로 판단")

        check(AgentLink.subscriptionStatus(.claude, output: try json(["loggedIn": true, "authMethod": "claude.ai"])), "Claude 구독 인증을 확인")
        check(!AgentLink.subscriptionStatus(.claude, output: try json(["loggedIn": true, "authMethod": "api_key"])), "Claude 구독 경로에서 API 키 인증 거절")
        check(AgentLink.subscriptionStatus(.codex, output: "Logged in using ChatGPT"), "ChatGPT 구독 인증을 확인")
        check(!AgentLink.subscriptionStatus(.codex, output: "Logged in using an API key"), "GPT 구독 경로에서 API 키 인증 거절")
        let gptSubscription = VideoGenerationRequest(renderer: .canvas, prompt: "검사", duration: 2, width: 640, height: 640, fps: 30, provider: .openAI)
        check(gptSubscription.access == .subscription, "새 GPT 요청은 구독 연결을 기본 제공")
        let claudeAPI = VideoGenerationRequest(renderer: .canvas, prompt: "검사", duration: 2, width: 640, height: 640, fps: 30, provider: .claude, access: .api)
        check(try JSONDecoder().decode(VideoGenerationRequest.self, from: JSONEncoder().encode(claudeAPI)) == claudeAPI, "Claude API 연결 방식을 요청에 보존")
        rejects("Gemini의 지원하지 않는 구독 경로 거절") {
            try VideoGenerationRequest(renderer: .canvas, prompt: "검사", duration: 2, width: 640, height: 640, fps: 30, provider: .gemini, access: .subscription).validate()
        }
        let finalJSON = try json(["title": "응답 검사", "source": "function frame(i){} function audio(t){return 0;}"])
        let codexEvents = try [json(["type": "thread.started"]), json(["type": "item.completed", "item": ["type": "reasoning", "text": "not output"]]),
                              json(["type": "item.completed", "item": ["type": "agent_message", "text": finalJSON]]), json(["type": "turn.completed"])].joined(separator: "\n")
        check(try VideoGenerationJob.codexResult(codexEvents) == finalJSON, "GPT 구독 이벤트에서 최종 메시지만 해석")
        rejects("GPT 구독의 도구 호출 응답 거절") { _ = try VideoGenerationJob.codexResult(json(["type": "item.completed", "item": ["type": "command_execution"]])) }
        rejects("GPT 구독의 실패 이벤트 거절") { _ = try VideoGenerationJob.codexResult(json(["type": "turn.failed"])) }
        rejects("GPT 구독의 최종 메시지 누락 거절") { _ = try VideoGenerationJob.codexResult(json(["type": "turn.completed"])) }

        print("영상 생성: 제작 스킬 선택·호환성·선택 지침 전달")
        let legacyJSON = try json(["renderer": "canvas", "prompt": "기존 요청", "duration": 2,
                                   "width": 640, "height": 640, "fps": 30])
        let legacyRequest = try JSONDecoder().decode(VideoGenerationRequest.self, from: Data(legacyJSON.utf8))
        check(legacyRequest.automaticSkills, "기존 요청 JSON은 스킬 자동 적용을 기본 사용")
        let disabledRequest = request(automaticSkills: false)
        let disabledRoundTrip = try JSONDecoder().decode(VideoGenerationRequest.self, from: JSONEncoder().encode(disabledRequest))
        check(disabledRoundTrip == disabledRequest && !disabledRoundTrip.automaticSkills,
              "스킬 자동 적용 끄기를 요청에 보존")

        let catalog = VideoGenerationSkills.catalog
        let catalogIDs = catalog.map(\.id)
        check(!catalog.isEmpty && catalogIDs.allSatisfy { !$0.isEmpty } && Set(catalogIDs).count == catalog.count,
              "제작 스킬 카탈로그 ID가 비어 있거나 중복되지 않음")
        check(catalog.allSatisfy { skill in
            guard skill.sourceURL.scheme == "https", !skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !skill.upstreamName.isEmpty, !skill.licenseName.isEmpty, !skill.revision.isEmpty else { return false }
            if skill.sourceURL.host == "github.com" {
                return skill.revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil &&
                       skill.sourceURL.path.contains("/blob/\(skill.revision)/")
            }
            return true
        }, "스킬에 HTTPS 출처·검토 버전·사용 조건·지침이 있으며 GitHub 원본은 커밋 고정")

        func selectionJSON(_ ids: [String], reason: String = "원인과 결과를 연결해 설명합니다.") throws -> String {
            try json(["skillIDs": ids, "reason": reason])
        }
        let selectedJSON = try selectionJSON(["visual-explainer"])
        let selectedSkills = try VideoSkillSelection.decode(selectedJSON)
        check(selectedSkills.skills.map(\.id) == ["visual-explainer"] && selectedSkills.catalogVersion == VideoGenerationSkills.version,
              "선택 결과를 검토된 카탈로그 지침으로 해석")
        let resultSelection = try VideoSkillSelection.decode(json(["result": selectedJSON]))
        check(resultSelection == selectedSkills, "Claude result의 스킬 선택 JSON 해석")
        let fencedSelection = try VideoSkillSelection.decode(json(["result": "```json\n\(selectedJSON)\n```" ]))
        check(fencedSelection == selectedSkills, "Claude result 코드블록의 스킬 선택 JSON 해석")
        let structuredSelection = try VideoSkillSelection.decode(json(["is_error": false,
            "structured_output": ["skillIDs": ["visual-explainer"], "reason": selectedSkills.reason]]))
        check(structuredSelection == selectedSkills, "Claude structured_output의 스킬 선택 해석")
        let noSkills = try VideoSkillSelection.decode(selectionJSON([], reason: "단순한 장면이므로 별도 지침이 필요하지 않습니다."))
        check(noSkills.skills.isEmpty && !noSkills.reason.isEmpty, "불필요한 스킬을 적용하지 않는 빈 선택 허용")
        for (label, invalid) in [
            ("알 수 없는 스킬 ID 거절", try selectionJSON(["unreviewed-download"])),
            ("같은 스킬 중복 선택 거절", try selectionJSON(["visual-explainer", "visual-explainer"])),
            ("한 번에 네 개 이상의 스킬 선택 거절", try selectionJSON(["motion-design", "visual-explainer", "kinetic-type", "data-story"])),
            ("비어 있는 스킬 선택 이유 거절", try selectionJSON(["visual-explainer"], reason: " \n ")),
            ("너무 긴 스킬 선택 이유 거절", try selectionJSON(["visual-explainer"], reason: String(repeating: "가", count: 501))),
        ] { rejects(label) { _ = try VideoSkillSelection.decode(invalid) } }
        do {
            _ = try VideoSkillSelection.decode(json(["is_error": true, "result": "스킬 선택 중 로그인이 만료되었습니다"]))
            check(false, "Claude 스킬 선택 오류를 성공으로 처리하지 않음")
        } catch {
            check(error.localizedDescription.contains("로그인이 만료되었습니다"), "Claude 스킬 선택 오류의 원인을 보존")
        }

        let canvasSkillPrompt = VideoGenerationJob.generationPrompt(request(), selection: selectedSkills)
        let selectedInstruction = selectedSkills.skills[0].instructions
        check(canvasSkillPrompt.contains(selectedInstruction) &&
              catalog.filter { $0.id != "visual-explainer" }.allSatisfy { !canvasSkillPrompt.contains($0.instructions) },
              "선택한 스킬의 지침만 영상 생성 프롬프트에 전달")
        check(!VideoGenerationJob.generationPrompt(disabledRequest, selection: selectedSkills).contains(selectedInstruction),
              "자동 적용을 끄면 전달받은 스킬 지침도 생성에 사용하지 않음")
        check(!VideoGenerationJob.generationPrompt(request(), selection: noSkills).contains("Selected, reviewed creative skills"),
              "빈 선택은 기본 생성 지침만 사용")
        check(canvasSkillPrompt.contains("function frame(i)") && canvasSkillPrompt.contains("function audio(t)") &&
              canvasSkillPrompt.contains("no imports/exports"), "스킬을 적용해도 Canvas의 프레임·소리·모듈 계약 유지")
        let remotionSkillPrompt = VideoGenerationJob.generationPrompt(request(renderer: .remotion), selection: selectedSkills)
        check(remotionSkillPrompt.contains(selectedInstruction) && remotionSkillPrompt.contains("Import only from react and remotion") &&
              remotionSkillPrompt.contains("silent motion graphic"), "스킬을 적용해도 Remotion의 모듈·무음 계약 유지")

        let canvasRequest = request()
        try canvasRequest.validate()
        check(canvasRequest.frames == 60, "2초·30fps는 60프레임")
        for (label, invalid) in [
            ("빈 영상 설명 거절", request(prompt: " \n ")),
            ("너무 긴 영상 설명 거절", request(prompt: String(repeating: "가", count: 20_001))),
            ("NaN 길이 거절", request(duration: .nan)),
            ("무한 길이 거절", request(duration: .infinity)),
            ("최소 길이 미만 거절", request(duration: 1)),
            ("최대 길이 초과 거절", request(duration: 61)),
            ("홀수 화면 크기 거절", request(width: 641)),
            ("최대 화면 크기 초과 거절", request(width: 1922)),
            ("최소 화면 크기 미만 거절", request(height: 318)),
            ("지원하지 않는 fps 거절", request(fps: 25)),
        ] { rejects(label) { try invalid.validate() } }

        let canvasSource = GeneratedVideoSource(title: "이지컷 Canvas 기술 검증", source: #"""
        function frame(i) {
          const t=i/FPS;
          ctx.fillStyle='#25214A'; ctx.fillRect(0,0,W,H);
          const x=W*(0.5+0.20*Math.sin(t*Math.PI));
          const radius=W*(0.07+seededRandom(17)*0.02);
          ctx.fillStyle='#8DD3F6'; ctx.beginPath();
          ctx.arc(x,H*0.38,radius,0,Math.PI*2); ctx.fill();
          ctx.fillStyle='#FFC93C'; ctx.textAlign='center';
          ctx.font='700 58px "Apple SD Gothic Neo", sans-serif';
          ctx.fillText('이지컷',W/2,H*0.72);
        }
        function audio(t) {
          const fade=Math.max(0,Math.min(1,t*10,(DURATION-t)*10));
          return 0.15*fade*Math.sin(2*Math.PI*440*t);
        }
        """#)
        let remotionSource = GeneratedVideoSource(title: "이지컷 Remotion 기술 검증", source: #"""
        import React from 'react';
        import {AbsoluteFill,useCurrentFrame,useVideoConfig} from 'remotion';
        export default function Scene() {
          const frame=useCurrentFrame(); const {fps}=useVideoConfig();
          const x=50+20*Math.sin(frame/fps*Math.PI);
          return <AbsoluteFill style={{backgroundColor:'#25214A',fontFamily:'Apple SD Gothic Neo, sans-serif'}}>
            <div style={{position:'absolute',left:`${x}%`,top:'38%',width:100,height:100,
              borderRadius:'50%',backgroundColor:'#8DD3F6',transform:'translate(-50%,-50%)'}} />
            <div style={{position:'absolute',top:'65%',width:'100%',textAlign:'center',
              fontSize:58,fontWeight:700,color:'#FFC93C'}}>이지컷</div>
          </AbsoluteFill>;
        }
        """#)
        let direct = try GeneratedVideoSource.decode(response(canvasSource.source), renderer: .canvas)
        check(direct.source == canvasSource.source, "Canvas 코드와 한글을 손실 없이 해석")
        let structured = try GeneratedVideoSource.decode(json(["is_error": false,
            "structured_output": ["title": canvasSource.title, "source": canvasSource.source]]), renderer: .canvas)
        check(structured.title == canvasSource.title, "Claude structured_output 응답 해석")
        let fenced = try GeneratedVideoSource.decode(json(["result": "```json\n\(try response(canvasSource.source))\n```"]), renderer: .canvas)
        check(fenced.source == canvasSource.source, "Claude result의 JSON 코드블록 해석")
        let remotion = try GeneratedVideoSource.decode(response(remotionSource.source), renderer: .remotion)
        check(remotion.source == remotionSource.source, "react·remotion만 쓰는 기본 컴포넌트 허용")

        rejects("잘못된 JSON 응답 거절") { _ = try GeneratedVideoSource.decode("{broken", renderer: .canvas) }
        rejects("필수 source 없는 응답 거절") { _ = try GeneratedVideoSource.decode(json(["title": "누락"]), renderer: .canvas) }
        rejects("비어 있는 제목 거절") { _ = try GeneratedVideoSource.decode(response(canvasSource.source, title: ""), renderer: .canvas) }
        do {
            _ = try GeneratedVideoSource.decode(json(["is_error": true, "result": "로그인이 만료되었습니다"]), renderer: .canvas)
            check(false, "Claude 오류 envelope를 생성 성공으로 취급하지 않음")
        } catch {
            check(error.localizedDescription.contains("로그인이 만료되었습니다"), "Claude 오류 envelope의 원인을 보존")
        }
        rejects("Canvas audio(t) 누락 거절") {
            _ = try GeneratedVideoSource.decode(response("function frame(i) { ctx.fillRect(0,0,W,H); }"), renderer: .canvas)
        }
        rejects("Canvas 모듈 import 거절") {
            _ = try GeneratedVideoSource.decode(response("import x from 'react';\n" + canvasSource.source), renderer: .canvas)
        }
        rejects("외부 네트워크 호출 거절") {
            _ = try GeneratedVideoSource.decode(response(canvasSource.source + "\nfetch('https://example.invalid');"), renderer: .canvas)
        }
        rejects("명령 실행 모듈 거절") {
            _ = try GeneratedVideoSource.decode(response(canvasSource.source + "\nrequire('child_process');"), renderer: .canvas)
        }
        rejects("비결정적 난수 거절") {
            _ = try GeneratedVideoSource.decode(response(canvasSource.source + "\nMath.random();"), renderer: .canvas)
        }
        rejects("현재 시각에 의존하는 코드 거절") {
            _ = try GeneratedVideoSource.decode(response(canvasSource.source + "\nDate.now();"), renderer: .canvas)
        }
        rejects("허용 목록 밖의 Remotion import 거절") {
            _ = try GeneratedVideoSource.decode(response("import extra from 'left-pad';\n" + remotionSource.source), renderer: .remotion)
        }
        rejects("Remotion 기본 컴포넌트 누락 거절") {
            _ = try GeneratedVideoSource.decode(response("import React from 'react'; function Scene(){return null;}"), renderer: .remotion)
        }

        guard let runtimePath = ProcessInfo.processInfo.environment["EASYCUT_GENERATION_RUNTIME"], !runtimePath.isEmpty else {
            print("  ⏭ 렌더 통합 검사 생략: EASYCUT_GENERATION_RUNTIME에 설치된 런타임 경로를 지정하세요.")
            return
        }
        let runtime = URL(fileURLWithPath: runtimePath, isDirectory: true)
        let modules = runtime.lastPathComponent == "node_modules" ? runtime : runtime.appendingPathComponent("node_modules", isDirectory: true)
        let ffmpegOverride = ProcessInfo.processInfo.environment["EASYCUT_GENERATION_FFMPEG"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFFmpeg = (ffmpegOverride?.isEmpty == false ? ffmpegOverride : nil) ?? Tools.find("ffmpeg") ?? VideoGenerationJob.executable("ffmpeg")
        guard FileManager.default.fileExists(atPath: modules.appendingPathComponent("puppeteer-core/package.json").path),
              FileManager.default.fileExists(atPath: modules.appendingPathComponent("@remotion/cli/remotion-cli.js").path),
              let node = VideoGenerationJob.executable("node"),
              let ffmpeg = selectedFFmpeg, FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw MediaError.failed("영상 생성 통합 검사에 node·FFmpeg·puppeteer-core·@remotion/cli가 필요합니다.")
        }
        let browserCandidates = [ProcessInfo.processInfo.environment["EASYCUT_GENERATION_BROWSER"] ?? "",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"]
        guard let browser = browserCandidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MediaError.failed("영상 생성 통합 검사에 Chrome이 필요합니다.")
        }

        print("영상 생성: 실제 브라우저 미리보기·2초 기술 검증 영상")
        for (renderer, source) in [(VideoGenerator.Renderer.canvas, canvasSource), (.remotion, remotionSource)] {
            let spec = request(renderer: renderer)
            let jobDir = dir.appendingPathComponent("video-generation-\(renderer.rawValue)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: jobDir.appendingPathComponent("node_modules"), withDestinationURL: modules)
            try JSONEncoder().encode(spec).write(to: jobDir.appendingPathComponent("request.json"), options: .atomic)
            let skillManifest = jobDir.appendingPathComponent("applied-skills.json")
            try JSONEncoder().encode(selectedSkills).write(to: skillManifest, options: .atomic)
            try VideoGenerationJob.writeSource(source, request: spec, directory: jobDir)
            let job = VideoGenerationJob(request: spec, directory: jobDir, node: node, browser: browser, ffmpeg: ffmpeg)
            let files = ["request.json", "source.json", "applied-skills.json"] + (renderer == .canvas ? ["scene.js", "canvas-render.cjs"] : ["Scene.tsx", "entry.tsx"])
            let originalFiles = try files.map { try Data(contentsOf: jobDir.appendingPathComponent($0)) }

            try await job.makePreviews(process: GenerationProcess())
            let previewData = try job.previews.map { try Data(contentsOf: $0) }
            check(job.previews.count == 4 && previewData.allSatisfy { data in
                guard let image = NSBitmapImageRep(data: data) else { return false }
                return image.pixelsWide == spec.width && image.pixelsHigh == spec.height
            }, "\(renderer.rawValue): 640×640 PNG 샘플 4장 생성")
            check(Set(previewData).count > 1, "\(renderer.rawValue): 시간에 따라 장면이 달라짐")
            check(!FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("render.mp4").path) &&
                  !FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("frames").path) &&
                  !FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("music.wav").path),
                  "\(renderer.rawValue): 미리보기만 만들고 전체 영상·음원은 생성하지 않음")
            try await job.makePreviews(process: GenerationProcess())
            let repeatedPreviews = try job.previews.map { try Data(contentsOf: $0) }
            check(previewData == repeatedPreviews, "\(renderer.rawValue): 같은 코드의 샘플 프레임 재현")

            let output = try await job.render(process: GenerationProcess())
            let asset = try await MediaProbe.probe(output)
            check(asset.kind == .video && Int(asset.width) == 640 && Int(asset.height) == 640 && abs(asset.duration - 2) < 0.07,
                  "\(renderer.rawValue): 실제 MP4 길이 2초·크기 640×640 일치")
            check(asset.hasAudio == (renderer == .canvas), "\(renderer.rawValue): Canvas 합성 오디오·Remotion 무음 계약 일치")
            let finalFiles = try files.map { try Data(contentsOf: jobDir.appendingPathComponent($0)) }
            check(originalFiles == finalFiles, "\(renderer.rawValue): 확인한 코드와 설정을 변경 없이 전체 렌더링")
            let retainedPreviews = try job.previews.map { try Data(contentsOf: $0) }
            check(previewData == retainedPreviews, "\(renderer.rawValue): 전체 렌더링 뒤에도 승인용 샘플 보존")
            try await VideoGenerationJob.validateOutput(output, request: spec)
            let wrongSize = request(renderer: renderer, width: 642)
            do {
                try await VideoGenerationJob.validateOutput(output, request: wrongSize)
                check(false, "\(renderer.rawValue): 요청과 다른 출력 크기를 거절")
            } catch { check(true, "\(renderer.rawValue): 요청과 다른 출력 크기를 거절") }
            print("  기술 검증 파일: \(output.path)")

            try await generationTestTimelineImport(output, label: renderer.rawValue, directory: jobDir)

            // The approved instruction/provenance snapshot is part of the render contract.
            let approvedManifest = try Data(contentsOf: skillManifest)
            let outputBeforeSkillEdit = try Data(contentsOf: output)
            try JSONEncoder().encode(VideoSkillSelection.disabled).write(to: skillManifest, options: .atomic)
            do {
                _ = try await job.render(process: GenerationProcess())
                check(false, "\(renderer.rawValue): 미리보기 이후 스킬 변경 시 재확인 요구")
            } catch {
                check(error.localizedDescription.contains("미리보기 이후"), "\(renderer.rawValue): 미리보기 이후 스킬 변경 시 재확인 요구")
            }
            let outputAfterSkillEdit = try Data(contentsOf: output)
            check(outputAfterSkillEdit == outputBeforeSkillEdit, "\(renderer.rawValue): 승인되지 않은 스킬 변경으로 기존 영상 덮어쓰지 않음")
            try approvedManifest.write(to: skillManifest, options: .atomic)

            // A manual edit after approval must be rejected before a new render starts.
            let changedFile = jobDir.appendingPathComponent(renderer == .canvas ? "scene.js" : "Scene.tsx")
            let approvedSource = try Data(contentsOf: changedFile)
            let approvedOutput = try Data(contentsOf: output)
            var editedSource = approvedSource
            editedSource.append(Data("\n// Edited after preview\n".utf8))
            try editedSource.write(to: changedFile, options: .atomic)
            do {
                _ = try await job.render(process: GenerationProcess())
                check(false, "\(renderer.rawValue): 미리보기 이후 코드 변경 시 재확인 요구")
            } catch {
                check(error.localizedDescription.contains("미리보기 이후"), "\(renderer.rawValue): 미리보기 이후 코드 변경 시 재확인 요구")
            }
            let unchangedOutput = try Data(contentsOf: output)
            check(unchangedOutput == approvedOutput, "\(renderer.rawValue): 승인되지 않은 코드로 기존 영상 덮어쓰지 않음")
            try approvedSource.write(to: changedFile, options: .atomic)
        }
    }

    @MainActor
    private static func generationTestTimelineImport(_ output: URL, label: String, directory: URL) async throws {
        // These overrides exist only in this self-test process; persistent preferences are preserved.
        let oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["autosave"] = false
        arguments["sttEngine"] = STTEngine.apple.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
        let store = EditorStore()
        store.projectURL = directory.appendingPathComponent("import-test.easycut")
        let initial = store.project
        try await VideoGenerator.importGenerated(output, store: store)
        check(store.project.assets.count == 1 && abs(store.project.duration - 2) < 0.07 && store.canUndo,
              "\(label): 생성 영상이 실행 취소 가능한 타임라인 클립으로 추가")
        check(store.project.canvasWidth == 640 && store.project.canvasHeight == 640,
              "\(label): 빈 프로젝트 화면 크기를 생성 영상에 맞춤")
        store.undo()
        check(store.project == initial && store.canRedo, "\(label): 추가 실행 취소로 원래 프로젝트 복원")
        store.redo()
        check(store.project.assets.count == 1 && abs(store.project.duration - 2) < 0.07,
              "\(label): 다시 실행으로 생성 영상 복원")
    }
}
