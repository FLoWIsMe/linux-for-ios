import SwiftUI
import TernCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var settings: SettingsStore { model.settings }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    appearanceSection
                    terminalSection
                    shellSection
                    keyboardSection
                    aboutSection
                }
                .screenPadding()
                .padding(.vertical, 16)
            }
            .background(ChromeColor.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onChange(of: settings.fontSize) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.font) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.cursorShape) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.cursorBlinks) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.darkPaletteID) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.lightPaletteID) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.optionAsMeta) { _, _ in model.refreshAppearance() }
        .onChange(of: settings.hapticKeys) { _, _ in model.refreshAppearance() }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Appearance")
            AppearancePicker(settings: settings)
            PalettePicker(title: "Dark palette", palettes: TerminalPalette.all.filter(\.isDark), selectedID: Binding(
                get: { settings.darkPaletteID }, set: { settings.darkPaletteID = $0 }))
            PalettePicker(title: "Light palette", palettes: TerminalPalette.all.filter { !$0.isDark }, selectedID: Binding(
                get: { settings.lightPaletteID }, set: { settings.lightPaletteID = $0 }))
        }
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Terminal")
            Card {
                CardRow(title: "Font") {
                    Picker("Font", selection: Binding(get: { settings.font }, set: { settings.font = $0 })) {
                        ForEach(TerminalFont.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                CardDivider()
                CardRow(title: "Size", subtitle: "\(Int(settings.fontSize)) pt") {
                    Stepper("Size", value: Binding(get: { settings.fontSize }, set: { settings.fontSize = $0 }),
                            in: SettingsStore.fontSizeRange, step: 1)
                        .labelsHidden()
                }
                CardDivider()
                CardRow(title: "Cursor") {
                    Picker("Cursor", selection: Binding(get: { settings.cursorShape }, set: { settings.cursorShape = $0 })) {
                        ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                CardDivider()
                CardRow(title: "Blinking cursor") {
                    Toggle("Blinking cursor", isOn: Binding(get: { settings.cursorBlinks }, set: { settings.cursorBlinks = $0 })).labelsHidden()
                }
                CardDivider()
                CardRow(title: "Bell") {
                    Picker("Bell", selection: Binding(get: { settings.bell }, set: { settings.bell = $0 })) {
                        ForEach(BellBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                CardDivider()
                CardRow(title: "Stay awake while a command runs", subtitle: "Keeps the screen on during ssh sessions and downloads") {
                    Toggle("Stay awake", isOn: Binding(get: { settings.keepAwakeWhileRunning }, set: { settings.keepAwakeWhileRunning = $0 })).labelsHidden()
                }
            }
        }
    }

    private var shellSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Shell")
            Card {
                CardRow(title: "Prompt", subtitle: "Applies to new tabs") {
                    Picker("Prompt", selection: Binding(get: { settings.promptStyle }, set: { settings.promptStyle = $0 })) {
                        ForEach(PromptStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                }
                CardDivider()
                CardRow(title: "Suggestions from history", subtitle: "Grey text after the cursor, accept with the right arrow") {
                    Toggle("Suggestions", isOn: Binding(get: { settings.autosuggestions }, set: { settings.autosuggestions = $0 })).labelsHidden()
                }
                CardDivider()
                CardRow(title: "Syntax highlighting") {
                    Toggle("Highlighting", isOn: Binding(get: { settings.syntaxHighlighting }, set: { settings.syntaxHighlighting = $0 })).labelsHidden()
                }
                CardDivider()
                CardRow(title: "Welcome line in new tabs") {
                    Toggle("Welcome", isOn: Binding(get: { settings.welcomeTips }, set: { settings.welcomeTips = $0 })).labelsHidden()
                }
                CardDivider()
                CardRow(title: "Startup script", subtitle: "~/.ternrc runs when a tab opens") {
                    Button("Edit") {
                        dismiss()
                        model.selected?.runCommand("vim ~/.ternrc")
                    }
                    .font(Typography.body(15, weight: .medium))
                    .foregroundStyle(ChromeColor.accent)
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Keyboard")
            Card {
                CardRow(title: "Key bar above the keyboard", subtitle: "esc, tab, ctrl, alt, arrows and symbols") {
                    Toggle("Key bar", isOn: Binding(get: { settings.keyboardBarEnabled }, set: { settings.keyboardBarEnabled = $0 })).labelsHidden()
                }
                CardDivider()
                CardRow(title: "Haptic feedback on key bar") {
                    Toggle("Haptics", isOn: Binding(get: { settings.hapticKeys }, set: { settings.hapticKeys = $0 })).labelsHidden()
                }
                CardDivider()
                CardRow(title: "Option key sends Alt", subtitle: "Hardware keyboards. Off lets Option type special characters") {
                    Toggle("Option as Alt", isOn: Binding(get: { settings.optionAsMeta }, set: { settings.optionAsMeta = $0 })).labelsHidden()
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "About")
            Card {
                CardRow(title: "Tern", subtitle: "Version \(SystemEnvironment.appVersion) (\(SystemEnvironment.buildNumber))") {
                    EmptyView()
                }
                CardDivider()
                linkRow(title: "Source code", subtitle: "MIT licensed, on GitHub", url: "https://github.com/FLoWIsMe/linux-for-ios")
                CardDivider()
                linkRow(title: "Report a problem", subtitle: "GitHub issues", url: "https://github.com/FLoWIsMe/linux-for-ios/issues")
                CardDivider()
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    CardRow(title: "Acknowledgements", subtitle: "Open source software inside Tern") {
                        Image(systemName: "chevron.right").foregroundStyle(ChromeColor.textTertiary).font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(PressableStyle(pressedScale: 1))
                CardDivider()
                CardRow(title: "Show the welcome tour again") {
                    Button("Show") {
                        dismiss()
                        model.showsOnboarding = true
                    }
                    .font(Typography.body(15, weight: .medium))
                    .foregroundStyle(ChromeColor.accent)
                    .buttonStyle(PressableStyle())
                }
            }
            Text("Tern never collects data. Everything you type stays on your device and on the servers you connect to.")
                .font(Typography.body(13))
                .foregroundStyle(ChromeColor.textTertiary)
                .padding(.top, 4)
        }
    }

    private func linkRow(title: String, subtitle: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            CardRow(title: title, subtitle: subtitle) {
                Image(systemName: "arrow.up.right").foregroundStyle(ChromeColor.textTertiary).font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(PressableStyle(pressedScale: 1))
    }
}

/// Horizontal strip of palette swatches.
struct PalettePicker: View {
    let title: String
    let palettes: [TerminalPalette]
    @Binding var selectedID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.body(14, weight: .medium))
                .foregroundStyle(ChromeColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(palettes) { palette in
                        Button {
                            selectedID = palette.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 0) {
                                        Text("~ ").foregroundStyle(palette.foreground.color.opacity(0.6))
                                        Text("\u{276F} ").foregroundStyle(palette.cursor.color).fontWeight(.bold)
                                        Text("ls").foregroundStyle(palette.foreground.color)
                                    }
                                    HStack(spacing: 3) {
                                        ForEach(0..<8, id: \.self) { index in
                                            RoundedRectangle(cornerRadius: 2).fill(palette.ansi[index].color).frame(width: 9, height: 9)
                                        }
                                    }
                                }
                                .font(Typography.mono(11))
                                .padding(10)
                                .frame(width: 128, height: 62, alignment: .topLeading)
                                .background(palette.background.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(selectedID == palette.id ? ChromeColor.accent : ChromeColor.hairline, lineWidth: selectedID == palette.id ? 2 : 1)
                                )
                                Text(palette.name)
                                    .font(Typography.body(12, weight: selectedID == palette.id ? .semibold : .regular))
                                    .foregroundStyle(selectedID == palette.id ? ChromeColor.textPrimary : ChromeColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(PressableStyle(pressedScale: 0.97))
                        .accessibilityLabel("\(palette.name) palette")
                        .accessibilityAddTraits(selectedID == palette.id ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct AcknowledgementsView: View {
    private let items: [(String, String, String)] = [
        ("ios_system", "Nicolas Holzschuch. BSD 3-Clause.", "Runs Unix commands inside an iOS app and provides the shell, text and files utilities."),
        ("SwiftTerm", "Miguel de Icaza. MIT.", "The terminal emulator that draws everything."),
        ("OpenSSH, libssh2, OpenSSL", "BSD and Apache 2.0 licenses.", "ssh, scp, sftp, ssh-keygen."),
        ("curl", "Daniel Stenberg and contributors. curl license.", "Downloads and HTTP."),
        ("libgit2", "GPL v2 with linking exception.", "lg2, the git client."),
        ("Vim", "Bram Moolenaar and contributors. Vim license.", "The editor, plus its runtime files."),
        ("dash", "BSD 3-Clause.", "POSIX sh for scripts."),
        ("Lua", "PUC-Rio. MIT.", "lua and luac."),
        ("jq", "Stephen Dolan. MIT.", "JSON processing."),
        ("GNU bc, GNU make, GNU awk compat", "GPL.", "bc, dc and make."),
        ("BSD utilities", "Apple and BSD contributors. BSD licenses.", "ls, cp, grep, sed, tar and friends."),
        ("Mozilla CA bundle", "MPL 2.0.", "Root certificates for TLS."),
        ("Terminal palettes", "Solarized (MIT), Dracula (MIT), Nord (MIT), Gruvbox (MIT), One Dark (MIT), Catppuccin (MIT).", "Optional color schemes."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tern stands on open source software. Full license texts are in THIRD_PARTY_LICENSES.md in the source repository.")
                    .font(Typography.body(15))
                    .foregroundStyle(ChromeColor.textSecondary)
                    .padding(.bottom, 4)
                Card {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.0).font(Typography.body(16, weight: .medium)).foregroundStyle(ChromeColor.textPrimary)
                            Text(item.1).font(Typography.body(13)).foregroundStyle(ChromeColor.textSecondary)
                            Text(item.2).font(Typography.body(13)).foregroundStyle(ChromeColor.textTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < items.count - 1 { CardDivider() }
                    }
                }
            }
            .screenPadding()
            .padding(.vertical, 16)
        }
        .background(ChromeColor.background)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
