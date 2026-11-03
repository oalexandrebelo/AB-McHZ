import CoreGraphics
import Foundation
import Testing
@testable import HetzCore

/// Monitor falso: responde Get VCP com `values`, depois de `failuresBeforeReply` leituras com erro de I2C.
final class FakeBus: I2CBus, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt8: (current: UInt16, maximum: UInt16)]
    private var failuresLeft: Int
    private var lastRequest: [UInt8] = []
    private(set) var attempts = 0

    init(values: [UInt8: (UInt16, UInt16)], failuresBeforeReply: Int = 0) {
        self.values = values.mapValues { (current: $0.0, maximum: $0.1) }
        failuresLeft = failuresBeforeReply
    }

    var attemptCount: Int { lock.withLock { attempts } }

    func write(chip: UInt8, offset: UInt8, _ bytes: [UInt8]) throws(DDCError) {
        lock.lock(); defer { lock.unlock() }
        lastRequest = bytes
        if bytes[1] == 0x03 { values[bytes[2]]?.current = UInt16(bytes[3]) << 8 | UInt16(bytes[4]) }
    }

    func read(chip: UInt8, offset: UInt8, count: Int) throws(DDCError) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw .io(kIOReturnTimeout)
        }
        let code = lastRequest[2]
        guard let value = values[code] else { return vcpReply(code: code, current: 0, maximum: 0, result: 0x01) }
        return vcpReply(code: code, current: value.current, maximum: value.maximum)
    }
}

@Suite struct DisplayEngineTests {
    let fast = RetryPolicy(maxRetries: 2, base: .milliseconds(1), maxDelay: .milliseconds(5), jitter: .zero)

    private func engine(_ bus: FakeBus) -> DisplayEngine {
        DisplayEngine(displays: [], buses: [7: bus], policy: fast, breaker: CircuitBreaker())
    }

    @Test func retriesTransientFailures() async throws {
        let bus = FakeBus(values: [0x10: (75, 100)], failuresBeforeReply: 2)
        let value = try await engine(bus).readVCP(0x10, on: 7)
        #expect(value.current == 75)
        #expect(bus.attemptCount == 3)
    }

    @Test func threeTimeoutsIsolateTheDisplay() async {
        let bus = FakeBus(values: [0x10: (75, 100)], failuresBeforeReply: .max)
        let engine = engine(bus)
        await #expect(throws: DDCError.io(kIOReturnTimeout)) { try await engine.readVCP(0x10, on: 7) }
        #expect(await engine.breakerState(for: 7) != .closed(failures: 0))
        do {
            _ = try await engine.readVCP(0x10, on: 7)
            Issue.record("deveria estar isolada")
        } catch {
            guard case .circuitOpen(let wait) = error else { Issue.record("esperado circuitOpen, veio \(error)"); return }
            #expect(wait > .seconds(29))
        }
        #expect(bus.attemptCount == 3)
    }

    @Test func unsupportedCodeIsNotRetriedNorCountedAsTimeout() async {
        let bus = FakeBus(values: [:])
        let engine = engine(bus)
        await #expect(throws: DDCError.unsupportedVCP(0x10)) { try await engine.readVCP(0x10, on: 7) }
        #expect(bus.attemptCount == 1)
        #expect(await engine.breakerState(for: 7) == .closed(failures: 0))
    }

    @Test func setRefusesContinuousValueAboveMaximum() async throws {
        let engine = engine(FakeBus(values: [0x10: (75, 100), 0x60: (18, 14)]))
        await #expect(throws: DDCError.valueOutOfRange(code: 0x10, value: 101, maximum: 100)) {
            try await engine.setVCP(0x10, to: 101, on: 7)
        }
        #expect(try await engine.setVCP(0x10, to: 25, on: 7).current == 25)
        // 0x60 (entrada) não é contínuo: o "máximo" 14 não é teto.
        #expect(try await engine.setVCP(0x60, to: 15, on: 7).current == 15)
    }

    @Test func writeWithoutReadBackUsesCachedMaximum() async throws {
        let bus = FakeBus(values: [0x10: (75, 100)])
        let engine = engine(bus)
        _ = try await engine.readVCP(0x10, on: 7)
        try await engine.writeVCP(0x10, value: 40, on: 7)
        #expect(await engine.lastValues[7]?[0x10]?.current == 40)
        await #expect(throws: DDCError.valueOutOfRange(code: 0x10, value: 101, maximum: 100)) {
            try await engine.writeVCP(0x10, value: 101, on: 7)
        }
    }

    @Test func applyStillWritesDDCWhenModeCannotChange() async throws {
        // ID que não existe: o teste nunca mexe numa tela de verdade.
        let offline: CGDirectDisplayID = 0xFFFF_FFF0
        let bus = FakeBus(values: [0x10: (75, 100), 0x12: (50, 100)])
        let engine = DisplayEngine(displays: [], buses: [offline: bus], policy: fast, breaker: CircuitBreaker())
        let plan = try Profile.load(from: profileURL("benq-xl2430t")).plan(for: "competitivo")
        let report = await engine.apply(plan, to: offline)
        #expect(report.modeAttempts.count == 1)
        #expect(throws: ModeError.offline(offline)) { try report.modeAttempts[0].result.get() }
        #expect(report.ddc.compactMap { try? $0.result.get().current } == [55, 50])
        #expect(report.exitStatus == 1)
    }

    @Test func nullDisplayIDIsNotTreatedAsMain() async {
        // Para o CoreGraphics, ID 0 é a tela principal. 1x1@1 não existe, então nem uma regressão troca modo.
        await #expect(throws: ModeError.offline(0)) {
            try await engine(FakeBus(values: [:])).switchMode(0, to: DisplayModeSpec(width: 1, height: 1, hz: 1))
        }
    }

    @Test func unknownDisplayHasNoChannel() async {
        let engine = engine(FakeBus(values: [:]))
        await #expect(throws: DDCError.unavailable(99)) { try await engine.readVCP(0x10, on: 99) }
    }
}
