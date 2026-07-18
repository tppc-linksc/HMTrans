import Foundation
import HMTransCore

struct Options {
    var command: String = ""
    var host: String?
    var port: UInt16 = defaultPort
    var filePath: String?
    var outputDirectory: String = defaultReceiveDirectory()
    var deviceId: String?
    var fingerprint: String?
    var sharedSecret: String?
}

@main
struct HMTransMacCLI {
    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case "send":
                try runSend(options)
            case "receive":
                try runReceive(options)
            default:
                throw HMTransError.usage(usageText())
            }
        } catch {
            fputs("Error: \(error)\n\n\(usageText())\n", stderr)
            exit(1)
        }
    }
}

func parseOptions(_ args: [String]) throws -> Options {
    guard let command = args.first else {
        throw HMTransError.usage(usageText())
    }

    var options = Options(command: command)
    var index = 1

    while index < args.count {
        let arg = args[index]
        func nextValue() throws -> String {
            guard index + 1 < args.count else {
                throw HMTransError.usage("缺少参数值：\(arg)")
            }
            index += 1
            return args[index]
        }

        switch arg {
        case "--host":
            options.host = try nextValue()
        case "--port":
            let value = try nextValue()
            guard let port = UInt16(value) else {
                throw HMTransError.usage("端口不合法：\(value)")
            }
            options.port = port
        case "--file":
            options.filePath = try nextValue()
        case "--dir":
            options.outputDirectory = NSString(string: try nextValue()).expandingTildeInPath
        case "--device-id":
            options.deviceId = try nextValue()
        case "--fingerprint":
            options.fingerprint = try nextValue()
        case "--secret":
            options.sharedSecret = try nextValue().lowercased()
        case "-h", "--help":
            throw HMTransError.usage(usageText())
        default:
            throw HMTransError.usage("未知参数：\(arg)")
        }
        index += 1
    }

    if command == "send" {
        guard options.host != nil else { throw HMTransError.usage("send 需要 --host") }
        guard options.filePath != nil else { throw HMTransError.usage("send 需要 --file") }
        guard options.deviceId?.isEmpty == false else { throw HMTransError.usage("send 需要 --device-id") }
        guard options.fingerprint?.isEmpty == false else { throw HMTransError.usage("send 需要 --fingerprint") }
        guard options.sharedSecret?.count == 64 else { throw HMTransError.usage("send 需要 64 位十六进制 --secret") }
    } else if command != "receive" {
        throw HMTransError.usage("未知命令：\(command)")
    } else if options.sharedSecret?.count != 64 {
        throw HMTransError.usage("receive 需要 64 位十六进制 --secret")
    }

    return options
}

func runSend(_ options: Options) throws {
    guard let host = options.host, let path = options.filePath,
          let deviceId = options.deviceId, let fingerprint = options.fingerprint,
          let sharedSecret = options.sharedSecret else {
        throw HMTransError.usage(usageText())
    }

    let fileURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    print("开始发送：\(fileURL.lastPathComponent)")
    try sendFile(
        fileURL: fileURL,
        host: host,
        port: options.port,
        senderDeviceId: deviceId,
        senderName: Host.current().localizedName ?? "Mac CLI",
        senderPlatform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        senderFingerprint: fingerprint,
        sharedSecret: sharedSecret,
        onProgress: { current, total in
        printProgress(prefix: "发送中", current: current, total: total)
        }
    )
    print("\n传输完成，接收方校验通过。")
}

func runReceive(_ options: Options) throws {
    guard let sharedSecret = options.sharedSecret else { throw HMTransError.usage(usageText()) }
    print("HMTrans 正在监听 0.0.0.0:\(options.port)")
    print("接收目录：\(options.outputDirectory)")
    print("等待一个传输请求...")

    let received = try receiveOneFile(
        port: options.port,
        outputDirectory: options.outputDirectory,
        shouldAccept: { meta in
            guard verifyFileMetaAuthentication(meta, sharedSecret: sharedSecret) else {
                print("拒绝：文件元数据认证失败")
                return false
            }
            print("")
            print("收到文件请求：")
            print("  文件名：\(meta.fileName)")
            print("  大小：\(formatBytes(meta.fileSize))")
            print("  SHA-256：\(meta.sha256)")
            print("是否接收？[y/N]: ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return answer == "y" || answer == "yes"
        },
        onProgress: { _, current, total in
            printProgress(prefix: "接收中", current: current, total: total)
        }
    )

    if let received {
        print("\n已保存：\(received.url.path)")
    } else {
        print("已拒绝。")
    }
}

func usageText() -> String {
    """
    HMTrans V0.3

    接收：
      swift run hmtrans receive --secret <64位配对主密钥> [--port 51888] [--dir ~/Downloads/HMTrans]

    发送：
      swift run hmtrans send --host 192.168.1.35 --file /path/to/file \
        --device-id <本机设备ID> --fingerprint <本机身份指纹> --secret <64位配对主密钥> [--port 51888]

    图形端：
      swift run HMTransMac
    """
}

func printProgress(prefix: String, current: Int64, total: Int64) {
    let percent = total == 0 ? 100.0 : Double(current) / Double(total) * 100.0
    print("\r\(prefix)：\(String(format: "%.1f", percent))% (\(formatBytes(current)) / \(formatBytes(total)))", terminator: "")
    fflush(stdout)
    if current == total {
        print("")
    }
}
