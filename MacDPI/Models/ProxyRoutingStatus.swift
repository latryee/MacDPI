import Foundation
import SystemConfiguration

/// Read-only. No SCPreferences writes, authorizations, or networksetup execution from the app.
enum ProxyRoutingStatus {
    static func systemHTTPSProxyMatches(port: UInt16) -> Bool {
        guard let proxy = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return (proxy[kSCPropNetProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true
            && (proxy[kSCPropNetProxiesHTTPSProxy as String] as? String) == "127.0.0.1"
            && (proxy[kSCPropNetProxiesHTTPSPort as String] as? NSNumber)?.uint16Value == port
    }
}
