import SwiftUI
import AppKit

/// 말로 편집하는 AI 대화 패널
struct AIPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var ai: AIAssistant
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
                        if ai.backend == .plan {
                            Button { ai.modelID = "" } label: { check(ai.modelID.isEmpty, "계정 기본값") }
                        }
                        ForEach(AIModel.all) { m in
                            Button { ai.modelID = m.id } label: { check(ai.modelID == m.id || (ai.backend == .api && ai.modelID.isEmpty && m.id == "claude-opus-5"), "\(m.name) — \(m.note)") }
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
                .help("Claude 모델과 추론 강도 선택 (\(ai.backend == .plan ? "플랜 로그인" : "API 키"))")
                Menu {
                    Picker("연결 방식", selection: $ai.backend) {
                        ForEach(AIBackend.allCases) { Text(L($0.rawValue)).tag($0) }
                    }
                    Divider()
                    Button("API 키 설정…") { showKey = true }
                    Button("Claude 연결 도우미…") { showConnect = true }
                    Divider()
                    Button("대화 지우기") { ai.reset() }
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            Divider()

            if ai.backend == .plan && !ai.ready {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Claude 플랜으로 쓰려면 Claude Code가 필요합니다.").font(.callout.weight(.semibold))
                    Text("Claude Code를 설치하고 터미널에서 claude 실행 → /login 으로 Pro/Max 계정에 로그인하면, API 키 없이 구독 플랜으로 AI 편집을 쓸 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Claude 연결 도우미 열기") { showConnect = true }.buttonStyle(.borderedProminent)
                    Button("API 키 방식으로 바꾸기") { ai.backend = .api }.controlSize(.small)
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
                    Text("또는 Claude Code/데스크톱에서 이 앱을 직접 조작할 수도 있습니다.").font(.caption).foregroundStyle(.secondary)
                    Button("Claude에 연결하는 방법 보기") { showConnect = true }.controlSize(.small)
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
                    HStack {
                        Image(systemName: "person.badge.key.fill").foregroundStyle(.orange)
                        Text("터미널에서  claude  →  /login").font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("로그인하기") { showConnect = true }
                            .controlSize(.small)
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
        .sheet(isPresented: $showConnect) { ConnectSheet() }
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

/// Claude 연결 도우미: 설치·로그인·Claude Code/데스크톱 연결을 버튼으로
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var codeInstalled = AIAssistant.claudeBinary != nil
    @State private var loggedIn: Bool?
    @State private var checking = false
    @State private var codeLinked = ClaudeLink.codeConnected
    @State private var desktopLinked = ClaudeLink.desktopConnected
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple).font(.title2)
                Text("Claude 연결").font(.title2.bold())
            }
            Text("Claude Pro/Max 구독이 있으면 API 키 없이 AI 편집을 쓸 수 있습니다. 아래 순서대로 한 번만 설정하세요.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Claude Code 설치", done: codeInstalled) {
                        Button(L(codeInstalled ? "다시 설치" : "설치하기")) {
                            Tools.runInTerminal("""
                            echo "Claude Code를 설치합니다 (공식 설치 스크립트: claude.ai/install.sh)"
                            curl -fsSL https://claude.ai/install.sh | bash
                            echo ""
                            echo "설치가 끝났습니다. 이 창을 닫고 EasyCut에서 [2. 로그인]을 누르세요."
                            """, name: "Claude Code 설치")
                        }
                        Button("확인") { codeInstalled = AIAssistant.claudeBinary != nil }
                    }
                    step(2, "Claude 계정 로그인 (Pro/Max)", done: loggedIn == true) {
                        Button("로그인 창 열기") {
                            let bin = AIAssistant.claudeBinary ?? "claude"
                            Tools.runInTerminal("""
                            echo "잠시 후 Claude Code가 열리면  /login  을 입력하고 Enter → 'Claude 계정'을 고르세요."
                            echo "브라우저에서 로그인을 마친 뒤, 이 창은 닫아도 됩니다."
                            echo ""
                            "\(bin)"
                            """, name: "Claude 로그인")
                        }
                        .disabled(!codeInstalled)
                        Button(L(checking ? "확인 중…" : "로그인 확인")) {
                            checking = true
                            Task { loggedIn = await ClaudeLink.checkLogin(); checking = false }
                        }
                        .disabled(!codeInstalled || checking)
                    }
                    if loggedIn == false {
                        Text("아직 로그인되지 않았습니다. [로그인 창 열기]로 로그인해 주세요.").font(.caption).foregroundStyle(.orange)
                    } else if loggedIn == true {
                        Text("연결 완료! 이제 AI 탭에서 말로 편집할 수 있습니다.").font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(6)
            } label: { Text("앱 안에서 AI 편집 (AI 탭)").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    step(nil, "Claude 데스크톱 앱에서 EasyCut 조작", done: desktopLinked) {
                        Button(L(desktopLinked ? "다시 연결" : "연결하기")) {
                            do {
                                try ClaudeLink.connectDesktop()
                                desktopLinked = ClaudeLink.desktopConnected
                                message = "Claude 데스크톱을 완전히 종료(⌘Q) 후 다시 열면 EasyCut 도구가 보입니다."
                            } catch { message = error.localizedDescription }
                        }
                    }
                    step(nil, "Claude Code(터미널)에서 EasyCut 조작", done: codeLinked) {
                        Button(L(codeLinked ? "다시 연결" : "연결하기")) {
                            Task {
                                do { try await ClaudeLink.connectCode(); codeLinked = ClaudeLink.codeConnected; message = "Claude Code에 연결했습니다. 새 대화에서 EasyCut 도구를 쓸 수 있습니다." }
                                catch { message = error.localizedDescription }
                            }
                        }
                        .disabled(!codeInstalled)
                    }
                    Text("EasyCut을 켜 둔 상태에서 Claude에게 \"EasyCut에서 무음 잘라줘\"처럼 말하면 됩니다. 연결은 이 Mac 안에서만 이뤄집니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Text("Claude 앱에서 EasyCut 조작 (선택)").font(.headline) }

            if !message.isEmpty { Text(L(message)).font(.callout).foregroundStyle(.blue) }
            HStack {
                Text("API 키로 쓰려면 AI 탭 ⚙︎ › 연결 방식 › API 키").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    @ViewBuilder
    func step<B: View>(_ n: Int?, _ title: String, done: Bool, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : (n.map { "\($0).circle" } ?? "circle"))
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            Text(L(title))
            Spacer()
            buttons().controlSize(.small)
        }
    }
}
