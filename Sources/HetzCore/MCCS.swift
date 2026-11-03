// DDC/CI (VESA) e MCCS: montagem e leitura dos pacotes Get/Set VCP.
//
// No fio o host escreve em 0x6E: [0x51, 0x80|n, opcode, dados…, checksum] e lê de 0x6F a resposta
// [0x6E, 0x80|n, opcode, dados…, checksum]. No Apple Silicon o IOAVServiceWriteI2C recebe o endereço
// de 7 bits (0x37) e envia o 0x51 como "data address"; por isso os pacotes daqui começam no byte de tamanho.

public struct VCPValue: Sendable, Equatable {
    public let code: UInt8
    public let current: UInt16
    public let maximum: UInt16
    public let isMomentary: Bool

    public init(code: UInt8, current: UInt16, maximum: UInt16, isMomentary: Bool = false) {
        self.code = code
        self.current = current
        self.maximum = maximum
        self.isMomentary = isMomentary
    }
}

public enum MCCS {
    public static let chipAddress: UInt8 = 0x37
    public static let edidAddress: UInt8 = 0x50
    public static let hostAddress: UInt8 = 0x51
    public static let displayAddress: UInt8 = 0x6E
    /// Respostas do monitor usam o endereço virtual 0x50 como semente do checksum.
    public static let replySeed: UInt8 = 0x50
    public static let getVCPReplyLength = 11

    /// VCPs contínuos (MCCS 2.2): neles o "máximo" da resposta é teto. Nos não contínuos (0x14, 0x60,
    /// 0xDC…) ele conta opções e pode ser menor que o valor atual (a BenQ responde 0x60 = 18, máx 14).
    public static let continuousCodes: Set<UInt8> = [0x10, 0x12, 0x16, 0x18, 0x1A, 0x62, 0x6C, 0x6E, 0x70, 0x87, 0x8A]

    public static func checksum(_ bytes: some Sequence<UInt8>, seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    public static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        frame([0x01, code])
    }

    public static func setVCPRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        frame([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func frame(_ message: [UInt8]) -> [UInt8] {
        let packet = [0x80 | UInt8(message.count)] + message
        return packet + [checksum(packet, seed: displayAddress ^ hostAddress)]
    }

    public static func decodeGetVCPReply(_ reply: [UInt8], code: UInt8) throws(DDCError) -> VCPValue {
        guard reply.count >= getVCPReplyLength else { throw .malformedReply }
        if reply[1] == 0x80 { throw .nullReply }  // "null message": monitor ocupado
        guard checksum(reply[0..<10], seed: replySeed) == reply[10] else { throw .badChecksum }
        guard reply[1] == 0x88, reply[2] == 0x02 else { throw .malformedReply }
        guard reply[3] == 0x00 else { throw .unsupportedVCP(code) }
        guard reply[4] == code else { throw .malformedReply }  // resposta de outro pedido no barramento
        return VCPValue(
            code: code,
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            maximum: UInt16(reply[6]) << 8 | UInt16(reply[7]),
            isMomentary: reply[5] == 0x01
        )
    }

    /// "0x10" é hexadecimal; "16" é decimal.
    public static func parseCode(_ text: String) -> UInt8? {
        let lower = text.lowercased()
        return lower.hasPrefix("0x") ? UInt8(lower.dropFirst(2), radix: 16) : UInt8(lower)
    }

    public static func format(_ code: UInt8) -> String {
        "0x" + String(code, radix: 16, uppercase: true).leftPadded(to: 2)
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
