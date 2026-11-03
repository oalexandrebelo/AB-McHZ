import Testing
@testable import HetzCore

/// Monta uma resposta Get VCP com checksum correto (semente 0x50).
func vcpReply(code: UInt8, current: UInt16, maximum: UInt16, result: UInt8 = 0x00) -> [UInt8] {
    let body: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00, UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
    return body + [MCCS.checksum(body, seed: MCCS.replySeed)]
}

@Suite struct MCCSTests {
    @Test func getRequestMatchesSpecExample() {
        // Exemplo clássico do DDC/CI: 6E 51 82 01 10 AC (0x6E e 0x51 vão como endereço/offset).
        #expect(MCCS.getVCPRequest(0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func setRequestEncodesValueBigEndian() {
        #expect(MCCS.setVCPRequest(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(Array(MCCS.setVCPRequest(0x12, value: 0x1234)[3...4]) == [0x12, 0x34])
    }

    @Test(arguments: [UInt8(0x10), 0x12, 0x60, 0xC9, 0xFF])
    func requestFramesXorToZeroWithAddresses(code: UInt8) {
        for packet in [MCCS.getVCPRequest(code), MCCS.setVCPRequest(code, value: 0xBEEF)] {
            #expect(MCCS.checksum([MCCS.displayAddress, MCCS.hostAddress] + packet, seed: 0) == 0)
            #expect(Int(packet[0] & 0x7F) == packet.count - 2)
        }
    }

    @Test func decodesKnownReply() throws {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
        let value = try MCCS.decodeGetVCPReply(reply, code: 0x10)
        #expect(value == VCPValue(code: 0x10, current: 75, maximum: 100))
    }

    @Test func roundTripsSixteenBitValues() throws {
        let value = try MCCS.decodeGetVCPReply(vcpReply(code: 0xC9, current: 513, maximum: 0xFFFF), code: 0xC9)
        #expect(value.current == 513)
        #expect(value.maximum == 0xFFFF)
    }

    @Test func rejectsCorruptedChecksum() {
        var reply = vcpReply(code: 0x10, current: 75, maximum: 100)
        reply[9] ^= 0x01
        #expect(throws: DDCError.badChecksum) { try MCCS.decodeGetVCPReply(reply, code: 0x10) }
    }

    @Test func nullMessageMeansBusy() {
        let reply: [UInt8] = [0x6E, 0x80, 0xBE] + Array(repeating: 0, count: 8)
        #expect(throws: DDCError.nullReply) { try MCCS.decodeGetVCPReply(reply, code: 0x10) }
    }

    @Test func unsupportedCodeIsReported() {
        let reply = vcpReply(code: 0x10, current: 0, maximum: 0, result: 0x01)
        #expect(throws: DDCError.unsupportedVCP(0x10)) { try MCCS.decodeGetVCPReply(reply, code: 0x10) }
    }

    @Test func replyForAnotherCodeIsMalformed() {
        let reply = vcpReply(code: 0x12, current: 50, maximum: 100)
        #expect(throws: DDCError.malformedReply) { try MCCS.decodeGetVCPReply(reply, code: 0x10) }
        #expect(throws: DDCError.malformedReply) { try MCCS.decodeGetVCPReply([0x6E, 0x88], code: 0x10) }
    }

    @Test func busErrorsAreTransientButProtocolAnswersAreNot() {
        #expect(DDCError.io(-1).isTransient)
        #expect(DDCError.badChecksum.isTransient)
        #expect(DDCError.nullReply.isTransient)
        #expect(!DDCError.unsupportedVCP(0x10).isTransient)
        #expect(!DDCError.circuitOpen(retryAfter: .seconds(1)).isTransient)
    }

    @Test func parsesVCPCodes() {
        #expect(MCCS.parseCode("0x10") == 0x10)
        #expect(MCCS.parseCode("0x1a") == 0x1A)
        #expect(MCCS.parseCode("16") == 0x10)
        #expect(MCCS.parseCode("0x100") == nil)
        #expect(MCCS.parseCode("zz") == nil)
        #expect(MCCS.format(0x1A) == "0x1A")
    }
}
