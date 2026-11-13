import Foundation
import LocalAuthentication
import AppKit

public struct PrivilegedCommandResult {
    public let output: String
    public let success: Bool
    public let canceled: Bool

    public init(output: String, success: Bool, canceled: Bool) {
        self.output = output
        self.success = success
        self.canceled = canceled
    }
}

public enum SudoTouchIDStatus: String, Codable {
    case enabled = "Configured & Active"
    case disabled = "Disabled in sudo_local"
    case notConfigured = "Not Configured"
}

@MainActor
public final class TouchIDManager: ObservableObject {
    public static let shared = TouchIDManager()

    public static let userDefaultsKeyEnableTouchID = "com.chip.maccare.enableTouchIDForPrivilege"

    @Published public private(set) var isHardwareAvailable: Bool = false
    @Published public private(set) var isEnrolled: Bool = false
    @Published public private(set) var biometryType: LABiometryType = .none
    @Published public private(set) var sudoStatus: SudoTouchIDStatus = .notConfigured
    @Published public var isTouchIDEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTouchIDEnabled, forKey: Self.userDefaultsKeyEnableTouchID)
        }
    }

    public init() {
        let storedPref = UserDefaults.standard.object(forKey: Self.userDefaultsKeyEnableTouchID) as? Bool
        // Default to enabled if Touch ID is available
        self.isTouchIDEnabled = storedPref ?? true
        refreshStatus()
    }

    public func refreshStatus() {
        let context = LAContext()
        var error: NSError?
        let canBio = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        self.biometryType = context.biometryType
        self.isHardwareAvailable = (context.biometryType == .touchID) || canBio || (error?.code == LAError.biometryNotEnrolled.rawValue)
        self.isEnrolled = canBio
        self.sudoStatus = Self.getSudoTouchIDStatus()
    }

    // MARK: - Static Diagnostic Helpers

    nonisolated public static func checkHardwareAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        let canBio = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if canBio || context.biometryType == .touchID {
            return true
        }
        if let error = error, error.code == LAError.biometryNotEnrolled.rawValue {
            return true
        }
        return false
    }

    nonisolated public static func checkBiometricsEnrolled() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    nonisolated public static func parseSudoLocal(content: String?) -> SudoTouchIDStatus {
        guard let content = content else { return .notConfigured }
        var hasCommented = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so") {
                hasCommented = true
            } else if !trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so") {
                return .enabled
            }
        }
        return hasCommented ? .disabled : .notConfigured
    }

    nonisolated public static func getSudoTouchIDStatus(path: String = "/etc/pam.d/sudo_local") -> SudoTouchIDStatus {
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .notConfigured
        }
        return parseSudoLocal(content: content)
    }

    public var statusDescription: String {
        if !isHardwareAvailable {
            return "Touch ID sensor not detected on this Mac"
        }
        if !isEnrolled {
            return "Touch ID hardware detected, but no fingerprints are enrolled in System Settings"
        }
        if !isTouchIDEnabled {
            return "Touch ID available but disabled in MacCare settings"
        }
        return "Touch ID available & active for privileged tasks"
    }

    // MARK: - Biometric Authentication

    /// Prompts the user with the native macOS Touch ID biometric sheet.
    public func authenticate(reason: String) async -> (success: Bool, canceled: Bool, errorDescription: String?) {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        // Use .deviceOwnerAuthentication so the user can use Touch ID or fall back to their Mac password
        let policy: LAPolicy = .deviceOwnerAuthentication

        var authError: NSError?
        guard context.canEvaluatePolicy(policy, error: &authError) else {
            return (false, false, authError?.localizedDescription ?? "Authentication policy unavailable")
        }

        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            return (success, false, nil)
        } catch let err as LAError {
            switch err.code {
            case .userCancel, .appCancel, .systemCancel:
                return (false, true, "Canceled by user")
            default:
                return (false, false, err.localizedDescription)
            }
        } catch {
            return (false, false, error.localizedDescription)
        }
    }

    // MARK: - Privileged Execution

    /// Centralized runner for privileged system commands.
    /// If Touch ID is supported and enabled, prompts with Touch ID before elevation.
    public func runPrivilegedCommand(_ command: String, reason: String) async -> PrivilegedCommandResult {
        refreshStatus()

        // 1. If Touch ID is available and enabled in settings, authenticate with biometrics first
        if isHardwareAvailable && isTouchIDEnabled {
            let (success, canceled, errorDesc) = await authenticate(reason: reason)
            if canceled {
                return PrivilegedCommandResult(output: "Operation canceled by user.", success: false, canceled: true)
            }
            if !success {
                return PrivilegedCommandResult(
                    output: errorDesc ?? "Touch ID authentication failed.",
                    success: false,
                    canceled: false
                )
            }
        }

        // 2. Execute via osascript with administrator privileges off the main thread
        let appleScriptCmd = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(appleScriptCmd)\" with administrator privileges"

        let out = await Task.detached(priority: .userInitiated) { () -> String in
            SystemScanner.runShell("/usr/bin/osascript", args: ["-e", osa])
        }.value

        if out.lowercased().contains("user canceled") {
            return PrivilegedCommandResult(output: "Canceled by user.", success: false, canceled: true)
        }

        let isError = out.contains("execution error:")
        return PrivilegedCommandResult(output: out, success: !isError, canceled: false)
    }

    // MARK: - Sudo PAM Configuration Helpers

    /// Enables Touch ID for sudo by creating /etc/pam.d/sudo_local with auth sufficient pam_tid.so
    public func enableSudoTouchID() async -> (success: Bool, message: String) {
        let script = """
        if [ -f /etc/pam.d/sudo_local.template ]; then
            /bin/cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local && /usr/bin/sed -i '' 's/^#auth/auth/' /etc/pam.d/sudo_local
        else
            /bin/echo 'auth       sufficient     pam_tid.so' > /etc/pam.d/sudo_local
        fi
        """
        let result = await runPrivilegedCommand(
            script,
            reason: "Authenticate with Touch ID to enable Touch ID for sudo commands system-wide"
        )
        refreshStatus()
        if result.success {
            return (true, "Touch ID for sudo successfully configured in /etc/pam.d/sudo_local.")
        } else {
            return (false, result.canceled ? "Canceled by user." : result.output)
        }
    }

    /// Disables Touch ID for sudo by removing /etc/pam.d/sudo_local
    public func disableSudoTouchID() async -> (success: Bool, message: String) {
        let script = "/bin/rm -f /etc/pam.d/sudo_local"
        let result = await runPrivilegedCommand(
            script,
            reason: "Authenticate with Touch ID to remove /etc/pam.d/sudo_local"
        )
        refreshStatus()
        if result.success {
            return (true, "Removed /etc/pam.d/sudo_local. Terminal sudo reverted to standard password.")
        } else {
            return (false, result.canceled ? "Canceled by user." : result.output)
        }
    }
}
