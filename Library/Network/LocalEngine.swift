#if os(macOS)
import Foundation
import CryptoKit
import Libbox
import Security
import Darwin

public enum LocalEngine {
    private static let engineVersion = EngineVersionCache()
    public static var isCurrentVersion: Bool { engineVersion.matchesBundle() }
    public static var socketDirectory: URL {
        URL(fileURLWithPath: "/var/run/io.github.tier777.sfmroutes-\(getuid())", isDirectory: true)
    }
    public static var isAvailable: Bool { FileManager.default.fileExists(atPath: socketDirectory.appendingPathComponent("command.sock").path) }

    public static func state() throws -> LibboxLocalEngineState {
        guard isAvailable else { throw engineError("Локальный движок не установлен или не запущен. Нажми «Настроить локальный движок» на главной панели.") }
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        return try client.getLocalEngineState()
    }
    public static func start(_ config: String) throws {
        guard isAvailable else { throw engineError("Сначала настрой локальный движок на главной панели.") }
        guard isCurrentVersion else { throw engineError("Обновите движок SFM+ на главной панели. Установленная версия не поддерживает текущие правила kill switch.") }
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        try client.localEngineStart(config)
    }
    public static func stop() throws {
        guard isCurrentVersion else { throw engineError("Сначала обновите движок SFM+: старая версия снимает блокировку при выключении VPN. Kill switch можно отключить отдельно.") }
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        try client.localEngineStop()
    }
    public static func leakProtection() throws -> LibboxLocalEngineLeakProtection {
        guard isAvailable else { throw engineError("Локальный движок не установлен.") }
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        return try client.getLocalEngineLeakProtection()
    }
    public static func setLeakProtection(_ enabled: Bool) throws -> LibboxLocalEngineLeakProtection {
        guard isAvailable else { throw engineError("Сначала настрой локальный движок на главной панели.") }
        if enabled, !isCurrentVersion { throw engineError("Сначала обновите движок SFM+ на главной панели.") }
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        return try client.setLocalEngineLeakProtection(enabled)
    }
    public static func wake() throws {
        guard isAvailable else { return }
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        try client.localEngineWake()
    }

    // Standard macOS administrator authorization. The password goes to the OS,
    // never into our process, profile files, logs or chat.
    public static func install() throws {
        try executeAdminScript("install-local-engine", arguments: [Bundle.main.bundleURL.path, String(describing: Darwin.getuid())])
    }

    public static func emergencyDisableProtection() throws {
        try executeAdminScript("disable-kill-switch", arguments: [])
    }

    private static func executeAdminScript(_ name: String, arguments: [String]) throws {
        guard let script = Bundle.main.url(forResource: name, withExtension: "sh") else {
            throw engineError("В сборке отсутствует необходимая служебная команда: \(name).")
        }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { throw engineError("Не удалось запросить разрешение администратора.") }
        defer { AuthorizationFree(authorization, []) }
        let name = strdup(kAuthorizationRightExecute)!
        defer { free(name) }
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        let allowed = withUnsafeMutablePointer(to: &item) { pointer in
            var rights = AuthorizationRights(count: 1, items: pointer)
            return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
        }
        guard allowed == errAuthorizationSuccess else { throw engineError("Установка не разрешена: \(allowed)") }
        let argumentStrings = [script.path] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = []
        for argument in argumentStrings { argv.append(argument.withCString { strdup($0) }) }
        argv.append(nil)
        defer { for pointer in argv { if let pointer { free(pointer) } } }
        // The Security framework still exports this administrator-authorized API,
        // although modern Swift SDKs mark its direct declaration unavailable.
        typealias Execute = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else { throw engineError("macOS не предоставляет API установки локального движка.") }
        let execute = unsafeBitCast(symbol, to: Execute.self)
        var output: UnsafeMutablePointer<FILE>?
        let result: OSStatus = argv.withUnsafeMutableBufferPointer { buffer in
            "/bin/sh".withCString { executable in execute(authorization, executable, 0, buffer.baseAddress!, &output) }
        }
        guard result == errAuthorizationSuccess else { throw engineError("Не удалось запустить установщик: \(result)") }
        guard let output else { throw engineError("Не удалось прочитать результат служебной команды.") }
        defer { fclose(output) }
        var bytes = Data()
        while bytes.count < 32_768 {
            let byte = fgetc(output)
            if byte == EOF { break }
            bytes.append(UInt8(byte))
        }
        let message = String(data: bytes, encoding: .utf8) ?? ""
        guard message.split(whereSeparator: \.isNewline).contains("SFM_PLUS_OK") else {
            throw engineError("Служебная команда не завершилась успешно. \(message.suffix(900))")
        }
    }
    private static func engineError(_ message: String) -> NSError { NSError(domain: "LocalEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

// RPC compatibility alone cannot distinguish an older helper whose StopProfile
// releases the firewall. Match the packaged helper before using its lifecycle.
// Cache by file identity so the status poll does not hash binaries every 2 seconds.
private final class EngineVersionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var matches = false

    func matchesBundle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let bundled = Bundle.main.url(forResource: "sfm-route-engine", withExtension: nil) else { return false }
        let installed = URL(fileURLWithPath: "/Library/Application Support/SFMRoutes/engine")
        do {
            let urls = [bundled, installed]
            let identities = try urls.map { url -> String in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return "\(url.path)|\(attributes[.systemFileNumber] ?? "")|\(attributes[.size] ?? "")|\(attributes[.modificationDate] ?? "")"
            }.joined(separator: ";")
            if identities == key { return matches }
            let expected = try Data(contentsOf: bundled, options: .mappedIfSafe)
            let actual = try Data(contentsOf: installed, options: .mappedIfSafe)
            matches = SHA256.hash(data: expected) == SHA256.hash(data: actual)
            key = identities
            return matches
        } catch { return false }
    }
}
#endif
