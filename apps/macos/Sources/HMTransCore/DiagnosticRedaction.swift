import Foundation

/// 对用户主动复制的诊断文本做本地隐私脱敏；保留错误语义，不暴露局域网地址或磁盘路径。
public func redactDiagnosticTextForSharing(_ value: String) -> String {
    value
        .replacingOccurrences(
            of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            with: "<local-ip>",
            options: .regularExpression
        )
        .replacingOccurrences(
            // 不匹配 URL 中的斜杠；覆盖 /Users、/Volumes、/System、/Library、/tmp 及 ~/ 等路径。
            of: #"(?<![A-Za-z0-9:/])(?:~|/)[^\s,;]+"#,
            with: "<local-path>",
            options: .regularExpression
        )
}
