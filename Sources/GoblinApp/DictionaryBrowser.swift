import GoblinCore
import SwiftUI

/// The Terms area of the Dictionary page: places on the left, the words of the selected place on the right.
struct DictionaryBrowser: View {
    @ObservedObject var model: DictionaryModel
    /// Terms that don't fit the selected speech model.
    let excluded: Set<String>
    @Binding var editing: DictionaryEntry?
    @Binding var importing: Bool
    @State private var selection: DictionaryPlace
    @State private var expanded: Set<String> = []
    @State private var search = ""
    @State private var showingActive = false

    init(model: DictionaryModel, excluded: Set<String>, editing: Binding<DictionaryEntry?>, importing: Binding<Bool>, place: DictionaryPlace) {
        self.model = model; self.excluded = excluded
        _editing = editing; _importing = importing
        _selection = State(initialValue: place)
        if case .project(_, let app?) = place { _expanded = State(initialValue: [app]) }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let places = model.places
        // One plate: search and Add Term are its header, at the same height and inset as the rows below.
        Plate(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchField(prompt: model.entries.count > 1 ? "Search all \(model.entries.count) words" : "Search", text: $search)
                    Menu {
                        Button("Import Words…") { importing = true }
                    } label: { IconButtonLabel(symbol: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More")
                    Button("Add Term", systemImage: "plus") { editing = selection.newEntry }.prominent()
                }
                .disabled(!model.available)
                .padding(.horizontal, 12).padding(.vertical, 8)
                Hairline()
                if model.entries.isEmpty && places.apps.isEmpty {
                    ContentUnavailableView("Add your vocabulary", systemImage: "character.book.closed",
                        description: Text("Add a preferred spelling and optional “sounds like” aliases. Import a text file with one term per line."))
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    HStack(spacing: 0) {
                        sidebar(places).frame(width: 204)
                        Divider()
                        Group { if isSearching { results } else { detail(places) } }.frame(maxWidth: .infinity)
                    }
                    .frame(height: listHeight(places))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous))
        }
        .task { await model.refreshProjectUses() }
        .onChange(of: places) { if !places.contains(selection) { selection = .everywhere } }
    }

    /// The split hugs its content: room for six words at least, and it scrolls past fourteen. It is
    /// sized by the selected place even during a search, so typing never resizes the page; results
    /// scroll inside it.
    private func listHeight(_ places: DictionaryPlaces) -> CGFloat {
        let words = model.entries.filter(selection.holds).count
        let sidebarRows = 1 + places.apps.reduce(0) { $0 + 1 + (expanded.contains($1.id) ? $1.projects.count : 0) }
            + (places.unassigned.isEmpty ? 0 : places.unassigned.count + 1)
        let rows = max(words + 3, sidebarRows)
        return CGFloat(min(max(rows, 9), 15)) * 32
    }

    private func select(_ place: DictionaryPlace) {
        selection = place
        search = ""
        if case .app(let id) = place { expanded.insert(id) }
    }

    // MARK: Sidebar

    private func sidebar(_ places: DictionaryPlaces) -> some View {
        let apps = places.apps.map { (app: $0, name: DictionaryApps.name($0.id)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Room for a disclosure chevron only when some app has projects to disclose.
        let gutter: CGFloat = places.apps.contains { !$0.projects.isEmpty } ? 16 : 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutter, height: 1)
                    SidebarRow(title: "Everywhere", selected: selection == .everywhere && !isSearching, action: { select(.everywhere) }, tinted: true) {
                        Image(systemName: "globe")
                    } trailing: { Text("\(places.everywhereCount)") }
                }
                ForEach(apps, id: \.app.id) { app, name in
                    appRow(app, name: name, gutter: gutter)
                    if expanded.contains(app.id) {
                        ForEach(app.projects) { projectRow($0).padding(.leading, gutter + 18) }
                    }
                }
                if !places.unassigned.isEmpty {
                    CapsHeader("Other Projects").padding(.leading, gutter + 9).padding(.top, 10).padding(.bottom, 3)
                    ForEach(places.unassigned) { projectRow($0).padding(.leading, gutter) }
                }
            }
            .padding(6)
        }
    }

    private func appRow(_ app: DictionaryPlaces.App, name: String, gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            if app.projects.isEmpty {
                Color.clear.frame(width: gutter, height: 1)
            } else {
                let open = expanded.contains(app.id)
                Button {
                    if open { expanded.remove(app.id) } else { expanded.insert(app.id) }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 16, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide projects in \(name)" : "Show projects in \(name)")
            }
            SidebarRow(title: name, selected: selection == .app(app.id) && !isSearching, action: { select(.app(app.id)) }, tinted: true) {
                appIcon(app.id, size: 17)
            } trailing: { Text("\(app.wordCount)") }
        }
    }

    private func projectRow(_ project: DictionaryPlaces.Project) -> some View {
        SidebarRow(title: project.name, selected: selection == project.place && !isSearching, action: { select(project.place) }, tinted: true) {
            Image(systemName: "folder")
        } trailing: { Text("\(project.wordCount)") }
    }

    @ViewBuilder private func appIcon(_ id: String, size: CGFloat) -> some View {
        if let icon = DictionaryApps.icon(id) {
            Image(nsImage: icon).resizable().frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "app").accessibilityHidden(true)
        }
    }

    // MARK: Words

    private func detail(_ places: DictionaryPlaces) -> some View {
        let words = model.entries.filter(selection.holds)
            .sorted { $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending }
        let active = selection.activeWords(in: model.entries)
        let also = alsoActive(active.used + active.missed)
        return VStack(spacing: 0) {
            header(places, active: active).padding(.horizontal, 12).padding(.vertical, 9)
            Hairline()
            if words.isEmpty {
                Text("I don't have any words for this place yet.").font(.status).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                wordList(words, showsPlace: false)
            }
            if !also.isEmpty {
                Hairline()
                Text("Also active here: " + also).font(.meta).foregroundStyle(.secondary).lineLimit(1)
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
    }

    private var results: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let words = model.entries.filter { entry in ([entry.spelling] + entry.aliases).contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted { $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending }
        return Group {
            if words.isEmpty {
                Text("I couldn't find that spelling.").font(.status).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                wordList(words, showsPlace: true)
            }
        }
    }

    private func wordList(_ words: [DictionaryEntry], showsPlace: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DictionaryWordRow.columnSpacing) {
                column("Word")
                column("Sounds like")
                if showsPlace { column("Where") }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(words.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Hairline().padding(.leading, 12) }
                        DictionaryWordRow(entry: entry, place: showsPlace ? placeCaption(entry) : nil, excluded: excluded.contains(entry.spelling),
                                          edit: { editing = entry }, delete: { model.delete(entry) })
                    }
                }
            }
        }
    }

    private func column(_ title: String) -> some View {
        CapsHeader(title).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeCaption(_ entry: DictionaryEntry) -> String {
        guard entry.isScoped else { return "Everywhere" }
        return [entry.apps.isEmpty ? nil : DictionaryApps.summary(entry.apps), entry.projects.isEmpty ? nil : entry.projects.joined(separator: ", ")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func header(_ places: DictionaryPlaces, active: (used: [DictionaryEntry], missed: [DictionaryEntry])) -> some View {
        HStack(spacing: 9) {
            headerIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.cardTitle).lineLimit(1)
                Text(subtitle(places)).font(.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { showingActive = true } label: {
                HStack(spacing: 8) {
                    Text("\(active.used.count) of \(DictionaryScope.activeLimit) active").font(.meta).foregroundStyle(.secondary).monospacedDigit()
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.1))
                        Capsule().fill(GoblinBrand.moss).frame(width: 72 * CGFloat(active.used.count) / CGFloat(DictionaryScope.activeLimit))
                    }
                    .frame(width: 72, height: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every word used here, in order")
            .popover(isPresented: $showingActive, arrowEdge: .bottom) {
                DictionaryActiveWords(used: active.used, missed: active.missed, label: layerName)
            }
        }
    }

    @ViewBuilder private var headerIcon: some View {
        switch selection {
        case .everywhere: Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(.secondary).accessibilityHidden(true)
        case .app(let id), .project(_, app: .some(let id)): appIcon(id, size: 24)
        case .project(_, app: nil): Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var title: String {
        switch selection {
        case .everywhere: "Everywhere"
        case .app(let id): DictionaryApps.name(id)
        case .project(let name, _): name
        }
    }

    private func subtitle(_ places: DictionaryPlaces) -> String {
        switch selection {
        case .everywhere: return "Every app and project"
        case .app: return "The whole app"
        case .project(let name, let app):
            let also = places.otherApps(listing: name, besides: app).map(DictionaryApps.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let kind = app == ProjectResolution.slackBundle ? "workspace" : "project"
            let owner = app.map { "\(DictionaryApps.name($0)) \(kind)" } ?? "Project"
            return also.isEmpty ? owner : "\(owner) · also in \(also.joined(separator: ", "))"
        }
    }

    /// The name of the layer an active word comes from.
    private func layerName(_ entry: DictionaryEntry) -> String {
        if !entry.projects.isEmpty, case .project(let name, _) = selection { return name }
        if !entry.apps.isEmpty { return DictionaryApps.summary(entry.apps.filter { selection.scope.application == $0 }) }
        return "Everywhere"
    }

    /// "T3 Code 8 · Everywhere 30": active words listed somewhere other than here.
    private func alsoActive(_ active: [DictionaryEntry]) -> String {
        var layers: [(name: String, count: Int)] = []
        for entry in active where !selection.holds(entry) {
            let name = layerName(entry)
            if let index = layers.firstIndex(where: { $0.name == name }) { layers[index].count += 1 } else { layers.append((name, 1)) }
        }
        return layers.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
    }
}

private struct DictionaryWordRow: View {
    static let columnSpacing: CGFloat = 12

    let entry: DictionaryEntry
    let place: String?
    let excluded: Bool
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    /// "soul, sole · near GPT, 6.1"
    private var aliases: String {
        let near = entry.context.isEmpty ? [] : ["near " + entry.context.joined(separator: ", ")]
        return ([entry.aliases.joined(separator: ", ")].filter { !$0.isEmpty } + near).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Self.columnSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.spelling).font(.row).lineLimit(1).truncationMode(.middle).help(entry.spelling)
                if excluded { Text("Not sent to recognition").font(.meta).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(aliases).font(.row).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).help(aliases)
            if let place {
                Text(place).font(.row).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).help(place)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 12).frame(minHeight: 32)
        .overlay(alignment: .trailing) {
            // Over the row, so hidden buttons don't take room from the columns.
            if hovering {
                HStack(spacing: 4) {
                    Button("Edit", action: edit)
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete).labelStyle(.iconOnly)
                }
                .padding(.leading, 16).padding(.trailing, 8).frame(maxHeight: .infinity)
                .background(GoblinBrand.plate)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Delete", delete)
    }
}

/// Every word a dictation in the selected place uses, in the order they count against the limit.
struct DictionaryActiveWords: View {
    let used: [DictionaryEntry]
    let missed: [DictionaryEntry]
    let label: (DictionaryEntry) -> String

    private var layers: [(name: String, words: [String])] {
        var result: [(name: String, words: [String])] = []
        for entry in used {
            let name = label(entry)
            if result.last?.name == name { result[result.count - 1].words.append(entry.spelling) } else { result.append((name, [entry.spelling])) }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("I use \(used.count) of \(DictionaryScope.activeLimit) words here. The most specific come first, then the newest.")
                    .font(.status).fixedSize(horizontal: false, vertical: true).monospacedDigit()
                ForEach(layers, id: \.name) { layer in
                    VStack(alignment: .leading, spacing: 4) {
                        CapsHeader("\(layer.name) · \(layer.words.count)")
                        wordText(layer.words)
                    }
                }
                if !missed.isEmpty {
                    Hairline()
                    VStack(alignment: .leading, spacing: 4) {
                        CapsHeader("Past the Limit · \(missed.count)")
                        wordText(missed.map(\.spelling)).foregroundStyle(.secondary)
                        Text("Their “sounds like” fixes still work.").font(.meta).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 320).frame(maxHeight: 420)
    }

    private func wordText(_ words: [String]) -> some View {
        Text(words.joined(separator: ", ")).font(.row)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
