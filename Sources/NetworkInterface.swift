import Darwin
import Foundation

/// The Mac's primary LAN IPv4 address (Wi-Fi/Ethernet en0/en1), or nil when only loopback is up.
///
/// The stream proxy advertises this so AirPlay receivers on the same network can reach it: when you
/// AirPlay an HLS stream, the receiver (e.g. an Apple TV) fetches the manifest and segments itself and
/// cannot reach the Mac's 127.0.0.1. Serving on the LAN address lets both the local player and the
/// receiver load the stream.
func primaryIPv4Address() -> String? {
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
        return nil
    }
    defer { freeifaddrs(ifaddrPointer) }

    var preferred: String?
    var fallback: String?

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = pointer.pointee
        let flags = Int32(interface.ifa_flags)
        guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else {
            continue
        }
        guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr,
            socklen_t(addr.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else {
            continue
        }
        let ip = String(cString: host)
        guard !ip.isEmpty else {
            continue
        }

        // Prefer the standard Wi-Fi/Ethernet interfaces; keep the first other candidate as a fallback.
        let name = String(cString: interface.ifa_name)
        if name == "en0" || name == "en1" {
            preferred = ip
            break
        }
        if fallback == nil {
            fallback = ip
        }
    }

    return preferred ?? fallback
}
