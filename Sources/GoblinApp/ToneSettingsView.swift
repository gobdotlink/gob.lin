import GoblinCore
import SwiftUI

struct ToneSettingsView: View {
    @AppStorage(DictationTone.preferenceKey) private var selectedRaw = DictationTone.formal.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tone").font(.title.bold())
            Text("Choose how your dictation sounds. Works without AI cleanup.").foregroundStyle(.secondary)
            ForEach(DictationTone.allCases) { tone in
                Button {
                    selectedRaw = tone.rawValue
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: selectedRaw == tone.rawValue ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedRaw == tone.rawValue ? Color.accentColor : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tone.title).font(.headline)
                            Text(tone.preview).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(selectedRaw == tone.rawValue ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedRaw == tone.rawValue ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tone.title + ", " + tone.preview)
                .accessibilityAddTraits(selectedRaw == tone.rawValue ? [.isSelected] : [])
            }
            Text("Your choice applies globally. Names, dictionary spellings, code, URLs, and acronyms keep their original form.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(24)
    }
}
