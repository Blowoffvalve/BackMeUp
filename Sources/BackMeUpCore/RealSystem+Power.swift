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
