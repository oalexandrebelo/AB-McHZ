// Descoberta de telas: CoreGraphics + IORegistry. Cada DCPAVServiceProxy externo é ligado ao
// framebuffer que o precede na árvore IOService (IOMobileFramebufferShim/AppleCLCD2), e o framebuffer
// é ligado à tela do CoreGraphics pelo IODisplayLocation que o CoreDisplay informa.
import CoreGraphics
import Foundation
import IOKit

public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: CGDirectDisplayID
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let name: String?
    public let isBuiltin: Bool
    public let isVirtual: Bool
    public let isMain: Bool
    public let transport: String?
    public let hasDDC: Bool
    public let currentMode: ModeInfo?

    /// Tela física externa para a qual o macOS não leu EDID (vendor 0, só o modo atual é seguro).
    public var isMissingEDID: Bool { vendor == 0 && !isBuiltin && !isVirtual }

    /// Sem EDID o kernel (AppleDisplayManager) dá ao link a banda mínima (na HDMI do Mac mini: 1280×720,
    /// 74,25 MHz) e recusa qualquer modo acima, por qualquer API. Só um hotplug com EDID lido libera.
    public static let missingEDIDHint = "sem EDID o macOS limita o link desta tela: reconecte o cabo ou desligue e ligue o monitor"
}

public struct ModeInfo: Sendable, Equatable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let ioFlags: UInt32
    public let isUsableForDesktopGUI: Bool

    public init(_ mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
        ioFlags = mode.ioFlags
        isUsableForDesktopGUI = mode.isUsableForDesktopGUI()
    }

    init(width: Int, height: Int, hz: Double, hiDPI: Bool = false, safe: Bool = true, usable: Bool = true) {
        self.width = width
        self.height = height
        pixelWidth = hiDPI ? width * 2 : width
        pixelHeight = hiDPI ? height * 2 : height
        refreshRate = hz
        ioFlags = safe ? DisplayModes.safeFlag : 0
        isUsableForDesktopGUI = usable
    }

    public var hz: Int { Int(refreshRate.rounded()) }
    public var isHiDPI: Bool { pixelWidth != width }
    public var isSafe: Bool { ioFlags & DisplayModes.safeFlag != 0 }

    public func sameMode(as other: ModeInfo) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth && hz == other.hz
    }

    public var description: String {
        "\(width)x\(height)@\(hz)Hz\(isHiDPI ? " HiDPI" : "")\(isSafe ? "" : " [não-seguro]")"
    }
}

public struct DisplayModeSpec: Sendable, Equatable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public let hz: Int

    public init(width: Int, height: Int, hz: Int) {
        self.width = width
        self.height = height
        self.hz = hz
    }

    /// "1920x1080@60" ou "1920x1080@60Hz".
    public init?(_ text: String) {
        let parts = text.lowercased().replacingOccurrences(of: "hz", with: "").split(whereSeparator: { $0 == "x" || $0 == "@" })
        guard parts.count == 3, let w = Int(parts[0]), let h = Int(parts[1]), let hz = Int(parts[2]) else { return nil }
        self.init(width: w, height: h, hz: hz)
    }

    public func matches(_ mode: ModeInfo) -> Bool {
        mode.width == width && mode.height == height && mode.hz == hz
    }

    public var description: String { "\(width)x\(height)@\(hz)Hz" }
}

enum DisplayModes {
    /// kDisplayModeSafeFlag (IOGraphicsTypes.h). Sem EDID, só o modo atual vem com ele.
    static let safeFlag: UInt32 = 0x2

    static func all(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        onlineIDs().contains(id)
    }

    /// Modo seguro vai pela API pública. Modo sem SafeFlag ela aceita e ignora em silêncio, então vai
    /// pelo número do modo na lista do SkyLight (o "displayModeNumber" com que o BetterDisplay trocava).
    /// `.forSession` durante o watchdog: se o app cair no meio, o logout desfaz. Só o modo confirmado vira `.permanently`.
    static func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID, option: CGConfigureOption = .forSession) -> CGError {
        let info = ModeInfo(mode)
        let number = info.isSafe ? nil : modeNumber(for: info, on: id)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return .failure }
        if let number, let configure = PrivateAPI.shared.configureMode {
            _ = configure(config, id, number)
        } else {
            CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        }
        return CGCompleteDisplayConfiguration(config, option)
    }

    /// Layout do registro do SkyLight (displayplacer): +0 número, +8 largura, +12 altura, +190 Hz (UInt16), +0xD0 densidade.
    static func modeNumber(for mode: ModeInfo, on id: CGDirectDisplayID) -> Int32? {
        guard let count = PrivateAPI.shared.modeCount, let describe = PrivateAPI.shared.modeDescription else { return nil }
        var total: Int32 = 0
        count(id, &total)
        var record = [UInt8](repeating: 0, count: 0xDC)
        for index in 0..<max(0, total) {
            describe(id, index, &record, 0xD4)
            let (number, width, height, hz, density) = record.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: 0, as: Int32.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self),
                 $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self), $0.loadUnaligned(fromByteOffset: 190, as: UInt16.self),
                 $0.loadUnaligned(fromByteOffset: 0xD0, as: Float.self))
            }
            if width == mode.width, height == mode.height, Int(hz) == mode.hz, (density > 1) == mode.isHiDPI { return number }
        }
        return nil
    }
}

enum Discovery {
    static func scan() -> (displays: [DisplayInfo], buses: [CGDirectDisplayID: any I2CBus]) {
        let services = externalAVServices()
        var buses: [CGDirectDisplayID: any I2CBus] = [:]
        let displays = DisplayModes.onlineIDs().map { id -> DisplayInfo in
            let info = (PrivateAPI.shared.displayInfo?(id)?.takeRetainedValue() as? [String: Any]) ?? [:]
            let location = info["IODisplayLocation"] as? String
            let match = location.flatMap { loc in services.first { $0.framebuffer == loc } }
            if let match { buses[id] = IOAVBus(service: match.service, dpDevice: match.dpDevice) }
            return DisplayInfo(
                id: id,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                name: productName(info),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isVirtual: (info["kCGDisplayIsVirtualDevice"] as? Bool) ?? false,
                isMain: CGDisplayIsMain(id) != 0,
                transport: match?.transport,
                hasDDC: match != nil,
                currentMode: CGDisplayCopyDisplayMode(id).map(ModeInfo.init)
            )
        }
        return (displays, buses)
    }

    private static func productName(_ info: [String: Any]) -> String? {
        guard let names = info["DisplayProductName"] as? [String: String] else { return nil }
        let name = names["en_US"] ?? names.values.first { !$0.isEmpty }
        return name?.isEmpty == false ? name : nil
    }

    private struct AVService {
        let framebuffer: String
        let transport: String?
        let service: CFTypeRef
        let dpDevice: CFTypeRef?
    }

    private static func externalAVServices() -> [AVService] {
        guard let create = PrivateAPI.shared.avCreate else { return [] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        // Depois de cada framebuffer vêm os proxies do coprocessador dele: DCPDPDeviceProxy e então DCPAVServiceProxy.
        var found: [AVService] = []
        var framebuffer: (path: String, transport: String?)?
        var dpDevice: CFTypeRef?
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let entryName = string(name)
            if entryName.contains("IOMobileFramebufferShim") || entryName.contains("AppleCLCD2") {
                var path = [CChar](repeating: 0, count: 1024)
                IORegistryEntryGetPath(entry, kIOServicePlane, &path)
                framebuffer = (string(path), transport(entry))
                dpDevice = nil
            } else if entryName == "DCPDPDeviceProxy", property(entry, "Location") as? String == "External" {
                dpDevice = PrivateAPI.shared.dpDeviceCreate?(kCFAllocatorDefault, entry)?.takeRetainedValue()
            } else if entryName == "DCPAVServiceProxy",
                      property(entry, "Location") as? String == "External",
                      let fb = framebuffer,
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found.append(AVService(framebuffer: fb.path, transport: fb.transport, service: service, dpDevice: dpDevice))
                framebuffer = nil
                dpDevice = nil
            }
        }
        return found
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func transport(_ entry: io_registry_entry_t) -> String? {
        guard let t = property(entry, "Transport") as? [String: String], let up = t["Upstream"] else { return nil }
        guard let down = t["Downstream"], down != up else { return up }
        return "\(up)→\(down)"
    }
}
