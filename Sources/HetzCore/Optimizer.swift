// PRO: otimização automática por monitor a partir do perfil medido (profiles/*.json).
// Ao conectar ou acordar: taxa mais alta que o perfil aceita e o link oferece (ex.: PG259QN 360 → 240 Hz,
// XL2430T 144 Hz na DP / 60 Hz na HDMI), perfil de cor do perfil (sRGB) e, uma vez por conexão, o DDC do preset padrão.
@preconcurrency import ColorSync  // as constantes kColorSync* são vars globais C, imutáveis na prática
import CoreGraphics
import Foundation

public struct OptimizeReport: Sendable {
    public var mode: Result<ModeSwitchOutcome, ModeError>?
    public var bestOffered: ModeInfo?
    public var colorProfile: Result<String, ColorProfileError>?
    public var ddc: [ApplyReport.DDCResult] = []

    public var summary: String {
        var parts: [String] = []
        switch mode {
        case .success(.alreadyActive(let info)): parts.append("taxa ok (\(info.hz) Hz)")
        case .success(let outcome): parts.append(outcome.description)
        case .failure(let error): parts.append("modo: \(error)")
        case nil: if bestOffered == nil { parts.append("nenhuma taxa do perfil oferecida") }
        }
        switch colorProfile {
        case .success(let name): parts.append("cor \(name)")
        case .failure(let error): parts.append("cor: \(error)")
        case nil: break
        }
        if !ddc.isEmpty {
            parts.append("DDC \(ddc.filter { (try? $0.result.get()) != nil }.count)/\(ddc.count)")
        }
        return parts.joined(separator: " · ")
    }
}

public enum Optimizer {
    /// Primeira taxa da ordem do perfil (`hz`, depois `fallbackHz`) que o link oferece como modo seguro.
    /// Modo sem SafeFlag fica de fora: otimização automática não arrisca tela preta.
    public static func bestMode(for mode: Profile.Mode, offered: [ModeInfo]) -> ModeInfo? {
        for hz in [mode.hz] + [mode.fallbackHz].compactMap(\.self) {
            let match = offered.first {
                $0.width == mode.width && $0.height == mode.height && $0.hz == hz
                    && $0.isSafe && $0.isUsableForDesktopGUI && $0.isHiDPI == (mode.hiDPI ?? false)
            }
            if let match { return match }
        }
        return nil
    }
}

extension DisplayEngine {
    /// `fixRefresh: false` quando o usuário escolheu um modo à mão nesta conexão: respeita a escolha.
    public func optimize(
        _ profile: Profile,
        on id: CGDirectDisplayID,
        fixRefresh: Bool = true,
        applyDefaultPreset: Bool,
        dryRun: Bool = false
    ) async -> OptimizeReport {
        var report = OptimizeReport()
        report.bestOffered = Optimizer.bestMode(for: profile.macos.mode, offered: modes(for: id))
        if fixRefresh, let best = report.bestOffered {
            let current = CGDisplayCopyDisplayMode(id).map(ModeInfo.init)
            if let current, current.sameMode(as: best) {
                report.mode = .success(.alreadyActive(current))
            } else if !dryRun {
                let spec = DisplayModeSpec(width: best.width, height: best.height, hz: best.hz)
                do throws(ModeError) {
                    report.mode = .success(try await switchMode(id, to: spec, hiDPI: best.isHiDPI))
                } catch {
                    report.mode = .failure(error)
                }
            }
        }
        if let name = profile.macos.colorProfile {
            report.colorProfile = dryRun ? ColorProfiles.check(name, on: id) : ColorProfiles.ensure(name, on: id)
        }
        if applyDefaultPreset, let preset = profile.defaultPresetName, let plan = try? profile.plan(for: preset), !dryRun {
            for write in plan.ddc {
                do {
                    report.ddc.append(.init(write: write, result: .success(try await setVCP(write.code, to: write.value, on: id))))
                } catch {
                    report.ddc.append(.init(write: write, result: .failure(error)))
                }
            }
        }
        return report
    }
}

public enum ColorProfileError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case noDisplayUUID
    case assignFailed
    case differs(current: String?, wanted: String)

    public var description: String {
        switch self {
        case .notFound(let name): "perfil ICC \"\(name)\" não encontrado nas pastas do ColorSync"
        case .noDisplayUUID: "tela sem UUID no ColorSync"
        case .assignFailed: "o ColorSync recusou o perfil"
        case .differs(let current, let wanted): "atual \(current ?? "—"), perfil pede \(wanted)"
        }
    }
}

enum ColorProfiles {
    static let folders = [
        "/System/Library/ColorSync/Profiles",
        "/Library/ColorSync/Profiles",
        NSHomeDirectory() + "/Library/ColorSync/Profiles",
    ]

    static func description(of url: URL) -> String? {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
    }

    static func url(named name: String) -> URL? {
        for folder in folders {
            let urls = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { ["icc", "icm"].contains($0.pathExtension.lowercased()) } ?? []
            if let match = urls.first(where: { description(of: $0) == name }) { return match }
        }
        return nil
    }

    static func current(on id: CGDirectDisplayID) -> String? {
        guard let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
    }

    static func check(_ name: String, on id: CGDirectDisplayID) -> Result<String, ColorProfileError> {
        let current = current(on: id)
        return current == name ? .success(name) : .failure(.differs(current: current, wanted: name))
    }

    /// Grava como perfil padrão da tela no escopo do usuário (o mesmo que Ajustes do Sistema > Telas > Perfil de cor).
    static func ensure(_ name: String, on id: CGDirectDisplayID) -> Result<String, ColorProfileError> {
        if current(on: id) == name { return .success(name) }
        guard let url = url(named: name) else { return .failure(.notFound(name)) }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return .failure(.noDisplayUUID) }
        let settings = [
            kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): url,
            kColorSyncProfileUserScope.takeUnretainedValue(): kCFPreferencesCurrentUser,
        ] as CFDictionary
        guard ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, settings) else {
            return .failure(.assignFailed)
        }
        return .success(name)
    }
}

extension Optimizer {
    /// Perfil de cor do perfil como padrão da tela (usado pela automação do app, uma vez por conexão).
    public static func ensureColorProfile(_ name: String, on id: CGDirectDisplayID) -> Result<String, ColorProfileError> {
        ColorProfiles.ensure(name, on: id)
    }
}
