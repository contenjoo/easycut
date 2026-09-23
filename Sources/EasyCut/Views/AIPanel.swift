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
                Text(ai.backend == .plan ? "Claude 플랜" : "Claude API").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("연결 방식", selection: $ai.backend) {
                        ForEach(AIBackend.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button("API 키 설정…") { showKey = true }
                    Button("Claude Code / 데스크톱에 연결…") { showConnect = true }
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
                    Button("Claude Code 설치 안내 열기") { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
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
                                            Text(ex).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
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
                                    Text(ai.status).font(.caption).foregroundStyle(.secondary)
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
                        Button("터미널 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
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
            Label(item.text, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.purple)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
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
            Text(ai.hasKey ? "키가 저장되어 있습니다. 새 키를 넣으면 바뀝니다." : "키를 붙여 넣으세요.").foregroundStyle(.secondary)
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

struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    var appBinary: String {
        Bundle.main.executableURL?.path ?? "/Applications/EasyCut.app/Contents/MacOS/EasyCut"
    }

    var claudeCodeCommand: String { "claude mcp add easycut -- \"\(appBinary)\" --mcp" }

    var desktopJSON: String {
        """
        "easycut": {
          "command": "\(appBinary)",
          "args": ["--mcp"]
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude에서 EasyCut 조작하기").font(.title2.bold())
            Text("EasyCut을 켜 둔 상태에서 Claude Code나 Claude 데스크톱이 편집 도구(무음 제거, 말 삭제, 속도, 자막…)를 직접 쓸 수 있습니다. 연결은 이 Mac 안(127.0.0.1)에서만 이뤄집니다.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Claude Code — 터미널에서 한 번 실행") {
                copyRow(claudeCodeCommand)
            }
            GroupBox("Claude 데스크톱 — 설정 › 개발자 › 구성 편집의 mcpServers 안에 추가") {
                copyRow(desktopJSON)
            }
            Text("예) \"EasyCut에서 무음 다 자르고 자막 만들어줘\"").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 600)
    }

    func copyRow(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(4)
    }
}
