import Foundation
import AppKit

/// 앱 언어: 한국어가 원문이고, 영어는 LocTable(코드 문구)과 en.lproj/Localizable.strings(SwiftUI 문구)로 옮긴다.
/// 언어는 macOS 설정을 따르고(한국어가 아니면 영어), 앱 메뉴에서 바꾸면 다음 실행부터 적용된다.
enum Loc {
    enum Choice: String, CaseIterable { case auto, ko, en }

    /// 앱만 다른 언어로 쓰기 (AppleLanguages 앱 설정)
    static var choice: Choice {
        get {
            guard let l = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
                  let f = l.first else { return .auto }
            return f.hasPrefix("ko") ? .ko : .en
        }
        set {
            switch newValue {
            case .auto: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .ko: UserDefaults.standard.set(["ko"], forKey: "AppleLanguages")
            case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            }
        }
    }

    /// 이번 실행에서 영어로 보이는지
    static let english: Bool = !(Bundle.main.preferredLocalizations.first ?? "ko").hasPrefix("ko")


    // MARK: 번역

    private static let marker: Character = "\u{1}"
    /// %d, %.1f, %lld, %@, {} 같은 자리표시
    private static let placeholder = try! NSRegularExpression(pattern: #"\{\}|%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSaA]"#)

    private static func placeholders(in s: String) -> [String] {
        placeholder.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    private static func normalized(_ s: String) -> String {
        placeholder.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: String(marker))
    }

    private static let table: [String: String] = {
        var t: [String: String] = [:]
        for (k, v) in LocTable.english { t[normalized(k)] = v }
        return t
    }()

    /// 자리표시가 있는 문구 → 이미 값이 채워진 문장을 알아보기 위한 정규식
    private static let patterns: [(NSRegularExpression, String)] = {
        LocTable.english.compactMap { k, v -> (NSRegularExpression, String, Int)? in
            let parts = normalized(k).split(separator: marker, omittingEmptySubsequences: false)
            guard parts.count > 1 else { return nil }
            let literal = parts.joined()
            guard literal.count >= 2 else { return nil }
            let pattern = "^" + parts.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "(.*?)") + "$"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return (re, v, literal.count)
        }
        .sorted { $0.2 > $1.2 }
        .map { ($0.0, $0.1) }
    }()

    /// 영어 문구의 자리표시를 차례로 values로 바꾼다
    private static func fill(_ template: String, with values: [String]) -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        for (i, m) in placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)).enumerated() {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += i < values.count ? values[i] : ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// 값이 채워진 한국어 문장 → 영어
    static func translate(_ s: String, force: Bool = false) -> String {
        guard english || force, !s.isEmpty else { return s }
        if let v = table[normalized(s)], placeholders(in: s).isEmpty { return v }
        let ns = s as NSString
        for (re, v) in patterns {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let values = (1..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : translate(ns.substring(with: r), force: force)
            }
            return fill(v, with: values)
        }
        return s
    }

    /// 자리표시가 그대로 있는 키(SwiftUI·String(format:)) → 같은 자리표시를 쓰는 영어 키
    static func translateKey(_ key: String) -> String? {
        guard let v = table[normalized(key)] else { return nil }
        return fill(v, with: placeholders(in: key))
    }
}

/// 문구를 현재 언어로
func L(_ s: String) -> String { Loc.english ? Loc.translate(s) : s }

extension NSAlert {
    /// 제목·설명·버튼을 현재 언어로 바꾼 뒤 돌려준다
    func localized() -> NSAlert {
        messageText = L(messageText)
        informativeText = L(informativeText)
        for b in buttons { b.title = L(b.title) }
        return self
    }
}

/// 언어를 바꾸고 다시 시작할지 묻는다
@MainActor
enum LanguageSwitch {
    static func set(_ c: Loc.Choice) {
        guard c != Loc.choice else { return }
        Loc.choice = c
        let a = NSAlert()
        a.messageText = "언어를 바꾸려면 EasyCut을 다시 시작해야 합니다.\nRestart EasyCut to change the language."
        a.informativeText = "작업 중인 프로젝트는 저장됩니다. / Your project will be saved."
        a.addButton(withTitle: "지금 다시 시작 / Restart Now")
        a.addButton(withTitle: "나중에 / Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
