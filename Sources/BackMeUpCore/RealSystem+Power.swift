import Foundation
import IOKit.ps
import IOKit.pwr_mgt

extension RealSystem {
    /// From IOKit's power sources: AC, battery (or UPS) power.
    public var powerSource: PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch type {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }

    /// IOKit's power source notification, delivered on the main run loop in every mode (so also
    /// while the menu is open). It fires when the Mac is plugged in or unplugged, and when the
    /// battery level changes.
    public func watchPowerSource(_ onChange: @escaping @MainActor () -> Void) {
        let watcher = PowerSourceWatcher(onChange)
        let context = Unmanaged.passUnretained(watcher).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue()
            // The source is on the main run loop, so this runs on the main thread.
            MainActor.assumeIsolated { watcher.onChange() }
        }, context)?.takeRetainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceWatchers.append(watcher)
    }

    /// An IOKit "prevent user idle system sleep" assertion. It doesn't stop sleep when the lid
    /// closes, and macOS drops it if BackMeUp quits or crashes. `pmset -g assertions` lists it.
    public func setIdleSleepPrevented(_ prevented: Bool) {
        if prevented, sleepAssertion == nil {
            var id = IOPMAssertionID(0)
            let created = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "BackMeUp is running a Time Machine backup" as CFString,
                &id
            )
            if created == kIOReturnSuccess { sleepAssertion = id }
        } else if !prevented, let id = sleepAssertion {
            IOPMAssertionRelease(id)
            sleepAssertion = nil
        }
    }
}

/// Holds a power source callback for IOKit, which only takes a C function and a context pointer.
final class PowerSourceWatcher {
    let onChange: @MainActor () -> Void

    init(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }
}
