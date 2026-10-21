import Core
import Foundation
import Gemma4ANE
import IOKit.ps

@MainActor
enum ConverterResourceStatus {
    private static var timer: Timer?
    static func start() {
        refresh()
        InferenceActivity.setObserver { event in
            DispatchQueue.main.async {
                guard InferenceActivity.isCurrent(event) else { return }
                PersonalLearner.shared.recordResourceUsage(feature: event.feature, device: event.device, milliseconds: event.milliseconds)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }
    static func refresh() {
        var onAC = true, battery: Double?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            onAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) != kIOPSBatteryPowerValue
            if let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
                for source in sources {
                    if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                       let current = description[kIOPSCurrentCapacityKey] as? Double,
                       let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 { battery = current / maximum }
                }
            }
        }
        ResourceBudget.update(.init(onAC: onAC, battery: battery, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                    thermal: ProcessInfo.processInfo.thermalState.rawValue,
                                    memoryGB: Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))))
    }
    static var summary: String {
        let tier = ResourceBudget.current
        return "資源の段: \(tier.name)（\(ResourceBudget.memoryGB)GB）／\(tier.completion)／放置\(tier.idleSentences)文／12B:\(tier.allow12B ? 1 : 0)／31B:\(tier.allow31B ? 1 : 0)／再生・夜間:\(tier.replay ? 1 : 0)"
    }
}
