import GoblinCore
import SwiftUI

/// DESIGN.md › Status lights. The words beside a light carry the meaning; the colour repeats it.
enum LightState {
    case ready, waiting, problem, off

    var color: Color {
        switch self {
        case .ready: Color(nsColor: NSColor(hex: 0x2FB765))
        case .waiting: Color(nsColor: NSColor(hex: 0xF2A417))
        case .problem: Color(nsColor: NSColor(hex: 0xE2372D))
        case .off: .clear
        }
    }
}

struct StatusLight: View {
    let state: LightState
    var size: CGFloat = 8

    var body: some View {
        Group {
            if state == .off {
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            } else {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.55), state.color], center: UnitPoint(x: 0.5, y: 0.35),
                                         startRadius: 0, endRadius: size * 0.6))
                    .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: state.color.opacity(0.55), radius: size * 0.4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The last row of a settings group: one light, one sentence, and a detail or a single button.
struct StatusRow<Trailing: View>: View {
    let state: LightState
    let text: Text
    @ViewBuilder var trailing: Trailing

    init(_ state: LightState, _ text: Text, @ViewBuilder trailing: () -> Trailing) {
        self.state = state
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 9) {
            // Light and words read as one; the trailing control stays its own element.
            HStack(spacing: 9) {
                StatusLight(state: state)
                text.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing.font(.callout).foregroundStyle(.secondary)
        }
        .containerValue(\.statusRow, true)
    }
}

extension StatusRow where Trailing == EmptyView {
    init(_ state: LightState, _ text: Text) { self.init(state, text) { EmptyView() } }
}

/// Small-caps label above a plate.
struct CapsHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.85).foregroundStyle(.secondary)
    }
}

/// A white plate on the case, for pages that can't be a grouped Form.
struct Plate<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GoblinBrand.plate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

/// A shortcut drawn as physical keys: "⌥⇧Space" becomes ⌥ ⇧ Space.
struct KeyCombo: View {
    let label: String
    var small = false

    var body: some View {
        let modifiers = label.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = label.dropFirst(modifiers.count)
        HStack(spacing: small ? 2 : 3) {
            ForEach(Array(modifiers.enumerated()), id: \.offset) { KeyCap(String($0.element), small: small) }
            if !key.isEmpty { KeyCap(String(key), small: small) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

struct KeyCap: View {
    let label: String
    /// 17 pt instead of 20, for a key inside a line of small text.
    var small = false
    init(_ label: String, small: Bool = false) { self.label = label; self.small = small }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label)
            .font(.system(size: small ? 10 : 11, weight: .medium))
            .padding(.horizontal, small ? 4 : 5).frame(minWidth: small ? 17 : 20, minHeight: small ? 17 : 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(
                scheme == .dark ? LinearGradient(colors: [Color(white: 0.24), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [.white, Color(white: 0.945)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(scheme == .dark ? 0.7 : 0.2), lineWidth: 0.5))
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(scheme == .dark ? 0.5 : 0.09)).offset(y: 1.5))
    }
}

/// The talk key the way the keyboard draws it, one cap per key, with a light that is green once macOS lets gob.lin hear it.
struct TalkKeyCaps: View {
    let shortcut: HotkeyShortcut
    var light: LightState = .ready

    var body: some View {
        let keys = shortcut.keys
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                BigKeyCap(symbol: key.symbol, word: key.word, globe: shortcut.modifier == .fn, light: index == 0 ? light : nil)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(shortcut.title)
    }
}

struct BigKeyCap: View {
    let symbol: String
    var word = ""
    var globe = false
    var light: LightState?

    var body: some View {
        let ink = Color.black.opacity(0.86)
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [.white, Color(white: 0.945)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 2)
            .shadow(color: .black.opacity(0.06), radius: 5, y: 4)
            .overlay(alignment: word.isEmpty && !globe ? .center : .topTrailing) {
                // Modifiers and fn print small in the corner; an ordinary key prints big in the middle.
                Text(symbol).font(.system(size: word.isEmpty && !globe && symbol.count == 1 ? 17 : 12, weight: .medium)).foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, word.isEmpty && !globe ? 0 : 7).padding(.horizontal, word.isEmpty && !globe ? 6 : 9)
            }
            .overlay(alignment: .topLeading) { if let light { StatusLight(state: light, size: 5).padding(.top, 9).padding(.leading, 10) } }
            .overlay(alignment: .bottomLeading) {
                if globe { Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(ink).padding(.leading, 9).padding(.bottom, 8) }
                else if !word.isEmpty { Text(word).font(.system(size: 9, weight: .medium)).foregroundStyle(ink).lineLimit(1).fixedSize().padding(.leading, 7).padding(.bottom, 7) }
            }
            .frame(width: 60, height: 56)
    }
}

/// Cut words struck through on red, added words on green, in one line of the person's own words.
struct InlineDiff: View {
    let changes: [TextDiff.Change]

    init(from old: String, to new: String) { changes = TextDiff.changes(from: old, to: new) }

    var body: some View {
        Text(attributed).lineSpacing(5)
            .accessibilityLabel(changes.compactMap { if case .removed = $0 { nil } else { text($0) } }.joined(separator: " "))
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, change) in changes.enumerated() {
            let value = text(change)
            if index > 0, !(value.count == 1 && ".,!?;:)…".contains(value)) { result += AttributedString(" ") }
            var run = AttributedString(value)
            switch change {
            case .kept: break
            case .removed:
                run.strikethroughStyle = .single
                run.foregroundColor = Color(nsColor: .dynamic(light: 0xB4362E, dark: 0xFF8A80))
                run.backgroundColor = Color(nsColor: NSColor(hex: 0xE2372D, alpha: 0.12))
            case .added:
                run.foregroundColor = Color(nsColor: .dynamic(light: 0x1E6B40, dark: 0x7BE3A3))
                run.backgroundColor = Color(nsColor: NSColor(hex: 0x2FB765, alpha: 0.16))
            }
            result += run
        }
        return result
    }

    private func text(_ change: TextDiff.Change) -> String {
        switch change { case .kept(let value), .removed(let value), .added(let value): value }
    }
}

extension View {
    /// The one primary action on a surface: moss fill, white label. Everything else stays neutral,
    /// which is why moss is applied here rather than as an app-wide tint.
    func prominent() -> some View { buttonStyle(.borderedProminent).tint(GoblinBrand.moss) }

    /// The warm grey window background shared by Settings and History.
    func caseBackground() -> some View { background(GoblinBrand.caseBackground.ignoresSafeArea()) }
}

// MARK: - Case and plates

/// Settings pages as white plates on the warm case. A native grouped Form can only draw its sections
/// darker than the window in light mode, so this style lays the same sections out itself.
struct PlateFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group(sections: configuration.content) { sections in
                    ForEach(Array(sections.enumerated()), id: \.element.id) { position, section in
                        Self.section(section, first: position == 0)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 2).padding(.bottom, 28)
        }
        .labeledContentStyle(PlateLabeledContentStyle())
        .disclosureGroupStyle(RowDisclosureStyle())
        .toggleStyle(PlateToggleStyle())
    }

    @ViewBuilder private static func section(_ section: SectionConfiguration, first: Bool) -> some View {
        if section.containerValues.plateless {
            section.content.frame(maxWidth: .infinity).padding(.top, 14)
        } else {
            if !section.header.isEmpty {
                // The first header sits 6 pt under the toolbar; later ones leave 22 pt above.
                section.header
                    .font(.system(size: 10, weight: .semibold)).tracking(0.85).textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14).padding(.top, first ? 6 : 22).padding(.bottom, 8)
            } else {
                Spacer().frame(height: first ? 6 : 14)
            }
            Group(subviews: section.content) { rows in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline().padding(.horizontal, 14) }
                        row.padding(.vertical, 9)
                            .frame(maxWidth: .infinity, minHeight: row.containerValues.statusRow ? 36 : 42, alignment: .leading)
                            .padding(.horizontal, 14)
                    }
                }
                .background(GoblinBrand.plate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.035), radius: 1, y: 1)
            }
            if !section.footer.isEmpty {
                section.footer.font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 7)
            }
        }
    }
}

/// A title, then an optional grey second line, stacked. Shared by rows and switches.
private struct RowTitle: View {
    let label: AnyView

    var body: some View {
        Group(subviews: label) { lines in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index == 0 { line } else { line.font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PlateLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            RowTitle(label: AnyView(configuration.label))
            Spacer(minLength: 12)
            configuration.content
        }
    }
}

struct PlateToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            RowTitle(label: AnyView(configuration.label))
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden().tint(GoblinBrand.moss)
        }
    }
}

/// One device pixel, so it never rounds away at 1× or doubles at 2×.
struct Hairline: View {
    @Environment(\.displayScale) private var scale

    var body: some View { Rectangle().fill(.primary.opacity(0.12)).frame(height: 1 / scale) }
}

/// The whole row opens and closes, not just the chevron and its words.
struct RowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isExpanded ? [.isSelected] : [])
            if configuration.isExpanded { configuration.content }
        }
    }
}

extension ContainerValues {
    /// A Settings section drawn straight on the case, without a plate (About's hero and side-by-side plates).
    @Entry var plateless: Bool = false
    /// Status rows are shorter than control rows in a plate.
    @Entry var statusRow: Bool = false
}

/// A sidebar row: a neutral grey fill when selected, with the glyph in moss. A List's selection is
/// always the system accent, so the sidebars draw their own rows.
struct SidebarRow<Icon: View, Trailing: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon.frame(width: 18).foregroundStyle(selected ? GoblinBrand.mossText : .secondary)
                Text(title).fontWeight(selected ? .medium : .regular).lineLimit(1)
                Spacer(minLength: 4)
                trailing.foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9).frame(height: 28)
            .background(selected ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension SidebarRow where Trailing == EmptyView {
    init(title: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, selected: selected, action: action, icon: icon) { EmptyView() }
    }
}

/// A toolbar title level with the traffic lights, in the size the mockups use, with an optional grey line under it.
struct ToolbarTitle: ToolbarContent {
    let title: String
    var subtitle: String?
    /// Inset from the sidebar's edge: 24 over a Settings page, 16 over the History list.
    var leading: CGFloat = 24

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            }
            // The navigation slot already starts 6 pt past the sidebar.
            .padding(.leading, leading - 6)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// Moves a selection through an ordered list with the arrow keys.
extension View {
    func arrowKeySelection<Item: Equatable>(_ items: [Item], selection: Binding<Item?>) -> some View {
        focusable().focusEffectDisabled()
            .onKeyPress(.downArrow) { step(items, selection, by: 1) }
            .onKeyPress(.upArrow) { step(items, selection, by: -1) }
    }

    private func step<Item: Equatable>(_ items: [Item], _ selection: Binding<Item?>, by delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let index = selection.wrappedValue.flatMap { items.firstIndex(of: $0) } ?? (delta > 0 ? -1 : items.count)
        selection.wrappedValue = items[min(items.count - 1, max(0, index + delta))]
        return .handled
    }
}

/// Where a `GazingGoblin` looks. Feed it the pointer from the whole region it should watch:
/// `.onContinuousHover(coordinateSpace: .global, perform: eyes.follow)`.
@MainActor @Observable final class GoblinEyes {
    /// Changes only when the pointer crosses into another direction, not on every move.
    var gaze = Gaze.ahead
    /// The goblin's eye line in global coordinates and its points per art pixel, reported by the goblin.
    @ObservationIgnored fileprivate var center = CGPoint.zero
    @ObservationIgnored fileprivate var scale: CGFloat = 1

    func follow(_ phase: HoverPhase) {
        var next = Gaze.ahead
        if case .active(let pointer) = phase {
            next = .toward(dx: (pointer.x - center.x) / scale, dy: (pointer.y - center.y) / scale, from: gaze)
        }
        if next != gaze { gaze = next }
    }
}

/// The goblin with slit pupils looking where `eyes` says.
struct GazingGoblin: View {
    let eyes: GoblinEyes
    var scale: CGFloat = 1

    var body: some View {
        PixelSprite(sprite: Sprite(rawValue: "goblin-eyes-" + eyes.gaze.rawValue)!, scale: scale)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // The eyes sit on art row 31 of 64.
                eyes.center = CGPoint(x: frame.midX, y: frame.minY + frame.height * 31 / 64)
                eyes.scale = frame.width / 64
            }
    }
}
