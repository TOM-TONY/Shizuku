// Standalone menu callbacks only: no registration, activation, key events, windows, or real XPC.
import Cocoa
import Core
import InputMethodKit

private final class MenuMutationSpy: NSMenuItem {
    var writes = 0
    override var title: String { didSet { writes += 1 } }
    override var isHidden: Bool { didSet { writes += 1 } }
    override var state: NSControl.StateValue { didSet { writes += 1 } }
    override var isEnabled: Bool { didSet { writes += 1 } }
}

private struct MenuItemState: Equatable {
    let identity: ObjectIdentifier
    let title: String
    let hidden: Bool
    let enabled: Bool
    let state: Int
    let action: String
}

private func snapshot(_ menu: NSMenu) -> [MenuItemState] {
    menu.items.map { .init(identity: ObjectIdentifier($0), title: $0.title, hidden: $0.isHidden,
        enabled: $0.isEnabled, state: $0.state.rawValue, action: $0.action.map(NSStringFromSelector) ?? "") }
}

@main struct ClientMenuValidationTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var preferences: [String: Any] = [Config.LiveConversion.key: false, Config.PersonalLearning.key: false, Config.PersonalLearningPaused.key: false,
            Config.PersonalInputModeSwitching.key: false, Config.NextTextCompletion.key: false,
            Config.NextTextCompletionIdle.key: false, Config.PromptHistory.key: Data("[]".utf8)]
        func setLearning(_ value: Bool) {
            preferences[Config.PersonalLearning.key] = value
            Config.userDefaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        }
        setLearning(false)
        let client = InitializationClient()
        ShizukuInputController.initializationTestClient = client
        var transportCalls = 0
        ConverterServerClient.initializationTestTransport = { _, reply in transportCalls += 1; reply(nil) }
        let initialWindows = NSApp.windows.count
        let start = ProcessInfo.processInfo.systemUptime
        let controller = ShizukuInputController(server: nil, delegate: nil, client: client)!
        let initMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let menu = controller.appMenu
        let beforeFirstMenu = snapshot(menu)
        let sameMenu = controller.menu() === menu
        var checks: [String: Bool] = ["firstMenuReadOnly": sameMenu && snapshot(menu) == beforeFirstMenu]

        // Count even idempotent setters: writing isHidden=false can notify IMK despite an unchanged value.
        let originalItems = menu.items
        var replacements: [ObjectIdentifier: MenuMutationSpy] = [:]
        for original in originalItems where !original.isSeparatorItem {
            let spy = MenuMutationSpy(title: original.title, action: original.action, keyEquivalent: original.keyEquivalent)
            spy.target = original.target; spy.state = original.state
            spy.isHidden = original.isHidden; spy.isEnabled = original.isEnabled
            replacements[ObjectIdentifier(original)] = spy
        }
        func replacement(_ item: NSMenuItem) -> NSMenuItem { replacements[ObjectIdentifier(item)] ?? item }
        controller.liveConversionToggleMenuItem = replacement(controller.liveConversionToggleMenuItem)
        controller.idleCompletionToggleMenuItem = replacement(controller.idleCompletionToggleMenuItem)
        controller.transformSelectedTextMenuItem = replacement(controller.transformSelectedTextMenuItem)
        controller.quoteMenuItem = replacement(controller.quoteMenuItem)
        controller.teachMenuItem = replacement(controller.teachMenuItem)
        controller.undoTeachMenuItem = replacement(controller.undoTeachMenuItem)
        menu.removeAllItems()
        for item in originalItems { menu.addItem(replacement(item)) }
        let spies = Array(replacements.values)
        func resetWrites() { spies.forEach { $0.writes = 0 } }
        var menuWrites = 0, validationWrites = 0, menuChanges = 0, validationChanges = 0, cycles = 0
        var availabilityCorrect = true, undoVisible = true
        for learning in [false, true] {
            setLearning(learning)
            for receipt in 0..<3 {
                controller.teachingUndoReceipt = receipt == 0 ? nil : ("fixture", Date().addingTimeInterval(receipt == 1 ? 60 : -60))
                for _ in 0..<3 {
                    let before = snapshot(menu)
                    resetWrites()
                    if controller.menu() !== menu || snapshot(menu) != before { menuChanges += 1 }
                    menuWrites += spies.reduce(0) { $0 + $1.writes }
                    let beforeValidation = snapshot(menu)
                    resetWrites()
                    for item in menu.items { _ = controller.validateMenuItem(item) }
                    availabilityCorrect = availabilityCorrect && controller.validateMenuItem(controller.undoTeachMenuItem) == (learning && receipt == 1)
                    validationWrites += spies.reduce(0) { $0 + $1.writes }
                    if snapshot(menu) != beforeValidation { validationChanges += 1 }
                    undoVisible = undoVisible && !controller.undoTeachMenuItem.isHidden
                    cycles += 1
                }
            }
        }
        checks["menuReadOnly"] = menuWrites == 0 && menuChanges == 0
        checks["validationReadOnly"] = validationWrites == 0 && validationChanges == 0
        checks["undoAlwaysVisible"] = undoVisible
        checks["undoAvailability"] = availabilityCorrect
        checks["teachingItemsPresent"] = menu.items.contains { $0 === controller.teachMenuItem } && menu.items.contains { $0 === controller.undoTeachMenuItem }
        checks["noClientQueries"] = client.queries == 0
        checks["noTransport"] = transportCalls == 0
        checks["noWindows"] = NSApp.windows.count == initialWindows
        let passed = checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["testsPassed": passed, "checks": checks, "cycles": cycles, "initializerMs": initMs,
            "menuAttributeWrites": menuWrites, "validationAttributeWrites": validationWrites,
            "menuStateChanges": menuChanges, "validationStateChanges": validationChanges,
            "clientQueries": client.queries, "transportCalls": transportCalls, "windowsCreated": NSApp.windows.count - initialWindows]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) + Data("\n".utf8)
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        FileHandle.standardOutput.write(data)
        if !passed { exit(1) }
    }
}
