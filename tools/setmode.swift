// Troca o modo de uma tela com watchdog de rollback.
// Uso: swift tools/setmode.swift <largura> <altura> <hz> [displayID]   (padrão: tela principal)
//      swift tools/setmode.swift --list [displayID]
import CoreGraphics
import Foundation

let kSafe: UInt32 = 0x2  // kDisplayModeSafeFlag (IOGraphicsTypes.h)
let args = CommandLine.arguments.dropFirst()
let listOnly = args.first == "--list"
let nums = args.filter { $0 != "--list" }.compactMap { Int($0) }
let id = CGDirectDisplayID(nums.count == 1 || nums.count == 4 ? nums.last! : Int(CGMainDisplayID()))

func describe(_ m: CGDisplayMode?) -> String {
    guard let m else { return "nil" }
    let scale = m.pixelWidth == m.width ? "" : " HiDPI"
    return "\(m.width)x\(m.height)@\(Int(m.refreshRate.rounded()))Hz\(scale)\(m.ioFlags & kSafe == 0 ? " [não-seguro]" : "")"
}
func isOnline() -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).contains(id)
}
func apply(_ m: CGDisplayMode) -> CGError {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
    CGConfigureDisplayWithDisplayMode(cfg, id, m, nil)
    return CGCompleteDisplayConfiguration(cfg, .permanently)
}

let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
print("tela \(id) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) atual=\(describe(CGDisplayCopyDisplayMode(id)))")
if CGDisplayVendorNumber(id) == 0 { print("aviso: macOS sem EDID desta tela — só o modo atual é seguro; refaça o hotplug (desligar/ligar o monitor)") }

if listOnly || nums.count < 3 {
    Set(modes.map(describe)).sorted().forEach { print("  " + $0) }
    exit(0)
}

let (w, h, hz) = (nums[0], nums[1], nums[2])
guard let prev = CGDisplayCopyDisplayMode(id) else { print("tela \(id) sem modo atual"); exit(1) }
guard let target = modes.first(where: {
    $0.width == w && $0.height == h && Int($0.refreshRate.rounded()) == hz && $0.isUsableForDesktopGUI()
}) else { print("modo \(w)x\(h)@\(hz) não oferecido; use --list"); exit(1) }

print("aplicando \(describe(target)): CGError \(apply(target).rawValue)")
Thread.sleep(forTimeInterval: 6)
let cur = CGDisplayCopyDisplayMode(id)
if isOnline() && cur?.width == w && cur?.height == h && Int(cur?.refreshRate.rounded() ?? 0) == hz {
    print("ok: \(describe(cur))")
} else {
    print("watchdog: modo não aplicado ou tela caiu — revertendo para \(describe(prev)): CGError \(apply(prev).rawValue)")
    exit(2)
}
