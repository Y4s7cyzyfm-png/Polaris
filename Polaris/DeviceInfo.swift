import Foundation

/// 设备与系统信息（仅用于界面展示）
enum DeviceInfo {

    /// 设备型号标识符，例如 "iPhone14,2"
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine)
            .children
            .compactMap { $0.value as? Int8 }
            .filter { $0 != 0 }
            .map { String(UnicodeScalar(UInt8(bitPattern: $0))) }
            .joined()
    }

    /// 系统版本号，例如 "17.4"
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
