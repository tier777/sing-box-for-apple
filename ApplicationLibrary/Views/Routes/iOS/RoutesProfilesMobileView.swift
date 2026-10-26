#if os(iOS)
import Library
import SwiftUI

struct ProfileLink: Hashable { let id: String }

@available(iOS 16.0, *)
struct RoutesProfilesMobileView: View {
    @EnvironmentObject private var board: RoutesBoard

    var body: some View {
        List {
            ForEach(board.profiles) { profile in
                NavigationLink(value: ProfileLink(id: profile.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        Text(subtitle(profile)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Профили")
        .navigationDestination(for: ProfileLink.self) { ProfileDetailMobileView(profileID: $0.id) }
    }

    private func subtitle(_ profile: RoutesBoard.Profile) -> String {
        let count = RoutesBoard.connections(in: profile.rules).count
        let connections = "\(count) \(count == 1 ? "подключение" : (2 ... 4).contains(count) ? "подключения" : "подключений")"
        return profile.id == board.activeProfileID ? "Активный · \(connections)" : connections
    }
}

@available(iOS 16.0, *)
struct ProfileDetailMobileView: View {
    @EnvironmentObject private var board: RoutesBoard
    let profileID: String
    @State private var editing: RuleSheetItem?

    var body: some View {
        if let index = board.profiles.firstIndex(where: { $0.id == profileID }) {
            content(index)
        }
    }

    private func content(_ index: Int) -> some View {
        let profile = board.profiles[index]
        let rules = profile.rules
        let editable = rules.editableIndices
        return List {
            Section {
                TextField("Название", text: $board.profiles[index].name)
                LabeledContent("Источник", value: "Файл")
                if profile.id != board.activeProfileID {
                    Button("Сделать активным") { board.activeProfileID = profile.id }
                }
            }

            Section {
                ForEach(editable, id: \.self) { ruleIndex in
                    let rule = rules.rule(at: ruleIndex)
                    Picker(selection: outbound(ruleIndex)) {
                        choices(rules)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RoutesBoard.siteTitle(rule.title))
                            if rule.detail != rule.title {
                                Text(rule.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .swipeActions(edge: .trailing) {
                        Button("Удалить", role: .destructive) { update { $0.remove(at: ruleIndex) } }
                        Button("Изменить") { editing = RuleSheetItem(index: ruleIndex) }
                    }
                }
                .onMove { from, to in move(from: from, to: to, in: editable) }
                .onDelete { offsets in
                    update { document in
                        for position in offsets.sorted(by: >) { document.remove(at: editable[position]) }
                    }
                }
                Picker("Всё остальное", selection: Binding(get: { rules.final }, set: { tag in update { $0.final = tag } })) {
                    choices(rules)
                }
                .pickerStyle(.menu)
                Button { editing = RuleSheetItem(index: nil) } label: {
                    Label("Добавить правило", systemImage: "plus")
                }
            } header: {
                Text("Правила")
            } footer: {
                Text("Срабатывает первое подходящее правило сверху.")
            }
        }
        .navigationTitle(profile.name.isEmpty ? "Профиль" : profile.name)
        .toolbar { EditButton() }
        .sheet(item: $editing) { item in
            RuleEditorMobileSheet(profileID: profileID, index: item.index)
        }
    }

    @ViewBuilder
    private func choices(_ rules: ProfileRulesDocument) -> some View {
        ForEach(RoutesBoard.connections(in: rules), id: \.tag) { route in
            Text(route.displayName).tag(route.tag)
        }
    }

    private func outbound(_ ruleIndex: Int) -> Binding<String> {
        Binding(
            get: { board.profiles.first { $0.id == profileID }?.rules.rule(at: ruleIndex).outbound ?? "" },
            set: { tag in update { $0.setOutbound(tag, at: ruleIndex) } }
        )
    }

    private func update(_ change: (inout ProfileRulesDocument) -> Void) {
        board.updateRules(of: profileID, change)
    }

    /// The document moves a rule one editable slot at a time.
    private func move(from source: IndexSet, to destination: Int, in editable: [Int]) {
        guard let start = source.first else { return }
        let end = destination > start ? destination - 1 : destination
        guard end != start else { return }
        let step = end > start ? 1 : -1
        update { document in
            var position = start
            while position != end {
                let slots = document.editableIndices
                document.move(slots[position], by: step)
                position += step
            }
        }
    }
}

private struct RuleSheetItem: Identifiable {
    let index: Int?
    var id: Int { index ?? -1 }
}

@available(iOS 16.0, *)
struct RuleEditorMobileSheet: View {
    @EnvironmentObject private var board: RoutesBoard
    @Environment(\.dismiss) private var dismiss
    let profileID: String
    let index: Int?

    @State private var sites = ""
    @State private var outbound = ""
    @State private var withDNS = true

    private var document: ProfileRulesDocument? { board.profiles.first { $0.id == profileID }?.rules }

    var body: some View {
        NavigationStack {
            if let document {
                form(document)
            }
        }
        .onAppear(perform: load)
    }

    private func form(_ document: ProfileRulesDocument) -> some View {
        let rule = index.map { document.rule(at: $0) }
        let editableSites = rule?.isSimple ?? true
        return Form {
            Section {
                if editableSites {
                    TextField("github.com", text: $sites, axis: .vertical)
                        .lineLimit(3 ... 8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } else {
                    Text(rule?.detail ?? "").foregroundStyle(.secondary)
                }
            } header: {
                Text("Сайты")
            } footer: {
                Text(editableSites
                    ? "По одному в строке: домен или подсеть. Поддомены входят автоматически."
                    : "Это составное правило: сайты в нём меняются в конфигурации профиля.")
            }
            Section {
                Picker("Через", selection: $outbound) {
                    ForEach(RoutesBoard.connections(in: document), id: \.tag) { Text($0.displayName).tag($0.tag) }
                }
                if index == nil {
                    Toggle("DNS тоже через него", isOn: $withDNS)
                        .disabled(document.dnsServer(for: outbound) == nil)
                }
            }
        }
        .navigationTitle(rule.map { RoutesBoard.siteTitle($0.title) } ?? "Новое правило")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iOS 26 sheets use the system ✕ and ✓ buttons, which leave room for the title.
            ToolbarItem(placement: .cancellationAction) {
                if #available(iOS 26.0, *) {
                    Button(role: .cancel) { dismiss() }
                } else {
                    Button("Отменить") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Group {
                    if #available(iOS 26.0, *) {
                        Button(role: .confirm) { save() }
                    } else {
                        Button(index == nil ? "Добавить" : "Готово") { save() }
                    }
                }
                .disabled(outbound.isEmpty || (index == nil && entries.isEmpty))
            }
        }
    }

    private var entries: [String] {
        sites.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func load() {
        guard let document else { return }
        if let index {
            let rule = document.rule(at: index)
            outbound = rule.outbound
            sites = rule.siteLines.joined(separator: "\n")
        } else {
            let routes = RoutesBoard.connections(in: document)
            outbound = routes.first { !$0.isDirect }?.tag ?? routes.first?.tag ?? ""
        }
    }

    private func save() {
        let entries = entries
        board.updateRules(of: profileID) { document in
            if let index {
                document.setOutbound(outbound, at: index)
                if document.rule(at: index).isSimple, !entries.isEmpty { document.setSites(entries, at: index) }
            } else {
                document.insertRule(sites: entries, outbound: outbound, dns: withDNS)
            }
        }
        dismiss()
    }
}
#endif
