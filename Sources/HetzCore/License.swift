// AB-McHZ PRO: chave de licença assinada com Ed25519 e verificada offline, mais avaliação de 14 dias.
// Formato da chave: "ABMCHZ-PRO." + base64url(JSON {"o": dono, "i": emissão ISO 8601}) + "." + base64url(assinatura).
// A chave privada que emite licenças fica fora do repositório (~/.config/ab-mchz/licenca-ed25519.key).
import CryptoKit
import Foundation

/// Recursos que exigem PRO. Os demais (brilho por DDC, resolução, reparo de EDID, leitura no CLI) são livres.
public enum ProFeature: String, CaseIterable, Sendable {
    case presets = "aplicar presets dos perfis"
    case autoOptimize = "otimização automática por monitor (taxa máxima, perfil de cor, preset padrão)"
}

public enum LicenseError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed
    case badSignature

    public var description: String {
        switch self {
        case .malformed: "chave de licença em formato inválido"
        case .badSignature: "chave de licença não foi emitida para o AB-McHZ PRO"
        }
    }
}

public struct LicenseKey: Sendable, Equatable {
    public let owner: String
    public let issued: Date

    static let prefix = "ABMCHZ-PRO."
    public static let embeddedPublicKey = "kA2gRURm79kqG6m+VLgSnTGFiTrLIUQKxLlZnEd+sDA="

    private struct Payload: Codable {
        let o: String
        let i: Date
    }

    public static func parse(_ text: String, publicKey: String = embeddedPublicKey) throws(LicenseError) -> LicenseKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw .malformed }
        let parts = trimmed.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              let decoded = try? decoder.decode(Payload.self, from: payload) else { throw .malformed }
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: payload) else { throw .badSignature }
        return LicenseKey(owner: decoded.o, issued: decoded.i)
    }

    /// Emite uma chave. Usado pelo `hetzctl license issue` com a chave privada local e pelos testes.
    public static func issue(owner: String, issued: Date = .now, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = try encoder.encode(Payload(o: owner, i: issued))
        let signature = try privateKey.signature(for: payload)
        return prefix + payload.base64URL + "." + signature.base64URL
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum Edition: Sendable, Equatable, CustomStringConvertible {
    case pro(owner: String)
    case trial(daysLeft: Int)
    case free

    public static let trialDays = 14

    public func allows(_ feature: ProFeature) -> Bool {
        if case .free = self { false } else { true }
    }

    public var description: String {
        switch self {
        case .pro(let owner): "AB-McHZ PRO · licenciado para \(owner)"
        case .trial(let days): "AB-McHZ PRO · avaliação, \(days) dia\(days == 1 ? "" : "s") restante\(days == 1 ? "" : "s")"
        case .free: "AB-McHZ · edição livre (PRO: hetzctl license activate <chave>)"
        }
    }

    /// Regra pura: chave válida vence; senão avaliação contada do primeiro uso; senão edição livre.
    public static func resolve(key: String?, trialStart: Date, now: Date, publicKey: String = LicenseKey.embeddedPublicKey) -> Edition {
        if let key, let license = try? LicenseKey.parse(key, publicKey: publicKey) { return .pro(owner: license.owner) }
        let elapsed = Calendar(identifier: .gregorian).dateComponents([.day], from: trialStart, to: now).day ?? 0
        let left = trialDays - max(0, elapsed)
        return left > 0 ? .trial(daysLeft: left) : .free
    }
}

/// Chave e início da avaliação, compartilhados entre o app e o `hetzctl`.
public enum Licensing {
    // UserDefaults é thread-safe (documentação da Apple), só não está marcado como Sendable.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "org.ab-mchz.shared")!

    public static var current: Edition {
        let start: Date
        if let saved = defaults.object(forKey: "trialStart") as? Date {
            start = saved
        } else {
            start = .now
            defaults.set(start, forKey: "trialStart")
        }
        return Edition.resolve(key: defaults.string(forKey: "licenseKey"), trialStart: start, now: .now)
    }

    @discardableResult
    public static func activate(_ text: String) throws(LicenseError) -> LicenseKey {
        let license = try LicenseKey.parse(text)
        defaults.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "licenseKey")
        return license
    }
}

extension Data {
    init?(base64URL text: some StringProtocol) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
