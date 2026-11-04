// Aviso de versão nova pela última release do GitHub (sem atualizar sozinho: o usuário baixa o DMG).
import Foundation

/// "0.3.0" ou "v0.3.0", comparada número a número ("0.10.0" > "0.9.1"); sufixo depois de "-" é ignorado.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]

    public init?(_ text: String) {
        let core = text.trimmingCharacters(in: .whitespaces).drop { $0 == "v" }.split(separator: "-").first ?? ""
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        self.numbers = numbers.compactMap { $0 }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        let pad = { (numbers: [Int]) in numbers + Array(repeating: 0, count: count - numbers.count) }
        return pad(lhs.numbers).lexicographicallyPrecedes(pad(rhs.numbers))
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public var description: String { numbers.map(String.init).joined(separator: ".") }
}

public struct AvailableUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let page: URL
}

public enum UpdateCheck {
    public static let latestRelease = URL(string: "https://api.github.com/repos/oalexandrebelo/AB-McHZ/releases/latest")!

    /// Resposta de `releases/latest`: só devolve algo se a release for mais nova que `current`.
    public static func parse(_ data: Data, current: AppVersion) -> AvailableUpdate? {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name), current < version else { return nil }
        return AvailableUpdate(version: version, page: release.html_url)
    }

    public static func fetch(current: AppVersion) async -> AvailableUpdate? {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, current: current)
    }
}
