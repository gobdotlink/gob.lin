import AppKit
import GoblinCore
import SwiftUI
import UniformTypeIdentifiers

/// Display names and icons for the bundle identifiers that scope dictionary entries.
@MainActor
enum DictionaryApps {
    static func name(_ bundleIdentifier: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return bundleIdentifier }
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func icon(_ bundleIdentifier: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Regular apps that are open now, excluding gob.lin, one per bundle identifier.
    static func running() -> [(id: String, name: String)] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func summary(_ apps: [String]) -> String {
        apps.map(name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }
}

/// Chooses the apps a term is used in; an empty selection means every app.
struct DictionaryAppScopeEditor: View {
    @Binding var apps: [String]
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("Every app").foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.self) { id in
                LabeledContent {
                    Button("Remove", systemImage: "minus.circle", role: .destructive) { apps.removeAll { $0 == id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(DictionaryApps.name(id))")
                } label: {
                    HStack(spacing: 8) {
                        if let icon = DictionaryApps.icon(id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(DictionaryApps.name(id))
                    }
                }
            }
            Menu("Add App") {
                let open = DictionaryApps.running().filter { !apps.contains($0.id) }
                if !open.isEmpty {
                    Section("Open apps") {
                        ForEach(open, id: \.id) { app in Button(app.name) { apps.append(app.id) } }
                    }
                }
                Button("Choose Another App…") { choosing = true }
            }
            .fixedSize()
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        } header: { Text("Use in") } footer: {
            Text("With no apps chosen, I use this term everywhere. Otherwise I only use it when you dictate into these apps.")
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application]) { result in
            switch result {
            case .success(let url):
                guard let id = Bundle(url: url)?.bundleIdentifier else { error = "That app has no bundle identifier."; return }
                error = nil
                if !apps.contains(id) { apps.append(id) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

/// Chooses the projects a term is used in; an empty selection means every project.
struct DictionaryProjectScopeEditor: View {
    @Binding var projects: [String]
    let suggestions: [String]
    @State private var name = ""

    private func add(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !DictionaryScope.projectKey(trimmed).isEmpty,
              !projects.contains(where: { DictionaryScope.projectKey($0) == DictionaryScope.projectKey(trimmed) }) else { return }
        projects.append(trimmed)
        name = ""
    }

    var body: some View {
        Section {
            if projects.isEmpty { Text("Every project").foregroundStyle(.secondary) }
            ForEach(projects, id: \.self) { project in
                LabeledContent(project) {
                    Button("Remove", systemImage: "minus.circle", role: .destructive) { projects.removeAll { $0 == project } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(project)")
                }
            }
            HStack {
                TextField("Project name", text: $name).onSubmit { add(name) }
                Button("Add") { add(name) }.disabled(DictionaryScope.projectKey(name).isEmpty)
                let remaining = suggestions.filter { suggestion in
                    !projects.contains { DictionaryScope.projectKey($0) == DictionaryScope.projectKey(suggestion) }
                }
                if !remaining.isEmpty {
                    Menu("Known Projects") {
                        ForEach(remaining, id: \.self) { project in Button(project) { add(project) } }
                    }
                    .fixedSize()
                }
            }
        } header: { Text("Projects") } footer: {
            Text("With no projects chosen, I use this term in any project. Otherwise I only use it when I can tell one of these projects is open: the repository of the open file, or the project of the T3 Code thread or Paseo workspace.")
        }
    }
}
