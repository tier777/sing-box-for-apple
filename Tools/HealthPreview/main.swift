import AppKit
import SwiftUI

// Entitlement-free preview of the SAME row used by the VPN app. All values are
// explicitly synthetic. It cannot create tunnels, log in or change networking.
struct HealthPreview: View {
    @State private var scenario = "Работает"
    let routes = try! JSONDecoder().decode(RouteCatalog.self, from: Data(#"{"routes":[{"tag":"CLAUDE","type":"hysteria2","destinations":["Claude / Anthropic"]},{"tag":"YOUTUBE","type":"tailscale","destinations":["YouTube","Telegram","OpenAI"]},{"tag":"DIRECT","type":"direct","destinations":[".ru","Ozon"],"directFallback":true},{"tag":"FORTINET","type":"openconnect","destinations":["Внутренние сайты компании"]}]}"#.utf8)).routes!
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Подключения и маршруты").font(.title2.weight(.semibold))
                        Text("Демонстрация интерфейса · данные условные").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Сценарий", selection: $scenario) { ForEach(["Работает", "Обрыв VPN", "После сна", "OTP"], id: \.self) { Text($0) } }.frame(width: 170)
                }
                Text(scenario == "Обрыв VPN" ? "Прямой интернет отвечает, но Tailscale не проходит проверку. Переключать Wi-Fi пока нет оснований." : scenario == "После сна" ? "После сна — проверяем подключения. Старые результаты больше не подтверждают связь." : "Маршруты проверяем отдельно. Нулевой трафик сам по себе не означает обрыв.")
                ForEach(routes) { route in
                    Divider()
                    RouteHealthRow(route: route, state: state(route), snapshot: .init(reachable: true, checkedAt: Date().addingTimeInterval(-3), latencyMs: route.isDirect ? 24 : 116, httpStatus: 200, stage: "http", exitIP: route.isDirect ? "198.51.100.10" : "203.0.113.20", country: route.tag == "CLAUDE" ? "DE" : "NL"), target: route.isWork ? "" : "https://www.cloudflare.com/cdn-cgi/trace", endpointState: route.type == "tailscale" ? "Running" : nil, now: Date(), configure: {}, authenticate: {})
                }
                Text("«Проверено» подтверждает последний HTTPS-запрос. При выключенном SFM правила VPN не защищают трафик.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 640, minHeight: 760)
    }
    func state(_ route: RouteDescriptor) -> RouteHealthState {
        if scenario == "После сна" { return .checking }
        if scenario == "Обрыв VPN" && route.type == "tailscale" { return .failed }
        if route.isWork { return scenario == "OTP" ? .authentication : .unconfigured }
        return .verified
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 840), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "SFM · предварительный просмотр"
window.contentView = NSHostingView(rootView: HealthPreview())
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
if CommandLine.arguments.count > 1 {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.terminate(nil)
    }
}
app.run()
