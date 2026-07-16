//  SystemPower.swift
//  Battery + AC state of this Mac, for the anchor watch.
//
//  Why: a MacBook at the nav station IS the anchor alarm. Unplugged, it dies
//  overnight — and macOS reports no battery through UIDevice (iOS-only), so
//  the low-battery alarm was silently disabled on the Mac. IOKit's power
//  sources API fills the gap. Returns nil on desktop Macs with no battery.

#if os(macOS)
import Foundation
import IOKit.ps

@MainActor
enum SystemPower {

    struct Battery {
        let level: Double   // 0…1
        let onAC:  Bool
    }

    private static var cached: (battery: Battery?, at: Date) = (nil, .distantPast)

    /// Battery state, or nil when this Mac has no internal battery.
    /// Cached 10 s — callers poll on the 2 s alarm cadence.
    static func battery() -> Battery? {
        if Date().timeIntervalSince(cached.at) < 10 { return cached.battery }
        cached = (readBattery(), Date())
        return cached.battery
    }

    private static func readBattery() -> Battery? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources  = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?
                      .takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return Battery(level: Double(cur) / Double(max), onAC: onAC)
        }
        return nil
    }
}
#endif
