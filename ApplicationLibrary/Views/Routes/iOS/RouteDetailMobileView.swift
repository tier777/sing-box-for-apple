#if os(iOS)
import Library
import SwiftUI

@available(iOS 16.0, *)
struct RouteDetailMobileView: View {
    @EnvironmentObject private var board: RoutesBoard
    let tag: String

    var body: some View {
        if let route = board.route(tag: tag) {
            content(route)
        } else {
            Text("Этого подключения нет в профиле «\(board.activeProfile?.name ?? "")».")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
    }

    private func content(_ route: RouteDescriptor) -> some View {
        let state = board.state(for: route)
        let snapshot = board.snapshot(for: route)
        let verified = state == .verified
        let sites = board.sites.filter { $0.viaTag == route.tag }
        return List {
            Section {
                HStack(spacing: 12) {
                    StatusSymbol(tier: state.tier(for: route), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title(for: route)).font(.title3.weight(.semibold))
                        if route.kindTitle != route.displayName {
                            Text(route.kindTitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if route.isWork, state == .authentication {
                    Button("Подключиться") { board.logIn(route.tag) }
                }
            }

            // Nothing to measure on a connection that is off or not logged in.
            if state.tier(for: route) != .off {
                Section("Состояние") {
                    LabeledContent("Последняя проверка") {
                        if verified, let snapshot {
                            let age = max(0, Int(board.now.timeIntervalSince(snapshot.checkedAt)))
                            Text(age == 0 ? "только что" : "\(age) с назад").monospacedDigit()
                        } else {
                            Text(state == .failed ? "не прошла" : state.note.isEmpty ? "—" : state.note)
                        }
                    }
                    LabeledContent("Выход в интернет", value: exit(route, snapshot))
                    LabeledContent("Задержка", value: verified && snapshot != nil ? "\(snapshot!.latencyMs) мс" : "—")
                }
            }

            Section {
                LabeledContent("Адрес") {
                    Text(board.target(for: route).replacingOccurrences(of: "https://", with: ""))
                        .lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("Интервал", value: "30 с")
            } header: {
                Text("Проверка")
            } footer: {
                Text("Запрос идёт только через \(route.displayName), без обхода напрямую.")
            }

            if !sites.isEmpty {
                Section("Через это подключение") {
                    ForEach(Array(sites.enumerated()), id: \.offset) { Text($1.name) }
                }
            }

            Section {
                DisclosureGroup("Диагностика") {
                    LabeledContent("Тег в профиле", value: route.tag)
                    if !route.isDirect {
                        LabeledContent("Прямой обход", value: route.directFallback ? "возможен" : "запрещён")
                    }
                    if let snapshot, !snapshot.error.isEmpty {
                        LabeledContent("Этап проверки", value: snapshot.stage)
                        LabeledContent("Ошибка", value: snapshot.error)
                    }
                }
            }

            if board.enabled {
                Section {
                    Button("Проверить сейчас") { Task { await board.refresh() } }
                    if route.isWork, state != .authentication {
                        Button("Отключиться", role: .destructive) { board.logOut(route.tag) }
                    }
                }
            }
        }
        .navigationTitle(route.displayName)
    }

    private func exit(_ route: RouteDescriptor, _ snapshot: RouteProbeSnapshot?) -> String {
        if route.isWork { return "Сеть компании" }
        guard let snapshot, snapshot.reachable else { return "—" }
        let value = [snapshot.country, snapshot.exitIP].filter { !$0.isEmpty }.joined(separator: " · ")
        return value.isEmpty ? "—" : value
    }
}
#endif
