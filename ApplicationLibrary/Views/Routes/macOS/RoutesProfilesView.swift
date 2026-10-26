#if os(macOS)
import Libbox
import Library
import SwiftUI

struct RoutesProfilesView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @ObservedObject var store: RoutesProfileStore
    @State private var showNew = false

    var body: some View {
        Form {
            Section {
                if store.list.isEmpty {
                    Text("Профилей пока нет").foregroundStyle(.secondary)
                }
                ForEach(store.list, id: \.mustID) { profile in
                    HStack(spacing: 10) {
                        Button { select(profile) } label: {
                            Image(systemName: profile.mustID == store.selectedID ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(profile.mustID == store.selectedID ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Сделать активным")
                        .accessibilityLabel("Сделать «\(profile.name)» активным")
                        NavigationLink {
                            RoutesProfileDetailView(profile: profile, store: store)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name).fontWeight(.medium)
                                Text(sourceLine(profile)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Профили")
            } footer: {
                Text("Кружок выбирает активный профиль. Строка открывает его настройки.")
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button { showNew = true } label: { Label("Новый профиль", systemImage: "plus") }
                    .help("Новый профиль")
            }
        }
        .sheet(isPresented: $showNew) {
            NewProfileMenuView(onComplete: { showNew = false; Task { await store.reload() } })
                .environmentObject(environments)
                .frame(minWidth: 420, minHeight: 360)
        }
    }

    private func sourceLine(_ profile: Profile) -> String {
        var parts: [String] = []
        switch profile.type {
        case .local: parts.append("Файл")
        case .icloud: parts.append("iCloud")
        case .remote: parts.append("По ссылке")
        }
        if let updated = profile.lastUpdated { parts.append("обновлён " + updated.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func select(_ profile: Profile) {
        guard profile.mustID != store.selectedID else { return }
        Task {
            await SharedPreferences.selectedProfileID.set(profile.mustID)
            store.selectedID = profile.mustID
            environments.selectedProfileUpdate.send()
            if let extensionProfile = environments.extensionProfile, extensionProfile.status.isConnected {
                try? await extensionProfile.reloadService()
            }
        }
    }
}

struct RoutesProfileDetailView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profile: Profile
    @ObservedObject var store: RoutesProfileStore

    @State private var document: ProfileRulesDocument?
    @State private var loadError: String?
    @State private var dirty = false
    @State private var saving = false
    @State private var alert: AlertState?
    @State private var newRule = false
    @State private var editingRule: Int?
    @State private var confirmDelete = false
    @State private var originalName = ""

    var body: some View {
        Form {
            Section("Профиль") {
                TextField("Название", text: $profile.name, prompt: Text("Обязательно"))
                    .onChangeCompat(of: profile.name) { _ in dirty = profile.name != originalName || dirty }
                LabeledContent("Источник", value: profile.type == .remote ? "По ссылке" : profile.type == .icloud ? "iCloud" : "Файл")
                if profile.type == .remote {
                    TextField("Ссылка", text: $profile.remoteURL.unwrapped(""), prompt: Text("https://"))
                        .onChangeCompat(of: profile.remoteURL) { _ in dirty = true }
                    Picker("Обновлять автоматически", selection: Binding(
                        get: { profile.autoUpdate ? Int(profile.autoUpdateInterval) : 0 },
                        set: { minutes in profile.autoUpdate = minutes > 0; if minutes > 0 { profile.autoUpdateInterval = Int32(minutes) }; dirty = true }
                    )) {
                        Text("Никогда").tag(0)
                        Text("Каждый час").tag(60)
                        Text("Раз в день").tag(1440)
                        Text("Раз в неделю").tag(10080)
                        if profile.autoUpdate, ![60, 1440, 10080].contains(Int(profile.autoUpdateInterval)) {
                            Text("Каждые \(profile.autoUpdateInterval) мин").tag(Int(profile.autoUpdateInterval))
                        }
                    }
                    LabeledContent("Обновлено") {
                        HStack {
                            Text(profile.lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            Button("Обновить сейчас") { updateRemote() }.disabled(saving)
                        }
                    }
                }
            }

            if let document {
                rulesSection(document)
            } else if let loadError {
                Section("Правила") { Text(loadError).foregroundStyle(.secondary) }
            }

            Section("Дополнительно") {
                LabeledContent {
                    Button("Редактировать JSON…") {
                        openWindow(value: EditProfileContentView.Context(profileID: profile.mustID, readOnly: false))
                    }
                } label: {
                    Text("Конфигурация sing-box")
                    Text("Всё, чего нет в настройках выше")
                }
                HStack {
                    Spacer()
                    Button("Удалить профиль…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name.isEmpty ? "Профиль" : profile.name)
        .toolbar {
            if dirty {
                ToolbarItem { Button("Отменить") { revert() } }
                ToolbarItem {
                    Button("Применить") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || profile.name.isEmpty)
                        .help(isActive ? "Сохранить и перезапустить профиль" : "Сохранить")
                }
            }
        }
        .task { originalName = profile.name; await load() }
        .alert($alert)
        .confirmationDialog("Удалить профиль «\(profile.name)»?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { delete() }
        } message: {
            Text("Файл профиля будет удалён. Это нельзя отменить.")
        }
        .sheet(isPresented: $newRule) {
            if let document {
                RuleEditorSheet(document: document, index: nil) { updated in self.document = updated; dirty = true }
            }
        }
        .sheet(item: Binding(get: { editingRule.map(RuleIndex.init) }, set: { editingRule = $0?.id })) { item in
            if let document {
                RuleEditorSheet(document: document, index: item.id) { updated in self.document = updated; dirty = true }
            }
        }
    }

    private var isActive: Bool { store.selectedID == profile.mustID && environments.extensionProfile?.status.isConnected == true }

    private func rulesSection(_ document: ProfileRulesDocument) -> some View {
        Section {
            ForEach(document.editableIndices, id: \.self) { index in
                let rule = document.rule(at: index)
                HStack(spacing: 10) {
                    Button { editingRule = index } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.title).fontWeight(.medium)
                            Text(rule.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Picker("Через", selection: Binding(get: { rule.outbound }, set: { tag in
                        self.document?.setOutbound(tag, at: index); dirty = true
                    })) {
                        ForEach(document.outboundChoices, id: \.tag) { Text($0.name).tag($0.tag) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(profile.type == .remote)
                }
                .contextMenu {
                    Button("Изменить…") { editingRule = index }
                    Button("Выше") { self.document?.move(index, by: -1); dirty = true }.disabled(document.editableIndices.first == index)
                    Button("Ниже") { self.document?.move(index, by: 1); dirty = true }.disabled(document.editableIndices.last == index)
                    Divider()
                    Button("Удалить", role: .destructive) { self.document?.remove(at: index); dirty = true }
                }
            }
            LabeledContent("Всё остальное") {
                Picker("Всё остальное", selection: Binding(get: { document.final }, set: { tag in self.document?.final = tag; dirty = true })) {
                    ForEach(document.outboundChoices, id: \.tag) { Text($0.name).tag($0.tag) }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(profile.type == .remote)
            }
        } header: {
            HStack {
                Text("Правила")
                Spacer()
                Button { newRule = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Добавить правило")
                    .accessibilityLabel("Добавить правило")
                    .disabled(profile.type == .remote)
            }
        } footer: {
            Text(profile.type == .remote
                ? "Правила приходят по ссылке и перезаписываются при обновлении. Меняйте их в источнике."
                : "Срабатывает первое подходящее правило сверху. Порядок и удаление — в контекстном меню строки.")
        }
    }

    private func load() async {
        do {
            let content = try await profile.readAsync()
            document = try ProfileRulesDocument(json: content)
            loadError = nil
        } catch {
            loadError = "Не удалось прочитать правила: \(error.localizedDescription)"
        }
    }

    private func revert() {
        profile.name = originalName
        dirty = false
        Task {
            if let stored = try? await ProfileManager.get(profile.mustID) {
                profile.remoteURL = stored.remoteURL
                profile.autoUpdate = stored.autoUpdate
                profile.autoUpdateInterval = stored.autoUpdateInterval
            }
            await load()
        }
    }

    private func apply() {
        saving = true
        Task {
            defer { saving = false }
            do {
                if let document, profile.type != .remote {
                    let content = try document.serialized()
                    var error: NSError?
                    LibboxCheckConfig(content, &error)
                    if let error { throw error }
                    try await profile.writeAsync(content)
                }
                try await ProfileManager.update(profile)
                originalName = profile.name
                dirty = false
                environments.profileUpdate.send()
                try await profile.onProfileUpdated()
            } catch {
                alert = AlertState(action: "save profile", error: error)
            }
        }
    }

    private func updateRemote() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await profile.updateRemoteProfile()
                await load()
                environments.profileUpdate.send()
            } catch {
                alert = AlertState(action: "update profile", error: error)
            }
        }
    }

    private func delete() {
        Task {
            do {
                try await ProfileManager.delete(profile)
                environments.profileUpdate.send()
                await store.reload()
                dismiss()
            } catch {
                alert = AlertState(action: "delete profile", error: error)
            }
        }
    }
}

private struct RuleIndex: Identifiable { let id: Int }

struct RuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: ProfileRulesDocument
    let index: Int?
    let onSave: (ProfileRulesDocument) -> Void

    @State private var sites = ""
    @State private var outbound = ""
    @State private var withDNS = true

    var body: some View {
        let isNew = index == nil
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Новое правило" : "Правило «\(document.rule(at: index!).title)»").font(.headline)
            if isNew || document.rule(at: index!).isSimple {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сайты")
                    TextEditor(text: $sites)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    Text("По одному в строке: домен (github.com) или подсеть (140.82.112.0/20). Поддомены входят автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(document.rule(at: index!).detail).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Это составное правило. Сайты в нём меняются через «Редактировать JSON…».").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Через", selection: $outbound) {
                ForEach(document.outboundChoices, id: \.tag) { Text($0.name).tag($0.tag) }
            }
            if isNew {
                Toggle(isOn: $withDNS) {
                    Text("DNS этих сайтов тоже через него")
                    Text(document.dnsServer(for: outbound) == nil ? "В профиле нет DNS-сервера для этого подключения" : "Провайдер не увидит, какие сайты открываются")
                }
                .disabled(document.dnsServer(for: outbound) == nil)
            }
            HStack {
                Spacer()
                Button("Отменить") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Добавить" : "Готово") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(outbound.isEmpty || (isNew && entries.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let index {
                let rule = document.rule(at: index)
                outbound = rule.outbound
                sites = rule.siteLines.joined(separator: "\n")
            } else {
                outbound = document.outboundChoices.first { $0.kind != "direct" }?.tag ?? document.outboundChoices.first?.tag ?? ""
            }
        }
    }

    private var entries: [String] {
        sites.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        var updated = document
        if let index {
            updated.setOutbound(outbound, at: index)
            if document.rule(at: index).isSimple, !entries.isEmpty { updated.setSites(entries, at: index) }
        } else {
            updated.insertRule(sites: entries, outbound: outbound, dns: withDNS)
        }
        onSave(updated)
        dismiss()
    }
}
#endif
