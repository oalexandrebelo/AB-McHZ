// hetzctl: CLI do motor AB-McHZ.
import CoreGraphics
import CryptoKit
import Foundation
import HetzCore

let usage = """
uso: hetzctl <comando>
  list                                      telas, modo atual, canal DDC e EDID lido por I2C
  edid <tela> [--raw]                       EDID lido por I2C (0x50); --raw imprime os bytes
  edid-fix <tela>                           entrega ao DCP o EDID com o cabeçalho corrigido (volátil)
  edid-clear <tela>                         devolve ao DCP o EDID do próprio monitor
  get <tela> <vcp>                          lê um código VCP (0x10 = brilho)
  set <tela> <vcp> <valor> [--force]        grava um código VCP e confere a releitura (--force para entrada, energia, reset)
  modes <tela>                              modos que o macOS oferece para a tela
  mode <tela> LxA@Hz [--hidpi] [--force]    troca o modo com watchdog de 6 s
  apply <perfil.json> <preset> [--display <tela>] [--dry-run] [--force]   (PRO)
  optimize <tela> [--dry-run] [--preset]    (PRO) taxa máxima do perfil, perfil de cor e, com --preset, o DDC do preset padrão
  license                                   edição atual (livre, avaliação de 14 dias ou PRO)
  license activate <chave>                  ativa o AB-McHZ PRO com a chave de licença
  license issue <dono>                      emite chave (precisa de ~/.config/ab-mchz/licenca-ed25519.key)

<tela>: ID numérico (veja list), "main" ou parte do nome (ex.: benq).
<vcp>:  0x10 é hexadecimal; 16 é decimal.
--force: tenta modo sem kDisplayModeSafeFlag (o watchdog reverte se não pegar).
"""

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct HetzCtl {
    static func main() async {
        var positional: [String] = []
        var flags: Set<String> = []
        var display: String?
        var args = CommandLine.arguments.dropFirst()
        while let arg = args.popFirst() {
            if arg == "--display" { display = args.popFirst() }
            else if arg.hasPrefix("-") { flags.insert(arg) }
            else { positional.append(arg) }
        }
        if positional.isEmpty || flags.contains("--help") || flags.contains("-h") {
            print(usage)
            exit(positional.isEmpty && flags.isEmpty ? 64 : 0)
        }

        let engine = DisplayEngine()
        await engine.refresh()
        let cli = CLI(engine: engine, flags: flags)
        do {
            let command = positional.removeFirst()
            let status: Int32 = switch (command, positional.count) {
            case ("list", 0): await cli.list()
            case ("edid", 1): try await cli.edid(positional[0])
            case ("edid-fix", 1): try await cli.edidFix(positional[0])
            case ("edid-clear", 1): try await cli.edidClear(positional[0])
            case ("get", 2): try await cli.get(positional[0], positional[1])
            case ("set", 3): try await cli.set(positional[0], positional[1], positional[2])
            case ("modes", 1): try await cli.modes(positional[0])
            case ("mode", 2): try await cli.mode(positional[0], positional[1])
            case ("apply", 2): try await cli.apply(positional[0], positional[1], display: display)
            case ("optimize", 1): try await cli.optimize(positional[0])
            case ("license", 0): cli.license()
            case ("license", 2) where positional[0] == "activate": try cli.activate(positional[1])
            case ("license", 2) where positional[0] == "issue": try cli.issue(owner: positional[1])
            default: throw UsageError("comando ou número de argumentos inválido: \(([command] + positional).joined(separator: " "))")
            }
            exit(status)
        } catch let error as UsageError {
            fputs("erro: \(error)\n\n\(usage)\n", stderr)
            exit(64)
        } catch {
            fputs("erro: \(error)\n", stderr)
            exit(1)
        }
    }
}

struct CLI {
    let engine: DisplayEngine
    let flags: Set<String>

    func list() async -> Int32 {
        let displays = await engine.displays
        guard !displays.isEmpty else {
            print("nenhuma tela online")
            return 1
        }
        var notes: [String] = []
        print(row("ID", "TELA", "TIPO", "LIGAÇÃO", "MODO ATUAL", "DDC", "EDID (I2C)"))
        for display in displays {
            var edid: EDID?
            var edidText = "—"
            if display.hasDDC {
                do {
                    let read = try await engine.edid(for: display.id)
                    edid = read
                    edidText = "\(read.manufacturerID) 0x\(hex16(read.productCode)) \(read.serialText ?? String(read.serialNumber))"
                    if !read.issues.isEmpty { edidText += " (com defeito)" }
                } catch {
                    edidText = "falhou: \(error)"
                }
            }
            let kind = display.isBuiltin ? "interna" : display.isVirtual ? "virtual" : "externa"
            print(row(
                "\(display.id)\(display.isMain ? "*" : "")",
                display.name ?? edid?.displayName ?? "—",
                kind,
                display.transport ?? "—",
                display.currentMode?.description ?? "—",
                display.hasDDC ? "sim" : "não",
                edidText
            ))
            if display.isMissingEDID {
                notes.append("aviso: tela \(display.id) sem EDID no macOS (vendor 0): só o modo atual é seguro e trocas de modo são ignoradas.")
                if let edid, edid.issues.isEmpty {
                    notes.append("  o EDID lido por I2C é válido: refaça o hotplug (desligar/ligar o monitor).")
                } else if edid?.headerRepaired != nil {
                    notes.append("  corrigível: hetzctl edid-fix \(display.id) (EDID virtual no DCP; some no replug, sleep e reboot)")
                }
            }
            if let edid, !edid.issues.isEmpty {
                notes.append("aviso: EDID da tela \(display.id) lido por I2C tem defeito:")
                notes += edid.issues.map { "  - \($0)" }
            }
        }
        if !notes.isEmpty { print("\n" + notes.joined(separator: "\n")) }
        return 0
    }

    func edid(_ query: String) async throws -> Int32 {
        let display = try await engine.resolve(query)
        let edid = try await engine.edid(for: display.id, refresh: true)
        print("tela \(display.id) · EDID por I2C (\(edid.bytes.count) bytes, versão \(edid.version))")
        print("  fabricante  \(edid.manufacturerID) (0x\(hex16(UInt16(edid.vendorNumber))))")
        print("  produto     0x\(hex16(edid.productCode))")
        print("  série       \(edid.serialText ?? "—") (número \(edid.serialNumber))")
        print("  nome        \(edid.displayName ?? "—")")
        print("  ano         \(edid.yearOfManufacture)")
        print("  extensões   \(edid.extensionCount)")
        print("  macOS       vendor \(display.vendor) model \(display.model)\(display.isMissingEDID ? " → o macOS não tem o EDID desta tela" : "")")
        if edid.issues.isEmpty {
            print("  integridade ok")
        } else {
            print("  defeitos")
            edid.issues.forEach { print("    - \($0)") }
        }
        if flags.contains("--raw") {
            for offset in stride(from: 0, to: edid.bytes.count, by: 16) {
                let line = edid.bytes[offset..<min(offset + 16, edid.bytes.count)].map { String(format: "%02x", $0) }
                print(String(format: "  %04x  ", offset) + line.joined(separator: " "))
            }
        }
        return 0
    }

    func edidFix(_ query: String) async throws -> Int32 {
        let display = try await engine.resolve(query)
        let outcome = try await engine.repairEDID(on: display.id)
        print("tela \(display.id) · \(outcome)")
        switch outcome {
        case .repaired, .notNeeded:
            let mode = CGDisplayCopyDisplayMode(display.id)
            print("  modo atual \(mode.map { "\($0.width)x\($0.height)@\(Int($0.refreshRate.rounded()))Hz" } ?? "—")")
            return 0
        case .notRepairable, .injectedWithoutEffect:
            return 1
        }
    }

    func edidClear(_ query: String) async throws -> Int32 {
        let display = try await engine.resolve(query)
        try await engine.clearVirtualEDID(on: display.id)
        print("tela \(display.id) · EDID do monitor devolvido ao DCP")
        return 0
    }

    func get(_ query: String, _ vcp: String) async throws -> Int32 {
        let code = try parseVCP(vcp)
        let display = try await engine.resolve(query)
        let value = try await engine.readVCP(code, on: display.id)
        print("tela \(display.id) · VCP \(MCCS.format(code)) = \(value.current) (máx \(value.maximum))")
        return 0
    }

    func set(_ query: String, _ vcp: String, _ text: String) async throws -> Int32 {
        let code = try parseVCP(vcp)
        guard let value = UInt16(text) else { throw UsageError("valor inválido: \(text) (0–65535)") }
        guard MCCS.safeCodes.contains(code) || flags.contains("--force") else {
            throw UsageError("VCP \(MCCS.format(code)) pode tirar a imagem ou resetar o monitor (entrada, energia, reset); repita com --force")
        }
        let display = try await engine.resolve(query)
        let after = try await engine.setVCP(code, to: value, on: display.id)
        print("tela \(display.id) · VCP \(MCCS.format(code)) = \(after.current) (máx \(after.maximum))")
        if after.current != value {
            print("aviso: a releitura (\(after.current)) difere do valor gravado (\(value))")
        }
        return 0
    }

    func modes(_ query: String) async throws -> Int32 {
        let display = try await engine.resolve(query)
        let current = display.currentMode
        let modes = engine.modes(for: display.id)
        print("tela \(display.id) · \(modes.count) modos (* = atual)")
        for mode in modes {
            print("  \(current?.sameMode(as: mode) == true ? "*" : " ") \(mode)")
        }
        return 0
    }

    func mode(_ query: String, _ text: String) async throws -> Int32 {
        guard let spec = DisplayModeSpec(text) else { throw UsageError("modo inválido: \(text) (formato LxA@Hz, ex.: 1920x1080@60)") }
        let display = try await engine.resolve(query)
        return try await switchMode(display, to: spec, hiDPI: flags.contains("--hidpi"))
    }

    func optimize(_ query: String) async throws -> Int32 {
        let display = try await engine.resolve(query)
        let edid = display.hasDDC ? try? await engine.edid(for: display.id) : nil
        let folder = ProcessInfo.processInfo.environment["ABMCHZ_PROFILES"].map { URL(fileURLWithPath: $0) } ?? Profile.directory
        guard let profile = Profile.loadAll(in: folder).first(where: { $0.matches(edid: edid, name: display.name) }) else {
            throw UsageError("nenhum perfil em \(folder.path) corresponde à tela \(display.id) (\(display.name ?? "—"))")
        }
        let dryRun = flags.contains("--dry-run")
        if !dryRun {
            let edition = Licensing.current
            guard edition.allows(.autoOptimize) else {
                fputs("erro: \(ProFeature.autoOptimize.rawValue) é recurso PRO. \(edition)\n", stderr)
                return 2
            }
        }
        print("perfil \(profile.id) → tela \(display.id) (\(display.name ?? profile.monitor.model))\(dryRun ? " · simulação" : "")")
        let report = await engine.optimize(profile, on: display.id, applyDefaultPreset: flags.contains("--preset"), dryRun: dryRun)
        print("  modo atual    \(display.currentMode?.description ?? "—")")
        print("  melhor modo   \(report.bestOffered?.description ?? "nenhuma taxa do perfil (\(profile.macos.mode.hz)/\(profile.macos.mode.fallbackHz.map(String.init) ?? "—") Hz) é oferecida como segura")")
        if dryRun, let preset = profile.defaultPresetName, let plan = try? profile.plan(for: preset) {
            print("  preset padrão \(preset): \(plan.ddc.map { "\(MCCS.format($0.code))=\($0.value)" }.joined(separator: " "))")
        }
        print("  resultado     \(report.summary.isEmpty ? "nada a fazer" : report.summary)")
        return 0
    }

    func license() -> Int32 {
        let edition = Licensing.current
        print(edition)
        if case .free = edition { print("recursos PRO: " + ProFeature.allCases.map(\.rawValue).joined(separator: ", ")) }
        return 0
    }

    func activate(_ key: String) throws -> Int32 {
        let license = try Licensing.activate(key)
        print("AB-McHZ PRO ativado para \(license.owner)")
        return 0
    }

    func issue(owner: String) throws -> Int32 {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/ab-mchz/licenca-ed25519.key")
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UsageError("chave privada não encontrada em \(path.path)")
        }
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        guard signer.publicKey.rawRepresentation.base64EncodedString() == LicenseKey.embeddedPublicKey else {
            throw UsageError("a chave privada em \(path.path) não corresponde à chave pública embutida no AB-McHZ")
        }
        print(try LicenseKey.issue(owner: owner, privateKey: signer))
        return 0
    }

    func apply(_ path: String, _ presetName: String, display query: String?) async throws -> Int32 {
        let profile = try Profile.load(from: URL(fileURLWithPath: path))
        let plan = try profile.plan(for: presetName)
        let display = if let query { try await engine.resolve(query) } else { try await match(profile) }

        print("perfil \(plan.profileID) · preset \(plan.preset) → tela \(display.id) (\(display.name ?? profile.monitor.model))")
        if let requires = plan.requires { print("  requer  \(requires)") }
        let fallback = plan.fallbackHz.map { " (alternativa \($0) Hz)" } ?? ""
        print("  modo    \(plan.mode)\(plan.hiDPI ? " HiDPI" : "")\(fallback) · atual \(display.currentMode?.description ?? "—")")
        print("  DDC     \(plan.ddc.isEmpty ? "—" : plan.ddc.map { "\(MCCS.format($0.code))=\($0.value)" }.joined(separator: " "))")
        if flags.contains("--dry-run") { return 0 }
        let edition = Licensing.current
        guard edition.allows(.presets) else {
            fputs("erro: \(ProFeature.presets.rawValue) é recurso PRO. \(edition)\n", stderr)
            return 2
        }

        print("  aplicando (troca de modo com watchdog de 6 s)…")
        let report = await engine.apply(plan, to: display.id, allowUnsafe: flags.contains("--force"))
        for attempt in report.modeAttempts {
            switch attempt.result {
            case .success(let outcome): print("  modo \(attempt.spec): \(outcome)")
            case .failure(let error): print("  modo \(attempt.spec): \(error)")
            }
        }
        for item in report.ddc {
            switch item.result {
            case .success(let after):
                let mismatch = after.current == item.write.value ? "" : "  (releitura difere de \(item.write.value))"
                print("  DDC \(MCCS.format(item.write.code)) = \(after.current)\(mismatch)")
            case .failure(let error):
                print("  DDC \(MCCS.format(item.write.code)): \(error)")
            }
        }
        return report.exitStatus
    }

    private func switchMode(_ display: DisplayInfo, to spec: DisplayModeSpec, hiDPI: Bool) async throws -> Int32 {
        print("tela \(display.id): \(display.currentMode?.description ?? "—") → \(spec) (watchdog 6 s)")
        let outcome = try await engine.switchMode(display.id, to: spec, hiDPI: hiDPI, allowUnsafe: flags.contains("--force"))
        print(outcome)
        guard case .reverted = outcome else { return 0 }
        if display.isMissingEDID { print("dica: \(DisplayInfo.missingEDIDHint)") }
        return 2
    }

    private func match(_ profile: Profile) async throws -> DisplayInfo {
        var hits: [DisplayInfo] = []
        for display in await engine.displays where !display.isVirtual {
            var edid: EDID?
            if display.hasDDC { edid = try? await engine.edid(for: display.id) }
            if profile.matches(edid: edid, name: display.name) { hits.append(display) }
        }
        guard hits.count == 1 else {
            throw UsageError(hits.isEmpty
                ? "nenhuma tela corresponde a \(profile.monitor.model); indique com --display"
                : "mais de uma tela corresponde a \(profile.monitor.model); indique com --display")
        }
        return hits[0]
    }

    private func parseVCP(_ text: String) throws -> UInt8 {
        guard let code = MCCS.parseCode(text) else { throw UsageError("código VCP inválido: \(text) (ex.: 0x10)") }
        return code
    }

    private func row(_ columns: String...) -> String {
        let widths = [6, 22, 8, 9, 26, 4]
        return zip(columns, widths + [0]).map { $1 == 0 ? $0 : $0.padding(toLength: max($1, $0.count), withPad: " ", startingAt: 0) }
            .joined(separator: " ")
    }

    private func hex16(_ value: UInt16) -> String {
        String(format: "%04X", value)
    }
}
