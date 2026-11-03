// Estado da automação PRO por monitor, fora do AppKit para ser testável.
// Regras (docs/REVISAO-CODIGO.md, itens 1, 2, 4 e 5):
// - Conexão = monitor visto online; só é esquecida depois de `grace` fora do ar (sleep curto não é reconexão).
// - Taxa só é corrigida ao conectar, ao acordar ou quando o preset ativo muda o alvo; no timer, só se observa.
//   Modo diferente do último aplicado pelo app = escolha do usuário, respeitada até reconectar.
// - Modo que o watchdog reverteu não é tentado de novo nesta conexão.
// - Presets automáticos (app em primeiro plano > agenda > padrão) são aplicados na borda: só quando o preset
//   desejado muda, então um preset escolhido à mão vale até a próxima mudança de app ou de horário.
// - Perfil de cor uma vez por conexão; reparo de EDID no máximo `maxRepairAttempts` por conexão.
import CoreGraphics
import Foundation

public struct DisplayKey: Hashable, Sendable, CustomStringConvertible {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// Sem EDID (vendor 0) todas as telas teriam a mesma chave: usa o ID do CoreGraphics.
    let fallbackID: CGDirectDisplayID?

    public var description: String { fallbackID.map { "tela \($0)" } ?? "\(vendor)-\(model)-\(serial)" }
}

extension DisplayInfo {
    public var key: DisplayKey {
        DisplayKey(vendor: vendor, model: model, serial: serial, fallbackID: vendor == 0 ? id : nil)
    }
}

public enum PilotTrigger: Sendable, Equatable {
    /// Hotplug, primeira execução ou volta do sleep: pode corrigir a taxa.
    case connectOrWake
    /// Timer, reconfiguração ou troca de app: só corrige a taxa se o alvo mudou.
    case tick
}

public enum PresetReason: String, Sendable, Equatable {
    case app = "app em primeiro plano"
    case schedule = "agenda"
    case defaultPreset = "padrão"
}

public struct DesiredPreset: Sendable, Equatable {
    public let name: String
    public let reason: PresetReason
}

public struct AutoPilot: Sendable {
    public static let grace: TimeInterval = 300
    public static let maxPresetAttempts = 3
    public static let maxRepairAttempts = 3

    struct Connection: Sendable {
        var lastSeen: Date
        var appliedMode: ModeInfo?
        var lastTarget: String?
        var userOverride = false
        var failedModes: Set<String> = []
        var colorDone = false
        var activePreset: String?
        var lastDesired: DesiredPreset?
        var presetAttempts = 0
        var repairAttempts = 0
    }

    private(set) var connections: [DisplayKey: Connection] = [:]

    public init() {}

    /// Marca as telas online e esquece as ausentes há mais de `grace`. Devolve as conexões novas.
    @discardableResult
    public mutating func observe(_ keys: some Sequence<DisplayKey>, now: Date) -> Set<DisplayKey> {
        var fresh = Set<DisplayKey>()
        for key in keys {
            if connections[key] == nil {
                connections[key] = Connection(lastSeen: now)
                fresh.insert(key)
            } else {
                connections[key]?.lastSeen = now
            }
        }
        connections = connections.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.grace }
        return fresh
    }

    public func activePreset(_ key: DisplayKey) -> String? { connections[key]?.activePreset }
    public func isUserOverride(_ key: DisplayKey) -> Bool { connections[key]?.userOverride ?? false }

    // MARK: Taxa

    public enum RefreshDecision: Sendable, Equatable {
        case keep
        case switchTo(ModeInfo)
    }

    public mutating func refreshDecision(_ key: DisplayKey, current: ModeInfo?, target: ModeInfo?, trigger: PilotTrigger) -> RefreshDecision {
        guard var connection = connections[key], let current, let target else { return .keep }
        defer { connections[key] = connection }
        let targetChanged = connection.lastTarget != target.description
        connection.lastTarget = target.description
        if current.sameMode(as: target) {
            connection.appliedMode = current
            return .keep
        }
        if trigger == .tick, !targetChanged {
            if let applied = connection.appliedMode, !current.sameMode(as: applied) { connection.userOverride = true }
            return .keep
        }
        guard !connection.userOverride || targetChanged, !connection.failedModes.contains(target.description) else { return .keep }
        return .switchTo(target)
    }

    public mutating func recordSwitch(_ key: DisplayKey, target: ModeInfo, result: Result<ModeSwitchOutcome, ModeError>) {
        switch result {
        case .success(.applied(let mode)), .success(.alreadyActive(let mode)):
            connections[key]?.appliedMode = mode
            connections[key]?.userOverride = false
        case .success(.reverted(_, _, let restored, _, _)):
            connections[key]?.appliedMode = restored
            connections[key]?.failedModes.insert(target.description)
        case .failure:
            connections[key]?.failedModes.insert(target.description)
        }
    }

    /// O usuário escolheu um modo à mão (menu de resolução): vale até reconectar ou o preset mudar o alvo.
    public mutating func recordUserMode(_ key: DisplayKey, mode: ModeInfo) {
        connections[key]?.appliedMode = mode
        connections[key]?.userOverride = true
    }

    // MARK: Presets

    /// Preset que a automação quer agora, por prioridade: app em primeiro plano > agenda > padrão.
    public static func desiredPreset(_ profile: Profile, frontmostApp: String?, appPresets: [String: String], now: Date,
                                     calendar: Calendar = .current) -> DesiredPreset? {
        if let app = frontmostApp, let name = appPresets[app], profile.presets[name] != nil {
            return DesiredPreset(name: name, reason: .app)
        }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        if let name = profile.presets.keys.sorted().first(where: { profile.presets[$0]?.schedule?.contains(minute) == true }) {
            return DesiredPreset(name: name, reason: .schedule)
        }
        return profile.defaultPresetName.map { DesiredPreset(name: $0, reason: .defaultPreset) }
    }

    /// Aplica só na borda: quando o desejado mudou desde a última aplicação bem-sucedida (ou desistência).
    public func shouldApply(_ key: DisplayKey, desired: DesiredPreset?) -> Bool {
        guard let desired, let connection = connections[key] else { return false }
        return connection.lastDesired != desired
    }

    public mutating func recordAutomaticPreset(_ key: DisplayKey, desired: DesiredPreset, succeeded: Bool) {
        guard connections[key] != nil else { return }
        connections[key]?.activePreset = desired.name
        if succeeded {
            connections[key]?.lastDesired = desired
            connections[key]?.presetAttempts = 0
        } else {
            connections[key]?.presetAttempts += 1
            if connections[key]!.presetAttempts >= Self.maxPresetAttempts { connections[key]?.lastDesired = desired }
        }
    }

    /// Preset escolhido no menu ou por atalho: passa a valer e o alvo de taxa passa a ser o dele.
    public mutating func recordManualPreset(_ key: DisplayKey, name: String) {
        connections[key]?.activePreset = name
        connections[key]?.userOverride = false
    }

    // MARK: Cor e EDID

    public func needsColor(_ key: DisplayKey) -> Bool { connections[key].map { !$0.colorDone } ?? false }
    public mutating func recordColor(_ key: DisplayKey) { connections[key]?.colorDone = true }

    public func mayRepairEDID(_ key: DisplayKey) -> Bool { (connections[key]?.repairAttempts ?? 0) < Self.maxRepairAttempts }
    public mutating func recordRepairAttempt(_ key: DisplayKey) { connections[key]?.repairAttempts += 1 }
}

extension Optimizer {
    /// Alvo de taxa considerando o preset ativo: preset com `macos.hz` (ex.: ULMB a 240 Hz) fixa a taxa, sem alternativa.
    public static func target(_ profile: Profile, preset: String?, offered: [ModeInfo]) -> ModeInfo? {
        var mode = profile.macos.mode
        if let preset, let hz = profile.presets[preset]?.hzOverride {
            mode = Profile.Mode(width: mode.width, height: mode.height, hz: hz, fallbackHz: nil, hiDPI: mode.hiDPI)
        }
        return bestMode(for: mode, offered: offered)
    }
}
