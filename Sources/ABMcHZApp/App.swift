// AB-McHZ na barra de menus: o título é a taxa de atualização das telas em texto (ex.: "60Hz").
// O menu tem brilho por DDC, resolução/taxa (com o watchdog do HetzCore) e os presets dos perfis.
// PRO: automação por monitor (AutoPilot): taxa, perfil de cor e presets por app, por horário ou padrão; atalhos ⌃⌥⌘1–9.
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
    private var pilot = AutoPilot()
    private var hotKeys: HotKeys?
    private let settings = AppSettings()
    private let settingsWindow = SettingsWindow()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let migrated = LegacyInstall.migrate()
        if !migrated.isEmpty { lastResult = "Instalação antiga: " + migrated.joined(separator: " · ") }
        // Duas cópias disputariam o barramento I2C e brigariam pela taxa: a mais nova sai.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "AB-McHZ")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "…"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        CGDisplayRegisterReconfigurationCallback(displaysChanged, nil)
        let center = NSWorkspace.shared.notificationCenter
        // O EDID virtual some no sleep e o macOS pode acordar em 60 Hz: ao acordar, a automação pode corrigir a taxa.
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refreshClicked), userInfo: nil, repeats: true)
        hotKeys = HotKeys { [weak self] index in self?.hotKeyPressed(index) }
        settings.onAutoRepairChange = { [weak self] on in self?.autoRepairChanged(on) }
        settings.onAutoOptimizeChange = { [weak self] on in if on { Task { await self?.refresh(.connectOrWake) } } }
        settings.onCheckUpdatesChange = { [weak self] on in if on { Task { await self?.checkForUpdate() } } }
        settings.onEditionChange = { [weak self] in Task { await self?.refresh(.connectOrWake) } }
        settings.registerLoginItemOnFirstLaunch()
        Timer.scheduledTimer(timeInterval: 6 * 3600, target: self, selector: #selector(updateTimerFired), userInfo: nil, repeats: true)
        Task {
            await refresh(.connectOrWake)
            await checkForUpdate(ifDueOnly: true)
        }
    }

    /// Abrir o app de novo (Finder, Spotlight, Launchpad) com ele já na barra de menus mostra os Ajustes.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsClicked()
        return false
    }

    /// Uma consulta por dia à última release do GitHub; "Procurar agora" ignora o intervalo.
    func checkForUpdate(ifDueOnly: Bool = false) async {
        let defaults = UserDefaults.standard
        if ifDueOnly {
            guard settings.checkUpdates else { return }
            if let last = defaults.object(forKey: "lastUpdateCheck") as? Date, Date.now.timeIntervalSince(last) < 86_400 { return }
        }
        guard let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") else { return }
        defaults.set(Date.now, forKey: "lastUpdateCheck")
        settings.availableUpdate = await UpdateCheck.fetch(current: current)
    }

    @objc private func updateTimerFired() {
        Task { await checkForUpdate(ifDueOnly: true) }
    }

    func refresh(_ trigger: PilotTrigger = .tick) async {
        displays = await engine.refresh().filter { !$0.isVirtual }
        for display in displays where display.hasDDC && edids[display.id] == nil {
            edids[display.id] = try? await engine.edid(for: display.id)
        }
        profiles = Profile.loadAll(in: Profile.searchDirectories)
        updateTitle()
        await repairMissingEDIDs()
        await automate(trigger)
    }

    private func profile(for display: DisplayInfo) -> Profile? {
        profiles.first { $0.matches(edid: edids[display.id], name: display.name) }
    }

    /// PRO. Regras em HetzCore/AutoPilot.swift: preset na borda (app > agenda > padrão), taxa só ao conectar/acordar
    /// ou quando o preset muda o alvo, modo revertido não é repetido, cor uma vez por conexão.
    private func automate(_ trigger: PilotTrigger) async {
        let fresh = pilot.observe(displays.map(\.key), now: .now)
        let edition = Licensing.current
        guard settings.autoOptimize, !busy, edition.allows(.autoOptimize) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        busy = true
        for display in displays where !display.isBuiltin && !display.isMissingEDID {
            guard let profile = profile(for: display) else { continue }
            let key = display.key
            var notes: [String] = []

            let mapping = edition.allows(.automation) ? settings.appPresets[profile.id] ?? [:] : [:]
            let desired = AutoPilot.desiredPreset(profile, frontmostApp: frontmost, appPresets: mapping, now: .now)
            if let desired, pilot.shouldApply(key, desired: desired), let plan = try? profile.plan(for: desired.name) {
                var succeeded = true
                for write in plan.ddc {
                    do { _ = try await engine.setVCP(write.code, to: write.value, on: display.id) } catch { succeeded = false }
                }
                pilot.recordAutomaticPreset(key, desired: desired, succeeded: succeeded)
                notes.append("preset \(desired.name) (\(desired.reason.rawValue))\(succeeded ? "" : ", DDC falhou")")
            }

            let target = Optimizer.target(profile, preset: pilot.activePreset(key), offered: engine.modes(for: display.id))
            let current = CGDisplayCopyDisplayMode(display.id).map(ModeInfo.init)
            let effective: PilotTrigger = fresh.contains(key) ? .connectOrWake : trigger
            if case .switchTo(let mode) = pilot.refreshDecision(key, current: current, target: target, trigger: effective) {
                let spec = DisplayModeSpec(width: mode.width, height: mode.height, hz: mode.hz)
                let result: Result<ModeSwitchOutcome, ModeError>
                do throws(ModeError) {
                    result = .success(try await engine.switchMode(display.id, to: spec, hiDPI: mode.isHiDPI))
                } catch {
                    result = .failure(error)
                }
                pilot.recordSwitch(key, target: mode, result: result)
                switch result {
                case .success(let outcome): notes.append(outcome.description)
                case .failure(let error): notes.append("modo: \(error)")
                }
            }

            if pilot.needsColor(key), let name = profile.macos.colorProfile {
                pilot.recordColor(key)
                switch Optimizer.ensureColorProfile(name, on: display.id) {
                case .success: notes.append("cor \(name)")
                case .failure(let error): notes.append("cor: \(error)")
                }
            }
            if !notes.isEmpty { lastResult = "\(profile.monitor.model): " + notes.joined(separator: " · ") }
        }
        busy = false
        displays = await engine.displays.filter { !$0.isVirtual }
        updateTitle()
    }

    /// Tela sem EDID no macOS cujo EDID só tem o cabeçalho corrompido: entrega a cópia corrigida ao DCP.
    /// No máximo `AutoPilot.maxRepairAttempts` por conexão (cada tentativa retreina o link e a tela pisca).
    private func repairMissingEDIDs() async {
        guard settings.autoRepairEDID, !busy else { return }
        pilot.observe(displays.map(\.key), now: .now)
        for display in displays where display.isMissingEDID && display.hasDDC && pilot.mayRepairEDID(display.key) {
            pilot.recordRepairAttempt(display.key)
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
        if let update = settings.availableUpdate {
            menu.addItem(action("Baixar versão \(update.version)…", #selector(updateClicked)))
            menu.addItem(.separator())
        }
        let repair = action("Corrigir EDID com cabeçalho corrompido", #selector(toggleAutoRepair))
        repair.state = settings.autoRepairEDID ? .on : .off
        repair.toolTip = "Entrega ao macOS o EDID do monitor com o byte 0 corrigido. Desligar devolve o EDID original."
        menu.addItem(repair)
        let edition = Licensing.current
        let optimize = action("Automação por monitor (PRO)", #selector(toggleAutoOptimize))
        optimize.state = settings.autoOptimize ? .on : .off
        optimize.isEnabled = edition.allows(.autoOptimize)
        optimize.toolTip = "Taxa máxima ao conectar/acordar, perfil de cor uma vez por conexão e presets por app, por horário ou padrão."
        menu.addItem(optimize)
        menu.addItem(info(edition.description))
        if case .pro = edition {} else { menu.addItem(action("Ativar AB-McHZ PRO…", #selector(settingsClicked))) }
        menu.addItem(.separator())
        menu.addItem(action("Atualizar telas", #selector(refreshClicked)))
        menu.addItem(action("Ajustes…", #selector(settingsClicked), key: ","))
        menu.addItem(action("Sobre o AB-McHZ", #selector(aboutClicked)))
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
        if let presets = presetsItem(for: display) { menu.addItem(presets) }
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

    private func presetsItem(for display: DisplayInfo) -> NSMenuItem? {
        guard let profile = profile(for: display) else { return nil }
        let edition = Licensing.current
        let allowed = edition.allows(.presets)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if !allowed { submenu.addItem(info("Presets são recurso PRO")) }
        let active = pilot.activePreset(display.key)
        for (index, name) in profile.presets.keys.sorted().enumerated() {
            let preset = profile.presets[name]!
            var label = name + (preset.isDefault ? " (padrão)" : "")
            if let schedule = preset.schedule { label += " · \(clock(schedule.start))–\(clock(schedule.end))" }
            let item = action(label, #selector(presetClicked(_:)))
            item.representedObject = PresetChoice(display: display, profile: profile, preset: name)
            item.toolTip = preset.requires.map { "Requer: \($0)" }
            item.state = name == active ? .on : .off
            item.isEnabled = !busy && allowed
            if index < 9, edition.allows(.hotkeys) {
                item.keyEquivalent = String(index + 1)
                item.keyEquivalentModifierMask = HotKeys.modifiers
            }
            submenu.addItem(item)
        }
        if let app = NSWorkspace.shared.frontmostApplication, app != .current, let bundleID = app.bundleIdentifier {
            submenu.addItem(.separator())
            let current = settings.appPresets[profile.id]?[bundleID]
            let parent = NSMenuItem(title: "Com \(app.localizedName ?? bundleID): \(current ?? "nenhum")", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            choices.autoenablesItems = false
            for name in [nil] + profile.presets.keys.sorted().map(Optional.some) {
                let item = action(name ?? "Nenhum", #selector(appPresetClicked(_:)))
                item.representedObject = AppPresetChoice(profileID: profile.id, bundleID: bundleID, preset: name)
                item.state = name == current ? .on : .off
                item.isEnabled = edition.allows(.automation)
                choices.addItem(item)
            }
            parent.submenu = choices
            parent.toolTip = "Preset aplicado sempre que este app vier para a frente (PRO)."
            submenu.addItem(parent)
        }
        let parent = NSMenuItem(title: allowed ? "Preset" : "Preset (PRO)", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func title(for mode: ModeInfo) -> String {
        "\(mode.width)×\(mode.height) · \(mode.hz) Hz\(mode.isHiDPI ? " HiDPI" : "")"
    }

    private func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
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
        let display = choice.display, mode = choice.mode
        run("Modo") { [weak self] engine in
            // Modo inseguro só vira permanente depois que o usuário confirma que há imagem.
            let outcome = try await engine.switchMode(display.id, to: spec(mode), hiDPI: mode.isHiDPI, allowUnsafe: !mode.isSafe, commit: mode.isSafe)
            switch outcome {
            case .reverted where display.isMissingEDID:
                return "\(outcome) · \(DisplayInfo.missingEDIDHint)"
            case .applied(let observed) where !mode.isSafe:
                // O watchdog só vê o lado do macOS; se o monitor ficou sem imagem, ninguém confirma e volta sozinho.
                guard let previous = display.currentMode, self?.confirmKeep(mode, previous: previous) == false else {
                    engine.commitCurrentMode(display.id)
                    self?.pilot.recordUserMode(display.key, mode: observed)
                    break
                }
                let back = try await engine.switchMode(display.id, to: spec(previous), hiDPI: previous.isHiDPI, allowUnsafe: true)
                return "não confirmado; \(back)"
            case .applied(let observed), .alreadyActive(let observed):
                self?.pilot.recordUserMode(display.key, mode: observed)
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

    @objc private func settingsClicked() {
        settingsWindow.show(settings) { [weak self] in await self?.checkForUpdate() }
    }

    @objc private func aboutClicked() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Uso pessoal e não comercial · PolyForm Noncommercial 1.0.0\ngithub.com/oalexandrebelo/AB-McHZ"),
        ])
    }

    @objc private func updateClicked() {
        if let page = settings.availableUpdate?.page { NSWorkspace.shared.open(page) }
    }

    @objc private func presetClicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PresetChoice else { return }
        applyPreset(choice.preset, of: choice.profile, on: choice.display)
    }

    /// Preset escolhido no menu ou por atalho: modo do preset (ex.: ULMB a 240 Hz) e DDC; vale até o preset
    /// automático desejado mudar (outro app, outro horário).
    private func applyPreset(_ name: String, of profile: Profile, on display: DisplayInfo) {
        guard Licensing.current.allows(.presets), let plan = try? profile.plan(for: name) else { return }
        run("Preset \(name)") { [weak self] engine in
            self?.pilot.recordManualPreset(display.key, name: name)
            let report = await engine.apply(plan, to: display.id)
            let written = report.ddc.filter { (try? $0.result.get()) != nil }.count
            var parts = report.ddc.isEmpty ? [] : ["DDC \(written)/\(report.ddc.count)"]
            switch report.modeAttempts.last?.result {
            case .success(let outcome): parts.append(outcome.description)
            case .failure(let error): parts.append("modo: \(error)")
            case nil: break
            }
            if let requires = plan.requires { parts.append("requer \(requires)") }
            return parts.joined(separator: " · ")
        }
    }

    @objc private func appPresetClicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AppPresetChoice, Licensing.current.allows(.automation) else { return }
        var all = settings.appPresets
        all[choice.profileID, default: [:]][choice.bundleID] = choice.preset
        settings.appPresets = all
    }

    private func hotKeyPressed(_ index: Int) {
        guard Licensing.current.allows(.hotkeys), !busy else { return }
        for display in displays where !display.isBuiltin {
            guard let profile = profile(for: display) else { continue }
            let names = profile.presets.keys.sorted()
            if names.indices.contains(index - 1) { applyPreset(names[index - 1], of: profile, on: display) }
            break  // uma tela por atalho: o run() aceita uma ação por vez
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

    @objc private func didWake() {
        Task { await refresh(.connectOrWake) }
    }

    /// Troca de app não muda as telas: só reavalia os presets por app, sem varrer o IORegistry.
    @objc private func appActivated() {
        Task { await automate(.tick) }
    }

    @objc private func toggleAutoRepair() {
        settings.autoRepairEDID.toggle()
    }

    private func autoRepairChanged(_ on: Bool) {
        if on {
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
        settings.autoOptimize.toggle()
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
    let display: DisplayInfo
    let profile: Profile
    let preset: String
}

private struct AppPresetChoice {
    let profileID: String
    let bundleID: String
    let preset: String?
}

/// Chamado pelo CoreGraphics a cada reconfiguração (troca de modo, hotplug); a fase "begin" é ignorada.
private func displaysChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Task { @MainActor in await (NSApp.delegate as? AppDelegate)?.refresh() }
}
