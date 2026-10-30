import SwiftUI
import AppKit

/// 생성한 장면의 샘플을 확인한 뒤 전체 영상을 렌더링하는 창.
/// 생성기는 EditorStore가 보관하므로 창을 닫아도 진행 중인 작업은 유지된다.
struct VideoGenerationSheet: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var generator: VideoGenerator
    @ObservedObject private var link = AgentLink.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showRuntime = false
    @State private var showSkills = false
    @State private var addingToTimeline = false
    @State private var pendingAPIKey = ""
    @FocusState private var promptFocused: Bool

    private func copy(_ korean: String, _ english: String) -> String { Loc.english ? english : korean }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "film.stack.fill")
                    .font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy("영상 만들기", "Create a Video")).font(.title2.bold())
                    Text(copy("원하는 내용을 설명하고, 미리보기 4장을 확인한 뒤 영상으로 만드세요", "Describe your idea, review four sample frames, then make your video"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copy("닫기", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    account
                    request
                    options
                    skills
                    runtime

                    Text(copy("입력한 설명은 \(transmissionName)에 전송되며, 생성 코드는 이 Mac에서 실행됩니다.",
                              "Your description is sent to \(transmissionName), and generated code runs on this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                    if generator.busy {
                        HStack(alignment: .top, spacing: 10) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L(generator.status)).font(.callout)
                                    .accessibilityLabel(copy("영상 생성 진행 상황", "Video generation progress"))
                                Text(copy("창을 닫아도 작업은 계속됩니다.", "Work continues if you close this window."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(copy("중지", "Stop")) { generator.cancel() }
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    } else if !generator.status.isEmpty && generator.outputURL == nil {
                        Text(L(generator.status)).font(.caption).foregroundStyle(.secondary)
                    }

                    if let error = generator.error {
                        Label(L(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !generator.previewURLs.isEmpty { previews }
                    if let output = generator.outputURL { result(output) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(providerUsage)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    promptFocused = false
                    generator.generate()
                } label: {
                    Label(copy("설명으로 미리보기 만들기", "Create Previews from Description"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(generator.busy || !generator.isReadyForGeneration || generator.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(copy("⌘Return으로 미리보기 4장 생성", "Generate four sample frames with ⌘Return"))
            }
            .padding(16)
        }
        .frame(width: 680, height: 720)
        .task { await refreshConnection() }
        .onChange(of: generator.provider) { _, _ in
            pendingAPIKey = ""
            Task { await refreshConnection() }
        }
        .onChange(of: generator.access) { _, _ in
            pendingAPIKey = ""
            Task { await refreshConnection() }
        }
        .onDisappear { pendingAPIKey = "" }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(copy("영상 제작 AI", "Video Creation AI"), selection: $generator.provider) {
                Text("Claude").tag(VideoGenerationProvider.claude)
                Text("GPT").tag(VideoGenerationProvider.openAI)
                Text("Gemini").tag(VideoGenerationProvider.gemini)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(copy("영상 제작 AI 선택", "Choose video creation AI"))
            .disabled(generator.busy)

            Text(copy("영상 제작 품질을 우선한다면 현재 Claude Opus 5.5를 가장 권장합니다.",
                      "For the best video creation quality in EasyCut, we currently recommend Claude Opus 5.5."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if generator.provider == .gemini {
                Text(copy("Gemini는 API 키로 연결합니다. 구독 계정 로그인은 현재 지원하지 않습니다.",
                          "Gemini connects with an API key. Subscription sign-in is not currently supported."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(copy("연결 방식", "Connection Method"), selection: $generator.access) {
                    Text(copy("구독 로그인", "Subscription Sign-in")).tag(VideoGenerationAccess.subscription)
                    Text(copy("API 키", "API Key")).tag(VideoGenerationAccess.api)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(copy("영상 AI 연결 방식", "Video AI connection method"))
                .disabled(generator.busy || generator.subscriptionChecking)
            }

            if generator.access == .subscription && generator.provider != .gemini {
                subscriptionAccount
            } else {
                apiAccount
            }
        }
    }

    private func refreshConnection() async {
        generator.refreshAPIKeyStatus()
        if generator.access == .subscription { await generator.refreshSubscriptionStatus() }
    }

    private var providerName: String {
        switch generator.provider {
        case .claude: return "Claude"
        case .openAI: return "GPT"
        case .gemini: return "Gemini"
        }
    }

    private var transmissionName: String {
        if generator.access == .api { return "\(providerName) API" }
        return generator.provider == .claude
            ? copy("Claude(구독)", "Claude (subscription)")
            : copy("ChatGPT(구독)", "ChatGPT (subscription)")
    }

    private var providerUsage: String {
        if generator.access == .subscription {
            return generator.provider == .claude
                ? copy("Claude Opus 5.5 · 구독 사용 한도 적용", "Claude Opus 5.5 · Subscription limits apply")
                : copy("ChatGPT · 구독 사용 한도 적용", "ChatGPT · Subscription limits apply")
        }
        return copy("\(providerName) API · 모델별 API 요금 발생", "\(providerName) API · Model-specific API charges apply")
    }

    private var subscriptionState: AgentLink.State {
        generator.provider == .claude ? link.claude : link.codex
    }

    private var subscriptionAccount: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if generator.subscriptionReady {
                    Label(copy("\(providerName) 구독 연결됨", "\(providerName) subscription connected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if generator.subscriptionChecking || subscriptionState.isWorking {
                    ProgressView().controlSize(.small)
                    if case .working(let message) = subscriptionState {
                        Text(L(message))
                    } else {
                        Text(copy("구독 계정을 확인하는 중…", "Checking your subscription account…"))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy("본인 구독 계정으로 로그인하세요", "Sign in with your own subscription account"))
                        if case .failed(let message) = subscriptionState {
                            Text(L(message)).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
                Spacer()
                if !generator.subscriptionReady {
                    Button(generator.provider == .claude
                           ? copy("Claude로 로그인", "Sign in to Claude")
                           : copy("ChatGPT로 로그인", "Sign in to ChatGPT")) {
                        Task { await generator.connectSubscription() }
                    }
                    .disabled(generator.subscriptionChecking || subscriptionState.isWorking || generator.busy)
                }
            }
            Text(copy("본인 구독 계정의 사용 한도가 적용됩니다. 필요한 연결 도구는 앱에서 준비합니다.",
                      "Your subscription account's usage limits apply. The app prepares the connection tools it needs."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var apiKeyGuideURL: URL {
        switch generator.provider {
        case .claude: return URL(string: "https://platform.claude.com/docs/en/api/overview")!
        case .openAI: return URL(string: "https://developers.openai.com/api/docs/quickstart")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/api-key")!
        }
    }

    private var apiAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(copy("\(providerName) API 키 입력", "Enter \(providerName) API key"), text: $pendingAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(copy("\(providerName) API 키", "\(providerName) API key"))
                Button(copy("키 저장", "Save Key")) {
                    defer { pendingAPIKey = "" }
                    _ = generator.saveAPIKey(pendingAPIKey)
                }
                .disabled(pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(generator.busy)

            HStack(alignment: .firstTextBaseline) {
                Text(copy("본인 계정의 키를 입력하세요. 이 Mac의 키체인에 저장합니다.",
                          "Use your own account's key. It is saved in this Mac's Keychain."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Link(copy("API 키 발급 안내", "Get an API Key"), destination: apiKeyGuideURL)
                    .font(.caption)
            }

            if generator.hasAPIKey {
                Label(copy("API 키가 저장되어 있습니다", "API key is saved"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text(copy("API 키를 저장하면 이 공급자로 영상을 만들 수 있습니다.",
                          "Save an API key to create videos with this provider."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = generator.apiKeyError {
                Text(L(error))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(copy("모델", "Model")).font(.caption)
                TextField(copy("사용할 모델 이름", "Model name"), text: $generator.apiModel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(copy("\(providerName) 모델 이름", "\(providerName) model name"))
            }
            .disabled(generator.busy)
            Text(copy("구독 요금과 별도로 선택한 모델의 API 사용 요금이 발생합니다.",
                      "The selected model's API usage is billed separately from subscriptions."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var request: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy("어떤 영상을 만들까요?", "What would you like to make?"))
                .font(.headline)
            Text(copy("주제와 이야기, 원하는 스타일·색상·움직임·글자·소리를 자유롭게 적어 주세요. 특정 스타일을 고를 필요는 없습니다.", "Describe your subject and story, style, colors, movement, text and sound. You do not need to choose a preset style."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $generator.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120, maxHeight: 170)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .focused($promptFocused)
                .accessibilityLabel(copy("만들 영상의 내용과 스타일", "Video content and style"))
                .disabled(generator.busy)

            Text(copy("어떻게 적을지 막막하면 예시에서 시작해 바꿔 보세요", "Start with an example and make it your own"))
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                example("교육 설명", "Educational Explainer",
                        "물의 순환을 초등학생이 이해하기 쉬운 설명 애니메이션으로 만들어줘. 종이 오려 붙이기 스타일로 바다에서 증발한 물이 구름이 되고 비가 내려 강으로 돌아오는 과정을 보여줘. 핵심 단어만 한국어로 넣어줘.",
                        "Explain the water cycle for elementary students in a paper-cutout animation. Show evaporation from the sea, clouds, rain and water returning to the sea through a river. Include only the key labels.")
                example("제품 홍보", "Product Promo",
                        "새로운 텀블러를 소개하는 홍보 영상. 밝고 미니멀한 배경에서 텀블러가 회전하고 '가볍게 들고, 오래 따뜻하게'라는 문구가 나타나게 해줘. 제품의 색은 민트, 분위기는 산뜻하게 해줘.",
                        "Promote a new mint-colored tumbler. Let it rotate on a bright minimal background, then reveal 'Carry light. Stay warm.' Keep the mood fresh and clean.")
                example("데이터 이야기", "Data Story",
                        "작은 습관이 쌓여 큰 변화가 되는 과정을 막대그래프와 도형으로 보여줘. 남색 배경에 흰색과 주황색을 쓰고, 막대가 하나씩 자란 뒤 하나의 큰 상승 곡선으로 연결되게 해줘. 수치는 예시임을 표시해줘.",
                        "Tell a story about small habits creating big changes with bars and shapes. Use white and orange on navy. Grow the bars one by one, then connect them into a rising curve. Clearly label any numbers as illustrative.")
                example("손그림 이야기", "Hand-drawn Story",
                        "작은 씨앗이 싹을 틔우고 나무로 자라는 따뜻한 손그림 애니메이션. 크레용 질감과 부드러운 파스텔 색상을 쓰고, 마지막에 새 한 마리가 가지에 앉게 해줘. 글자 없이 잔잔한 분위기로 만들어줘.",
                        "Make a warm hand-drawn animation of a seed sprouting and growing into a tree. Use crayon textures and soft pastel colors. End with a bird landing on a branch. Keep it gentle with no text.")
            }
            .disabled(generator.busy)
        }
    }

    private func example(_ koreanTitle: String, _ englishTitle: String, _ koreanPrompt: String, _ englishPrompt: String) -> some View {
        Button(copy(koreanTitle, englishTitle)) { generator.prompt = copy(koreanPrompt, englishPrompt) }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help(copy("설명만 채우며 화면·길이·제작 방식 설정은 유지합니다", "Fills the description and keeps your screen, duration and rendering settings"))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Picker(copy("화면", "Canvas"), selection: canvasBinding) {
                    Text(copy("가로 16:9 · 720p", "Landscape 16:9 · 720p")).tag("1280x720")
                    Text(copy("세로 9:16 · 720p", "Portrait 9:16 · 720p")).tag("720x1280")
                    Text(copy("정사각형 · 1080p", "Square · 1080p")).tag("1080x1080")
                    Text(copy("가로 16:9 · 1080p", "Landscape 16:9 · 1080p")).tag("1920x1080")
                }
                Stepper(value: $generator.duration, in: 2...60, step: 1) {
                    Text(copy("길이 \(Int(generator.duration))초", "Length \(Int(generator.duration))s"))
                        .monospacedDigit()
                }
                .fixedSize()
                Picker("fps", selection: $generator.fps) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .frame(width: 86)
                .accessibilityLabel(copy("초당 프레임", "Frames per second"))
            }
        }
        .disabled(generator.busy)
    }

    private var canvasBinding: Binding<String> {
        Binding(get: { "\(generator.width)x\(generator.height)" }, set: { value in
            let dimensions = value.split(separator: "x").compactMap { Int($0) }
            guard dimensions.count == 2 else { return }
            generator.width = dimensions[0]
            generator.height = dimensions[1]
        })
    }

    private var skills: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(copy("제작 스킬 자동 적용", "Automatically Apply Production Skills"), isOn: $generator.automaticSkills)
                .font(.callout.weight(.semibold))
                .accessibilityLabel(copy("제작 스킬 자동 적용", "Automatically apply production skills"))
                .disabled(generator.busy)
            Text(copy("설명에 맞는 제작 지침을 골라 적용합니다. 적어 주신 스타일과 내용이 우선합니다.",
                      "Selects production guidance to suit your description. Your requested style and content come first."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(copy("사용할 수 있는 스킬", "Available Skills"), isExpanded: $showSkills) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(VideoGenerationSkills.catalog) { skill in
                        skillDetails(skill)
                    }
                    if let notices = Bundle.main.url(forResource: "VideoSkillNotices", withExtension: "txt") {
                        Button(copy("출처와 사용 조건", "Sources and Licenses")) { NSWorkspace.shared.open(notices) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 10)
            }
            .font(.caption)
        }
    }

    private func skillDetails(_ skill: VideoGenerationSkill) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(copy(skill.title, skill.englishTitle)).font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Link(copy("원본 보기", "View Source"), destination: skill.sourceURL)
                    .font(.caption)
                    .accessibilityLabel(copy("\(skill.title) 원본 보기", "View source for \(skill.englishTitle)"))
                    .help("\(skill.upstreamName) · \(skill.licenseName) · \(skill.revision)")
            }
            Text(copy(skill.summary, skill.englishSummary))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appliedSkills: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(copy("적용한 제작 스킬", "Applied Production Skills"), systemImage: "sparkles")
                .font(.callout.weight(.semibold))
            if !generator.appliedSkillReason.isEmpty {
                Text(generator.appliedSkillReason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(generator.appliedSkills) { skill in
                skillDetails(skill)
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var runtime: some View {
        DisclosureGroup(copy("고급 설정", "Advanced Settings"), isExpanded: $showRuntime) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(copy("제작 방식", "Rendering Method"), selection: $generator.renderer) {
                    Text(copy("Canvas · 자유 애니메이션", "Canvas · Animation")).tag(VideoGenerator.Renderer.canvas)
                    Text(copy("Remotion · 모션그래픽", "Remotion · Motion Graphics")).tag(VideoGenerator.Renderer.remotion)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(copy("영상 제작 방식", "Video rendering method"))
                Text(generator.renderer == .canvas
                     ? copy("장면과 배경음악·효과음을 함께 만들 수 있습니다. 원하는 소리를 설명하거나 무음을 요청하세요.", "Creates animated scenes with optional synthesized music and sound effects. Describe the sound you want or request silence.")
                     : copy("React 기반 모션그래픽을 만듭니다. 기본 생성물은 무음이며, 완성 후 타임라인에서 소리를 더할 수 있습니다.", "Creates React-based motion graphics. Generated videos are silent by default; you can add audio on the timeline."))
                    .font(.caption).foregroundStyle(.secondary)
                if generator.renderer == .remotion {
                    Text(copy("기존 Remotion 프로젝트 폴더 (선택)", "Existing Remotion project folder (optional)"))
                        .font(.caption.weight(.semibold))
                    HStack {
                        TextField(copy("비워 두면 자동 준비", "Leave empty for automatic setup"), text: $generator.remotionProject)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(copy("Remotion 프로젝트 경로", "Remotion project path"))
                        Button(copy("폴더 선택…", "Choose Folder…")) { chooseRuntime() }
                    }
                    Text(copy(
                        "처음 한 번 Remotion 도구를 준비합니다. Node.js가 필요합니다. 이미 설치했다면 node_modules가 있는 프로젝트를 선택할 수 있습니다.",
                        "Remotion tools are prepared on first use. Node.js is required. You can optionally select an existing project containing node_modules."
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(copy(
                        "Node.js·npm과 Google Chrome이 필요합니다. Canvas 도구는 처음 한 번 자동으로 준비하며, 생성한 장면은 별도 작업 폴더에 저장합니다.",
                        "Node.js, npm and Google Chrome are required. Canvas tools are prepared on first use, and generated scenes are saved in a separate job folder."
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
            .disabled(generator.busy)
        }
    }

    private var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(copy("전체 렌더링 전 확인", "Review Before Full Render"), systemImage: "photo.on.rectangle.angled")
                .font(.headline)
            Text(copy("구도·색상·글자·장면 변화를 확인하세요. 이미지를 누르면 크게 볼 수 있습니다.",
                      "Check the composition, colors, text and scene changes. Click a frame to view it at full size."))
                .font(.caption).foregroundStyle(.secondary)

            if !generator.appliedSkills.isEmpty { appliedSkills }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(generator.previewURLs.enumerated()), id: \.offset) { index, url in
                    VStack(alignment: .leading, spacing: 5) {
                        if let image = NSImage(contentsOf: url) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: 250)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(copy("미리보기 \(index + 1) 크게 보기", "Open sample frame \(index + 1)"))
                        } else {
                            Label(copy("미리보기를 열 수 없습니다", "Unable to open sample frame"), systemImage: "photo")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).help(url.lastPathComponent)
                    }
                }
            }

            Text(copy("전체 렌더링에는 이 미리보기를 만든 코드와 설정을 사용합니다. 설명이나 설정을 바꾸면 미리보기를 다시 생성하세요.",
                      "Full rendering uses the code and settings that produced these frames. Generate new previews after changing the description or settings."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let job = generator.jobURL {
                    Button(copy("생성 코드 보기", "Show Generated Code")) { NSWorkspace.shared.open(job) }
                }
                Spacer()
                Button { generator.render() } label: {
                    Label(copy("확인하고 전체 렌더링", "Approve & Render Full Video"), systemImage: "film.stack")
                }
                .buttonStyle(.borderedProminent)
                .disabled(generator.busy || generator.previewURLs.count != 4 || generator.outputURL != nil)
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func result(_ output: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(copy("영상이 준비됐습니다", "Your video is ready"), systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            if !generator.status.isEmpty { Text(L(generator.status)).font(.caption).foregroundStyle(.secondary) }
            Text(output.lastPathComponent).font(.caption).textSelection(.enabled)
            HStack(spacing: 8) {
                Button(copy("재생", "Play")) { NSWorkspace.shared.open(output) }
                Button(copy("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                if let job = generator.jobURL {
                    Button(copy("생성 코드 보기", "Show Generated Code")) { NSWorkspace.shared.open(job) }
                }
                Spacer()
                Button(copy("타임라인에 추가", "Add to Timeline")) {
                    addingToTimeline = true
                    Task {
                        await generator.addToTimeline(store: store)
                        addingToTimeline = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(generator.busy || addingToTimeline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chooseRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = copy("Remotion의 node_modules가 있는 프로젝트 폴더를 선택하세요.", "Choose a Remotion project folder containing node_modules.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        generator.remotionProject = url.path
    }
}
