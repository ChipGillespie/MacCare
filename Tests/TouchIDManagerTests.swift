import Foundation
import LocalAuthentication

@main
enum TouchIDManagerTests {
    static var failures = 0
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("  FAIL: \(message)")
        }
    }

    static func main() {
        print("Running TouchIDManagerTests...")

        // 1. Test PAM parsing with nil / non-existent content
        print("• Sudo PAM parsing: nil / empty")
        expect(TouchIDManager.parseSudoLocal(content: nil) == .notConfigured, "nil content should be .notConfigured")
        expect(TouchIDManager.parseSudoLocal(content: "") == .notConfigured, "empty content should be .notConfigured")

        // 2. Test PAM parsing with template / commented pam_tid
        print("• Sudo PAM parsing: commented pam_tid")
        let commentedTemplate = """
        # sudo_local: local config file which survives system update
        #auth       sufficient     pam_tid.so
        """
        expect(TouchIDManager.parseSudoLocal(content: commentedTemplate) == .disabled, "commented pam_tid should be .disabled")

        // 3. Test PAM parsing with active pam_tid
        print("• Sudo PAM parsing: active pam_tid")
        let activeConfig = """
        # sudo_local: local config file which survives system update
        auth       sufficient     pam_tid.so
        """
        expect(TouchIDManager.parseSudoLocal(content: activeConfig) == .enabled, "active pam_tid should be .enabled")

        // 4. Test PAM parsing with multiple lines and tabs/spaces
        print("• Sudo PAM parsing: active with trailing spaces and other directives")
        let multiConfig = """
        # Custom PAM configuration
        auth       optional       pam_permit.so
        auth       sufficient     pam_tid.so   
        account    required       pam_permit.so
        """
        expect(TouchIDManager.parseSudoLocal(content: multiConfig) == .enabled, "active pam_tid in multi-line config should be .enabled")

        // 5. Test temporary file getSudoTouchIDStatus
        print("• Sudo PAM file status via getSudoTouchIDStatus")
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("sudo_local_test_\(UUID().uuidString)")
        try? activeConfig.write(to: tmpFile, atomically: true, encoding: .utf8)
        expect(TouchIDManager.getSudoTouchIDStatus(path: tmpFile.path) == .enabled, "temporary file status should be .enabled")
        try? FileManager.default.removeItem(at: tmpFile)
        expect(TouchIDManager.getSudoTouchIDStatus(path: tmpFile.path) == .notConfigured, "missing file status should be .notConfigured")

        // 6. Test hardware check returns a valid boolean
        print("• Hardware and biometrics detection")
        let hardware = TouchIDManager.checkHardwareAvailable()
        let enrolled = TouchIDManager.checkBiometricsEnrolled()
        // On this MacBook Air M2, hardware should be true
        expect(hardware == true, "hardware should be detected on MacBook Air M2")
        expect(enrolled == true, "enrolled biometrics should be true on this machine")

        // 7. Test PrivilegedCommandResult struct properties
        print("• PrivilegedCommandResult initialization")
        let resSuccess = PrivilegedCommandResult(output: "Done", success: true, canceled: false)
        expect(resSuccess.success == true, "success should be true")
        expect(resSuccess.canceled == false, "canceled should be false")
        expect(resSuccess.output == "Done", "output should match")

        let resCancel = PrivilegedCommandResult(output: "Canceled", success: false, canceled: true)
        expect(resCancel.success == false, "success should be false")
        expect(resCancel.canceled == true, "canceled should be true")

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            exit(1)
        }
    }
}
