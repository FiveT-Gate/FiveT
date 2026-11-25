import Foundation

/// `FiveT --check-network`: the route and address helpers that reconnect, split DNS and the kill switch rely on
/// (netstat's abbreviated networks, "is this address inside these networks"). Pure functions: no VPN, no root.
enum NetworkCheck {
    static func run() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failed += 1 } }
        func norm(_ s: String, _ want: String?) {
            let got = VPNManager.normalizeCIDR(s)
            check(got == want, "normalizeCIDR(\"\(s)\") = \(got ?? "nil"), expected \(want ?? "nil")")
        }
        func covered(_ ip: String, _ cidrs: [String], _ want: Bool) {
            check(VPNManager.ipv4(ip, isCoveredBy: cidrs) == want, "\(ip) \(want ? "is" : "is not") inside \(cidrs)")
        }
        // netstat writes classful networks short; the prefix is implied by how many octets are written.
        norm("192.168.22", "192.168.22.0/24")
        norm("10", "10.0.0.0/8")
        norm("172.16.101/24", "172.16.101.0/24")
        norm("10.1.2.3", "10.1.2.3/32")
        norm("10/33", "10.0.0.0/32")            // a prefix above 32 is clamped
        norm("10/abc", "10.0.0.0/8")            // an unreadable prefix falls back to the implied one
        norm("default", nil)
        norm("300.1.1.1", nil)
        norm("1.2.3.4.5", nil)
        norm("", nil)                           // used to crash: the empty string has no network part
        norm("/24", nil)
        // Membership: network, host, everything, nothing, and a bad entry that must not hide a good one.
        covered("192.168.22.7", ["192.168.22.0/24"], true)
        covered("192.168.23.7", ["192.168.22.0/24"], false)
        covered("8.8.8.8", ["0.0.0.0/0"], true)
        covered("10.0.0.5", ["10.0.0.5/32"], true)
        covered("10.0.0.6", ["10.0.0.5/32"], false)
        covered("10.9.9.9", ["bogus", "10.0.0.0/8"], true)
        covered("not-an-address", ["10.0.0.0/8"], false)
        covered("10.0.0.1", [], false)
        print(failed == 0 ? "network: all checks passed" : "network: \(failed) check(s) FAILED")
        return failed == 0 ? 0 : 1
    }
}
