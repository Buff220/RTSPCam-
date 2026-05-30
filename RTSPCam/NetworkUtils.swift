import Foundation
import Network

struct NetworkUtils {
    /// Returns the device's current WiFi/LAN IPv4 address, or nil if not connected.
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && !isLoopback,
               current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                // Prefer en0 (WiFi) but accept any non-loopback
                let name = String(cString: current.pointee.ifa_name)
                if name == "en0" {
                    return ip
                } else if address == nil {
                    address = ip
                }
            }
            ptr = current.pointee.ifa_next
        }
        return address
    }
}
