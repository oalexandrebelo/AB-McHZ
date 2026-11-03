// Atalhos globais ⌃⌥⌘1…9 (PRO) pelo Carbon RegisterEventHotKey: não pede permissão de Acessibilidade.
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeys {
    static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    private static var onPress: ((Int) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// `onPress` recebe 1…9.
    init(onPress: @escaping (Int) -> Void) {
        Self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let index = Int(hotKey.id)
            MainActor.assumeIsolated { HotKeys.onPress?(index) }  // o Carbon entrega na thread principal
            return noErr
        }, 1, &spec, nil, &handler)
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (offset, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4142_4D43), id: UInt32(offset + 1))  // "ABMC"
            if RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { refs.append(ref) }
        }
    }
}
