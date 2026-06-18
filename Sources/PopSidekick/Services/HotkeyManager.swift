import AppKit
import Carbon.HIToolbox

/// Registers global keyboard shortcuts (via Carbon Hot Keys) and invokes a
/// callback with the associated task id when one is pressed. Used so a task can
/// be run on the current selection from anywhere, without the popup being open.
@MainActor
final class HotkeyManager {
    /// Called on the main actor with the task id whose hotkey was pressed.
    var onTrigger: ((String) -> Void)?

    private struct Registration {
        var ref: EventHotKeyRef
        var taskID: String
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x50534b59 // 'PSKY'

    init() {
        installHandler()
    }

    deinit {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Re-registers all hotkeys from the given tasks, replacing any prior set.
    func register(tasks: [TaskDef]) {
        unregisterAll()
        for task in tasks {
            guard let hk = task.hotkey else { continue }
            register(hotkey: hk, taskID: task.id)
        }
    }

    private func register(hotkey: Hotkey, taskID: String) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode,
                                         hotkey.modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            registrations[id] = Registration(ref: ref, taskID: taskID)
        }
    }

    private func unregisterAll() {
        for (_, reg) in registrations {
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                guard let taskID = manager.registrations[id]?.taskID else { return }
                manager.onTrigger?(taskID)
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }
}
