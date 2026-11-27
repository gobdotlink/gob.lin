import GoblinCore
import SwiftUI

/// The switch and level apply as soon as they change; the provider is edited in a sheet and applies on Save.
struct RewriteSettingsView: View {
    @State private var settings: RewriteSettings
    private let defaults: UserDefaults
    private let inspectCredentials: Bool
    private let onSaved: () -> Void
    private let onFailure: (DiagnosticFailure) -> Void
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

    init(defaults: UserDefaults = .standard, inspectCredentials: Bool = true, onSaved: @escaping () -> Void = {},
         onFailure: @escaping (DiagnosticFailure) -> Void = { _ in }) {
        self.defaults = defaults; self.inspectCredentials = inspectCredentials
        self.onSaved = onSaved; self.onFailure = onFailure
        _settings = State(initialValue: RewriteSettingsStore.load(defaults: defaults))
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { setEnabled($0) })) {
                Text("AI cleanup")
                Text("Sends text only, never audio.").rowDetail()
            }
            StatusRow(isOn ? .ready : .off,
                      Text(isOn ? (settings.provider.runsOnDevice
                                   ? "Cleanup runs on this Mac with \(Text(settings.provider.title).fontWeight(.semibold)). Nothing is sent anywhere."
                                   : settings.usesScreenContext
                                   ? "Your text and the text near your cursor go to \(Text(settings.provider.title).fontWeight(.semibold)). Everything else stays on this Mac."
                                   : "Your text goes to \(Text(settings.provider.title).fontWeight(.semibold)). Everything else stays on this Mac.")
                                : "Off. Everything stays on this Mac."))
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
                    var next = settings; next.usesScreenContext = on; persist(next)
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
        Section {
            ForEach(RewriteCleanup.allCases) { level in
                let selected = settings.cleanup == level
                Button {
                    var next = settings; next.cleanup = level; persist(next)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title)
                            Text(level.detail).font(.status).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark").font(.row.weight(.semibold))
                            .foregroundStyle(GoblinBrand.mossText).opacity(selected ? 1 : 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(level.title + ", " + level.detail)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        } header: { Text("Level") }
        Section {
            formattingToggle(\.paragraphs) {
                Text("Paragraphs")
                Text("Starts a new paragraph when you move to a new point.").rowDetail()
                Text("Saying “next” or “another thing” starts one too. Each point keeps its own words, in the order you said them.")
            }
            formattingToggle(\.lists) {
                Text("Lists")
                Text("Turns “one… two…” or “first… second…” into a numbered list.").rowDetail()
                Text("Three or more things after “three things” or a similar lead-in become bullets. Things you mention in passing, like “milk, eggs and bread”, stay in the sentence.")
                Text("Lists use plain “1.” and “-”, so they read the same in every app.")
            }
            formattingToggle(\.spokenBreaks) {
                Text("Say “New Line”")
                Text("Say “new line” or “new paragraph” to start one.").rowDetail()
                Text("Only when you say it on its own, between thoughts. “Add a new line to the file” stays as words.")
            }
        } header: { Text("Formatting") }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("What you said → what gets typed")
                        Spacer()
                        if let testOutput {
                            Text("\(sample.split(whereSeparator: \.isWhitespace).count) → \(testOutput.split(whereSeparator: \.isWhitespace).count) words").monospacedDigit()
                        }
                    }
                    .font(.meta).foregroundStyle(.secondary)
                    Group {
                        if let testOutput { InlineDiff(from: sample, to: testOutput) }
                        else { Text(sample).foregroundStyle(.secondary) }
                    }
                    .font(.row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                HStack(spacing: 10) {
                    Text(testMeta ?? (isOn ? (settings.provider.runsOnDevice ? "Runs this one sentence on this Mac." : "Sends this one sentence, nothing else.") : "Turn on AI cleanup to try it."))
                        .font(.status).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button(testing ? "Testing…" : testOutput == nil ? "Run Test" : "Run Again") { testCleanup() }
                        .prominent()
                        .disabled(testing || !inspectCredentials || !isOn)
                }
            }
            .padding(.vertical, 4)
            if let testFailure { StatusRow(.problem, Text(testFailure)) }
        } header: { Text("Try it") } footer: {
            Text("Slower than 4 s? I type what you said instead, and say so in the bubble.")
        }
        .onAppear { refreshKeyStatus() }
        .onDisappear { testTask?.cancel(); testTask = nil; testing = false }
        .sheet(isPresented: $editingProvider, onDismiss: { turnOnAfterEdit = false }) {
            CleanupProviderSheet(settings: settings, defaults: defaults, inspectCredentials: inspectCredentials, turnOn: turnOnAfterEdit,
                                 onSave: { saved in
                                     testTask?.cancel()
                                     settings = saved; message = nil; testOutput = nil; testMeta = nil; testFailure = nil
                                     refreshKeyStatus(); onSaved()
                                 }, onFailure: onFailure)
        }
    }

    /// Fillers, a doubled word and missing punctuation, so the diff has something to show.
    static let sample = "um so i think we should uh ship the overlay fix tonight and and do onboarding tomorrow like the copy is basically done"
    /// The same, plus a list and a new point, for when Paragraphs or Lists is on.
    static let formattedSample = "um so this week there are three things the overlay fix the onboarding copy and and the docs another thing can we uh move the review to friday"

    private var sample: String { settings.formatting.paragraphs || settings.formatting.lists ? Self.formattedSample : Self.sample }

    private var isOn: Bool { settings.enabled && settings.cleanup != .none }

    /// A formatting switch. It saves at once like the level, and does nothing while the level is None.
    private func formattingToggle<Label: View>(_ option: WritableKeyPath<RewriteFormatting, Bool>,
                                               @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { settings.formatting[keyPath: option] }, set: { on in
            var next = settings; next.formatting[keyPath: option] = on; persist(next)
            // The sample may change with formatting, and a result must stay beside the text it came from.
            testTask?.cancel(); testOutput = nil; testMeta = nil; testFailure = nil
        }), label: label)
        .disabled(settings.cleanup == .none)
    }

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
        var next = settings; next.enabled = on; persist(next)
    }

    private func persist(_ next: RewriteSettings) {
        do {
            try RewriteSettingsStore.save(next, defaults: defaults)
            settings = next; message = nil
            onSaved()
        } catch { message = error.localizedDescription; onFailure(.settingsSaveFailed) }
    }

    private func refreshKeyStatus() {
        guard inspectCredentials else { keySaved = false; return }
        do { keySaved = try !RewriteKeyStore.load(for: settings, defaults: defaults).isEmpty }
        catch { keySaved = false }
    }

    private func testCleanup() {
        guard !testing, inspectCredentials, isOn else { return }
        let snapshot = settings, sample = sample
        testing = true
        testFailure = nil
        testTask = Task { @MainActor in
            defer { testing = false; testTask = nil }
            do {
                let key = try RewriteKeyStore.load(for: snapshot, defaults: defaults)
                let start = ContinuousClock.now
                let result = await RewriteClient().rewrite(sample, settings: snapshot, apiKey: key)
                try Task.checkCancellation()
                if let failure = result.failure { throw failure }
                guard result.wasRewritten else { throw RewriteFailure.invalidResponse }
                let elapsed = start.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                testOutput = result.outputText
                testMeta = "\(snapshot.cleanup.title) · \(snapshot.model) · \(Int(milliseconds.rounded())) ms"
            } catch {
                guard !Task.isCancelled else { return }
                testFailure = "\(snapshot.provider.title) didn't answer the test: \(error.localizedDescription)"
            }
        }
    }
}
