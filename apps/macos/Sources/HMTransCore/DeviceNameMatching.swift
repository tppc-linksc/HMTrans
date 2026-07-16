import Foundation

/// 历史记录展示使用的设备名称别名判断。安全信任仍必须使用安装级 device ID 和指纹。
public func deviceDisplayNamesAreAliases(_ lhs: String, _ rhs: String) -> Bool {
    let left = normalizedDeviceDisplayName(lhs)
    let right = normalizedDeviceDisplayName(rhs)
    guard !left.isEmpty, !right.isEmpty else { return false }
    if left == right { return true }

    return ownerQualifiedName(left, hasBaseName: right)
        || ownerQualifiedName(right, hasBaseName: left)
}

private func normalizedDeviceDisplayName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
        .lowercased()
}

private func ownerQualifiedName(_ qualified: String, hasBaseName base: String) -> Bool {
    ["的", "'s ", "’s "].contains { separator in
        qualified.hasSuffix(separator + base)
    }
}
