import AppKit
import GoblinCore
import SwiftUI
import UniformTypeIdentifiers

/// The switch, sorting and every profile setting apply as soon as they change; the provider is edited in a sheet and
/// applies on Save.
struct RewriteSettingsView: View {
    @State private var settings: RewriteSettings
    @AppStorage private var profilesData: Data
    private let defaults: UserDefaults
    private let inspectCredentials: Bool
    private let onSaved: () -> Void
    private let onFailure: (DiagnosticFailure) -> Void
    @State private var selectedID: String
    @State private var keySaved = false
    @State private var message: String?
    @State private var editingProvider = false
    /// The switch opened the sheet because the provider wasn't ready; saving it turns cleanup on.
    @State private var turnOnAfterEdit = false
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testOutput: String?
    @State private var testMeta: String?
    @State private var testFailure: String?
    @State private var typeSafeKey = ""
    @State private var deleting: CleanupProfile?
    @State private var choosingApp = false
    @State private var showsPrompt = false

    init(defaults: UserDefaults = .standard, inspectCredentials: Bool = true, profile: String = CleanupProfile.everywhereID,
         onSaved: @escaping () -> Void = {}, onFailure: @escaping (DiagnosticFailure) -> Void = { _ in }) {
        self.defaults = defaults; self.inspectCredentials = inspectCredentials
        self.onSaved = onSaved; self.onFailure = onFailure
        _settings = State(initialValue: RewriteSettingsStore.load(defaults: defaults))
        _profilesData = AppStorage(wrappedValue: Data(), CleanupProfiles.preferenceKey, store: defaults)
        _selectedID = State(initialValue: profile)
    }

    /// Read from the saved data on every change, so an app placed from the overlay shows up while the page is open.
    private var profiles: CleanupProfiles {
        (try? JSONDecoder().decode(CleanupProfiles.self, from: profilesData)) ?? CleanupProfileStore.load(defaults: defaults)
    }

    private var profile: CleanupProfile { profiles.profile(selectedID) ?? profiles.everywhere }

    var body: some View {
        let profiles = profiles, profile = profile
        Section {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { setEnabled($0) })) {
                Text("AI cleanup")
                Text("Sends text only, never audio.").rowDetail()
            }
            StatusRow(settings.enabled ? .ready : .off, cleanupStatus(profiles))
            if let message { StatusRow(.problem, Text(message)) }
        }
        Section {
            LabeledContent {
                Button("Edit…") { editingProvider = true }
            } label: {
                Text(settings.provider.title)
                Text(providerSummary).rowDetail()
            }
            if !settings.provider.runsOnDevice {
                Toggle(isOn: Binding(get: { settings.usesScreenContext }, set: { on in
                    update { $0.usesScreenContext = on }
                })) {
                    Text("Send text near the cursor")
                    Text("Sends the app, window title and nearby text to \(settings.provider.title) with each take.").rowDetail()
                    Text("Nearby text is what's around the cursor, such as the messages above it. It helps spell names and fit what's already there.")
                    Text("Text in password fields and password managers is never sent.")
                }
            }
            if let setupProblem {
                StatusRow(.waiting, Text(setupProblem)) { Button("Set Up…") { editingProvider = true } }
            }
        } header: { Text("Provider") }
        sorting(profiles)
        Section {
            ProfileList(profiles: profiles, selectedID: $selectedID) { newProfile(profiles) }
        }
        .containerValue(\.plateless, true)
        details(profile)
        apps(profile, in: profiles)
        tone(profile)
        level(profile)
        formatting(profile)
        prompt(profile)
        tryIt(profile)
            .onAppear { refreshKeyStatus() }
            .onDisappear { testTask?.cancel(); testTask = nil; testing = false }
            // The profile can change from the menu bar too; a result must stay beside the settings it came from.
            .onChange(of: profile) { resetTest() }
            .sheet(isPresented: $editingProvider, onDismiss: { turnOnAfterEdit = false }) {
                CleanupProviderSheet(settings: settings, defaults: defaults, inspectCredentials: inspectCredentials, turnOn: turnOnAfterEdit,
                                     onSave: { saved in
                                         settings = saved; message = nil; resetTest()
                                         refreshKeyStatus(); onSaved()
                                     }, onFailure: onFailure)
            }
            .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                presenting: deleting) { doomed in
                Button("Delete Profile") {
                    selectedID = CleanupProfile.everywhereID
                    updateProfiles { $0.remove(doomed.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its apps go back to Everywhere, or to sorting if it's on.")
            }
    }

    /// Where cleanup's text goes, and app names too while a cloud model sorts them.
    private func cleanupStatus(_ profiles: CleanupProfiles) -> Text {
        let provider = Text(settings.provider.title).fontWeight(.semibold)
        let sorting = profiles.sortsApps ? resolvedSorter(profiles).flatMap { $0 == .appleIntelligence ? nil : $0 } : nil
        let rest = sorting.map { Text("App names go to \(Text($0.title).fontWeight(.semibold)) for sorting.") } ?? Text("Everything else stays on this Mac.")
        guard settings.enabled else {
            return sorting == nil ? Text("Off. Tone still applies, and everything stays on this Mac.") : Text("Off. Tone still applies. \(rest)")
        }
        if settings.provider.runsOnDevice {
            return sorting == nil ? Text("Cleanup runs on this Mac with \(provider). Nothing is sent anywhere.")
                                  : Text("Cleanup runs on this Mac with \(provider). \(rest)")
        }
        return settings.usesScreenContext ? Text("Your text and the text near your cursor go to \(provider). \(rest)")
                                          : Text("Your text goes to \(provider). \(rest)")
    }

    // MARK: Sorting

    @ViewBuilder private func sorting(_ profiles: CleanupProfiles) -> some View {
        let sorter = resolvedSorter(profiles)
        Section {
            Toggle(isOn: profileBinding(\.sortsApps)) {
                Text("Sort new apps")
                Text("The first time you dictate into an app, sends its name to \(sorter?.title ?? "a decision model") to pick its profile.").rowDetail()
                Text("What goes: the app's name and bundle ID, and your profiles' names and When to use lines. Never what you say or what's on screen.")
                Text("When it's sure, the app stays in that profile. When it's unsure, I use its pick once and ask you. Apps it can't place use Everywhere until you choose.")
            }
            Toggle(isOn: profileBinding(\.sortsBrowserTabs)) {
                Text("Sort browser tabs")
                Text("Sends the window's title with each take in a browser, so Gmail and GitHub can differ.").rowDetail()
                Text("A browser you put in a profile yourself always uses that profile.")
            }
            .disabled(!profiles.sortsApps)
            .padding(.leading, 16)
            LabeledContent {
                Picker("Decides with", selection: profileBinding(\.sorter)) {
                    ForEach(ProfileSorter.allCases) { option in
                        Text(option == .automatic ? "Automatic\(sorter.map { " (\($0.title))" } ?? "")" : option.title).tag(option)
                    }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            } label: {
                Text("Decides with")
                Text(sorterDetail(profiles.sorter == .automatic ? nil : profiles.sorter)).rowDetail()
            }
            if sorter == .openRouter || profiles.sorter == .openRouter {
                LabeledContent {
                    Picker("Model", selection: profileBinding(\.openRouterModel)) {
                        ForEach(ProfileSorter.openRouterModels, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                } label: {
                    Text("Model")
                    Text("Any decision model OpenRouter routes to, billed to your OpenRouter key.").rowDetail()
                    Text("Perplexity Decider 1.2 is pinned, so it doesn't change under you; Latest moves to each new Decider.")
                }
            }
            if profiles.sorter == .typeSafe {
                LabeledContent {
                    SecureField("Paste a key", text: $typeSafeKey)
                        .font(.system(.body, design: .monospaced)).frame(width: 220)
                        .onSubmit(saveTypeSafeKey)
                        .onChange(of: typeSafeKey) { saveTypeSafeKey() }
                } label: {
                    Text("TypeSafe API key")
                    Text("Saved in gob.lin preferences.").rowDetail()
                }
            }
            if profiles.sortsApps {
                if let sorter {
                    StatusRow(.ready, sorter == .openRouter
                              ? Text("Sorting with \(Text(ProfileSorter.openRouterTitle(profiles.openRouterModel)).fontWeight(.semibold)) through OpenRouter.")
                              : Text("Sorting with \(Text(sorter.title).fontWeight(.semibold))."))
                } else {
                    StatusRow(.waiting, Text(sorterProblem(profiles.sorter)))
                }
            }
        } header: { Text("Sorting") }
    }

    private func sorterDetail(_ sorter: ProfileSorter?) -> String {
        switch sorter {
        case .appleIntelligence: "Runs on this Mac. It can't say how sure it is, so it always asks before keeping a pick."
        case .openAI: "OpenAI's Decisions API, with your OpenAI key."
        case .openRouter: "A decision model through OpenRouter, with your OpenRouter key."
        case .typeSafe: "TypeSafe Jev, with its own key."
        case .automatic, nil: "Your OpenAI, OpenRouter or TypeSafe key, else Apple Intelligence."
        }
    }

    private func sorterProblem(_ chosen: ProfileSorter) -> String {
        switch chosen {
        case .appleIntelligence: OnDeviceCleanup.availability.problem ?? "Apple Intelligence is unavailable right now."
        case .typeSafe: "Add a TypeSafe key to sort apps."
        case .openAI, .openRouter: "Save an \(chosen.title) key in the provider sheet to sort apps."
        case .automatic: "I need an OpenAI or OpenRouter key, or Apple Intelligence, to sort apps."
        }
    }

    private func resolvedSorter(_ profiles: CleanupProfiles) -> ProfileSorter? {
        profiles.sorter.resolved(cleanup: settings.provider,
                                 hasKey: { sorter in inspectCredentials && sorter.keyAccount.map { !RewriteKeyStore.load(account: $0, defaults: defaults).isEmpty } == true },
                                 onDevice: OnDeviceCleanup.availability == .available)
    }

    private func saveTypeSafeKey() {
        guard inspectCredentials else { return }
        RewriteKeyStore.save(typeSafeKey.trimmingCharacters(in: .whitespacesAndNewlines), account: ProfileSorter.typeSafe.keyAccount!, defaults: defaults)
    }

    // MARK: The selected profile

    @ViewBuilder private func details(_ profile: CleanupProfile) -> some View {
        if profile.isEverywhere {
            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Everywhere")
                    Text("Every app that isn't in another profile, and gob.lin's command line.").rowDetail()
                }
            } header: { Text(profile.name) }
        } else {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: field(\.name)).labelsHidden().frame(width: 280)
                }
                LabeledContent {
                    TextField("Email, replies and longer writing", text: field(\.purpose), axis: .vertical)
                        .labelsHidden().lineLimit(1...3).frame(width: 280)
                } label: {
                    Text("When to use")
                    Text("Sorting reads this to choose the profile.").rowDetail()
                }
                LabeledContent {
                    Button("Delete Profile…", role: .destructive) { deleting = profile }
                } label: {
                    Text("Delete this profile")
                    Text("Its apps go back to Everywhere.").rowDetail()
                }
            } header: { Text(profile.name) }
        }
    }

    @ViewBuilder private func apps(_ profile: CleanupProfile, in profiles: CleanupProfiles) -> some View {
        let placed = profiles.apps(in: profile.id)
            .sorted { DictionaryApps.name($0.id).localizedStandardCompare(DictionaryApps.name($1.id)) == .orderedAscending }
        Section {
            if placed.isEmpty {
                Text(profile.isEverywhere ? "Every app without a profile lands here. Add one to keep it here, out of sorting."
                                          : "No apps yet. An app you add always uses \(profile.name).")
                    .font(.status).foregroundStyle(.secondary)
            }
            ForEach(placed, id: \.id) { app in
                LabeledContent {
                    Menu {
                        ForEach(profiles.profiles.filter { $0.id != profile.id }) { other in
                            Button("Move to \(other.name)") { updateProfiles { $0.apps[app.id] = AppPlacement(profile: other.id) } }
                        }
                        Divider()
                        Button("Remove", role: .destructive) { updateProfiles { $0.apps[app.id] = nil } }
                    } label: { IconButtonLabel(symbol: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for \(DictionaryApps.name(app.id))")
                } label: {
                    HStack(spacing: 8) {
                        if let icon = DictionaryApps.icon(app.id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true) }
                        Text(DictionaryApps.name(app.id))
                        if app.automatic {
                            Text("Sorted by me").font(.meta).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Menu("Add App") {
                let suggested = (CleanupProfile.suggestedApps[profile.id] ?? [])
                    .filter { profiles.apps[$0]?.profile != profile.id && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                if !suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(suggested, id: \.self) { id in Button(DictionaryApps.name(id)) { place(id, in: profile) } }
                    }
                }
                let open = DictionaryApps.running().filter { profiles.apps[$0.id]?.profile != profile.id }
                if !open.isEmpty {
                    Section("Open apps") {
                        ForEach(open, id: \.id) { app in Button(app.name) { place(app.id, in: profile) } }
                    }
                }
                Button("Choose Another App…") { choosingApp = true }
            }
            .fixedSize()
        } header: { Text("Apps") } footer: {
            Text("An app is in one profile at a time. Adding it here moves it from another.")
        }
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result, let id = Bundle(url: url)?.bundleIdentifier { place(id, in: profile) }
        }
    }

    private func place(_ app: String, in profile: CleanupProfile) {
        updateProfiles { $0.apps[app] = AppPlacement(profile: profile.id) }
    }

    @ViewBuilder private func tone(_ profile: CleanupProfile) -> some View {
        Section {
            ForEach(DictationTone.allCases) { tone in
                CheckRow(title: tone.title, selected: profile.tone == tone) {
                    Text(tone.preview).font(.status).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                } action: { edit { $0.tone = tone } }
            }
        } header: { Text("Tone") } footer: {
            Text("Works without AI cleanup. Names, dictionary spellings, code, URLs and acronyms stay as they are.")
        }
    }

    @ViewBuilder private func level(_ profile: CleanupProfile) -> some View {
        let custom = profile.prompt != nil
        Section {
            ForEach(RewriteCleanup.allCases) { level in
                CheckRow(title: level.title, selected: !custom && profile.cleanup == level) {
                    Text(level.detail).font(.status).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    InlineDiff(from: RewriteCleanup.exampleSaid,
                               to: ToneFormatter.format(level.exampleTyped, tone: profile.tone, protectedTerms: ["Maya"]))
                        .font(.status).padding(.top, 3)
                } action: { edit { $0.cleanup = level } }
                .disabled(custom)
            }
            if custom {
                StatusRow(.off, Text("Your prompt decides how much cleanup changes. Reset it to use these."))
            }
        } header: { Text("Level") } footer: {
            Text("Light and Medium also write what you say as you'd type it: “google dot com” becomes google.com, “five point four” 5.4 and “this slash that” this/that.")
            Text("Your dictionary's spellings fix words the recognizer misheard.")
        }
    }

    @ViewBuilder private func formatting(_ profile: CleanupProfile) -> some View {
        let off = profile.cleanup == .none || profile.prompt != nil
        Section {
            formattingToggle(\.paragraphs, off: off) {
                Text("Paragraphs")
                Text("Starts a new paragraph when you move to a new point.").rowDetail()
                Text("Saying “next” or “another thing” starts one too. Each point keeps its own words, in the order you said them.")
            }
            formattingToggle(\.lists, off: off) {
                Text("Lists")
                Text("Turns “one… two…” or “first… second…” into a numbered list.").rowDetail()
                Text("Three or more things after “three things” or a similar lead-in become bullets. Things you mention in passing, like “milk, eggs and bread”, stay in the sentence.")
                Text("Lists use plain “1.” and “-”, so they read the same in every app.")
            }
            formattingToggle(\.spokenBreaks, off: off) {
                Text("Say “New Line”")
                Text("Say “new line” or “new paragraph” to start one.").rowDetail()
                Text("Only when you say it on its own, between thoughts. “Add a new line to the file” stays as words.")
            }
            formattingToggle(\.commands, off: off) {
                Text("Commands and Issue IDs")
                Text("“Slash review” becomes /review, “OLY four two four” becomes OLY-424.").rowDetail()
                Text("Also “PR hash nine seven five” as PR #975. Anything ambiguous stays as words, and model names are never expanded.")
            }
            if profile.prompt != nil {
                StatusRow(.off, Text("Your prompt decides the formatting too."))
            }
        } header: { Text("Formatting") }
    }

    @ViewBuilder private func prompt(_ profile: CleanupProfile) -> some View {
        Section {
            if let custom = profile.customPrompt {
                TextEditor(text: Binding(get: { custom }, set: { text in edit { $0.customPrompt = text } }))
                    .font(.status).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 240)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
                    .accessibilityLabel("Prompt")
                Toggle(isOn: Binding(get: { profile.tonesCustomPrompt }, set: { on in edit { $0.tonesCustomPrompt = on } })) {
                    Text("Apply the tone after cleanup")
                    Text("Runs \(profile.tone.title)'s own pass on what your prompt writes.").rowDetail()
                    Text("Off, I type what cleanup wrote, exactly. Without AI cleanup the tone always applies.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Copy") { copy(custom) }
                        Button("Reset to Default") { edit { $0.customPrompt = nil; $0.tonesCustomPrompt = false } }
                    }
                } label: {
                    Text("Your prompt")
                    Text("Replaces mine for \(profile.name). The level and formatting above wait until you reset it.").rowDetail()
                }
                if custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StatusRow(.waiting, Text("An empty prompt uses mine instead."))
                } else if settings.provider.runsOnDevice, OnDeviceCleanup.exceedsContext(instructions: custom, transcript: String(repeating: "word ", count: 120)) {
                    StatusRow(.waiting, Text("This prompt leaves Apple Intelligence little room for what you say, so longer takes may be typed as you said them."))
                }
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Copy") { copy(profile.instructions) }
                        Button("Edit Prompt") { edit { $0.customPrompt = $0.instructions } }
                    }
                } label: {
                    Text("My prompt")
                    Text("Built from this profile's level, formatting and tone.").rowDetail()
                    Text("Edit Prompt copies it so you can change anything. Your words and dictionary spellings always arrive as data the model must not follow, and a cleanup that comes back empty or late is never typed.")
                }
                DisclosureGroup(isExpanded: $showsPrompt) {
                    ScrollView {
                        Text(profile.instructions).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220).padding(.top, 6)
                } label: { Text("Show Prompt") }
            }
        } header: { Text("Prompt") }
    }

    @ViewBuilder private func tryIt(_ profile: CleanupProfile) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("What you said → what \(profile.name) types")
                        Spacer()
                        if let testOutput {
                            Text("\(Self.wordCount(sample(profile))) → \(Self.wordCount(testOutput)) words").monospacedDigit()
                        }
                    }
                    .font(.meta).foregroundStyle(.secondary)
                    Group {
                        if let testOutput { InlineDiff(from: sample(profile), to: testOutput) }
                        else { Text(sample(profile)).foregroundStyle(.secondary) }
                    }
                    .font(.row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                HStack(spacing: 10) {
                    Text(testMeta ?? (isOn(profile) ? (settings.provider.runsOnDevice ? "Runs this one sentence on this Mac." : "Sends this one sentence, nothing else.")
                                      : settings.enabled ? "This profile's level is None." : "Turn on AI cleanup to try it."))
                        .font(.status).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button(testing ? "Testing…" : testOutput == nil ? "Run Test" : "Run Again") { testCleanup(profile) }
                        .prominent()
                        .disabled(testing || !inspectCredentials || !isOn(profile))
                }
            }
            .padding(.vertical, 4)
            if let testFailure { StatusRow(.problem, Text(testFailure)) }
        } header: { Text("Try it") } footer: {
            Text("Slower than 4 s? I type what you said instead, and say so in the bubble.")
        }
    }

    /// Fillers, a doubled word and missing punctuation, so the diff has something to show.
    static let sample = "um so i think we should uh ship the overlay fix tonight and and do onboarding tomorrow like the copy is basically done"
    /// Fillers plus a list and a new point, for when formatting is on, with a spoken break when Say "New Line" is.
    static func formattedSample(spokenBreak: Bool) -> String {
        "um so this week there are three things the overlay fix the onboarding copy and and the docs"
            + (spokenBreak ? " new paragraph" : "") + " another thing can we uh move the review to friday"
    }
    /// A command and an issue ID, for when Commands and Issue IDs is the only formatting on.
    static let commandSample = "um can you run slash review triage on PR hash nine seven five and and check issue OLY four two four"

    private func sample(_ profile: CleanupProfile) -> String {
        if !profile.formatting.isPlain { return Self.formattedSample(spokenBreak: profile.formatting.spokenBreaks) }
        return profile.formatting.commands ? Self.commandSample : Self.sample
    }

    /// Words, not the "-" or "1." starting a list item.
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.range(of: #"^(?:[-*•]|\d+[.)])$"#, options: .regularExpression) == nil }.count
    }

    private func isOn(_ profile: CleanupProfile) -> Bool { settings.enabled && profile.applied(to: settings).cleanup != .none }

    /// A formatting switch. It saves at once like the level, and does nothing while the level is None or a custom prompt decides.
    private func formattingToggle<Label: View>(_ option: WritableKeyPath<RewriteFormatting, Bool>, off: Bool,
                                               @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { profile.formatting[keyPath: option] }, set: { on in edit { $0.formatting[keyPath: option] = on } }),
               label: label)
        .disabled(off)
    }

    // MARK: Saving

    private var setupProblem: String? { cleanupSetupProblem(settings, hasKey: keySaved) }

    private var providerSummary: String {
        if settings.provider.runsOnDevice { return OnDeviceCleanup.availability.problem ?? "On-device · no key needed" }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [model.isEmpty ? "No model" : model]
        if !settings.provider.hasFixedAddress, let host = try? settings.endpoint().host() { parts.append(host) }
        if settings.provider.offersServiceTiers, let tier = settings.serviceTier { parts.append(tier.title) }
        if keySaved { parts.append("key saved") }
        return parts.joined(separator: " · ")
    }

    private func setEnabled(_ on: Bool) {
        // Turning on an unfinished provider opens it instead; its Save turns cleanup on.
        if on, setupProblem != nil {
            turnOnAfterEdit = true; editingProvider = true
            return
        }
        update { $0.enabled = on }
    }

    /// Applies one change to the saved settings, not this page's copy: the menu bar may have changed them since it opened.
    private func update(_ change: (inout RewriteSettings) -> Void) {
        var next = RewriteSettingsStore.load(defaults: defaults)
        change(&next)
        do {
            try RewriteSettingsStore.save(next, defaults: defaults)
            settings = next; message = nil
            onSaved()
        } catch { message = error.localizedDescription; onFailure(.settingsSaveFailed) }
    }

    private func updateProfiles(_ change: (inout CleanupProfiles) -> Void) {
        var next = CleanupProfileStore.load(defaults: defaults)
        change(&next)
        do { try CleanupProfileStore.save(next, defaults: defaults) }
        catch { message = error.localizedDescription; onFailure(.settingsSaveFailed) }
    }

    /// Changes the selected profile. A result must stay beside the settings it came from, so the test resets.
    private func edit(_ change: (inout CleanupProfile) -> Void) {
        let id = profile.id
        updateProfiles { profiles in
            guard var edited = profiles.profile(id) else { return }
            change(&edited)
            profiles.put(edited)
        }
        resetTest()
    }

    private func field(_ key: WritableKeyPath<CleanupProfile, String>) -> Binding<String> {
        Binding(get: { profile[keyPath: key] }, set: { text in edit { $0[keyPath: key] = text } })
    }

    private func profileBinding<Value>(_ key: WritableKeyPath<CleanupProfiles, Value>) -> Binding<Value> {
        Binding(get: { profiles[keyPath: key] }, set: { value in updateProfiles { $0[keyPath: key] = value } })
    }

    private func newProfile(_ profiles: CleanupProfiles) {
        let created = CleanupProfile(name: "New Profile", tone: profiles.everywhere.tone, cleanup: .light)
        updateProfiles { $0.put(created) }
        selectedID = created.id
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func refreshKeyStatus() {
        guard inspectCredentials else { keySaved = false; return }
        do { keySaved = try !RewriteKeyStore.load(for: settings, defaults: defaults).isEmpty }
        catch { keySaved = false }
        typeSafeKey = RewriteKeyStore.load(account: ProfileSorter.typeSafe.keyAccount!, defaults: defaults)
    }

    private func resetTest() {
        testTask?.cancel(); testTask = nil; testing = false
        testOutput = nil; testMeta = nil; testFailure = nil
    }

    private func testCleanup(_ profile: CleanupProfile) {
        guard !testing, inspectCredentials, isOn(profile) else { return }
        let snapshot = profile.applied(to: settings), sample = sample(profile)
        testing = true
        testFailure = nil
        testTask = Task { @MainActor in
            defer { testing = false; testTask = nil }
            do {
                let key = try RewriteKeyStore.load(for: snapshot, defaults: defaults)
                let start = ContinuousClock.now
                let result = await RewriteClient().rewrite(sample, settings: snapshot, apiKey: key, tone: profile.tone,
                                                           customPrompt: profile.prompt)
                try Task.checkCancellation()
                if let failure = result.failure { throw failure }
                guard result.wasRewritten else { throw RewriteFailure.invalidResponse }
                let elapsed = start.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                // Typed text gets the profile's tone, so the preview does too.
                testOutput = profile.formatsTone ? ToneFormatter.format(result.outputText, tone: profile.tone) : result.outputText
                testMeta = "\(profile.summary) · \(snapshot.model) · \(Int(milliseconds.rounded())) ms"
            } catch {
                guard !Task.isCancelled else { return }
                testFailure = "\(snapshot.provider.title) didn't answer the test: \(error.localizedDescription)"
            }
        }
    }
}

/// A choice among a few, drawn like the old Tone page: the title, lines under it, and a moss check on the chosen one.
private struct CheckRow<Detail: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder var detail: Detail
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    detail
                }
                Spacer(minLength: 12)
                Image(systemName: "checkmark").font(.row.weight(.semibold))
                    .foregroundStyle(GoblinBrand.mossText).opacity(selected ? 1 : 0)
            }
            .padding(.vertical, 4)
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The profiles, Everywhere first, in one plate. The selected one is edited below.
private struct ProfileList: View {
    let profiles: CleanupProfiles
    @Binding var selectedID: String
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                CapsHeader("Profiles").accessibilityAddTraits(.isHeader)
                InfoButton {
                    Text("Each app you dictate into uses one profile: its tone, how much cleanup changes, and the prompt. Everywhere covers every app that isn't in another.")
                    Text("Tone works without AI cleanup, so profiles do too.")
                }
            }
            .frame(minHeight: 18).padding(.leading, 14).padding(.top, 4).padding(.bottom, 4)
            Plate(padding: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(profiles.profiles) { profile in row(profile) }
                    Hairline().padding(.vertical, 5).padding(.horizontal, 3)
                    Button("New Profile", systemImage: "plus", action: add)
                        .padding(.horizontal, 3).padding(.bottom, 2)
                }
            }
        }
    }

    private func row(_ profile: CleanupProfile) -> some View {
        let selected = profile.id == selectedID
        let count = profiles.apps(in: profile.id).count
        return Button { selectedID = profile.id } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(profile.id)).frame(width: 20)
                    .foregroundStyle(selected ? GoblinBrand.mossText : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).fontWeight(selected ? .medium : .regular).lineLimit(1)
                    Text(profile.purpose.isEmpty ? "No description yet" : profile.purpose)
                        .font(.meta).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(profile.summary + (profile.isEverywhere ? "" : " · \(count) \(count == 1 ? "app" : "apps")"))
                    .font(.status).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .font(.row)
            .padding(.horizontal, 9).frame(height: 40)
            .background(selected ? AnyShapeStyle(GoblinBrand.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case CleanupProfile.everywhereID: "globe"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "chat": "bubble.left.and.bubble.right"
        case "email": "envelope"
        default: "square.stack"
        }
    }
}
