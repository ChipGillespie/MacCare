import Foundation

// Standalone test for LsofParser. Run with: ./Tests/run_tests.sh
// Rows follow the real `lsof -i -n -P` layout (see lsof(8)):
//   COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
// NODE (column 7) is the protocol; DEVICE (column 5) is a hex address.

@main
enum LsofParserTests {
    static var failures = 0
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("  FAIL: \(message)")
        }
    }

    static func check(_ name: String, line: String, proto: String? = nil, local: String? = nil,
                      remote: String? = nil, state: String? = nil, name processName: String? = nil,
                      expected: LsofClassification?) {
        print("• \(name)")
        let row = LsofParser.parseLine(line)
        guard let expected else {
            expect(row == nil, "expected line to be rejected")
            return
        }
        guard let row else {
            expect(false, "expected line to parse")
            return
        }
        if let proto { expect(row.proto == proto, "proto \(row.proto) != \(proto)") }
        if let local { expect(row.localEndpoint == local, "local \(row.localEndpoint) != \(local)") }
        if let remote { expect(row.remoteEndpoint == remote, "remote \(row.remoteEndpoint) != \(remote)") }
        if let state { expect(row.state == state, "state \(row.state) != \(state)") }
        if let processName { expect(row.processName == processName, "name \(row.processName) != \(processName)") }
        expect(LsofParser.classify(row) == expected, "classified \(LsofParser.classify(row)) != \(expected)")
    }

    static func main() {
        // 1. TCP listener (real row from this Mac)
        check("TCP IPv4 wildcard listener",
              line: "rapportd   1004 chip   12u  IPv4 0x3d0be8b9811368f3      0t0  TCP *:49158 (LISTEN)",
              proto: "TCP", local: "*:49158", state: "LISTEN", expected: .listener)

        // 2. TCP IPv6 loopback listener
        check("TCP IPv6 loopback listener",
              line: "node      2210 chip   22u  IPv6 0xaaaaaaaaaaaaaaaa      0t0  TCP [::1]:8080 (LISTEN)",
              proto: "TCP", local: "[::1]:8080", expected: .listener)

        // 3. TCP established flow
        check("TCP established flow",
              line: "Safari    3301 chip   30u  IPv4 0xbbbbbbbbbbbbbbbb      0t0  TCP 192.168.1.20:53210->17.253.144.10:443 (ESTABLISHED)",
              proto: "TCP", local: "192.168.1.20:53210", remote: "17.253.144.10:443", state: "ESTABLISHED", expected: .established)

        // 4. UDP listener (real row) - previously dropped
        check("UDP listener",
              line: "rapportd   1004 chip   20u  IPv4 0xef3932c40ce4c8e6      0t0  UDP *:3722",
              proto: "UDP", local: "*:3722", state: "UDP", expected: .listener)

        // 5. UDP flow with a remote side - previously dropped
        check("UDP flow",
              line: "Chrome    4410 chip   45u  IPv4 0xcccccccccccccccc      0t0  UDP 192.168.1.20:60123->142.250.80.46:443",
              proto: "UDP", local: "192.168.1.20:60123", remote: "142.250.80.46:443", expected: .established)

        // 6. Unbound UDP socket (real row) - no port to show
        check("UDP unbound socket ignored",
              line: "identitys  1035 chip   13u  IPv4 0xf9677e5fd9a87d3a      0t0  UDP *:*",
              proto: "UDP", expected: .ignored)

        // 7. Process name with an escaped space
        check("Escaped space in command name",
              line: "Google\\x20Chrome  5120 chip   18u  IPv4 0xdddddddddddddddd      0t0  TCP 10.0.0.5:51000->1.1.1.1:443 (ESTABLISHED)",
              name: "Google Chrome", expected: .established)

        // 8. TCP TIME_WAIT is not listed (TCP behaviour unchanged)
        check("TCP TIME_WAIT ignored",
              line: "curl      6001 chip   10u  IPv4 0xeeeeeeeeeeeeeeee      0t0  TCP 10.0.0.5:51001->1.1.1.1:443 (TIME_WAIT)",
              expected: .ignored)

        // 9. Short/garbage lines are rejected
        check("Short line rejected", line: "COMMAND PID USER", expected: nil)

        // 10. Protocol comes from NODE (parts[7]), never from the hex DEVICE column (parts[5])
        print("• Protocol column is NODE, not DEVICE")
        if let row = LsofParser.parseLine("rapportd   1004 chip   12u  IPv4 0x3d0be8b9811368f3      0t0  TCP *:49158 (LISTEN)") {
            expect(row.proto == "TCP", "proto should be TCP")
            expect(!row.proto.hasPrefix("0x"), "proto must not be the DEVICE hex value")
        } else {
            expect(false, "row should parse")
        }

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
