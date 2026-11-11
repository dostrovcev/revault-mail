import SwiftUI

/// Содержимое всплывающего окна над списком: метки, перенос или отложение.
struct ListPopoverContent: View {
    let popover: ListPopover
    var body: some View {
        switch popover.kind {
        case .labels: LabelPickerView(keys: popover.keys, moveMode: false)
        case .move: LabelPickerView(keys: popover.keys, moveMode: true)
        case .snooze: SnoozePickerView(keys: popover.keys)
        }
    }
}

/// Метки с поиском, как в Gmail: галочка у стоящих, клик ставит или снимает, Enter по новому имени создаёт метку.
/// В режиме переноса клик ставит метку и убирает тред из входящих.
struct LabelPickerView: View {
    let keys: [ThreadKey]
    let moveMode: Bool
    @Environment(MailStore.self) private var store
    @State private var query = ""
    @FocusState private var focused: Bool

    private var names: [String] {
        let all = store.labelNames(for: keys).filter { !MailStore.snoozeLabelNames.contains($0) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var exactExists: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.labelNames(for: keys).contains { $0.caseInsensitiveCompare(q) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(moveMode ? "Move to" : "Labels").font(.g(12, .semibold)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField(moveMode ? "Move to label" : "Search or create label", text: $query)
                    .textFieldStyle(.plain).font(.g(13.5))
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.chip))
            .padding(.horizontal, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(names, id: \.self) { name in
                        let cov = store.labelCoverage(name, keys: keys)
                        Button {
                            pick(name, coverage: cov)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: cov.have == 0 ? "square" : (cov.have == cov.total ? "checkmark.square.fill" : "minus.square.fill"))
                                    .font(.system(size: 13)).foregroundStyle(cov.have == 0 ? Theme.ghost : Theme.blue)
                                    .opacity(moveMode ? 0 : 1)
                                    .frame(width: moveMode ? 0 : 16)
                                Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                Text(name).font(.g(13.5)).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PickerRowStyle())
                    }
                    let q = query.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty && !exactExists {
                        Button { submit() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.blue)
                                Text("Create \"\(q)\"").font(.g(13.5)).foregroundStyle(Theme.blueText).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PickerRowStyle())
                    }
                    if names.isEmpty && q.isEmpty {
                        Text("No labels yet. Type a name to create one.").font(.g(12.5)).foregroundStyle(Theme.faint)
                            .padding(10)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 280)
        .background(Theme.white)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func pick(_ name: String, coverage: (have: Int, total: Int)) {
        if moveMode {
            store.move(keys, toLabel: name)
            store.listPopover = nil
        } else {
            store.setLabel(name, on: keys, apply: coverage.have < coverage.total)
        }
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let name = store.labelNames(for: keys).first(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
            pick(name, coverage: store.labelCoverage(name, keys: keys))
        } else if names.count == 1, let only = names.first {
            // одна подходящая метка: Enter выбирает её, как в Gmail
            pick(only, coverage: store.labelCoverage(only, keys: keys))
        } else if moveMode {
            store.move(keys, toLabel: q)
            store.listPopover = nil
        } else {
            store.createAndApplyLabel(q, on: keys)
        }
        query = ""
    }
}

/// Отложить: готовые сроки и свой день с часом.
struct SnoozePickerView: View {
    let keys: [ThreadKey]
    @Environment(MailStore.self) private var store
    @State private var picking = false
    @State private var custom = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0,
                                                       of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Snooze until").font(.g(12, .semibold)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
            if picking {
                DatePicker("", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical).labelsHidden()
                    .frame(width: 260)
                HStack {
                    Button("Back") { picking = false }.buttonStyle(.dash(.ghost, small: true))
                    Spacer()
                    Button("Snooze") { done(custom) }.buttonStyle(.dash(.primary, small: true))
                        .disabled(custom <= Date())
                }
                .padding(.top, 6)
            } else {
                ForEach(MailStore.snoozePresets(), id: \.title) { p in
                    Button { done(p.date) } label: {
                        HStack {
                            Text(p.title).font(.g(13.5)).foregroundStyle(Theme.ink)
                            Spacer(minLength: 12)
                            Text(Fmt.snoozeTime(p.date)).font(.g(12.5)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 8).frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PickerRowStyle())
                }
                Button { picking = true } label: {
                    HStack {
                        Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Text("Pick date and time").font(.g(13.5)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 8).frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PickerRowStyle())
                if keys.contains(where: { store.snoozeEntry($0) != nil }) {
                    HLine().padding(.vertical, 4)
                    Button { store.unsnooze(keys); store.listPopover = nil } label: {
                        HStack {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Text("Unsnooze now").font(.g(13.5)).foregroundStyle(Theme.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PickerRowStyle())
                }
            }
        }
        .padding(8)
        .frame(width: picking ? 280 : 260)
        .background(Theme.white)
    }

    private func done(_ d: Date) {
        store.snooze(keys, until: d)
        store.listPopover = nil
    }
}

/// Строка списка во всплывающем окне: подсветка под мышкой.
struct PickerRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.navOn : (hover ? Theme.navHover : .clear)))
            .onHover { hover = $0 }
    }
}
