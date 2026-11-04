// Preferências do app (UserDefaults do bundle) e a janela de Ajustes.
import AppKit
import HetzCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var autoRepairEDID: Bool { didSet { changed("autoRepairEDID", autoRepairEDID, onAutoRepairChange) } }
    @Published var autoOptimize: Bool { didSet { changed("autoOptimize", autoOptimize, onAutoOptimizeChange) } }
    @Published var checkUpdates: Bool { didSet { changed("checkUpdates", checkUpdates, onCheckUpdatesChange) } }
    @Published var edition = Licensing.current { didSet { if edition != oldValue { onEditionChange?() } } }
    @Published var availableUpdate: AvailableUpdate?

    var onAutoRepairChange: ((Bool) -> Void)?
    var onAutoOptimizeChange: ((Bool) -> Void)?
    var onCheckUpdatesChange: ((Bool) -> Void)?
    var onEditionChange: (() -> Void)?

    init() {
        autoRepairEDID = defaults.object(forKey: "autoRepairEDID") as? Bool ?? true
        autoOptimize = defaults.object(forKey: "autoOptimize") as? Bool ?? true
        checkUpdates = defaults.object(forKey: "checkUpdates") as? Bool ?? true
    }

    /// id do perfil → bundle id do app → preset.
    var appPresets: [String: [String: String]] {
        get { defaults.dictionary(forKey: "appPresets") as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: "appPresets") }
    }

    /// Na primeira execução o app se registra para abrir no login (como os outros apps de barra de menus);
    /// depois disso vale o que o usuário escolher em Ajustes ou em Ajustes do Sistema > Itens de Início.
    func registerLoginItemOnFirstLaunch() {
        guard !defaults.bool(forKey: "loginItemConfigured") else { return }
        defaults.set(true, forKey: "loginItemConfigured")
        try? SMAppService.mainApp.register()
    }

    private func changed(_ key: String, _ value: Bool, _ hook: ((Bool) -> Void)?) {
        defaults.set(value, forKey: key)
        hook?(value)
    }
}

/// `hetzctl` dentro do app, exposto no PATH por um link simbólico (como o comando `code` do VS Code).
enum CommandLineTool {
    static let systemLink = URL(fileURLWithPath: "/usr/local/bin/hetzctl")
    static let userLink = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/hetzctl")
    static var bundled: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS/hetzctl") }

    static var installedLink: URL? {
        [systemLink, userLink].first {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) == bundled.path
        }
    }

    /// Pede a senha de administrador do macOS para criar /usr/local/bin/hetzctl. Devolve o erro, se houver.
    static func install() -> String? {
        let command = "mkdir -p /usr/local/bin && ln -sf '\(bundled.path)' /usr/local/bin/hetzctl"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&error)
        return error.map { $0[NSAppleScript.errorMessage] as? String ?? "falhou" }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let checkNow: () async -> Void
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var key = ""
    @State private var licenseMessage: String?
    @State private var cliLink = CommandLineTool.installedLink
    @State private var cliMessage: String?
    @State private var checking = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "—"))"
    }

    var body: some View {
        Form {
            Section("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { on in
                        _ = try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        loginStatus = SMAppService.mainApp.status
                    }))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Falta aprovar em Itens de Início.").foregroundStyle(.secondary)
                        Button("Abrir Ajustes do Sistema") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Corrigir EDID com cabeçalho corrompido", isOn: $settings.autoRepairEDID)
                Toggle("Automação por monitor (PRO)", isOn: $settings.autoOptimize)
                    .disabled(!settings.edition.allows(.autoOptimize))
            }
            Section("Licença") {
                Text(settings.edition.description)
                if case .pro = settings.edition {} else {
                    TextField("Chave", text: $key, prompt: Text("ABMCHZ-PRO.…"))
                    Button("Ativar") {
                        do {
                            let license = try Licensing.activate(key)
                            key = ""
                            licenseMessage = "PRO vitalício ativado para \(license.owner)."
                        } catch {
                            licenseMessage = "\(error)"
                        }
                        settings.edition = Licensing.current
                    }
                    .disabled(key.isEmpty)
                }
                if let licenseMessage { Text(licenseMessage).foregroundStyle(.secondary) }
            }
            Section("Linha de comando") {
                if let cliLink {
                    Text("hetzctl instalado em \(cliLink.path)").foregroundStyle(.secondary)
                } else {
                    Button("Instalar hetzctl em /usr/local/bin…") {
                        cliMessage = CommandLineTool.install()
                        cliLink = CommandLineTool.installedLink
                    }
                }
                if let cliMessage { Text(cliMessage).foregroundStyle(.secondary) }
            }
            Section("Perfis") {
                Text("Os perfis do BenQ XL2430T e do ASUS PG259QN/XG259QN vêm no app. Um .json com o mesmo id na pasta de perfis substitui o do app.")
                    .foregroundStyle(.secondary)
                Button("Mostrar pasta de perfis") {
                    try? FileManager.default.createDirectory(at: Profile.userDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Profile.userDirectory)
                }
            }
            Section("Atualizações") {
                Toggle("Procurar versão nova uma vez por dia (GitHub)", isOn: $settings.checkUpdates)
                HStack {
                    if let update = settings.availableUpdate {
                        Link("Versão \(update.version.description) disponível", destination: update.page)
                    } else {
                        Text(checking ? "Procurando…" : "Nenhuma versão nova encontrada").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Procurar agora") {
                        checking = true
                        Task {
                            await checkNow()
                            checking = false
                        }
                    }
                    .disabled(checking)
                }
            }
            Section("Sobre") {
                LabeledContent("Versão", value: version)
                Link("github.com/oalexandrebelo/AB-McHZ", destination: URL(string: "https://github.com/oalexandrebelo/AB-McHZ")!)
                Text("Uso pessoal e não comercial · PolyForm Noncommercial 1.0.0").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
            cliLink = CommandLineTool.installedLink
            settings.edition = Licensing.current
        }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(_ settings: AppSettings, checkNow: @escaping () async -> Void) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, checkNow: checkNow)))
            window.title = "Ajustes do AB-McHZ"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
