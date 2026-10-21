import AppKit
import ApplicationServices
import Core
import Foundation

// MARK: - 場面の場所をアクセシビリティで読む（任意）（llm-ime、フェーズ 4）
//
// 本人がシステム設定で ConverterServer にアクセシビリティを許可したときだけ使う。許可は求めない（AXIsProcessTrusted だけを見て、
// 許可を求める呼び出しはしない。システム設定も勝手に開かない）。読むだけで、相手のアプリの属性は書かない（AXEnhancedUserInterface・
// AXManualAccessibility などを設定すると Chromium 系の動きと速さが変わる）。入力欄に入ったときに裏のキューで読み、キー入力の処理は待たない。
// 学習がオフ・記録しないアプリ（パスワード管理・本人が外したもの）・設定がオフ・許可がないときは、何も問い合わせない。
// 入力欄が安全な入力欄（パスワード）なら、それ以上は読まない。読めなければ場所はなく、場面は今と同じ

enum PersonalAccessibility {
    private static let queue = DispatchQueue(label: "dev.tomonari.llm-ime.personal-accessibility", qos: .utility)
    /// 1 回の問い合わせを待つ上限（秒）と、全体の上限・親をたどる回数の上限
    private static let messagingTimeout: Float = 0.05
    private static let budget: TimeInterval = 0.15
    private static let maxHops = 15

    /// 許可があるか（許可を求める呼び出しはしない）
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 場所を読んでよいか（学習と設定がオン、記録してよいアプリ、許可がある）
    static func mayRead(app: String) -> Bool {
        PersonalLearner.isEnabled && Config.PersonalAccessibilityPlaces().value && !PersonalPrivacy.isExcluded(app: app) && Self.isTrusted
    }

    /// 場所を裏のキューで読み、主スレッドで返す（読まない・読めなければ nil）
    static func readPlace(app: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        guard Self.mayRead(app: app), let pid = Self.pid(of: app) else {
            Task { @MainActor in
                completion(nil)
            }
            return
        }
        Self.queue.async {
            let place = Self.place(pid: pid)
            Task { @MainActor in
                completion(place)
            }
        }
    }

    /// 場所を読む（async）
    static func place(app: String) async -> String? {
        await withCheckedContinuation { continuation in
            Self.readPlace(app: app) { place in
                continuation.resume(returning: place)
            }
        }
    }

    private static func pid(of bundleID: String) -> pid_t? {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID {
            return front.processIdentifier
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// 入力欄の場所: いちばん近い Web の領域の URL のホスト名、なければ入力欄の案内文の符号。安全な入力欄・読めなければ nil
    private static func place(pid: pid_t) -> String? {
        let deadline = Date().addingTimeInterval(Self.budget)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let focused = Self.element(application, kAXFocusedUIElementAttribute) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
        let role = Self.string(focused, kAXRoleAttribute) ?? ""
        let subrole = Self.string(focused, kAXSubroleAttribute) ?? ""
        // 安全な入力欄（パスワード）では、それ以上は読まない
        if role.contains("Secure") || subrole == kAXSecureTextFieldSubrole as String || subrole.contains("Secure") {
            return nil
        }
        var current = focused
        for _ in 0..<Self.maxHops where Date() < deadline {
            if Self.string(current, kAXRoleAttribute) == "AXWebArea" {
                if let url = Self.url(current, kAXURLAttribute) {
                    return PersonalPlace.host(of: url)
                }
                break
            }
            guard let parent = Self.element(current, kAXParentAttribute) else {
                break
            }
            AXUIElementSetMessagingTimeout(parent, Self.messagingTimeout)
            current = parent
        }
        guard Date() < deadline, let placeholder = Self.string(focused, kAXPlaceholderValueAttribute) else {
            return nil
        }
        return PersonalPlace.placeholderLabel(placeholder)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = Self.value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        Self.value(element, attribute) as? String
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        if let url = Self.value(element, attribute) as? URL {
            return url
        }
        return (Self.value(element, attribute) as? String).flatMap(URL.init(string:))
    }
}
