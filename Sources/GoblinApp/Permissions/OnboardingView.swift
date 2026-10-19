import GoblinCore
import SwiftUI

/// First run: permissions, the talk key, a first take, then "You're hired." Also the place
/// gob.lin sends people back to when a permission goes missing.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var permissions: PermissionModel
    @ObservedObject private var hotkeys: HotkeyService
    @State private var step: Step = .permissions
    @State private var waitingFor: PermissionModel.Permission?
    @State private var keyChecked = false
    @State private var take: (result: OverlayResult, text: String)?
    @State private var celebrate = false

    enum Step: Int, CaseIterable { case permissions, talkKey, firstTake, hired }

    init(model: AppModel, startAt step: Step = .permissions) {
        self.model = model
        _step = State(initialValue: step)
        _permissions = ObservedObject(wrappedValue: model.permissions)
        _hotkeys = ObservedObject(wrappedValue: model.hotkeys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if step != .hired { steps }
            switch step {
            case .permissions: permissionsStep
            case .talkKey: talkKeyStep
            case .firstTake: firstTakeStep
            case .hired: hiredStep
            }
        }
        // The mockup's 548 pt window measures 54 pt from its top edge; the 32 pt title bar is above this.
        .padding(.top, step == .hired ? 8 : 22).padding(.horizontal, 44).padding(.bottom, 26)
        .frame(width: 660, height: 548 - 32, alignment: .topLeading)
        .caseBackground()
        .onChange(of: step, initial: true) { _, step in listen(on: step) }
        .onChange(of: hotkeys.recording) { _, recording in if recording != nil, step == .talkKey { keyChecked = true } }
        .onChange(of: permissions.snapshot.ready) { _, ready in if ready { waitingFor = nil } }
        .onDisappear { model.onboardingTake = nil }
    }

    /// The talk-key and first-take steps catch dictations made with this window in front.
    private func listen(on step: Step) {
        guard step == .talkKey || step == .firstTake else { model.onboardingTake = nil; return }
        model.onboardingTake = { result, text in
            keyChecked = true
            if self.step == .firstTake { take = (result, text) }
        }
    }

    // MARK: Steps bar

    private var steps: some View {
        HStack(spacing: 10) {
            stepLabel("Permissions", .permissions)
            Rectangle().fill(.quaternary).frame(width: 36, height: 1)
            stepLabel("Talk key", .talkKey)
            Rectangle().fill(.quaternary).frame(width: 36, height: 1)
            stepLabel("First take", .firstTake)
        }
        .font(.system(size: 12.5))
    }

    private func stepLabel(_ title: String, _ value: Step) -> some View {
        HStack(spacing: 7) {
            StatusLight(state: value.rawValue < step.rawValue || (value == .permissions && permissions.snapshot.ready) ? .ready
                        : value == step ? .waiting : .off)
            Text(title).fontWeight(value == step ? .semibold : .regular).foregroundStyle(value == step ? .primary : .secondary)
        }
    }

    private func headline(_ title: String, _ subtitle: Text) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.4)
            subtitle.font(.system(size: 13.5)).foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 26)
    }

    private func footer<Buttons: View>(_ note: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Text(note).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            buttons().controlSize(.large)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: 1 · Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(permissions.snapshot.ready ? "You're all set." : "Two switches, then you can talk.",
                     Text("macOS asks for each one. I only listen while you hold the talk key."))
            Plate(padding: 4) {
                VStack(spacing: 0) {
                    permissionRow(.microphone, symbol: "mic", title: "Microphone", detail: "Hears you only while the talk key is down.")
                    Divider().padding(.leading, 110)
                    permissionRow(.accessibility, symbol: "accessibility", title: "Accessibility", detail: "Puts your words wherever the cursor is, and notices the talk key.")
                }
            }
            .overlay(alignment: .topTrailing) {
                PeekingGoblin(sprite: .shut, scale: 2)
                    .alignmentGuide(.top) { $0[.bottom] }
                    .padding(.trailing, 20)
            }
            .padding(.top, 74)
            if let failure = permissions.tapFailure {
                StatusRow(.waiting, Text(failure == .runLoopSourceFailed
                    ? "The talk key couldn't start. Quit and reopen gob.lin."
                    : permissions.snapshot.accessibility ? "macOS says Accessibility is on, but the talk key still couldn't start. Try Check Again, then reopen gob.lin."
                    : "Accessibility is still off for this copy of gob.lin."))
                    .padding(.top, 12)
            }
            if permissions.lastRevoked != nil {
                StatusRow(.waiting, Text("A permission was turned off, so I stopped listening safely.")).padding(.top, 12)
            }
            footer("Lights flip on as you allow each one.") {
                if !permissions.snapshot.ready { Button("Check Again") { permissions.checkAgain() } }
                Button("Later") { permissions.closeOnboarding() }
                Button("Continue") { step = .talkKey }.prominent().disabled(!permissions.snapshot.ready)
            }
        }
    }

    private var currentPermission: PermissionModel.Permission? {
        [.microphone, .accessibility].first { !permissions.snapshot.isGranted($0) }
    }

    private func permissionRow(_ permission: PermissionModel.Permission, symbol: String, title: String, detail: String) -> some View {
        let granted = permissions.snapshot.isGranted(permission)
        let current = permission == currentPermission
        let waiting = waitingFor == permission && !granted
        let light: LightState = granted ? .ready : waiting ? .waiting : .off
        return HStack(spacing: 12) {
            VStack(spacing: 5) {
                StatusLight(state: light)
                Text(granted ? "ON" : waiting ? "WAIT" : "OFF").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            }
            .frame(width: 40)
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if waiting {
                    Text("Waiting for System Settings. Flip gob.lin on, then come back. I'll notice.")
                        .font(.system(size: 12)).foregroundStyle(GoblinBrand.candle).padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if granted {
                Label("Allowed", systemImage: "checkmark").font(.system(size: 12.5, weight: .medium)).foregroundStyle(GoblinBrand.mossText)
            } else {
                let label = permission == .microphone && permissions.snapshot.microphone == .notDetermined ? "Allow…" : "Open Settings"
                let button = Button(label) { waitingFor = permission; permissions.request(permission) }
                    .accessibilityLabel("\(label) for \(title)")
                if current { button.prominent() } else { button.buttonStyle(.bordered) }
            }
        }
        .padding(.vertical, 11).padding(.leading, 8).padding(.trailing, 12)
        .background(current ? AnyShapeStyle(GoblinBrand.moss.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: 2 · Talk key

    private var talkKeyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline("Pick your talk key.", Text("Hold it to talk, let go to type. Tap it to keep listening hands-free."))
            Plate {
                VStack(alignment: .leading, spacing: 14) {
                    let stacked = hotkeys.shortcut.keys.count > 2
                    if stacked { TalkKeyCaps(shortcut: hotkeys.shortcut, light: keyChecked ? .ready : .off) }
                    HStack(spacing: 16) {
                        if !stacked { TalkKeyCaps(shortcut: hotkeys.shortcut, light: keyChecked ? .ready : .off) }
                        Text(hotkeys.shortcut.title).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        ShortcutRecorder(service: hotkeys, showsCurrent: false)
                    }
                    Picker("Quick picks", selection: Binding(get: { hotkeys.shortcut }, set: { hotkeys.setShortcut($0); keyChecked = false })) {
                        Text("fn / Globe").tag(HotkeyShortcut.fn)
                        Text("Right ⌥").tag(HotkeyShortcut.rightOption)
                        Text("⌥ Space").tag(HotkeyShortcut.optionSpace)
                    }
                    .pickerStyle(.segmented).fixedSize().tint(GoblinBrand.moss)
                    Divider()
                    StatusRow(keyChecked ? .ready : .off, Text(keyChecked ? "Got it. That's your talk key." : "Press it now to check it works."))
                }
            }
            .padding(.top, 28)
            if hotkeys.shortcut == .fn {
                Text("If the Globe key opens emoji, set it to Do Nothing in System Settings › Keyboard.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
            }
            footer("You can change this any time in Settings.") {
                Button("Back") { step = .permissions }
                Button("Continue") { step = .firstTake }.prominent()
            }
        }
    }

    // MARK: 3 · First take

    private var shortcutName: String { hotkeys.shortcut == .fn ? "fn" : hotkeys.shortcut.title }

    private var firstTakeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline("Say something.", Text("Hold \(Text(shortcutName).fontWeight(.semibold)), read this out loud, then let go."))
            Text("“The goblin types faster than I do.”").font(.system(size: 19, weight: .medium)).padding(.top, 26)
            takeField
                .overlay(alignment: .topTrailing) {
                    PeekingGoblin(sprite: .cackle, scale: 1).alignmentGuide(.top) { $0[.bottom] }.padding(.trailing, 40)
                }
                .padding(.top, 84)
            if let take {
                Label {
                    Text("**Nailed it.** \(take.result.words.formatted()) \(take.result.words == 1 ? "word" : "words") in \(take.result.seconds.formatted(.number.precision(.fractionLength(2)))) s.")
                } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(GoblinBrand.mossText) }
                .font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit().padding(.top, 10)
            }
            footer("Try it as many times as you like.") {
                Button("Back") { step = .talkKey }
                Button("Continue") { step = .hired; celebrate = true }.prominent().disabled(take == nil)
            }
        }
    }

    private var takeField: some View {
        Text(take?.text ?? "Your words land here.")
            .font(.system(size: 15)).lineSpacing(3)
            .foregroundStyle(take == nil ? .tertiary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(take == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(GoblinBrand.moss), lineWidth: take == nil ? 0.5 : 1.5))
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(GoblinBrand.moss.opacity(take == nil ? 0 : 0.12)).padding(-4))
    }

    // MARK: 4 · You're hired

    private var hiredStep: some View {
        VStack(spacing: 0) {
            Celebration(active: celebrate)
            Text("You're hired.").font(.system(size: 28, weight: .bold)).tracking(-0.4).padding(.top, 18)
            Group {
                if let take {
                    Text("Your first words took \(Text("\(take.result.seconds.formatted(.number.precision(.fractionLength(2)))) s").fontWeight(.semibold)) from release to text\(cleanupOn ? "." : ", and nothing left this Mac.")")
                } else {
                    Text("From now on, hold \(shortcutName) in any app and talk.")
                }
            }
            .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8)
            if take != nil { takeField.frame(width: 440).padding(.top, 20) }
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: GoblinBrand.menuImage(.idle)).padding(.horizontal, 4).frame(height: 22)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "wifi").font(.system(size: 13))
                    Text(Date(), format: .dateTime.hour().minute()).font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
                Text("That's me, top right. Click me for history and settings.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .padding(8).padding(.trailing, 4)
            .background(GoblinBrand.caseBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 16)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                GoblinTagline(size: 20, reply: "ok").fixedSize()
                .padding(.horizontal, 12).frame(height: 36)
                .background(Color(nsColor: NSColor(hex: 0x101312)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .environment(\.colorScheme, .dark)
                Spacer()
                Button("Open Settings") { permissions.closeOnboarding(); model.openSettings(.general) }.controlSize(.large)
                Button("Done") { permissions.closeOnboarding() }.prominent().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var cleanupOn: Bool {
        let settings = RewriteSettingsStore.load(defaults: model.defaults)
        return settings.enabled && settings.cleanup != .none
    }
}

/// The app's one long animation: sparkles and coins appear at 1×, step up to full size, and stay.
/// Pixel art never tweens, so the steps are instant and only the first appearance fades.
private struct Celebration: View {
    let active: Bool
    @State private var stage = 0
    // ponytail: shown settled when the step opens without a fresh take, e.g. in fixtures.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pieces: [(Sprite, CGFloat, CGFloat, CGFloat)] = [
        (.spark, -86, -40, 3), (.spark, 84, -52, 2), (.spark, 106, 14, 3), (.spark, -100, 40, 2),
        (.coin, -58, 2, 2), (.coin, 66, -20, 2),
    ]

    var body: some View {
        PixelSprite(sprite: .cackle, scale: 2)
            .overlay {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    PixelSprite(sprite: piece.0, scale: stage == 2 || reduceMotion ? piece.3 : 1)
                        .offset(x: piece.1, y: piece.2)
                        .opacity(stage > 0 || reduceMotion ? 1 : 0)
                }
            }
            .task {
                guard active, !reduceMotion else { stage = 2; return }
                withAnimation(.easeOut(duration: 0.15)) { stage = 1 }
                try? await Task.sleep(for: .milliseconds(200))
                stage = 2
            }
    }
}
