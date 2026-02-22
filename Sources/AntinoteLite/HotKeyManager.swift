import Carbon
import Foundation

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: @Sendable () -> Void
    private let hotKeyID: EventHotKeyID

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @Sendable () -> Void) {
        self.action = action
        self.hotKeyID = EventHotKeyID(signature: OSType(0x414E544E), id: 1)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard
                let event,
                let userData
            else {
                return noErr
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var triggeredID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &triggeredID
            )

            if status == noErr, triggeredID.signature == manager.hotKeyID.signature, triggeredID.id == manager.hotKeyID.id {
                manager.action()
            }

            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            return nil
        }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
