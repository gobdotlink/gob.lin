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
            StatusLight(state: state)
            text.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing.font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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

    var body: some View {
        let modifiers = label.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = label.dropFirst(modifiers.count)
        HStack(spacing: 3) {
            ForEach(Array(modifiers.enumerated()), id: \.offset) { KeyCap(String($0.element)) }
            if !key.isEmpty { KeyCap(String(key)) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

struct KeyCap: View {
    let label: String
    init(_ label: String) { self.label = label }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(
                scheme == .dark ? LinearGradient(colors: [Color(white: 0.24), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(colors: [.white, Color(white: 0.945)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(scheme == .dark ? 0.7 : 0.2), lineWidth: 0.5))
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(scheme == .dark ? 0.5 : 0.09)).offset(y: 1.5))
    }
}

/// The talk key the way the keyboard draws it, with a light that is green once macOS lets gob.lin hear it.
struct BigKeyCap: View {
    let label: String
    var globe = false
    var light: LightState = .ready

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [.white, Color(white: 0.945)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 2)
            .shadow(color: .black.opacity(0.06), radius: 5, y: 4)
            .overlay(alignment: .topTrailing) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.black.opacity(0.86)).padding(.top, 7).padding(.trailing, 9)
            }
            .overlay(alignment: .topLeading) { StatusLight(state: light, size: 5).padding(.top, 9).padding(.leading, 10) }
            .overlay(alignment: .bottomLeading) {
                if globe { Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(.black.opacity(0.86)).padding(.leading, 9).padding(.bottom, 8) }
            }
            .frame(width: 60, height: 56)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
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
                ForEach(sections: configuration.content) { section in
                    if !section.header.isEmpty {
                        section.header
                            .font(.system(size: 10, weight: .semibold)).tracking(0.85).textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14).padding(.top, 22).padding(.bottom, 8)
                    } else {
                        Spacer().frame(height: 14)
                    }
                    Group(subviews: section.content) { rows in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Hairline().padding(.horizontal, 14) }
                                row.frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
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
            .padding(.horizontal, 28).padding(.top, 2).padding(.bottom, 28)
        }
        .labeledContentStyle(PlateLabeledContentStyle())
        .disclosureGroupStyle(RowDisclosureStyle())
        .toggleStyle(PlateToggleStyle())
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
