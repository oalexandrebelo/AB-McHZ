// EDID 1.x lido por I2C em 0x50. O parser é tolerante: um EDID com cabeçalho ou checksum errado
// ainda é decodificado, e `issues` diz o que está errado (é justamente o que faz o macOS rejeitá-lo).
import Foundation

public enum EDIDError: Error, Equatable, Sendable {
    case badLength(Int)
    case notAnEDID
}

public struct EDID: Sendable, Equatable {
    public static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    public let bytes: [UInt8]

    /// Recusa só o que não parece EDID (leitura vazia ou lixo); defeitos reais ficam em `issues`.
    public init(_ bytes: [UInt8]) throws(EDIDError) {
        guard bytes.count >= 128, bytes.count % 128 == 0 else { throw .badLength(bytes.count) }
        guard bytes[1...7].elementsEqual(Self.header[1...7]) else { throw .notAnEDID }
        self.bytes = bytes
    }

    public var manufacturerID: String {
        let m = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return String([10, 5, 0].map { Character(UnicodeScalar(UInt8((m >> $0) & 0x1F) + 64)) })
    }
    /// Mesmo valor que `CGDisplayVendorNumber` devolve quando o macOS tem o EDID.
    public var vendorNumber: UInt32 { UInt32(bytes[8]) << 8 | UInt32(bytes[9]) }
    public var productCode: UInt16 { UInt16(bytes[10]) | UInt16(bytes[11]) << 8 }
    public var serialNumber: UInt32 { bytes[12...15].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    public var yearOfManufacture: Int { 1990 + Int(bytes[17]) }
    public var version: String { "\(bytes[18]).\(bytes[19])" }
    public var extensionCount: Int { Int(bytes[126]) }
    public var displayName: String? { descriptorText(0xFC) }
    public var serialText: String? { descriptorText(0xFF) }

    public var issues: [String] {
        var found: [String] = []
        if bytes[0] != 0x00 { found.append("cabeçalho: byte 0 = 0x\(hex(bytes[0])) (esperado 0x00)") }
        for block in 0..<(bytes.count / 128) {
            let sum = blockSum(block)
            guard sum != 0 else { continue }
            found.append("checksum do bloco \(block) não fecha (soma 0x\(hex(sum)))")
        }
        if bytes[0] != 0x00, blockSum(0) == bytes[0] {
            found.append("com o byte 0 = 0x00 o checksum do bloco 0 fecha: o resto do bloco é consistente")
        }
        if extensionCount > bytes.count / 128 - 1 {
            found.append("anuncia \(extensionCount) extensões; lidas \(bytes.count / 128 - 1)")
        }
        return found
    }

    /// Cópia corrigida quando o único defeito é o byte 0 do cabeçalho (o caso da BenQ XL2430T pela HDMI);
    /// nil se não há o que corrigir ou se há qualquer outro defeito.
    public var headerRepaired: EDID? {
        guard bytes[0] != 0x00 else { return nil }
        var fixed = bytes
        fixed[0] = 0x00
        guard let edid = try? EDID(fixed), edid.issues.isEmpty else { return nil }
        return edid
    }

    private func blockSum(_ block: Int) -> UInt8 {
        bytes[(block * 128)..<(block * 128 + 128)].reduce(0, &+)
    }

    private func descriptorText(_ tag: UInt8) -> String? {
        for offset in stride(from: 54, to: 126, by: 18)
        where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == tag {
            let text = bytes[(offset + 5)..<(offset + 18)].prefix { $0 != 0x0A }
            return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

func hex(_ byte: UInt8) -> String {
    String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
}
