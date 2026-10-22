import AppKit
import SwiftUI

/// Edits one Boost: zapped elements, font, and custom CSS/JavaScript. Changes apply live.
struct BoostEditorView: View {
    let boostID: UUID
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private static let fonts = ["Avenir Next", "Georgia", "Helvetica Neue", "Iowan Old Style", "Menlo", "New York", "Palatino", "SF Pro", "Times New Roman"]
        .filter { NSFontManager.shared.availableFontFamilies.contains($0) || $0 == "SF Pro" }

    var body: some View {
        if let boost = store.boosts.first(where: { $0.id == boostID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "bolt.fill").foregroundStyle(.pink)
                    TextField("Name", text: binding(boost, \.name))
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                    Toggle("Enabled", isOn: binding(boost, \.isEnabled))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(boost.isEnabled ? "Turn this Boost off" : "Turn this Boost on")
                }
                .padding([.horizontal, .top], 20)
                Text("Applies to \(boost.domain) and its subdomains")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                Form {
                    Section("Zap") {
                        Button("Zap Elements on This Page…") { store.startZapping() }
                            .disabled(!(store.activeHost.map(boost.matches) ?? false))
                        if boost.zappedSelectors.isEmpty {
                            Text("Click elements on the page to hide them for good.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(boost.zappedSelectors, id: \.self) { selector in
                            HStack {
                                Text(selector).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { store.updateBoost(boostID) { $0.zappedSelectors.removeAll { $0 == selector } } } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderless)
                                .help("Unzap")
                            }
                        }
                    }
                    Section("Font") {
                        Picker("Page font", selection: binding(boost, \.fontFamily)) {
                            Text("Site default").tag(String?.none)
                            ForEach(Self.fonts, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    Section("CSS") {
                        CodeEditor(text: binding(boost, \.css))
                    }
                    Section {
                        CodeEditor(text: binding(boost, \.js))
                    } header: {
                        Text("JavaScript")
                    } footer: {
                        Text("Runs when a page on this site loads. Reload to apply changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button("Delete Boost", role: .destructive) { store.deleteBoost(boostID) }
                    Spacer()
                    Button("Reload Page") { store.pool.existingWebView(for: store.activeTabID)?.reload() }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .frame(width: 520, height: 640)
        }
    }

    private func binding<Value>(_ boost: Boost, _ keyPath: WritableKeyPath<Boost, Value>) -> Binding<Value> {
        Binding(
            get: { boost[keyPath: keyPath] },
            set: { value in store.updateBoost(boostID) { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct CodeEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .frame(height: 110)
            .scrollContentBackground(.hidden)
    }
}
