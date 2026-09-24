import SwiftUI
import AppKit

/// 말로 편집하는 AI 대화 패널
struct AIPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var ai: AIAssistant
    @ObservedObject private var link = AgentLink.shared
    @State private var input = ""
    @State private var keyInput = ""
    @State private var showKey = false
    @State private var showConnect = false
    @FocusState private var focused: Bool

    static let examples = [
        "말 없는 부분 다 잘라줘",
        "'음', '어' 같은 말 빼고 자막 만들어줘",
        "처음 10초 잘라내고 나머지는 1.5배속",
        "자막을 노란색 글자, 외곽선으로 크게",
        "'감사합니다'라고 말한 부분 찾아서 삭제",
        "5초에 '오늘의 주제' 제목 넣어줘",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AI 편집").font(.headline)
                Spacer()
                Menu {
                    Section("모델") {
                        if ai.backend == .codex {
                            check(true, "ChatGPT 기본 모델")
                        } else {
                            if ai.backend == .plan {
                                Button { ai.modelID = "" } label: { check(ai.modelID.isEmpty, "계정 기본값") }
                            }
                            ForEach(AIModel.all) { m in
                                Button { ai.modelID = m.id } label: { check(ai.modelID == m.id || (ai.backend == .api && ai.modelID.isEmpty && m.id == "claude-opus-5"), "\(m.name) — \(m.note)") }
                            }
                        }
                    }
                    Section("추론 강도") {
                        ForEach(AIEffort.allCases) { e in
                            Button { ai.effort = e } label: { check(ai.effort == e, e.label) }
                        }
                    }
                    Divider()
                    Toggle("생각 과정 보기", isOn: $ai.showThinking)
                } label: {
                    Text(L(ai.currentModelName) + (ai.effort == .auto ? "" : " · " + (L(ai.effort.label).components(separatedBy: " ").first ?? "")))
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("모델과 추론 강도 선택") + " (" + L(ai.backend.rawValue) + ")")
                Menu {
                    Picker("연결 방식", selection: $ai.backend) {
                        ForEach(AIBackend.allCases) { Text(L($0.rawValue)).tag($0) }
                    }
                    Divider()
                    Button("계정 연결 관리…") { showConnect = true }
                    Button("Claude API 키 설정…") { showKey = true }
                    Divider()
                    Button("대화 지우기") { ai.reset() }
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            Divider()

            if ai.backend != .api && !ai.ready {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AI로 편집하려면 계정을 연결하세요").font(.callout.weight(.semibold))
                    Text("쓰고 있는 구독 계정으로 로그인하면 API 키 없이 바로 쓸 수 있습니다. 필요한 프로그램은 자동으로 설치됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    AgentLoginButtons(ai: ai)
                    Divider()
                    Button("Claude API 키로 쓰기") { ai.backend = .api }.controlSize(.small)
                    Spacer()
                }
                .padding(12)
            } else if ai.backend == .api && !ai.hasKey {
                VStack(alignment: .leading, spacing: 10) {
                    Text("말로 편집하려면 Claude API 키가 필요합니다.").font(.callout.weight(.semibold))
                    Text("console.anthropic.com 에서 키를 만든 뒤 아래에 붙여 넣으세요. 키는 이 Mac의 키체인에만 저장됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-ant-…", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("저장") { ai.setKey(keyInput); keyInput = "" }
                            .buttonStyle(.borderedProminent)
                            .disabled(keyInput.count < 20)
                        Button("키 발급 페이지 열기") { NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!) }
                    }
                    Divider()
                    Text("또는 구독 계정으로 로그인해서 쓸 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    AgentLoginButtons(ai: ai)
                    Spacer()
                }
                .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if ai.items.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("이렇게 말해 보세요").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(Self.examples, id: \.self) { ex in
                                        Button { ai.send(ex) } label: {
                                            Text(L(ex)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            ForEach(ai.items) { item in
                                bubble(item).id(item.id)
                            }
                            if ai.busy {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L(ai.status)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("중지") { ai.cancel() }.controlSize(.small)
                                }
                                .id("busy")
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: ai.items.count) { _, _ in
                        withAnimation { proxy.scrollTo(ai.items.last?.id, anchor: .bottom) }
                    }
                }
                if ai.needsLogin {
                    let provider: AgentLink.Provider = ai.backend == .codex ? .codex : .claude
                    HStack {
                        Image(systemName: "person.badge.key.fill").foregroundStyle(.orange)
                        if case .working(let msg) = link.state(provider) {
                            ProgressView().controlSize(.small)
                            Text(L(msg)).font(.caption)
                        } else {
                            Text(L(provider == .codex ? "ChatGPT 로그인이 필요합니다" : "Claude 로그인이 필요합니다")).font(.caption)
                        }
                        Spacer()
                        Button("로그인") {
                            Task { if await link.connect(provider) { ai.needsLogin = false } }
                        }
                        .controlSize(.small)
                        .disabled(link.state(provider).isWorking)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                }
                Divider()
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("무엇을 편집할까요? (Enter로 보내기)", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($focused)
                        .onSubmit(submit)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || ai.busy)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                .padding(8)
                Text("모든 AI 편집은 ⌘Z로 되돌릴 수 있습니다").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showKey) { KeySheet(ai: ai) }
        .sheet(isPresented: $showConnect) { ConnectSheet(ai: ai) }
        .task { if link.claude == .unknown || link.codex == .unknown { await link.refresh() } }
    }

    @ViewBuilder
    func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(L(title), systemImage: "checkmark") } else { Text(L(title)) }
    }

    func submit() {
        let t = input
        input = ""
        ai.send(t)
    }

    @ViewBuilder
    func bubble(_ item: ChatItem) -> some View {
        switch item.role {
        case .user:
            HStack { Spacer(minLength: 30); Text(item.text).padding(8).background(Theme.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white).textSelection(.enabled) }
        case .assistant:
            Text(item.text).padding(8).background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10)).textSelection(.enabled)
        case .tool:
            Label(L(item.text), systemImage: "wand.and.stars").font(.caption).foregroundStyle(.purple)
        case .error:
            Label(L(item.text), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .thinking:
            DisclosureGroup {
                Text(L(item.text)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("생각 과정", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct KeySheet: View {
    @ObservedObject var ai: AIAssistant
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude API 키").font(.title2.bold())
            Text(L(ai.hasKey ? "키가 저장되어 있습니다. 새 키를 넣으면 바뀝니다." : "키를 붙여 넣으세요.")).foregroundStyle(.secondary)
            SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                if ai.hasKey { Button("키 삭제", role: .destructive) { ai.setKey(""); dismiss() } }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") { ai.setKey(key); dismiss() }.keyboardShortcut(.defaultAction).disabled(key.count < 20)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

/// 원클릭 로그인 버튼: 설치 → 브라우저 로그인 → 연결 방식 전환까지 한 번에
struct AgentLoginButtons: View {
    @ObservedObject var ai: AIAssistant
    @ObservedObject private var link = AgentLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(.claude, .plan, "Claude로 로그인", "Pro/Max 구독", "sparkles", .purple)
            row(.codex, .codex, "ChatGPT로 로그인", "Plus/Pro 구독 · Codex", "bubble.left.and.bubble.right.fill", .green)
        }
    }

    @ViewBuilder
    func row(_ p: AgentLink.Provider, _ backend: AIBackend, _ title: String, _ note: String, _ icon: String, _ tint: Color) -> some View {
        let st = link.state(p)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { if await link.connect(p) { ai.backend = backend; ai.needsLogin = false } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(title)).font(.callout.weight(.semibold))
                        Text(L(note)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if st.isWorking { ProgressView().controlSize(.small) }
                    else if st.isReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(st.isWorking)
            switch st {
            case .working(let msg):
                HStack {
                    Text(L(msg)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if msg.contains("브라우저") {
                        if let u = link.loginURL { Button("브라우저 다시 열기") { NSWorkspace.shared.open(u) }.controlSize(.mini) }
                        Button("취소") { link.cancelLogin() }.controlSize(.mini)
                    }
                }
            case .failed(let msg):
                Text(L(msg)).font(.caption).foregroundStyle(.orange).lineLimit(4)
            default:
                EmptyView()
            }
        }
    }
}

/// 계정 연결 관리: 앱 안 AI 로그인 + 다른 AI 앱에서 EasyCut 조작
struct ConnectSheet: View {
    @ObservedObject var ai: AIAssistant
    @ObservedObject private var link = AgentLink.shared
    @Environment(\.dismiss) private var dismiss
    @State private var codeLinked = ClaudeLink.codeConnected
    @State private var desktopLinked = ClaudeLink.desktopConnected
    @State private var codexLinked = ClaudeLink.codexConnected
    @State private var openAIKey = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple).font(.title2)
                Text("AI 계정 연결").font(.title2.bold())
            }
            Text("버튼 하나로 로그인하면 끝입니다. 필요한 프로그램 설치와 연결은 앱이 알아서 합니다.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    AgentLoginButtons(ai: ai)
                    DisclosureGroup("OpenAI API 키로 로그인 (구독 대신)") {
                        HStack {
                            SecureField("sk-…", text: $openAIKey).textFieldStyle(.roundedBorder)
                            Button("로그인") {
                                let k = openAIKey
                                openAIKey = ""
                                Task { if await link.connectCodexWithKey(k) { ai.backend = .codex } }
                            }
                            .disabled(openAIKey.count < 20 || link.codex.isWorking)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                    HStack {
                        Text("지금 쓰는 연결:").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $ai.backend) {
                            ForEach(AIBackend.allCases) { Text(L($0.rawValue)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .padding(6)
            } label: { Text("앱 안에서 AI 편집 (AI 탭)").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    step("Claude 데스크톱 앱", done: desktopLinked) {
                        Button(L(desktopLinked ? "다시 연결" : "연결하기")) {
                            do {
                                try ClaudeLink.connectDesktop()
                                desktopLinked = ClaudeLink.desktopConnected
                                message = "Claude 데스크톱을 완전히 종료(⌘Q) 후 다시 열면 EasyCut 도구가 보입니다."
                            } catch { message = error.localizedDescription }
                        }
                    }
                    step("Claude Code (터미널)", done: codeLinked) {
                        Button(L(codeLinked ? "다시 연결" : "연결하기")) {
                            Task {
                                do { try await ClaudeLink.connectCode(); codeLinked = ClaudeLink.codeConnected; message = "Claude Code에 연결했습니다. 새 대화에서 EasyCut 도구를 쓸 수 있습니다." }
                                catch { message = error.localizedDescription }
                            }
                        }
                        .disabled(AgentLink.claudeBinary == nil)
                    }
                    step("Codex (터미널)", done: codexLinked) {
                        Button(L(codexLinked ? "다시 연결" : "연결하기")) {
                            Task {
                                do { try await ClaudeLink.connectCodex(); codexLinked = ClaudeLink.codexConnected; message = "Codex에 연결했습니다. 새 대화에서 EasyCut 도구를 쓸 수 있습니다." }
                                catch { message = error.localizedDescription }
                            }
                        }
                        .disabled(AgentLink.codexBinary == nil)
                    }
                    Text("EasyCut을 켜 둔 상태에서 \"EasyCut에서 무음 잘라줘\"처럼 말하면 됩니다. 연결은 이 Mac 안에서만 이뤄집니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Text("다른 AI 앱에서 EasyCut 조작 (선택)").font(.headline) }

            if !message.isEmpty { Text(L(message)).font(.callout).foregroundStyle(.blue) }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task { await link.refresh() }
    }

    @ViewBuilder
    func step<B: View>(_ title: String, done: Bool, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            Text(L(title))
            Spacer()
            buttons().controlSize(.small)
        }
    }
}
