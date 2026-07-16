import Foundation

struct LocalPairingIdentity: Sendable {
    let deviceID: String
    let fingerprint: String
}

/**
 将本机身份与配对关系保存在应用数据目录中。

 覆盖安装和正常升级不会改变该文件，因此已配对设备可以自动重连；清除
 `~/Library/Application Support/HMTrans` 后再次启动会生成全新的身份。
 */
enum PairingConfigurationStore {
    private struct Configuration: Codable {
        var schemaVersion: Int
        var deviceID: String
        var fingerprint: String
        var trustedDeviceIDs: Set<String>
        var trustedFingerprints: [String: String]
        var sharedSecrets: [String: String]?
    }

    /** 可变缓存只在同一个锁内访问；封装后避免把共享可变状态暴露为全局变量。 */
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var cached: Configuration?
    }

    private static let storage = Storage()
    private static let legacyTrustedIDsKey = "trustedDeviceIds.v3.deviceSnapshot"
    private static let legacyFingerprintsKey = "trustedDeviceFingerprints.v1"

    static func localIdentity() -> LocalPairingIdentity {
        storage.lock.withLock {
            let configuration = loadLocked()
            return LocalPairingIdentity(
                deviceID: configuration.deviceID,
                fingerprint: configuration.fingerprint
            )
        }
    }

    static func contains(_ deviceID: String?) -> Bool {
        guard let deviceID, !deviceID.isEmpty else { return false }
        return storage.lock.withLock { loadLocked().trustedDeviceIDs.contains(deviceID) }
    }

    static func insert(_ deviceID: String?, fingerprint: String?, sharedSecret: String? = nil) {
        guard let deviceID, !deviceID.isEmpty else { return }
        storage.lock.withLock {
            var configuration = loadLocked()
            configuration.trustedDeviceIDs.insert(deviceID)
            if let fingerprint, !fingerprint.isEmpty {
                configuration.trustedFingerprints[deviceID] = fingerprint
            }
            if let sharedSecret, sharedSecret.count == 64 {
                var secrets = configuration.sharedSecrets ?? [:]
                secrets[deviceID] = sharedSecret.lowercased()
                configuration.sharedSecrets = secrets
            }
            saveLocked(configuration)
        }
    }

    static func sharedSecret(for deviceID: String?) -> String? {
        guard let deviceID, !deviceID.isEmpty else { return nil }
        return storage.lock.withLock { loadLocked().sharedSecrets?[deviceID] }
    }

    static func matches(_ deviceID: String?, fingerprint: String?) -> Bool {
        guard let deviceID, !deviceID.isEmpty,
              let fingerprint, !fingerprint.isEmpty
        else { return false }
        return storage.lock.withLock {
            let configuration = loadLocked()
            return configuration.trustedDeviceIDs.contains(deviceID)
                && configuration.trustedFingerprints[deviceID] == fingerprint
        }
    }

    static func remove(_ deviceID: String?) {
        guard let deviceID, !deviceID.isEmpty else { return }
        storage.lock.withLock {
            var configuration = loadLocked()
            configuration.trustedDeviceIDs.remove(deviceID)
            configuration.trustedFingerprints.removeValue(forKey: deviceID)
            configuration.sharedSecrets?.removeValue(forKey: deviceID)
            saveLocked(configuration)
        }
    }

    private static func loadLocked() -> Configuration {
        if let cached = storage.cached { return cached }
        if let data = try? Data(contentsOf: configurationURL),
           let decoded = try? JSONDecoder().decode(Configuration.self, from: data),
           !decoded.deviceID.isEmpty,
           !decoded.fingerprint.isEmpty {
            storage.cached = decoded
            return decoded
        }

        let defaults = UserDefaults.standard
        let legacyDeviceID = defaults.string(forKey: "deviceId")
        let legacyFingerprint = defaults.string(forKey: "identityFingerprint")
        let trustedIDs = Set(defaults.stringArray(forKey: legacyTrustedIDsKey) ?? [])
        let trustedFingerprints = defaults.dictionary(forKey: legacyFingerprintsKey) as? [String: String] ?? [:]
        let configuration = Configuration(
            schemaVersion: 1,
            deviceID: nonEmpty(legacyDeviceID) ?? "mac-\(UUID().uuidString)",
            fingerprint: nonEmpty(legacyFingerprint)
                ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            trustedDeviceIDs: trustedIDs,
            trustedFingerprints: trustedFingerprints,
            sharedSecrets: nil
        )
        if saveLocked(configuration) {
            removeLegacyValues()
        }
        return configuration
    }

    @discardableResult
    private static func saveLocked(_ configuration: Configuration) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: configurationURL, options: [.atomic])
            storage.cached = configuration
            return true
        } catch {
            // 写入失败时仍保留进程内状态，同时将原因写入系统日志，避免静默丢失配对。
            storage.cached = configuration
            NSLog("HMTrans pairing configuration write failed: %@", error.localizedDescription)
            return false
        }
    }

    private static func removeLegacyValues() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "deviceId")
        defaults.removeObject(forKey: "identityFingerprint")
        defaults.removeObject(forKey: legacyTrustedIDsKey)
        defaults.removeObject(forKey: legacyFingerprintsKey)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static var configurationURL: URL {
        let root = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("HMTrans/Config", isDirectory: true)
            .appendingPathComponent("pairing.json", isDirectory: false)
    }
}
