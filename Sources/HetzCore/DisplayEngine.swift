// Estado das telas (lista, canais DDC, circuit breakers, EDIDs e últimos valores VCP) num actor.
import CoreGraphics
import Foundation

public enum DisplayEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [CGDirectDisplayID])

    public var description: String {
        switch self {
        case .notFound(let query): "nenhuma tela corresponde a \"\(query)\" (veja hetzctl list)"
        case .ambiguous(let query, let ids): "\"\(query)\" casa com mais de uma tela: \(ids.map(String.init).joined(separator: ", "))"
        }
    }
}

public enum ModeError: Error, Equatable, Sendable, CustomStringConvertible {
    case offline(CGDirectDisplayID)
    case noCurrentMode(CGDirectDisplayID)
    case notOffered(DisplayModeSpec)
    case unsafe(ModeInfo)
    case configurationFailed(Int32)

    public var description: String {
        switch self {
        case .offline(let id): "tela \(id) não está online"
        case .noCurrentMode(let id): "tela \(id) sem modo atual"
        case .notOffered(let spec): "modo \(spec) não oferecido pelo macOS (veja hetzctl modes)"
        case .unsafe(let mode): "modo \(mode) sem kDisplayModeSafeFlag (use --force para tentar com watchdog)"
        case .configurationFailed(let code): "CGCompleteDisplayConfiguration falhou (CGError \(code))"
        }
    }
}

public enum ModeSwitchOutcome: Sendable, Equatable {
    case alreadyActive(ModeInfo)
    case applied(ModeInfo)
    /// O watchdog não viu o modo pedido (ou a tela caiu) e restaurou o anterior.
    case reverted(attempted: ModeInfo, observed: ModeInfo?, restored: ModeInfo, revertError: Int32, droppedOffline: Bool)
}

extension ModeSwitchOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyActive(let mode):
            return "\(mode) já está ativo"
        case .applied(let mode):
            return "\(mode) aplicado"
        case .reverted(let attempted, let observed, let restored, let revertError, let dropped):
            let why = dropped ? "a tela saiu do ar" : "o modo ativo ficou \(observed?.description ?? "indefinido")"
            return "watchdog: \(attempted) não pegou (\(why)); revertido para \(restored)\(revertError == 0 ? "" : " (CGError \(revertError))")"
        }
    }
}

public enum EDIDRepairOutcome: Sendable, Equatable, CustomStringConvertible {
    case notNeeded
    case notRepairable([String])
    case repaired(vendor: UInt32)
    case injectedWithoutEffect

    public var description: String {
        switch self {
        case .notNeeded: "o macOS já tem o EDID desta tela"
        case .notRepairable(let issues): issues.isEmpty ? "EDID por I2C sem defeito no cabeçalho para corrigir" : "EDID com defeito que não é só o cabeçalho: \(issues.joined(separator: "; "))"
        case .repaired(let vendor): "EDID corrigido entregue ao DCP; o macOS reconhece a tela (vendor 0x\(String(vendor, radix: 16, uppercase: true)))"
        case .injectedWithoutEffect: "EDID corrigido entregue ao DCP, mas o macOS continua sem reconhecer a tela"
        }
    }
}

public struct ApplyReport: Sendable {
    public struct ModeAttempt: Sendable {
        public let spec: DisplayModeSpec
        public let result: Result<ModeSwitchOutcome, ModeError>
    }

    public struct DDCResult: Sendable {
        public let write: VCPWrite
        public let result: Result<VCPValue, DDCError>
    }

    public internal(set) var modeAttempts: [ModeAttempt] = []
    public internal(set) var ddc: [DDCResult] = []

    /// 0 = tudo aplicado, 2 = o watchdog reverteu o modo, 1 = outra falha (como o tools/setmode.swift).
    public var exitStatus: Int32 {
        let reverted = modeAttempts.contains { if case .success(.reverted) = $0.result { true } else { false } }
        if reverted { return 2 }
        let modeFailed = modeAttempts.last.map { if case .failure = $0.result { true } else { false } } ?? false
        let ddcFailed = ddc.contains { if case .failure = $0.result { true } else { false } }
        return modeFailed || ddcFailed ? 1 : 0
    }
}

public actor DisplayEngine {
    public private(set) var displays: [DisplayInfo] = []
    public let policy: RetryPolicy
    private let breakerTemplate: CircuitBreaker
    private var buses: [CGDirectDisplayID: any I2CBus] = [:]
    private var breakers: [CGDirectDisplayID: CircuitBreaker] = [:]
    private var edids: [CGDirectDisplayID: EDID] = [:]
    public private(set) var lastValues: [CGDirectDisplayID: [UInt8: VCPValue]] = [:]

    public init(policy: RetryPolicy = .ddc, breaker: CircuitBreaker = CircuitBreaker()) {
        self.policy = policy
        breakerTemplate = breaker
    }

    init(displays: [DisplayInfo], buses: [CGDirectDisplayID: any I2CBus], policy: RetryPolicy, breaker: CircuitBreaker) {
        self.displays = displays
        self.buses = buses
        self.policy = policy
        breakerTemplate = breaker
    }

    @discardableResult
    public func refresh() -> [DisplayInfo] {
        (displays, buses) = Discovery.scan()
        return displays
    }

    public func breakerState(for id: CGDirectDisplayID) -> CircuitBreaker.State {
        (breakers[id] ?? breakerTemplate).state
    }

    /// ID numérico, "main" ou trecho do nome (do macOS ou do EDID lido por I2C).
    public func resolve(_ query: String) async throws -> DisplayInfo {
        if let id = CGDirectDisplayID(query) {
            guard let display = displays.first(where: { $0.id == id }) else { throw DisplayEngineError.notFound(query) }
            return display
        }
        if query.lowercased() == "main", let main = displays.first(where: \.isMain) { return main }
        let needle = query.lowercased()
        var hits: [DisplayInfo] = []
        for display in displays {
            var names = [display.name]
            if display.hasDDC, let edid = try? await edid(for: display.id) {
                names += [edid.displayName, edid.manufacturerID]
            }
            if names.contains(where: { $0?.lowercased().contains(needle) == true }) { hits.append(display) }
        }
        guard let first = hits.first else { throw DisplayEngineError.notFound(query) }
        guard hits.count == 1 else { throw DisplayEngineError.ambiguous(query, hits.map(\.id)) }
        return first
    }

    // MARK: DDC

    public func readVCP(_ code: UInt8, on id: CGDirectDisplayID) async throws(DDCError) -> VCPValue {
        let request = MCCS.getVCPRequest(code)
        let value = try await withRetry(on: id) { bus throws(DDCError) in
            try bus.write(chip: MCCS.chipAddress, offset: MCCS.hostAddress, request)
            usleep(50_000)  // DDC/CI: ≥ 40 ms entre o pedido e a leitura da resposta
            let reply = try bus.read(chip: MCCS.chipAddress, offset: 0, count: MCCS.getVCPReplyLength)
            return try MCCS.decodeGetVCPReply(reply, code: code)
        }
        lastValues[id, default: [:]][code] = value
        return value
    }

    /// Lê antes (VCP contínuo acima do máximo é recusado), grava e devolve a releitura.
    public func setVCP(_ code: UInt8, to value: UInt16, on id: CGDirectDisplayID) async throws(DDCError) -> VCPValue {
        _ = try await readVCP(code, on: id)
        try await writeVCP(code, value: value, on: id)
        return try await readVCP(code, on: id)
    }

    /// Grava sem releitura (ex.: slider de brilho). VCP contínuo é conferido contra o último máximo lido.
    public func writeVCP(_ code: UInt8, value: UInt16, on id: CGDirectDisplayID) async throws(DDCError) {
        let known = lastValues[id]?[code]
        if MCCS.continuousCodes.contains(code), let maximum = known?.maximum, value > maximum {
            throw .valueOutOfRange(code: code, value: value, maximum: maximum)
        }
        let request = MCCS.setVCPRequest(code, value: value)
        try await withRetry(on: id) { bus throws(DDCError) in
            try bus.write(chip: MCCS.chipAddress, offset: MCCS.hostAddress, request)
            usleep(50_000)  // DDC/CI: ≥ 50 ms depois de um Set antes do próximo comando
        }
        if let known {
            lastValues[id]?[code] = VCPValue(code: code, current: value, maximum: known.maximum, isMomentary: known.isMomentary)
        }
    }

    public func edid(for id: CGDirectDisplayID, refresh: Bool = false) async throws(DDCError) -> EDID {
        if !refresh, let cached = edids[id] { return cached }
        let edid = try await withRetry(on: id) { bus throws(DDCError) in
            var bytes = try bus.read(chip: MCCS.edidAddress, offset: 0, count: 128)
            // Só a primeira extensão: blocos 2+ exigem o ponteiro de segmento do E-DDC (0x30).
            if bytes[126] > 0 { bytes += try bus.read(chip: MCCS.edidAddress, offset: 128, count: 128) }
            do { return try EDID(bytes) } catch { throw .badEDID("\(error)") }
        }
        edids[id] = edid
        return edid
    }

    /// Se o macOS está sem o EDID da tela e o lido por I2C só tem o byte 0 do cabeçalho errado, entrega ao DCP
    /// a cópia corrigida como EDID virtual. Com o EDID, o kernel libera a banda do link (na BenQ pela HDMI:
    /// de 1280×720/74,25 MHz para 1920/182,75 MHz). Volátil: chame de novo após replug, sleep e reboot.
    public func repairEDID(on id: CGDirectDisplayID, wait: Duration = .seconds(4)) async throws(DDCError) -> EDIDRepairOutcome {
        guard CGDisplayVendorNumber(id) == 0 else { return .notNeeded }
        let wire = try await edid(for: id, refresh: true)
        guard let fixed = wire.headerRepaired else { return .notRepairable(wire.issues) }
        // Uma tentativa só: cada SetVirtualEDID retreina o link (a tela pisca); quem insiste é o chamador, com limite.
        guard let bus = buses[id] else { throw .unavailable(id) }
        try await onI2CQueue { () throws(DDCError) in try bus.setVirtualEDID(fixed.bytes) }
        let step = Duration.milliseconds(250)
        for _ in 0..<max(1, Int(wait / step)) {
            try? await Task.sleep(for: step)
            let vendor = CGDisplayVendorNumber(id)
            if vendor != 0 {
                refresh()
                return .repaired(vendor: vendor)
            }
        }
        return .injectedWithoutEffect
    }

    /// Devolve ao DCP o EDID do próprio monitor.
    public func clearVirtualEDID(on id: CGDirectDisplayID) async throws(DDCError) {
        try await withRetry(on: id) { bus throws(DDCError) in try bus.setVirtualEDID(nil) }
        edids[id] = nil
    }

    private func withRetry<T: Sendable>(
        on id: CGDirectDisplayID,
        _ operation: @escaping @Sendable (any I2CBus) throws(DDCError) -> T
    ) async throws(DDCError) -> T {
        guard let bus = buses[id] else { throw .unavailable(id) }
        var retry = 0
        while true {
            var breaker = breakers[id] ?? breakerTemplate
            let now = ContinuousClock.now
            guard breaker.allowsRequest(at: now) else {
                breakers[id] = breaker
                throw .circuitOpen(retryAfter: breaker.retryAfter(at: now))
            }
            breakers[id] = breaker
            do {
                let value = try await onI2CQueue { () throws(DDCError) in try operation(bus) }
                breakers[id]?.recordSuccess()
                return value
            } catch where error.isTransient {
                breakers[id]?.recordFailure(at: .now)
                guard retry < policy.maxRetries, breakers[id]?.isOpen == false else { throw error }
                try? await Task.sleep(for: policy.delay(forRetry: retry))
                retry += 1
            } catch {
                breakers[id]?.recordSuccess()  // o monitor respondeu (ex.: VCP não suportado): o barramento está vivo
                throw error
            }
        }
    }

    // MARK: Modo

    /// Modos distintos utilizáveis no desktop, do maior para o menor.
    public nonisolated func modes(for id: CGDirectDisplayID) -> [ModeInfo] {
        var seen = Set<String>()
        return DisplayModes.all(id).map(ModeInfo.init)
            .filter(\.isUsableForDesktopGUI)
            .sorted { ($0.width, $0.height, $0.hz, $0.pixelWidth) > ($1.width, $1.height, $1.hz, $1.pixelWidth) }
            .filter { seen.insert($0.description).inserted }
    }

    /// Modo primeiro (tentando o `fallbackHz` só se o modo pedido não existir), depois o DDC:
    /// a troca de modo ressincroniza o monitor e pode descartar escritas feitas antes dela.
    public func apply(_ plan: ApplyPlan, to id: CGDirectDisplayID, allowUnsafe: Bool = false) async -> ApplyReport {
        var report = ApplyReport()
        var specs = [plan.mode]
        if let hz = plan.fallbackHz { specs.append(DisplayModeSpec(width: plan.mode.width, height: plan.mode.height, hz: hz)) }
        for spec in specs {
            do {
                let outcome = try await switchMode(id, to: spec, hiDPI: plan.hiDPI, allowUnsafe: allowUnsafe)
                report.modeAttempts.append(.init(spec: spec, result: .success(outcome)))
                break
            } catch {
                report.modeAttempts.append(.init(spec: spec, result: .failure(error)))
                guard case .notOffered = error else { break }
            }
        }
        for write in plan.ddc {
            do {
                report.ddc.append(.init(write: write, result: .success(try await setVCP(write.code, to: write.value, on: id))))
            } catch {
                report.ddc.append(.init(write: write, result: .failure(error)))
            }
        }
        return report
    }

    /// Porta do tools/setmode.swift: aplica, observa a tela pelo `watchdog` e só aceita o modo se ele
    /// estiver de fato ativo com a tela online. CGError de sucesso não é prova; sem prova, reverte.
    public func switchMode(
        _ id: CGDirectDisplayID,
        to spec: DisplayModeSpec,
        hiDPI: Bool = false,
        allowUnsafe: Bool = false,
        watchdog: Duration = .seconds(6),
        commit: Bool = true
    ) async throws(ModeError) -> ModeSwitchOutcome {
        // O CoreGraphics trata o ID 0 como "tela principal": só aceita ID que esteja online.
        guard id != kCGNullDirectDisplay, DisplayModes.isOnline(id) else { throw .offline(id) }
        guard let previous = CGDisplayCopyDisplayMode(id) else { throw .noCurrentMode(id) }
        let candidates = DisplayModes.all(id).filter {
            let info = ModeInfo($0)
            return spec.matches(info) && info.isUsableForDesktopGUI && info.isHiDPI == hiDPI
        }
        guard let target = candidates.first(where: { ModeInfo($0).isSafe }) ?? candidates.first else { throw .notOffered(spec) }
        let targetInfo = ModeInfo(target), previousInfo = ModeInfo(previous)
        if previousInfo.sameMode(as: targetInfo) { return .alreadyActive(previousInfo) }
        guard targetInfo.isSafe || allowUnsafe else { throw .unsafe(targetInfo) }

        let result = DisplayModes.apply(target, to: id)
        guard result == .success else { throw .configurationFailed(result.rawValue) }

        var droppedOffline = false
        let step = Duration.milliseconds(500)
        for _ in 0..<max(1, Int(watchdog / step)) {
            try? await Task.sleep(for: step)  // cancelado ou não, o watchdog termina e decide
            if !DisplayModes.isOnline(id) { droppedOffline = true }
        }
        let observed = CGDisplayCopyDisplayMode(id).map(ModeInfo.init)
        defer { refresh() }
        if DisplayModes.isOnline(id), let observed, observed.sameMode(as: targetInfo) {
            if commit { _ = DisplayModes.apply(target, to: id, option: .permanently) }
            return .applied(observed)
        }
        let revert = DisplayModes.apply(previous, to: id)
        return .reverted(attempted: targetInfo, observed: observed, restored: previousInfo, revertError: revert.rawValue, droppedOffline: droppedOffline)
    }

    /// Grava como permanente o modo ativo (depois que o usuário confirmou um modo aplicado com `commit: false`).
    public nonisolated func commitCurrentMode(_ id: CGDirectDisplayID) {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return }
        _ = DisplayModes.apply(mode, to: id, option: .permanently)
    }
}
