import Foundation
import CryptoKit
import Combine

struct YouTubeEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let privacy: String
    let date: Date
}

private struct LiveServiceError: LocalizedError {
    let errorDescription: String?
    let status: Int?
    init(_ message: String, status: Int? = nil) { self.errorDescription = message; self.status = status }
}

private final class YouTubeAPIRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class YouTubeLiveService: ObservableObject {
    @Published private(set) var channelTitle: String?
    static let shared = YouTubeLiveService(account: .shared)

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]
        let nextPageToken: String?
    }
    private struct Identifier: Decodable { let id: String }
    private struct Channel: Decodable {
        struct Snippet: Decodable { let title: String }
        let id: String
        let snippet: Snippet
    }
    private struct Broadcast: Decodable {
        struct Snippet: Decodable { let title, channelId, scheduledStartTime: String }
        struct Status: Decodable { let lifeCycleStatus, privacyStatus: String }
        struct Details: Decodable { let boundStreamId: String?; let enableAutoStart, enableAutoStop: Bool? }
        let id: String
        let snippet: Snippet
        let status: Status
        let contentDetails: Details

        func event() throws -> YouTubeEvent {
            let seconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            guard let date = (try? seconds.parse(snippet.scheduledStartTime)) ?? (try? fractional.parse(snippet.scheduledStartTime)) else {
                throw LiveServiceError("YouTube가 보낸 예약 시간을 읽을 수 없습니다.")
            }
            return YouTubeEvent(id: id, title: snippet.title, privacy: status.privacyStatus, date: date)
        }
    }
    private struct CreatedBroadcast: Decodable {
        let id: String
        let broadcast: Broadcast?
        init(from decoder: Decoder) throws {
            id = try Identifier(from: decoder).id
            broadcast = try? Broadcast(from: decoder)
        }
    }
    private struct Stream: Decodable {
        struct Snippet: Decodable { let channelId: String; let description: String? }
        struct Details: Decodable { let isReusable: Bool? }
        struct CDN: Decodable {
            struct Ingestion: Decodable { let rtmpsIngestionAddress, streamName: String? }
            let ingestionInfo: Ingestion?
        }
        let id: String
        let snippet: Snippet
        let contentDetails: Details
        let cdn: CDN?
    }
    private struct Context { let token, channel: String }

    private let account: YouTubeAccount
    private let defaults: UserDefaults
    private let session: URLSession
    private var connectionObserver: AnyCancellable?
    private var lastChannel: (tokenDigest: SHA256.Digest, id: String)?
    private var preparing = Set<String>()
    // Only IDs are retained while an uncertain bind is retried. Ingest credentials are never saved.
    private var pendingStreams: [String: String] = [:]
    private let registryKey = "YouTubeLiveService.createdBroadcastIDsByChannel"
    private let broadcastParts = "id,snippet,status,contentDetails"
    private let streamParts = "id,snippet,contentDetails,cdn"
    private let launchStates: Set<String> = ["created", "ready"]
    private let privacyValues: Set<String> = ["private", "unlisted", "public"]

    init(account: YouTubeAccount, configuration: URLSessionConfiguration = .ephemeral, defaults: UserDefaults = .standard) {
        self.account = account
        self.defaults = defaults
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: configuration, delegate: YouTubeAPIRedirects(), delegateQueue: nil)
        connectionObserver = account.$isConnected.removeDuplicates().sink { [weak self] connected in
            if !connected {
                self?.channelTitle = nil
                self?.lastChannel = nil
            }
        }
    }

    func refreshChannelIdentity() async throws {
        _ = try await authorizedChannel()
    }

    func schedule(title: String, date: Date, privacy: String, madeForKids: Bool) async throws -> YouTubeEvent {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf16.count <= 100, !title.contains("<"), !title.contains(">") else {
            throw LiveServiceError("방송 제목을 1~100자로 입력하고 꺾쇠 기호를 제거하세요.")
        }
        guard privacyValues.contains(privacy) else { throw LiveServiceError("방송 공개 범위를 선택하세요.") }
        let immediate = date <= Date()
        let context = try await authorizedChannel()
        // The insert API requires a future timestamp even when the encoder is starting immediately.
        let scheduled = immediate ? Date().addingTimeInterval(30) : date
        guard scheduled > Date() else { throw LiveServiceError("예약 시간이 지났습니다. 새로운 시작 시간을 선택하세요.") }
        let body: [String: Any] = [
            "snippet": ["title": title, "scheduledStartTime": scheduled.formatted(.iso8601)],
            "status": ["privacyStatus": privacy, "selfDeclaredMadeForKids": madeForKids] as [String: Any],
            "contentDetails": ["enableAutoStart": true, "enableAutoStop": true]
        ]
        // Reserve first. Preparing the stream at launch means a network error binding it cannot duplicate the event.
        let created: CreatedBroadcast = try await request("liveBroadcasts", token: context.token, query: ["part": broadcastParts],
                                                   method: "POST", body: body)
        guard !created.id.isEmpty else { throw invalidResponse }
        var registry = ownedIDs
        var ids = registry[context.channel] ?? []
        if !ids.contains(created.id) { ids.append(created.id) }
        registry[context.channel] = ids
        defaults.set(registry, forKey: registryKey)
        // Report YouTube's effective visibility. Do not start when the requested and actual visibility differ.
        let broadcast: Broadcast
        if let details = created.broadcast, details.snippet.channelId == context.channel {
            broadcast = details
        } else {
            guard let saved = try? await broadcasts(ids: [created.id], context: context).first else {
                throw LiveServiceError("예약을 만들었습니다. 예약 목록을 새로 고쳐 방송 정보를 확인하세요.")
            }
            broadcast = saved
        }
        guard broadcast.status.privacyStatus == privacy else {
            throw LiveServiceError("예약되었지만 YouTube가 공개 범위를 변경했습니다. 예약 목록에서 확인하세요.")
        }
        return try broadcast.event()
    }

    func upcoming() async throws -> [YouTubeEvent] {
        let context = try await authorizedChannel()
        let ids = ownedIDs[context.channel] ?? []
        var result: [YouTubeEvent] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            for broadcast in try await broadcasts(ids: batch, context: context) where launchStates.contains(broadcast.status.lifeCycleStatus) {
                result.append(try broadcast.event())
            }
        }
        return result.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    func destination(for event: YouTubeEvent) async throws -> URL {
        guard preparing.insert(event.id).inserted else { throw LiveServiceError("이 방송의 송출 연결을 준비하고 있습니다.") }
        defer { preparing.remove(event.id) }
        let context = try await authorizedChannel()
        let broadcast = try await owned(event, context: context)
        try validateLaunch(broadcast, event: event)
        let marker = "EasyCut broadcast " + event.id
        let streamID: String
        if let bound = broadcast.contentDetails.boundStreamId, !bound.isEmpty {
            streamID = bound
        } else {
            if let pending = pendingStreams[event.id] {
                do {
                    let existing: Page<Identifier> = try await request("liveStreams", token: context.token, query: ["id": pending, "part": "id"])
                    if !existing.items.contains(where: { $0.id == pending }) { pendingStreams.removeValue(forKey: event.id) }
                } catch let error as LiveServiceError where error.status == 404 {
                    pendingStreams.removeValue(forKey: event.id)
                }
            }
            if let pending = pendingStreams[event.id] {
                streamID = pending
            } else {
                let body: [String: Any] = [
                    "snippet": ["title": event.title, "description": marker],
                    "cdn": ["ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable"],
                    "contentDetails": ["isReusable": false]
                ]
                let stream: Identifier = try await request("liveStreams", token: context.token, query: ["part": streamParts],
                                                           method: "POST", body: body)
                guard !stream.id.isEmpty else { throw invalidResponse }
                pendingStreams[event.id] = stream.id
                streamID = stream.id
            }
            // Another client may have bound this event while the stream was created. Preserve its binding.
            let current = try await owned(event, context: context)
            try validateLaunch(current, event: event)
            if let bound = current.contentDetails.boundStreamId, !bound.isEmpty {
                guard bound == streamID else { throw changedBinding }
            } else {
                let bound: Broadcast = try await request("liveBroadcasts/bind", token: context.token,
                    query: ["part": broadcastParts, "id": event.id, "streamId": streamID], method: "POST")
                guard bound.id == event.id, bound.contentDetails.boundStreamId == streamID else { throw changedBinding }
            }
        }

        let streams: Page<Stream> = try await request("liveStreams", token: context.token, query: ["id": streamID, "part": streamParts])
        guard let stream = streams.items.first(where: { $0.id == streamID }),
              stream.contentDetails.isReusable == false, stream.snippet.channelId == context.channel,
              stream.snippet.description == marker else { throw changedBinding }
        guard let info = stream.cdn?.ingestionInfo, let address = info.rtmpsIngestionAddress,
              let parts = URLComponents(string: address), parts.scheme?.lowercased() == "rtmps",
              let host = parts.host?.lowercased(), host.hasSuffix(".rtmps.youtube.com") || host == "rtmps.youtube.com",
              parts.port == nil || parts.port == 443,
              let key = info.streamName, !key.isEmpty else {
            throw LiveServiceError("YouTube의 보안 송출 주소를 확인할 수 없습니다.")
        }
        let destination = try StudioEndpoint.destination(server: address, key: key)
        let confirmed = try await owned(event, context: context)
        try validateLaunch(confirmed, event: event)
        guard confirmed.contentDetails.boundStreamId == streamID else { throw changedBinding }
        try Task.checkCancellation()
        guard try await account.accessToken() == context.token else { throw LiveServiceError("YouTube 연결이 바뀌었습니다. 다시 시도하세요.") }
        pendingStreams.removeValue(forKey: event.id)
        return destination
    }

    func status(of event: YouTubeEvent) async throws -> String {
        let context = try await authorizedChannel()
        return try await owned(event, context: context).status.lifeCycleStatus
    }

    func complete(_ event: YouTubeEvent) async throws {
        let context = try await authorizedChannel()
        let current = try await owned(event, context: context)
        if current.status.lifeCycleStatus == "complete" { return }
        guard current.status.lifeCycleStatus == "live" else {
            throw LiveServiceError("YouTube에서 방송이 라이브 상태가 되면 종료할 수 있습니다.")
        }
        do {
            let completed: Identifier = try await request("liveBroadcasts/transition", token: context.token,
                query: ["id": event.id, "broadcastStatus": "complete", "part": "id,status"], method: "POST")
            guard completed.id == event.id else { throw invalidResponse }
        } catch {
            // YouTube auto-stop can finish the broadcast between our read and transition.
            if let latest = try? await owned(event, context: context), latest.status.lifeCycleStatus == "complete" { return }
            throw error
        }
    }

    private var ownedIDs: [String: [String]] { defaults.dictionary(forKey: registryKey) as? [String: [String]] ?? [:] }
    private var changedBinding: LiveServiceError { LiveServiceError("이 예약의 전용 스트림 연결이 변경되었습니다. YouTube Studio에서 확인하세요.") }
    private var invalidResponse: LiveServiceError { LiveServiceError("YouTube 방송 정보를 확인할 수 없습니다. 예약 목록을 새로 고치세요.") }

    private func authorizedChannel() async throws -> Context {
        let token = try await account.accessToken()
        let digest = SHA256.hash(data: Data(token.utf8))
        if let lastChannel, lastChannel.tokenDigest == digest { return Context(token: token, channel: lastChannel.id) }
        let channels: Page<Channel> = try await request("channels", token: token,
            query: ["part": "id,snippet", "mine": "true", "fields": "items(id,snippet/title)"])
        guard channels.items.count == 1, let channel = channels.items.first, !channel.id.isEmpty,
              !channel.snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveServiceError("연결할 YouTube 채널을 확인하세요. 여러 채널이 있으면 로그인 시 방송할 채널을 선택하세요.")
        }
        try Task.checkCancellation()
        guard try await account.accessToken() == token, account.isConnected else {
            throw LiveServiceError("YouTube 연결이 바뀌었습니다. 다시 시도하세요.")
        }
        lastChannel = (digest, channel.id)
        channelTitle = channel.snippet.title
        return Context(token: token, channel: channel.id)
    }

    private func validateLaunch(_ broadcast: Broadcast, event: YouTubeEvent) throws {
        guard launchStates.contains(broadcast.status.lifeCycleStatus) else { throw LiveServiceError("이 방송은 이미 시작되었거나 종료되었습니다.") }
        guard privacyValues.contains(event.privacy), broadcast.status.privacyStatus == event.privacy else {
            throw LiveServiceError("YouTube에서 공개 범위가 변경되었습니다. 예약 목록을 새로 고쳐 확인하세요.")
        }
        guard broadcast.contentDetails.enableAutoStart == true, broadcast.contentDetails.enableAutoStop == true else {
            throw LiveServiceError("YouTube Studio에서 이 예약의 자동 시작과 자동 종료를 켜세요.")
        }
    }

    private func owned(_ event: YouTubeEvent, context: Context) async throws -> Broadcast {
        guard ownedIDs[context.channel]?.contains(event.id) == true,
              let broadcast = try await broadcasts(ids: [event.id], context: context).first else {
            throw LiveServiceError("연결된 채널에서 EasyCut으로 만든 예약을 찾을 수 없습니다.")
        }
        return broadcast
    }

    private func broadcasts(ids: [String], context: Context) async throws -> [Broadcast] {
        var result: [Broadcast] = []
        var query = ["part": broadcastParts, "id": ids.joined(separator: ","), "maxResults": "50"]
        var seen = Set<String>()
        repeat {
            let page: Page<Broadcast> = try await request("liveBroadcasts", token: context.token, query: query)
            result += page.items.filter { ids.contains($0.id) && $0.snippet.channelId == context.channel }
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            guard seen.insert(next).inserted else { throw invalidResponse }
            query["pageToken"] = next
        } while true
        return result
    }

    private func request<Result: Decodable>(_ resource: String, token: String, query: [String: String], method: String = "GET",
                                             body: [String: Any]? = nil) async throws -> Result {
        try Task.checkCancellation()
        guard try await account.accessToken() == token else { throw LiveServiceError("YouTube 연결이 바뀌었습니다. 다시 시도하세요.") }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.googleapis.com"
        parts.path = "/youtube/v3/" + resource
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            if method == "POST", resource == "liveBroadcasts" {
                throw LiveServiceError("예약 결과를 받지 못했습니다. 다시 예약하기 전에 YouTube Studio의 예약 목록을 확인하세요.")
            }
            throw LiveServiceError("YouTube에 연결하지 못했습니다. 네트워크 상태를 확인하세요.")
        }
        guard let http = response as? HTTPURLResponse, http.url?.host == parts.host, http.url?.scheme == "https" else { throw invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw apiError(http.statusCode, data: data) }
        guard let value = try? JSONDecoder().decode(Result.self, from: data) else { throw invalidResponse }
        return value
    }

    private func apiError(_ status: Int, data: Data) -> LiveServiceError {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let reasons = (error?["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        if reasons.contains("liveStreamingNotEnabled") || reasons.contains("livePermissionBlocked") {
            return LiveServiceError("YouTube Studio에서 채널의 실시간 스트리밍 사용 가능 여부를 확인하세요.")
        }
        if reasons.contains("invalidScheduledStartTime") {
            return LiveServiceError("YouTube에서 예약 시간을 허용하지 않았습니다. 미래의 시작 시간을 선택하세요.")
        }
        if reasons.contains("accessNotConfigured") {
            return LiveServiceError("Google Cloud 프로젝트에서 YouTube Data API v3를 사용 설정하세요.")
        }
        if reasons.contains("quotaExceeded") || status == 429 {
            return LiveServiceError("YouTube API 요청 한도에 도달했습니다. 잠시 후 다시 시도하세요.")
        }
        switch status {
        case 401, 403: return LiveServiceError("YouTube 채널 접근 권한을 확인하고 계정을 다시 연결하세요.")
        case 404: return LiveServiceError("YouTube에서 예약 방송 또는 전용 스트림을 찾을 수 없습니다.", status: 404)
        default: return LiveServiceError("YouTube에서 요청을 처리하지 못했습니다 (HTTP \(status)). 예약 상태를 확인한 뒤 다시 시도하세요.")
        }
    }
}
