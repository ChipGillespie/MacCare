import Foundation

/// A single parsed row of `lsof -i -n -P` output.
struct ParsedLsofRow: Equatable {
    let processName: String
    let pid: Int32
    let user: String
    let proto: String          // "TCP" or "UDP"
    let localEndpoint: String
    let remoteEndpoint: String // "—" when there is no remote side
    let state: String          // e.g. LISTEN, ESTABLISHED, or "UDP" for connectionless sockets
    let isListening: Bool
}

enum LsofClassification: Equatable {
    case listener
    case established
    case ignored
}

enum LsofParser {
    /// Parses one data line of `lsof -i -n -P` output.
    ///
    /// Column layout (see lsof(8), "OUTPUT"):
    ///   COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
    ///      0     1    2   3   4     5       6      7    8...
    ///
    /// NOTE: parts[7] (NODE) is the protocol (TCP/UDP) for `lsof -i`.
    /// parts[5] (DEVICE) is a hex kernel address, NOT the protocol.
    /// Do not "fix" this indexing; it is correct per lsof(8).
    static func parseLine(_ line: String) -> ParsedLsofRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { return nil }

        let proto = parts[7]
        guard proto == "TCP" || proto == "UDP" else { return nil }

        let processName = parts[0].replacingOccurrences(of: "\\x20", with: " ")
        let pid = Int32(parts[1]) ?? 0
        let user = parts[2]

        let nameAndState = parts[8...].joined(separator: " ")
        var state = "ACTIVE"
        var endpointPart = nameAndState

        if let parenStart = nameAndState.range(of: " ("),
           let parenEnd = nameAndState.range(of: ")", range: parenStart.upperBound..<nameAndState.endIndex) {
            state = String(nameAndState[parenStart.upperBound..<parenEnd.lowerBound])
            endpointPart = String(nameAndState[..<parenStart.lowerBound])
        } else if proto == "UDP" {
            state = "UDP"
        }

        var localEP = endpointPart
        var remoteEP = "—"
        if let arrowRange = endpointPart.range(of: "->") {
            localEP = String(endpointPart[..<arrowRange.lowerBound])
            remoteEP = String(endpointPart[arrowRange.upperBound...])
        }

        let isListening = (state == "LISTEN") || (proto == "UDP" && !endpointPart.contains("->"))

        return ParsedLsofRow(
            processName: processName,
            pid: pid,
            user: user,
            proto: proto,
            localEndpoint: localEP,
            remoteEndpoint: remoteEP,
            state: state,
            isListening: isListening
        )
    }

    /// Decides which list (if any) a parsed row belongs in.
    /// TCP behaviour is unchanged. UDP listeners show as listeners and UDP flows as established.
    static func classify(_ row: ParsedLsofRow) -> LsofClassification {
        if row.proto == "UDP" {
            if row.remoteEndpoint != "—" { return .established }
            // Unbound sockets (`*:*`) have no port to report.
            if row.localEndpoint == "*:*" { return .ignored }
            return .listener
        }
        if row.state == "LISTEN" { return .listener }
        if row.state == "ESTABLISHED" || row.state == "SYN_SENT" || row.state == "CLOSE_WAIT" {
            return .established
        }
        return .ignored
    }

    static func isWildcardBind(_ row: ParsedLsofRow) -> Bool {
        row.isListening && (
            row.localEndpoint.hasPrefix("*:") ||
            row.localEndpoint.hasPrefix("0.0.0.0:") ||
            row.localEndpoint.hasPrefix("[::]:")
        )
    }
}
