#if os(macOS)
import Library
import SwiftUI

struct RouteConnectionView: View {
    @EnvironmentObject private var model: RouteHealthViewModel
    let tag: String

    @State private var editingTarget = false
    @State private var targetValue = ""
    @State private var targetInvalid = false
    @State private var showTailscale = false
    @State private var showSpeed = false
    @State private var showLogin = false
    @State private var name = ""

    var body: some View {
        if let route = model.route(tag: tag) {
            content(route)
        } else {
            ContentUnavailableCompat(title: "Подключение не найдено", subtitle: "Оно есть только в другом профиле.")
        }
    }

    private func content(_ route: RouteDescriptor) -> some View {
        let state = model.state(for: route)
        let tier = state.tier(for: route)
        let snapshot = model.snapshots[route.tag]
        let verified = state == .verified
        let target = model.target(for: route)
        return Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: route.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.accentColor))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.displayName).font(.title2.weight(.bold))
                        HStack(spacing: 5) {
                            StatusSymbol(tier: tier)
                            Text(state.title(for: route)).fontWeight(.medium)
                            Text("· \(route.kindTitle)").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if route.type == "openconnect", state == .authentication {
                        Button("Подключиться…") { showLogin = true }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else if route.type == "tailscale", tier == .fail || tier == .action {
                        Button("Вход и путь до узла…") { showTailscale = true }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Состояние") {
                LabeledContent("Последняя проверка") {
                    if verified, let snapshot {
                        let age = max(0, Int(model.now.timeIntervalSince(snapshot.checkedAt)))
                        Text("HTTPS \(snapshot.httpStatus) · " + (age == 0 ? "только что" : "\(age) с назад")).monospacedDigit()
                    } else {
                        Text(state.note.isEmpty ? "—" : state.note)
                    }
                }
                LabeledContent("Выход в интернет") {
                    if let snapshot, snapshot.reachable, !snapshot.country.isEmpty || !snapshot.exitIP.isEmpty {
                        Text([snapshot.country, snapshot.exitIP].filter { !$0.isEmpty }.joined(separator: " · ")).textSelection(.enabled)
                    } else {
                        Text(route.isWork ? "Сеть компании" : "—")
                    }
                }
                LabeledContent("Задержка") {
                    Text(verified && snapshot != nil ? "\(snapshot!.latencyMs) мс" : "—").monospacedDigit()
                }
                if verified, let snapshot, snapshot.httpStatus >= 300 {
                    Text("Канал работает. Сайт ответил HTTP \(snapshot.httpStatus): вход на сам сайт это не проверяет.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Адрес") {
                    HStack {
                        Text(target.isEmpty ? "не задан" : target.replacingOccurrences(of: "https://", with: ""))
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Изменить…") { targetValue = target; targetInvalid = false; editingTarget = true }
                    }
                }
                LabeledContent("Интервал", value: "каждые 30 с")
            } header: {
                Text("Проверка")
            } footer: {
                Text("Запрос идёт только через \(route.displayName), без обхода напрямую.")
            }

            let sites = model.sites.filter { $0.viaTag == route.tag }
            if !sites.isEmpty {
                Section("Через это подключение") {
                    ForEach(sites) { Text($0.name) }
                }
            }

            Section("Название") {
                TextField("Название", text: $name, prompt: Text(route.displayName))
                    .onSubmit { RouteDescriptor.rename(route.tag, to: name); model.objectWillChange.send() }
                    .onAppear { name = route.displayName }
            }

            Section {
                DisclosureGroup("Диагностика") {
                    LabeledContent("Тег в профиле", value: route.tag)
                    if let endpoint = model.endpointState(for: route) { LabeledContent("Состояние движка", value: endpoint) }
                    if !route.bindInterface.isEmpty { LabeledContent("Интерфейс", value: route.bindInterface) }
                    if !route.detour.isEmpty { LabeledContent("Служебный трафик", value: "через \(model.route(tag: route.detour)?.displayName ?? route.detour)") }
                    if !route.isDirect {
                        LabeledContent("Прямой обход", value: route.directFallback ? "возможен: проверьте выбор" : "запрещён")
                    }
                    let error = model.endpointError(for: route)
                    if !error.isEmpty { LabeledContent("Ошибка") { Text(error).textSelection(.enabled) } }
                    if let snapshot, !snapshot.error.isEmpty {
                        LabeledContent("Этап проверки", value: snapshot.stage)
                        LabeledContent("Ошибка проверки") { Text(snapshot.error).textSelection(.enabled) }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    if route.type == "tailscale" { Button("Вход и путь до узла…") { showTailscale = true } }
                    Button("Измерить скорость…") { showSpeed = true }.disabled(!model.telemetryFresh)
                    Button("Проверить сейчас") { model.checkNow() }
                        .disabled(!model.telemetryFresh || !model.checking.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(route.displayName)
        .sheet(isPresented: $editingTarget) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Адрес проверки").font(.headline)
                Text("HTTPS-адрес, который должен отвечать через \(route.displayName). Для рабочего VPN — внутренний сайт компании.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("https://", text: $targetValue).textFieldStyle(.roundedBorder)
                if targetInvalid { Text("Нужен HTTPS-адрес без пароля, параметров и фрагмента.").foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button("Отменить") { editingTarget = false }.keyboardShortcut(.cancelAction)
                    Button("Сохранить") {
                        if model.setTarget(targetValue, for: route) { editingTarget = false } else { targetInvalid = true }
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 420)
        }
        .sheet(isPresented: $showTailscale) {
            NavigationStackCompat {
                if let tailscale = model.tailscaleModel() {
                    TailscaleEndpointView(viewModel: tailscale, endpointTag: route.tag)
                        .toolbar { ToolbarItem { Button("Готово") { showTailscale = false } } }
                }
            }.frame(minWidth: 440, minHeight: 420)
        }
        .sheet(isPresented: $showSpeed) {
            NavigationStackCompat {
                NetworkQualityView(outboundTag: route.tag)
                    .toolbar { ToolbarItem { Button("Готово") { showSpeed = false } } }
            }.frame(minWidth: 480, minHeight: 440)
        }
        .sheet(isPresented: $showLogin) {
            NavigationStackCompat {
                OpenConnectEndpointView(viewModel: model.openConnect, endpointTag: route.tag)
                    .toolbar { ToolbarItem { Button("Готово") { showLogin = false } } }
            }.frame(minWidth: 440, minHeight: 340)
        }
    }
}

struct ContentUnavailableCompat: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
