import AppKit
import Combine
import CryptoKit
import Foundation
@preconcurrency import Network
import Security

private enum AccountError: String, LocalizedError {
    case noClient = "Google 데스크톱 OAuth 클라이언트를 먼저 설정하세요."
    case invalidClient = "Google Cloud에서 받은 데스크톱 앱용 OAuth 클라이언트 JSON을 선택하세요."
    case busy = "현재 진행 중인 YouTube 계정 작업을 마친 뒤 다시 시도하세요."
    case connected = "다른 클라이언트를 가져오려면 먼저 YouTube 계정 연결을 해제하세요."
    case signedOut = "YouTube 계정을 다시 연결하세요."
    case keychain = "EasyCut이 macOS 키체인의 YouTube 계정 설정을 읽거나 저장할 수 없습니다."
    case random = "보안 인증 요청을 생성할 수 없습니다."
    case callback = "이 Mac에서 Google 로그인 응답을 받을 수 없습니다."
    case browser = "기본 브라우저를 열 수 없습니다."
    case timedOut = "Google 로그인 시간이 만료되었습니다. 다시 연결하세요."
    case denied = "Google 계정 연결을 취소했거나 YouTube 권한을 허용하지 않았습니다."
    case exchange = "Google이 로그인 요청을 완료하지 못했습니다. OAuth 클라이언트 설정을 확인하세요."
    case network = "Google 계정 서버에 연결할 수 없습니다. 네트워크 연결을 확인하세요."
    case revoke = "이 Mac에서 계정 연결을 해제했습니다. Google 계정의 연결된 앱에서 EasyCut 접근 권한도 해제하세요."
    var errorDescription: String? { rawValue }
}

private struct GoogleDesktopClient: Codable {
    let id: String
    let secret: String?

    init(id: String?, secret: String?) throws {
        guard let id, id.hasSuffix(".apps.googleusercontent.com"), id.count <= 256,
              let first = id.first, first.isASCII && first.isNumber,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              (secret ?? "").utf8.count <= 1024 else { throw AccountError.invalidClient }
        self.id = id
        self.secret = secret?.isEmpty == false ? secret : nil
    }

    static var bundled: GoogleDesktopClient? {
        guard let url = Bundle.main.url(forResource: "YouTubeOAuthClient", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListDecoder().decode([String: String].self, from: data) else { return nil }
        return try? Self(id: values["ClientID"], secret: values["ClientSecret"])
    }

    static func imported(at url: URL) throws -> Self {
        struct File: Decodable {
            struct Installed: Decodable { let client_id: String; let client_secret: String? }
            let installed: Installed
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { throw AccountError.invalidClient }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let client = try? JSONDecoder().decode(File.self, from: data).installed else { throw AccountError.invalidClient }
        return try Self(id: client.client_id, secret: client.client_secret)
    }
}

private struct GoogleGrant: Codable {
    let clientID: String
    let refreshToken: String
}

// Distinguish a missing item from a locked or inaccessible Keychain on every operation.
private enum YouTubeVault: String {
    case client, grant
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.contenjoo.easycut.youtube.oauth",
         kSecAttrAccount as String: rawValue]
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        var query = query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = try? JSONDecoder().decode(type, from: data) else { throw AccountError.keychain }
        return value
    }
    func write<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AccountError.keychain }
        var entry = query
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw AccountError.keychain }
    }
    func clear() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AccountError.keychain }
    }
}

private final class NoOAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum GoogleOAuth {
    static let scope = "https://www.googleapis.com/auth/youtube.force-ssl"
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config, delegate: NoOAuthRedirects(), delegateQueue: nil)
    }()
    struct Token: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int
        let scope: String?
        let refresh_token: String?
    }
    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountError.random }
        return base64URL(Data(bytes))
    }
    static func authorization(client: GoogleDesktopClient, redirect: URL, state: String, verifier: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let fields = ["client_id": client.id, "redirect_uri": redirect.absoluteString, "response_type": "code",
                      "scope": scope, "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
                      "access_type": "offline", "prompt": "consent select_account"]
        url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    static func post(_ url: URL, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AccountError.network }
            return (data, response.statusCode)
        } catch { try Task.checkCancellation(); throw AccountError.network }
    }
    static func token(client: GoogleDesktopClient, fields: [String: String]) async throws -> Token {
        var fields = fields
        fields["client_id"] = client.id
        fields["client_secret"] = client.secret
        let (data, status) = try await post(URL(string: "https://oauth2.googleapis.com/token")!, fields: fields)
        if status == 400, fields["grant_type"] == "refresh_token",
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["error"] as? String == "invalid_grant" { throw AccountError.signedOut }
        guard status == 200, let token = try? JSONDecoder().decode(Token.self, from: data),
              token.token_type.lowercased() == "bearer", !token.access_token.isEmpty, token.expires_in > 0 else {
            throw AccountError.exchange
        }
        if let scopes = token.scope, !scopes.split(separator: " ").contains(Substring(scope)) { throw AccountError.denied }
        return token
    }
}

// All listener and connection callbacks run on the main queue. Bind the local socket before opening the browser.
@MainActor
private final class OAuthLoopback {
    private let listener: NWListener
    private var wait: CheckedContinuation<(code: String, redirect: URL), Error>?
    private var timeout: DispatchWorkItem?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do { listener = try NWListener(using: parameters) } catch { throw AccountError.callback }
    }

    func code(state: String, open: @escaping @MainActor (URL) -> Bool) async throws -> (code: String, redirect: URL) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                wait = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    MainActor.assumeIsolated {
                        guard let self, self.wait != nil else { return }
                        switch status {
                        case .ready:
                            guard let port = self.listener.port,
                                  let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                                self.finish(.failure(AccountError.callback)); return
                            }
                            if !open(redirect) { self.finish(.failure(AccountError.browser)) }
                        case .failed: self.finish(.failure(AccountError.callback))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        guard let self, self.wait != nil, self.connections.count < 8 else { connection.cancel(); return }
                        let id = ObjectIdentifier(connection)
                        self.connections[id] = connection
                        connection.start(queue: .main)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
                            if let connection { self?.close(connection) }
                        }
                        self.read(connection, data: Data(), state: state)
                    }
                }
                let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(AccountError.timedOut)) }
                timeout = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: deadline)
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<(code: String, redirect: URL), Error>) {
        guard let continuation = wait else { return }
        wait = nil
        timeout?.cancel()
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        continuation.resume(with: result)
    }
    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }
    private func read(_ connection: NWConnection, data: Data, state: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] block, _, eof, error in
            MainActor.assumeIsolated {
                guard let self, self.wait != nil, self.connections[ObjectIdentifier(connection)] != nil else { return }
                let bytes = data + (block ?? Data())
                if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
                   let headers = String(data: bytes[..<end.lowerBound], encoding: .utf8) {
                    self.respond(connection, headers: headers, state: state)
                } else if eof || error != nil || bytes.count >= 8192 { self.close(connection) }
                else { self.read(connection, data: bytes, state: state) }
            }
        }
    }
    private func respond(_ connection: NWConnection, headers: String, state: String) {
        guard let port = listener.port else { close(connection); return }
        let origin = "127.0.0.1:\(port.rawValue)"
        let lines = headers.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let redirect = URL(string: "http://\(origin)/")!
        var result: Result<(code: String, redirect: URL), Error>?
        if request.count == 3, request[0] == "GET", request[2].hasPrefix("HTTP/1."),
           hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == origin,
           let target = URLComponents(string: String(request[1])), target.scheme == nil, target.host == nil,
           target.percentEncodedPath == "/", target.fragment == nil, let params = target.queryItems {
            let states = params.filter { $0.name == "state" }
            let codes = params.filter { $0.name == "code" }
            let errors = params.filter { $0.name == "error" }
            if states.count == 1, states[0].value == state {
                if errors.count == 1, codes.isEmpty { result = .failure(AccountError.denied) }
                else if errors.isEmpty, codes.count == 1, let code = codes[0].value, !code.isEmpty {
                    result = .success((code, redirect))
                }
            }
        }
        let body = result == nil ? "잘못된 요청입니다." : "Google 로그인 응답을 받았습니다. EasyCut으로 돌아가세요."
        let status = result == nil ? "400 Bad Request" : "200 OK"
        let outcome = result
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close(connection)
                if let outcome { self?.finish(outcome) }
            }
        })
    }
}

@MainActor
final class YouTubeAccount: ObservableObject {
    static let shared = YouTubeAccount()
    @Published private(set) var isConnected = false
    @Published private(set) var connecting = false
    @Published private(set) var hasClient = false

    private var cached: (value: String, expiry: Date)?
    private var refresh: Task<String, Error>?
    private var callback: OAuthLoopback?
    private var generation = UUID()
    private var disconnecting = false

    private init() {
        if let client = try? currentClient() {
            hasClient = true
            isConnected = (try? YouTubeVault.grant.read(GoogleGrant.self))?.clientID == client.id
        }
    }
    private func currentClient() throws -> GoogleDesktopClient? {
        try YouTubeVault.client.read(GoogleDesktopClient.self) ?? GoogleDesktopClient.bundled
    }
    func importClient(at url: URL) throws {
        guard !connecting, !disconnecting else { throw AccountError.busy }
        let client = try GoogleDesktopClient.imported(at: url)
        let grant = try YouTubeVault.grant.read(GoogleGrant.self)
        if let grant, grant.clientID != client.id { throw AccountError.connected }
        try YouTubeVault.client.write(client)
        hasClient = true
        isConnected = grant != nil
    }

    func connect() async throws {
        guard !connecting, !disconnecting else { throw AccountError.busy }
        guard let client = try currentClient() else { throw AccountError.noClient }
        hasClient = true
        if let grant = try YouTubeVault.grant.read(GoogleGrant.self), grant.clientID == client.id {
            isConnected = true
            return
        }
        let state = try GoogleOAuth.nonce()
        let verifier = try GoogleOAuth.nonce()
        let receiver = try OAuthLoopback()
        connecting = true
        callback = receiver
        let id = generation
        defer { if id == generation { connecting = false; callback = nil } }
        let authorization = try await receiver.code(state: state) { redirect in
            NSWorkspace.shared.open(GoogleOAuth.authorization(client: client, redirect: redirect, state: state, verifier: verifier))
        }
        try checkSession(id)
        let token = try await GoogleOAuth.token(client: client, fields: [
            "code": authorization.code, "code_verifier": verifier,
            "redirect_uri": authorization.redirect.absoluteString, "grant_type": "authorization_code"
        ])
        try checkSession(id)
        guard let refreshToken = token.refresh_token, !refreshToken.isEmpty else { throw AccountError.exchange }
        try YouTubeVault.grant.write(GoogleGrant(clientID: client.id, refreshToken: refreshToken))
        cache(token)
        isConnected = true
    }

    func accessToken() async throws -> String {
        guard !disconnecting else { throw AccountError.signedOut }
        if let cached, cached.expiry.timeIntervalSinceNow > 60 { return cached.value }
        let id = generation
        if let refresh {
            let token = try await refresh.value
            try checkSession(id)
            return token
        }
        guard let client = try currentClient(), let grant = try YouTubeVault.grant.read(GoogleGrant.self),
              grant.clientID == client.id else { throw AccountError.signedOut }
        let work = Task { @MainActor in
            defer { if generation == id { refresh = nil } }
            do {
                let token = try await GoogleOAuth.token(client: client, fields: [
                    "refresh_token": grant.refreshToken, "grant_type": "refresh_token"
                ])
                try checkSession(id)
                if let rotated = token.refresh_token, !rotated.isEmpty, rotated != grant.refreshToken {
                    try YouTubeVault.grant.write(GoogleGrant(clientID: client.id, refreshToken: rotated))
                }
                cache(token)
                isConnected = true
                return token.access_token
            } catch let error as AccountError where error == .signedOut || error == .denied {
                try checkSession(id)
                cached = nil
                isConnected = false
                try YouTubeVault.grant.clear()
                throw AccountError.signedOut
            }
        }
        refresh = work
        let token = try await work.value
        try checkSession(id)
        return token
    }

    func disconnect() async throws {
        guard !disconnecting else { throw AccountError.busy }
        disconnecting = true
        defer { disconnecting = false }
        generation = UUID()
        callback?.cancel()
        callback = nil
        refresh?.cancel()
        refresh = nil
        connecting = false
        cached = nil
        let grant = try YouTubeVault.grant.read(GoogleGrant.self)
        try YouTubeVault.grant.clear()
        isConnected = false
        guard let grant else { return }
        do {
            let (_, status) = try await GoogleOAuth.post(URL(string: "https://oauth2.googleapis.com/revoke")!,
                                                         fields: ["token": grant.refreshToken])
            guard status == 200 else { throw AccountError.revoke }
        } catch { throw AccountError.revoke }
    }
    private func checkSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == generation else { throw CancellationError() }
    }
    private func cache(_ token: GoogleOAuth.Token) {
        cached = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in)))
    }
}
