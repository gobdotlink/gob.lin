import GoblinCore
import SwiftUI

struct ToneSettingsView: View {
    @AppStorage(DictationTone.preferenceKey) private var selectedRaw = DictationTone.formal.rawValue

    var body: some View {
        Section {
            ForEach(DictationTone.allCases) { tone in
                let selected = selectedRaw == tone.rawValue
                Button {
                    selectedRaw = tone.rawValue
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tone.title).font(.headline)
                            Text(tone.preview).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark").font(.body.weight(.semibold))
                            .foregroundStyle(GoblinBrand.accent).opacity(selected ? 1 : 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tone.title + ", " + tone.preview)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        } header: { Text("Works without AI cleanup") } footer: {
            Text("Your choice applies globally. Names, dictionary spellings, code, URLs, and acronyms keep their original form.")
        }
    }
}
