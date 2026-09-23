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
    private let signature: OSType

    /// Each manager needs a distinct signature so several can coexist.
    init(signature: OSType = 0x50534b59 /* 'PSKY' */) {
        self.signature = signature
        installHandler()
    }

    deinit {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Reserved action id used for the "open clipboard history" global hotkey,
    /// distinguishable from any task id (task ids are UUID strings).
    static let clipboardHistoryActionID = "__clipboard_history__"
    /// Reserved action id for the FocusTrace on/off global hotkey.
    static let focusTraceActionID = "__focus_trace__"

    /// Re-registers all hotkeys from the given tasks plus the optional clipboard
    /// history shortcut, replacing any prior set.
    func register(tasks: [TaskDef], clipboardHotkey: Hotkey? = nil, focusTraceHotkey: Hotkey? = nil) {
        unregisterAll()
        for task in tasks {
            guard let hk = task.hotkey else { continue }
            register(hotkey: hk, taskID: task.id)
        }
        if let clipboardHotkey {
            register(hotkey: clipboardHotkey, taskID: HotkeyManager.clipboardHistoryActionID)
        }
        if let focusTraceHotkey {
            register(hotkey: focusTraceHotkey, taskID: HotkeyManager.focusTraceActionID)
        }
    }

    /// Replaces all registrations with the given action-id → hotkey bindings.
    func registerActions(_ actions: [(id: String, hotkey: Hotkey)]) {
        unregisterAll()
        for a in actions { register(hotkey: a.hotkey, taskID: a.id) }
    }

    func unregisterAllHotkeys() { unregisterAll() }

    private func register(hotkey: Hotkey, taskID: String) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
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
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Leave other managers' hotkeys to their own handlers.
            guard status == noErr, hotKeyID.signature == manager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                guard let taskID = manager.registrations[id]?.taskID else { return }
                manager.onTrigger?(taskID)
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }
}
