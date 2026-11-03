// Perfis profiles/*.json (schema ab-mchz/profile@1). Só o que o motor aplica é decodificado:
// o resto (OSD, justificativas, fontes) é texto para pessoas.
import Foundation

public enum ProfileError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchema(String)
    case unknownPreset(String, available: [String])

    public var description: String {
        switch self {
        case .unsupportedSchema(let schema): "schema \"\(schema)\" não suportado (esperado \(Profile.schemaID))"
        case .unknownPreset(let name, let available): "preset \"\(name)\" não existe; disponíveis: \(available.joined(separator: ", "))"
        }
    }
}

public struct Profile: Decodable, Sendable, Equatable {
    public static let schemaID = "ab-mchz/profile@1"

    public let schema: String
    public let id: String
    public let monitor: Monitor
    public let macos: MacOS
    public let presets: [String: Preset]

    public struct Monitor: Decodable, Sendable, Equatable {
        public let model: String
        public let edid: EDIDRef?
    }

    public struct EDIDRef: Decodable, Sendable, Equatable {
        public let manufacturer: String
        public let product: String
        public let serial: String?

        public var productCode: UInt16? {
            product.lowercased().hasPrefix("0x") ? UInt16(product.dropFirst(2), radix: 16) : UInt16(product)
        }

        public func matches(_ edid: EDID) -> Bool {
            edid.manufacturerID == manufacturer && edid.productCode == productCode
        }
    }

    public struct MacOS: Decodable, Sendable, Equatable {
        public let mode: Mode
        /// Descrição do perfil ICC (ex.: "sRGB IEC61966-2.1"), procurada nas pastas do ColorSync.
        public let colorProfile: String?
    }

    public struct Mode: Decodable, Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let hz: Int
        public let fallbackHz: Int?
        public let hiDPI: Bool?
    }

    public struct Preset: Decodable, Sendable, Equatable {
        public let isDefault: Bool
        public let requires: String?
        /// VCP → valor; as chaves do JSON são hex ("0x10").
        public let ddc: [UInt8: UInt16]
        /// `macos` do preset: objeto com "hz" sobrepõe o modo do perfil; texto é só nota.
        public let hzOverride: Int?
        public let macosNote: String?

        private enum CodingKeys: String, CodingKey {
            case isDefault = "default", requires, ddc, macos
        }

        private struct MacOSOverride: Decodable {
            let hz: Int?
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            requires = try container.decodeIfPresent(String.self, forKey: .requires)
            var ddc: [UInt8: UInt16] = [:]
            for (key, value) in try container.decodeIfPresent([String: Int].self, forKey: .ddc) ?? [:] {
                guard key.lowercased().hasPrefix("0x"), let code = MCCS.parseCode(key), let word = UInt16(exactly: value) else {
                    throw DecodingError.dataCorruptedError(forKey: .ddc, in: container, debugDescription: "par DDC inválido: \(key)=\(value)")
                }
                ddc[code] = word
            }
            self.ddc = ddc
            if let note = try? container.decodeIfPresent(String.self, forKey: .macos) {
                macosNote = note
                hzOverride = nil
            } else {
                macosNote = nil
                hzOverride = try container.decodeIfPresent(MacOSOverride.self, forKey: .macos)?.hz
            }
        }
    }

    public static func load(from url: URL) throws -> Profile {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
        guard profile.schema == schemaID else { throw ProfileError.unsupportedSchema(profile.schema) }
        return profile
    }

    /// Onde o app instalado procura perfis (o install.sh copia `profiles/` do repositório para lá).
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AB-McHZ/profiles", isDirectory: true)
    }

    /// Perfis válidos da pasta, em ordem de nome; arquivo inválido é ignorado.
    public static func loadAll(in directory: URL) -> [Profile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? load(from: $0) }
    }

    /// Pelo EDID quando o perfil o identifica; senão pelo modelo (última palavra, ex.: "PG259QN") no nome da tela.
    public func matches(edid: EDID?, name: String?) -> Bool {
        if let ref = monitor.edid { return edid.map(ref.matches) ?? false }
        guard let model = monitor.model.split(separator: " ").last?.lowercased() else { return false }
        return [name, edid?.displayName].contains { $0?.lowercased().contains(model) == true }
    }

    public var defaultPresetName: String? {
        presets.first { $0.value.isDefault }?.key
    }

    public func plan(for presetName: String) throws(ProfileError) -> ApplyPlan {
        guard let preset = presets[presetName] else { throw .unknownPreset(presetName, available: presets.keys.sorted()) }
        let base = macos.mode
        let hz = preset.hzOverride ?? base.hz
        return ApplyPlan(
            profileID: id,
            preset: presetName,
            mode: DisplayModeSpec(width: base.width, height: base.height, hz: hz),
            fallbackHz: preset.hzOverride == nil ? base.fallbackHz : nil,  // o override do preset é exigência, não preferência
            hiDPI: base.hiDPI ?? false,
            ddc: preset.ddc.keys.sorted().map { VCPWrite(code: $0, value: preset.ddc[$0]!) },
            requires: preset.requires
        )
    }
}

public struct VCPWrite: Sendable, Equatable {
    public let code: UInt8
    public let value: UInt16
}

public struct ApplyPlan: Sendable, Equatable {
    public let profileID: String
    public let preset: String
    public let mode: DisplayModeSpec
    public let fallbackHz: Int?
    public let hiDPI: Bool
    public let ddc: [VCPWrite]
    public let requires: String?
}
