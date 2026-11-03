// AB-McHZ na barra de menus: o título é a taxa de atualização das telas em texto (ex.: "60Hz").
// O menu tem brilho por DDC, resolução/taxa (com o watchdog do HetzCore) e os presets dos perfis.
import AppKit
import HetzCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = DisplayEngine()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var displays: [DisplayInfo] = []
    private var edids: [CGDirectDisplayID: EDID] = [:]
    private var profiles: [Profile] = []
    private var lastResult: String?
    private var busy = false
    private var pendingBrightness: [CGDirectDisplayID: UInt16] = [:]
    private var writingBrightness: Set<CGDirectDisplayID> = []
    private var repairedEDID: Set<CGDirectDisplayID> = []
    private var lastRepairAttempt: [CGDirectDisplayID: ContinuousClock.Instant] = [:]
    private var autoRepairEDID: Bool {
        get { UserDefaults.standard.object(forKey: "autoRepairEDID") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRepairEDID") }
    }
    /// PRO. Preset padrão só uma vez por conexão (não desfaz o slider de brilho a cada minuto);
    /// taxa não é corrigida na tela em que o usuário escolheu um modo à mão, até reconectar.
    private var optimizedConnection: Set<CGDirectDisplayID> = []
    private var manualMode: Set<CGDirectDisplayID> = []
    private var autoOptimize: Bool {
        get { UserDefaults.standard.object(forKey: "autoOptimize") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoOptimize") }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "AB-McHZ")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "…"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        CGDisplayRegisterReconfigurationCallback(displaysChanged, nil)
        // O EDID virtual some no sleep: ao acordar e a cada minuto, refresh() reaplica se preciso.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshClicked), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshClicked), name: NSWorkspace.screensDidWakeNotification, object: nil)
        Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refreshClicked), userInfo: nil, repeats: true)
        Task { await refresh() }
    }

    func refresh() async {
        displays = await engine.refresh().filter { !$0.isVirtual }
        for display in displays where display.hasDDC && edids[display.id] == nil {
            edids[display.id] = try? await engine.edid(for: display.id)
        }
        profiles = Profile.loadAll(in: profilesDirectory)
        updateTitle()
        await repairMissingEDIDs()
        await optimizeDisplays()
    }

    private func optimizeDisplays() async {
        let online = Set(displays.map(\.id))
        optimizedConnection.formIntersection(online)
        manualMode.formIntersection(online)
        guard autoOptimize, !busy, Licensing.current.allows(.autoOptimize) else { return }
        for display in displays where !display.isBuiltin && !display.isMissingEDID {
            guard let profile = profiles.first(where: { $0.matches(edid: edids[display.id], name: display.name) }) else { continue }
            let firstTime = !optimizedConnection.contains(display.id)
            busy = true
            let report = await engine.optimize(profile, on: display.id, fixRefresh: !manualMode.contains(display.id), applyDefaultPreset: firstTime)
            busy = false
            optimizedConnection.insert(display.id)
            let changed = switch report.mode { case .success(.alreadyActive), nil: false; default: true }
            if firstTime || changed { lastResult = "\(profile.monitor.model): \(report.summary)" }
        }
        displays = await engine.displays.filter { !$0.isVirtual }
        updateTitle()
    }

    /// Tela sem EDID no macOS cujo EDID só tem o cabeçalho corrompido: entrega a cópia corrigida ao DCP.
    /// No máximo uma tentativa por tela a cada 60 s, para não insistir num monitor que não se corrige.
    private func repairMissingEDIDs() async {
        guard autoRepairEDID else { return }
        for display in displays where display.isMissingEDID && display.hasDDC {
            let now = ContinuousClock.now
            if let last = lastRepairAttempt[display.id], last.duration(to: now) < .seconds(60) { continue }
            lastRepairAttempt[display.id] = now
            do {
                let outcome = try await engine.repairEDID(on: display.id)
                switch outcome {
                case .repaired:
                    repairedEDID.insert(display.id)
                    lastResult = "EDID: \(outcome)"
                    displays = await engine.displays.filter { !$0.isVirtual }
                    updateTitle()
                case .injectedWithoutEffect:
                    lastResult = "EDID: \(outcome)"
                case .notNeeded, .notRepairable:
                    break
                }
            } catch {
                lastResult = "EDID: \(error)"
            }
        }
    }

    private var profilesDirectory: URL {
        ProcessInfo.processInfo.environment["ABMCHZ_PROFILES"].map { URL(fileURLWithPath: $0) } ?? Profile.directory
    }

    /// Só as externas quando houver alguma (é delas que se quer saber a taxa); senão a interna.
    private func updateTitle() {
        guard !busy else { return }
        let externals = displays.filter { !$0.isBuiltin }
        let rates = (externals.isEmpty ? displays : externals).compactMap(\.currentMode?.hz).filter { $0 > 0 }
        statusItem.button?.title = rates.isEmpty ? "—" : rates.map { "\($0)Hz" }.joined(separator: " · ")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if displays.isEmpty { menu.addItem(info("Nenhuma tela")) }
        for (index, display) in displays.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            addSection(for: display, to: menu)
        }
        menu.addItem(.separator())
        if let lastResult {
            menu.addItem(info(lastResult))
            menu.addItem(.separator())
        }
        let repair = action("Corrigir EDID com cabeçalho corrompido", #selector(toggleAutoRepair))
        repair.state = autoRepairEDID ? .on : .off
        repair.toolTip = "Entrega ao macOS o EDID do monitor com o byte 0 corrigido. Desligar devolve o EDID original."
        menu.addItem(repair)
        let edition = Licensing.current
        let optimize = action("Otimização automática por monitor (PRO)", #selector(toggleAutoOptimize))
        optimize.state = autoOptimize ? .on : .off
        optimize.isEnabled = edition.allows(.autoOptimize)
        optimize.toolTip = "Ao conectar ou acordar: taxa máxima do perfil, perfil de cor e o preset padrão uma vez por conexão."
        menu.addItem(optimize)
        menu.addItem(info(edition.description))
        if case .pro = edition {} else { menu.addItem(action("Ativar AB-McHZ PRO…", #selector(activateClicked))) }
        menu.addItem(action("Atualizar telas", #selector(refreshClicked)))
        menu.addItem(action("Sair do AB-McHZ", #selector(quitClicked), key: "q"))
    }

    private func addSection(for display: DisplayInfo, to menu: NSMenu) {
        let edid = edids[display.id]
        menu.addItem(.sectionHeader(title: display.name ?? edid?.displayName ?? "Tela \(display.id)"))
        menu.addItem(info(display.currentMode.map(title(for:)) ?? "modo desconhecido"))
        if display.isMissingEDID {
            menu.addItem(info("macOS sem EDID desta tela: só o modo atual é seguro"))
        } else if repairedEDID.contains(display.id) {
            menu.addItem(info("EDID corrigido pelo AB-McHZ (virtual, reaplicado a cada replug)"))
        }
        if display.hasDDC {
            let view = BrightnessView { [weak self] value in self?.brightnessChanged(value, on: display.id) }
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            Task {
                do { view.show(try await engine.readVCP(0x10, on: display.id)) } catch { view.showError("\(error)") }
            }
        }
        menu.addItem(modesItem(for: display))
        if let presets = presetsItem(for: display, edid: edid) { menu.addItem(presets) }
    }

    private func modesItem(for display: DisplayInfo) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for mode in engine.modes(for: display.id) {
            let item = action(title(for: mode) + (mode.isSafe ? "" : " — não seguro"), #selector(modeClicked(_:)))
            item.representedObject = ModeChoice(display: display, mode: mode)
            item.state = display.currentMode?.sameMode(as: mode) == true ? .on : .off
            item.isEnabled = !busy
            item.toolTip = mode.isSafe ? nil : "Sem SafeFlag: tenta pelo número do modo, com watchdog e confirmação de 15 s."
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Resolução e taxa", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func presetsItem(for display: DisplayInfo, edid: EDID?) -> NSMenuItem? {
        let matching = profiles.filter { $0.matches(edid: edid, name: display.name) }
        guard !matching.isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let allowed = Licensing.current.allows(.presets)
        if !allowed { submenu.addItem(info("Presets são recurso PRO")) }
        for profile in matching {
            if matching.count > 1 { submenu.addItem(.sectionHeader(title: profile.monitor.model)) }
            for name in profile.presets.keys.sorted() {
                let preset = profile.presets[name]!
                let item = action(name + (preset.isDefault ? " (padrão)" : ""), #selector(presetClicked(_:)))
                item.representedObject = PresetChoice(display: display.id, profile: profile, preset: name)
                item.toolTip = preset.requires.map { "Requer: \($0)" }
                item.isEnabled = !busy && allowed
                submenu.addItem(item)
            }
        }
        let parent = NSMenuItem(title: allowed ? "Preset" : "Preset (PRO)", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func title(for mode: ModeInfo) -> String {
        "\(mode.width)×\(mode.height) · \(mode.hz) Hz\(mode.isHiDPI ? " HiDPI" : "")"
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text.count > 72 ? text.prefix(71) + "…" : text, action: nil, keyEquivalent: "")
        item.toolTip = text
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Ações

    @objc private func modeClicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeChoice else { return }
        manualMode.insert(choice.display.id)
        let display = choice.display, mode = choice.mode
        run("Modo") { [weak self] engine in
            let outcome = try await engine.switchMode(display.id, to: spec(mode), hiDPI: mode.isHiDPI, allowUnsafe: !mode.isSafe)
            switch outcome {
            case .reverted where display.isMissingEDID:
                return "\(outcome) · \(DisplayInfo.missingEDIDHint)"
            case .applied where !mode.isSafe:
                // O watchdog só vê o lado do macOS; se o monitor ficou sem imagem, ninguém confirma e volta sozinho.
                guard let previous = display.currentMode, self?.confirmKeep(mode, previous: previous) == false else { break }
                let back = try await engine.switchMode(display.id, to: spec(previous), hiDPI: previous.isHiDPI, allowUnsafe: true)
                return "não confirmado; \(back)"
            default:
                break
            }
            return outcome.description
        }
    }

    private func confirmKeep(_ mode: ModeInfo, previous: ModeInfo) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Manter \(title(for: mode))?"
        alert.informativeText = "Sem resposta em 15 s, volta para \(title(for: previous))."
        alert.addButton(withTitle: "Manter")
        alert.addButton(withTitle: "Voltar")
        let timer = Timer(timeInterval: 15, repeats: false) { _ in MainActor.assumeIsolated { NSApp.abortModal() } }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate()
        defer { timer.invalidate() }
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func activateClicked() {
        let alert = NSAlert()
        alert.messageText = "Ativar AB-McHZ PRO"
        alert.informativeText = "Cole a chave de licença (começa com ABMCHZ-PRO.)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Ativar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            lastResult = "PRO ativado para \(try Licensing.activate(field.stringValue).owner)"
        } catch {
            lastResult = "PRO: \(error)"
        }
    }

    @objc private func presetClicked(_ sender: NSMenuItem) {
        guard Licensing.current.allows(.presets) else { return }
        guard let choice = sender.representedObject as? PresetChoice, let plan = try? choice.profile.plan(for: choice.preset) else { return }
        run("Preset \(choice.preset)") { engine in
            let report = await engine.apply(plan, to: choice.display)
            let written = report.ddc.filter { (try? $0.result.get()) != nil }.count
            var parts = report.ddc.isEmpty ? [] : ["DDC \(written)/\(report.ddc.count)"]
            switch report.modeAttempts.last?.result {
            case .success(let outcome): parts.append(outcome.description)
            case .failure(let error): parts.append("modo: \(error)")
            case nil: break
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Troca de modo leva os 6 s do watchdog: uma ação por vez, com "…" no título enquanto roda.
    private func run(_ label: String, _ work: @escaping (DisplayEngine) async throws -> String) {
        guard !busy else { return }
        busy = true
        statusItem.button?.title = "…"
        Task {
            do { lastResult = "\(label): \(try await work(engine))" } catch { lastResult = "\(label): \(error)" }
            busy = false
            await refresh()
        }
    }

    /// O slider dispara muito mais rápido que o DDC aguenta (≥ 50 ms por escrita): grava só o valor mais recente.
    private func brightnessChanged(_ value: UInt16, on id: CGDirectDisplayID) {
        pendingBrightness[id] = value
        guard writingBrightness.insert(id).inserted else { return }
        Task {
            while let next = pendingBrightness.removeValue(forKey: id) {
                do { try await engine.writeVCP(0x10, value: next, on: id) } catch { lastResult = "Brilho: \(error)" }
            }
            writingBrightness.remove(id)
        }
    }

    @objc private func refreshClicked() {
        Task { await refresh() }
    }

    @objc private func toggleAutoRepair() {
        autoRepairEDID.toggle()
        if autoRepairEDID {
            lastRepairAttempt = [:]
            Task { await refresh() }
            return
        }
        let repaired = repairedEDID
        repairedEDID = []
        Task {
            for id in repaired {
                do { try await engine.clearVirtualEDID(on: id) } catch { lastResult = "EDID: \(error)" }
            }
            lastResult = repaired.isEmpty ? nil : "EDID original devolvido ao macOS"
        }
    }

    @objc private func toggleAutoOptimize() {
        autoOptimize.toggle()
        if autoOptimize { Task { await refresh() } }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

private struct ModeChoice {
    let display: DisplayInfo
    let mode: ModeInfo
}

private func spec(_ mode: ModeInfo) -> DisplayModeSpec {
    DisplayModeSpec(width: mode.width, height: mode.height, hz: mode.hz)
}

private struct PresetChoice {
    let display: CGDirectDisplayID
    let profile: Profile
    let preset: String
}

/// Chamado pelo CoreGraphics a cada reconfiguração (troca de modo, hotplug); a fase "begin" é ignorada.
private func displaysChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Task { @MainActor in await (NSApp.delegate as? AppDelegate)?.refresh() }
}
