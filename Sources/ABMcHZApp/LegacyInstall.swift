// Até a versão 0.2 o AB-McHZ era instalado pelo scripts/install.sh: app em ~/Applications com o id org.ab-mchz.agent,
// aberto por um LaunchAgent, mais cópias do hetzctl e dos perfis. A versão empacotada desfaz isso na primeira execução.
import AppKit
import HetzCore

enum LegacyInstall {
    static let label = "org.ab-mchz.agent"

    /// Devolve o que foi feito, para o menu; vazio quando não havia instalação antiga.
    @MainActor
    static func migrate() -> [String] {
        guard Bundle.main.bundleIdentifier != label, Bundle.main.bundlePath.hasSuffix(".app") else { return [] }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var done: [String] = []

        let plist = home.appending(path: "Library/LaunchAgents/\(label).plist")
        if fm.fileExists(atPath: plist.path) {
            // bootout encerra a cópia antiga e impede o launchd de reabri-la.
            let launchctl = Process()
            launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctl.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            try? launchctl.run()
            launchctl.waitUntilExit()
            try? fm.removeItem(at: plist)
            done.append("LaunchAgent antigo removido")
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: label) { app.forceTerminate() }

        let oldApp = home.appending(path: "Applications/AB-McHZ.app")
        if Bundle(url: oldApp)?.bundleIdentifier == label, oldApp.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
            if (try? fm.trashItem(at: oldApp, resultingItemURL: nil)) != nil { done.append("app antigo em ~/Applications foi para o Lixo") }
        }

        // A cópia do hetzctl em ~/.local/bin vira link para o do app (assim ela acompanha as atualizações).
        let oldCLI = CommandLineTool.userLink
        if let type = try? fm.attributesOfItem(atPath: oldCLI.path)[.type] as? FileAttributeType, type == .typeRegular {
            try? fm.removeItem(at: oldCLI)
            if (try? fm.createSymbolicLink(at: oldCLI, withDestinationURL: CommandLineTool.bundled)) != nil {
                done.append("~/.local/bin/hetzctl agora aponta para o app")
            }
        }

        // Perfis copiados pelo install.sh iguais aos do app só esconderiam as atualizações: saem. Editados ficam.
        if let bundled = Profile.bundledDirectory,
           let files = try? fm.contentsOfDirectory(at: Profile.userDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let twin = bundled.appending(path: file.lastPathComponent)
                if let mine = try? Data(contentsOf: file), let theirs = try? Data(contentsOf: twin), mine == theirs {
                    try? fm.removeItem(at: file)
                }
            }
        }
        return done
    }
}
