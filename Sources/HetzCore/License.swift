// AB-McHZ PRO: chave de licença assinada com Ed25519 e verificada offline, mais avaliação de 14 dias.
// Formato da chave: "ABMCHZ-PRO." + base64url(JSON {"o": dono, "i": emissão ISO 8601, "m": vínculo?}) + "." + base64url(assinatura).
// Toda chave é vitalícia. Com "m", só vale no Mac e no usuário de login cujo `MachineBinding.current` é igual.
// A chave privada que emite licenças fica fora do repositório (~/.config/ab-mchz/licenca-ed25519.key).
import CryptoKit
import Foundation
import IOKit

/// Recursos que exigem PRO. Os demais (brilho por DDC, resolução, reparo de EDID, leitura no CLI) são livres.
public enum ProFeature: String, CaseIterable, Sendable {
    case presets = "aplicar presets dos perfis"
    case autoOptimize = "otimização automática por monitor (taxa máxima, perfil de cor, preset padrão)"
    case automation = "presets por app em primeiro plano e por horário"
    case hotkeys = "atalhos ⌃⌥⌘1–9 para presets"
}

public enum LicenseError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed
    case badSignature
    case otherMachine

    public var description: String {
        switch self {
        case .malformed: "chave de licença em formato inválido"
        case .badSignature: "chave de licença não foi emitida para o AB-McHZ PRO"
        case .otherMachine: "chave de licença emitida para outro Mac ou outro usuário (veja hetzctl license machine)"
        }
    }
}

/// Vínculo da licença com o Mac e o login: hash do UUID da placa (IOPlatformUUID) com o nome curto do usuário.
/// O hash não revela nenhum dos dois, e trocar de usuário ou de Mac muda o valor.
public enum MachineBinding {
    public static func make(platformUUID: String, user: String) -> String {
        Data(SHA256.hash(data: Data("ab-mchz/v1|\(platformUUID)|\(user)".utf8))).prefix(16).base64URL
    }

    public static var current: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0,
              let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? String else { return nil }
        return make(platformUUID: uuid, user: NSUserName())
    }
}

public struct LicenseKey: Sendable, Equatable {
    public let owner: String
    public let issued: Date
    /// `MachineBinding` do Mac e usuário para quem a chave foi emitida; `nil` vale em qualquer Mac.
    public let machine: String?

    static let prefix = "ABMCHZ-PRO."
    public static let embeddedPublicKey = "kA2gRURm79kqG6m+VLgSnTGFiTrLIUQKxLlZnEd+sDA="

    private struct Payload: Codable {
        let o: String
        let i: Date
        let m: String?
    }

    public static func parse(_ text: String, publicKey: String = embeddedPublicKey,
                             machine: String? = MachineBinding.current) throws(LicenseError) -> LicenseKey {
        let trimmed = clean(text)
        guard trimmed.hasPrefix(prefix) else { throw .malformed }
        let parts = trimmed.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = Data(base64URL: parts[0]), let signature = Data(base64URL: parts[1]),
              let decoded = try? decoder.decode(Payload.self, from: payload) else { throw .malformed }
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(signature, for: payload) else { throw .badSignature }
        if let bound = decoded.m, bound != machine { throw .otherMachine }
        return LicenseKey(owner: decoded.o, issued: decoded.i, machine: decoded.m)
    }

    /// Chave colada de e-mail chega quebrada em linhas: remove todo espaço em branco.
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    /// Emite uma chave. Usado pelo `hetzctl license issue` com a chave privada local e pelos testes.
    public static func issue(owner: String, issued: Date = .now, machine: String? = nil,
                             privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = try encoder.encode(Payload(o: owner, i: issued, m: machine))
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
    case pro(owner: String, boundToThisMac: Bool = false)
    case trial(daysLeft: Int)
    case free

    public static let trialDays = 14

    public func allows(_ feature: ProFeature) -> Bool {
        if case .free = self { false } else { true }
    }

    public var description: String {
        switch self {
        case .pro(let owner, let bound): "AB-McHZ PRO vitalício · \(owner)\(bound ? " · vinculado a este Mac e usuário" : "")"
        case .trial(let days): "AB-McHZ PRO · avaliação, \(days) dia\(days == 1 ? "" : "s") restante\(days == 1 ? "" : "s")"
        case .free: "AB-McHZ · edição livre (PRO: hetzctl license activate <chave>)"
        }
    }

    /// Regra pura: chave válida vence; senão avaliação contada do primeiro uso; senão edição livre.
    /// `lastSeen` só avança: voltar o relógio não devolve dias, e início no futuro conta como expirado.
    public static func resolve(key: String?, trialStart: Date, now: Date, lastSeen: Date? = nil,
                               publicKey: String = LicenseKey.embeddedPublicKey,
                               machine: String? = MachineBinding.current) -> Edition {
        if let key, let license = try? LicenseKey.parse(key, publicKey: publicKey, machine: machine) {
            return .pro(owner: license.owner, boundToThisMac: license.machine != nil)
        }
        let effectiveNow = max(now, lastSeen ?? now)
        guard trialStart <= effectiveNow.addingTimeInterval(3600) else { return .free }
        let elapsed = Calendar(identifier: .gregorian).dateComponents([.day], from: trialStart, to: effectiveNow).day ?? 0
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
        let lastSeen = defaults.object(forKey: "lastSeen") as? Date
        let now = Date.now
        if now > (lastSeen ?? .distantPast) { defaults.set(now, forKey: "lastSeen") }
        return Edition.resolve(key: defaults.string(forKey: "licenseKey"), trialStart: start, now: now, lastSeen: lastSeen)
    }

    @discardableResult
    public static func activate(_ text: String) throws(LicenseError) -> LicenseKey {
        let license = try LicenseKey.parse(text)
        defaults.set(LicenseKey.clean(text), forKey: "licenseKey")
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
