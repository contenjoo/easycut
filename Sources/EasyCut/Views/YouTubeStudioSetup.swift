import SwiftUI
import UniformTypeIdentifiers

extension YouTubeEvent {
    var privacyLabel: String {
        switch privacy {
        case "private": return L("비공개")
        case "unlisted": return L("일부 공개")
        case "public": return L("공개")
        default: return L("공개 범위 확인 필요")
        }
    }

    var scheduleLabel: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct YouTubeChannelLabel: View {
    let title: String
    var body: some View {
        Label {
            Text(verbatim: "YouTube · " + title)
        } icon: {
            Image(systemName: "person.crop.circle")
        }
        .font(.subheadline).lineLimit(2)
        .accessibilityIdentifier("studio-youtube-channel")
    }
}

struct YouTubeStudioSetup: View {
    @ObservedObject var rec: RecordController
    @ObservedObject private var account = YouTubeAccount.shared
    @ObservedObject private var service = YouTubeLiveService.shared
    @State private var managing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if account.isConnected, let channel = service.channelTitle { YouTubeChannelLabel(title: channel) }
            if let event = rec.youtubeEvent, account.isConnected {
                Text(verbatim: event.title).fontWeight(.semibold).lineLimit(2)
                Text(verbatim: "\(event.privacyLabel) · \(event.scheduleLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !account.hasClient {
                Text("이 Mac에서 YouTube 계정을 연결하려면 데스크톱 앱용 OAuth 설정이 필요합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if account.isConnected {
                Text("방송할 예약을 선택하거나 새 방송을 만드세요.").font(.caption).foregroundStyle(.secondary)
            }
            Button(L(account.isConnected ? "방송 선택·예약…" : "YouTube 계정 설정…")) { managing = true }
                .accessibilityIdentifier("studio-youtube-manage")
        }
        .onChange(of: account.isConnected, initial: true) { _, connected in
            if !connected { rec.youtubeEvent = nil }
        }
        .task(id: account.isConnected) {
            if account.isConnected { try? await service.refreshChannelIdentity() }
        }
        .sheet(isPresented: $managing) { YouTubeBroadcastManager(rec: rec) }
    }
}

private struct YouTubeBroadcastManager: View {
    @ObservedObject var rec: RecordController
    @ObservedObject private var account = YouTubeAccount.shared
    @ObservedObject private var service = YouTubeLiveService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var loading = false
    @State private var events: [YouTubeEvent] = []
    @State private var error = ""
    @State private var title = ""
    @State private var later = false
    @State private var startDate = Date().addingTimeInterval(3600)
    @State private var privacy = "private"
    @State private var kids: Bool? = nil
    @State private var confirmCreate = false
    @State private var confirmDisconnect = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YouTube 방송").font(.title2.bold())
                Spacer()
                if account.isConnected {
                    Button("계정 연결 해제") { confirmDisconnect = true }
                        .controlSize(.small).disabled(loading)
                }
            }
            if account.isConnected {
                if let channel = service.channelTitle { YouTubeChannelLabel(title: channel) }
                Picker("방송 관리", selection: $creating) {
                    Text("예약된 방송").tag(false)
                    Text("새 방송").tag(true)
                }.labelsHidden().pickerStyle(.segmented).disabled(loading)
                if creating { creationForm } else { eventList }
            } else {
                connectionForm
            }
            if !error.isEmpty {
                Text(verbatim: error).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if loading || account.connecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(loading)
                if account.isConnected && creating {
                    Button(L(later ? "예약 만들기" : "방송 만들기")) {
                        if privacy == "private" { create() } else { confirmCreate = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || !validDraft)
                }
            }
        }
        .padding(20).frame(width: 495)
        .interactiveDismissDisabled(loading)
        .onAppear { if account.isConnected { refresh() } }
        .onChange(of: account.isConnected) { _, connected in
            if !connected { rec.youtubeEvent = nil; events = []; creating = false }
        }
        .alert("선택한 공개 범위로 YouTube 방송을 만들까요?", isPresented: $confirmCreate) {
            Button("취소", role: .cancel) {}
            Button(L(later ? "예약 만들기" : "방송 만들기")) { create() }
        } message: {
            Text(verbatim: "\(title.trimmingCharacters(in: .whitespacesAndNewlines)) · \(privacy == "public" ? L("공개") : L("일부 공개"))")
        }
        .confirmationDialog("이 Mac의 YouTube 계정 연결을 해제할까요?", isPresented: $confirmDisconnect) {
            Button("연결 해제", role: .destructive) {
                perform {
                    try await account.disconnect()
                    rec.youtubeEvent = nil
                    events = []
                }
            }
            Button("취소", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try account.importClient(at: url)
                error = ""
            } catch let problem as CocoaError where problem.code == .userCancelled {
                return
            } catch let problem { error = problem.localizedDescription }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !account.hasClient {
                Text("Google Cloud에서 YouTube Data API v3를 사용 설정하고 데스크톱 앱용 OAuth 클라이언트 JSON을 가져오세요.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Google Cloud 열기", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    Button("OAuth JSON 가져오기…") { importing = true }
                }
            } else {
                Text("방송할 YouTube 채널의 Google 계정으로 연결하세요.")
                Button("Google로 연결") {
                    perform {
                        try await account.connect()
                        try await loadEvents()
                    }
                }.buttonStyle(.borderedProminent).disabled(loading || account.connecting)
                if !account.connecting { Button("OAuth 설정 변경…") { importing = true }.controlSize(.small).disabled(loading) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("이 Mac의 EasyCut에서 만든 방송").font(.headline)
                Spacer()
                Button("새로고침") { refresh() }.controlSize(.small).disabled(loading)
            }
            if events.isEmpty {
                Text(verbatim: L(loading ? "방송 목록을 불러오는 중…" : "선택할 방송이 없습니다."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 112)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events, id: \.id) { event in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: event.title).lineLimit(2)
                                    Text(verbatim: "\(event.privacyLabel) · \(event.scheduleLabel)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("선택") { rec.youtubeEvent = event; dismiss() }
                                    .accessibilityLabel(Text(verbatim: "\(event.title) · \(L("선택"))"))
                            }.padding(.vertical, 7)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 228)
            }
        }.disabled(!account.isConnected || loading)
    }

    private var creationForm: some View {
        Form {
            TextField("방송 제목", text: $title)
            if !title.isEmpty && !validTitle {
                Text("100자 이하로 입력하고 <와 >는 빼 주세요.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("방송 시각", selection: $later) {
                Text("지금 준비").tag(false)
                Text("날짜 지정").tag(true)
            }.pickerStyle(.segmented)
            if later {
                DatePicker("시작 예정", selection: $startDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }
            Picker("공개 범위", selection: $privacy) {
                Text("비공개").tag("private")
                Text("일부 공개").tag("unlisted")
                Text("공개").tag("public")
            }
            Picker("아동용 콘텐츠", selection: $kids) {
                Text("선택하세요").tag(nil as Bool?)
                Text("예, 아동용입니다").tag(true as Bool?)
                Text("아니요, 아동용이 아닙니다").tag(false as Bool?)
            }
            Text(verbatim: L(later ? "예약은 YouTube에 저장됩니다. 방송 시각에 스튜디오에서 직접 라이브를 시작하세요." :
                    "방송을 만든 뒤 스튜디오에서 ‘녹화 및 라이브 시작’을 누르세요."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(loading)
    }

    private var validTitle: Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.utf16.count <= 100 && !clean.contains("<") && !clean.contains(">")
    }

    private var validDraft: Bool {
        validTitle && kids != nil && (!later || startDate > Date())
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !loading else { return }
        loading = true
        error = ""
        Task { @MainActor in
            defer { loading = false }
            do { try await operation() } catch let problem { error = problem.localizedDescription }
        }
    }

    private func loadEvents() async throws {
        let latest: [YouTubeEvent]
        do {
            latest = try await YouTubeLiveService.shared.upcoming()
        } catch {
            events = []
            rec.youtubeEvent = nil
            throw error
        }
        guard account.isConnected else { return }
        events = latest.sorted { $0.date < $1.date }
        if let selected = rec.youtubeEvent {
            rec.youtubeEvent = events.first { $0.id == selected.id }
        }
    }

    private func refresh() { perform { try await loadEvents() } }

    private func create() {
        guard validDraft, let kids else { return }
        perform {
            let event = try await YouTubeLiveService.shared.schedule(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                     date: later ? startDate : Date(),
                                                                     privacy: privacy, madeForKids: kids)
            rec.youtubeEvent = event
            dismiss()
        }
    }
}
