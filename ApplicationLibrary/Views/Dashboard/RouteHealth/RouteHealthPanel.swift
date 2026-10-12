import Library
import SwiftUI

@MainActor
public struct RouteHealthPanel: View {
    @EnvironmentObject private var model: RouteHealthViewModel
    @State private var editing: RouteDescriptor?
    @State private var targetValue = ""
    @State private var validationError = false
    @State private var authenticating: RouteDescriptor?
    @State private var diagnosing: RouteDescriptor?
    @State private var measuring: RouteDescriptor?

    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подключения и маршруты").font(.title2.weight(.semibold))
                    Text(model.networkInterfaces).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.checkNow() } label: {
                    Label(model.checking.isEmpty ? "Проверить сейчас" : "Проверяем…", systemImage: "arrow.clockwise")
                }.disabled(!model.telemetryFresh || !model.checking.isEmpty || model.sleeping)
            }
            Text(model.diagnosis).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("route-health-diagnosis")
            #if os(macOS)
            if model.needsEngineSetup {
                Text("Локальный движок работает без Apple Network Extension. Для настройки нужны права администратора. Установка сама по себе VPN не включает.")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Button(model.installingEngine ? "Настраиваем…" : "Настроить локальный движок") { model.installEngine() }
                    .buttonStyle(.borderedProminent).disabled(model.installingEngine)
            }
            #endif
            if let error = model.catalogError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if model.routes.isEmpty {
                Text(model.enabled ? "Ожидаем список маршрутов от запущенного движка…" : "Запусти профиль, чтобы увидеть его VPN и прямой выход.")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ForEach(model.routes) { route in
                    Divider()
                    RouteHealthRow(route: route, state: model.state(for: route), snapshot: model.snapshots[route.tag], target: model.target(for: route), endpointState: model.endpointState(for: route), endpointError: model.endpointError(for: route), selectedOutbound: model.selectedOutbound(for: route), now: model.now, configure: {
                        targetValue = model.target(for: route); validationError = false; editing = route
                    }, authenticate: { authenticating = route })
                    HStack {
                        if route.type == "tailscale" { Button("Tailscale: вход и диагностика пути") { diagnosing = route } }
                        Button("Измерить скорость маршрута") { measuring = route }.disabled(!model.telemetryFresh)
                    }.font(.caption)
                }
            }
            Text("«Проверено» подтверждает последний HTTPS-запрос, а не постоянную доступность сайта. При выключенном SFM правила VPN не защищают трафик.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $editing) { route in
            VStack(alignment: .leading, spacing: 16) {
                Text("Проверка \(route.tag)").font(.title2)
                Text("Укажи HTTPS-адрес, который должен отвечать через этот маршрут. Для рабочего VPN используй внутренний сайт компании.")
                TextField("https://…", text: $targetValue).textFieldStyle(.roundedBorder)
                if validationError { Text("Нужен HTTPS-адрес без пароля, параметров запроса и фрагмента.").foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Отмена") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Сохранить и проверить") {
                        if model.setTarget(targetValue, for: route) { editing = nil } else { validationError = true }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 420, idealWidth: 480)
        }
        .sheet(item: $diagnosing) { route in
            NavigationStackCompat {
                if let tailscale = model.tailscaleModel() { TailscaleEndpointView(viewModel: tailscale, endpointTag: route.tag)
                    .toolbar { ToolbarItem { Button("Закрыть") { diagnosing = nil } } }
                }
            }.frame(minWidth: 440, minHeight: 420)
        }
        .sheet(item: $measuring) { route in
            NavigationStackCompat {
                NetworkQualityView(outboundTag: route.tag)
                    .toolbar { ToolbarItem { Button("Закрыть") { measuring = nil } } }
            }.frame(minWidth: 480, minHeight: 440)
        }
        .sheet(item: $authenticating) { route in
            NavigationStackCompat {
                OpenConnectEndpointView(viewModel: model.openConnect, endpointTag: route.tag)
                    .toolbar { ToolbarItem { Button("Закрыть") { authenticating = nil } } }
            }.frame(minWidth: 440, minHeight: 340)
        }
    }
}
