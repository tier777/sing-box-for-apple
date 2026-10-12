#if os(macOS)
import Foundation
import Libbox
import Security
import Darwin

public enum LocalEngine {
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
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        try client.localEngineStart(config)
    }
    public static func stop() throws {
        let client = LibboxNewStandaloneCommandClient()!
        defer { try? client.disconnect() }
        try client.localEngineStop()
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
        guard let script = Bundle.main.url(forResource: "install-local-engine", withExtension: "sh") else {
            throw engineError("В сборке отсутствует установщик локального движка.")
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
        let argumentStrings: [String] = [script.path, Bundle.main.bundleURL.path, String(describing: Darwin.getuid())]
        var argv: [UnsafeMutablePointer<CChar>?] = []
        for argument in argumentStrings { argv.append(argument.withCString { strdup($0) }) }
        argv.append(nil)
        defer { for pointer in argv { if let pointer { free(pointer) } } }
        // The Security framework still exports this administrator-authorized API,
        // although modern Swift SDKs mark its direct declaration unavailable.
        typealias Execute = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else { throw engineError("macOS не предоставляет API установки локального движка.") }
        let execute = unsafeBitCast(symbol, to: Execute.self)
        let result: OSStatus = argv.withUnsafeMutableBufferPointer { buffer in
            "/bin/sh".withCString { executable in execute(authorization, executable, 0, buffer.baseAddress!, nil) }
        }
        guard result == errAuthorizationSuccess else { throw engineError("Не удалось запустить установщик: \(result)") }
    }
    private static func engineError(_ message: String) -> NSError { NSError(domain: "LocalEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
#endif
