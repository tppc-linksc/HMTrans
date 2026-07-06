import Foundation
import PureSendCore

struct Options {
    var command: String = ""
    var host: String?
    var port: UInt16 = defaultPort
    var filePath: String?
    var outputDirectory: String = defaultReceiveDirectory()
}

@main
struct PureSendMacCLI {
    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case "send":
                try runSend(options)
            case "receive":
                try runReceive(options)
            default:
                throw PureSendError.usage(usageText())
            }
        } catch {
            fputs("Error: \(error)\n\n\(usageText())\n", stderr)
            exit(1)
        }
    }
}

func parseOptions(_ args: [String]) throws -> Options {
    guard let command = args.first else {
        throw PureSendError.usage(usageText())
    }

    var options = Options(command: command)
    var index = 1

    while index < args.count {
        let arg = args[index]
        func nextValue() throws -> String {
            guard index + 1 < args.count else {
                throw PureSendError.usage("缺少参数值：\(arg)")
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
                throw PureSendError.usage("端口不合法：\(value)")
            }
            options.port = port
        case "--file":
            options.filePath = try nextValue()
        case "--dir":
            options.outputDirectory = NSString(string: try nextValue()).expandingTildeInPath
        case "-h", "--help":
            throw PureSendError.usage(usageText())
        default:
            throw PureSendError.usage("未知参数：\(arg)")
        }
        index += 1
    }

    if command == "send" {
        guard options.host != nil else { throw PureSendError.usage("send 需要 --host") }
        guard options.filePath != nil else { throw PureSendError.usage("send 需要 --file") }
    } else if command != "receive" {
        throw PureSendError.usage("未知命令：\(command)")
    }

    return options
}

func runSend(_ options: Options) throws {
    guard let host = options.host, let path = options.filePath else {
        throw PureSendError.usage(usageText())
    }

    let fileURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    print("开始发送：\(fileURL.lastPathComponent)")
    try sendFile(fileURL: fileURL, host: host, port: options.port) { current, total in
        printProgress(prefix: "发送中", current: current, total: total)
    }
    print("\n传输完成，接收方校验通过。")
}

func runReceive(_ options: Options) throws {
    print("PureSend 正在监听 0.0.0.0:\(options.port)")
    print("接收目录：\(options.outputDirectory)")
    print("等待一个传输请求...")

    let received = try receiveOneFile(
        port: options.port,
        outputDirectory: options.outputDirectory,
        shouldAccept: { meta in
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
    PureSend V0.1

    接收：
      swift run puresend receive [--port 51888] [--dir ~/Downloads/PureSend]

    发送：
      swift run puresend send --host 192.168.1.35 --file /path/to/file [--port 51888]

    图形端：
      swift run PureSendMac
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
