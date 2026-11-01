import SwiftUI

/// Five short pages shown once. Each page teaches one thing with a real component or an honest
/// rendering of the terminal, not an illustration.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .font(Typography.body(15, weight: .medium))
                    .foregroundStyle(ChromeColor.textSecondary)
                    .buttonStyle(PressableStyle())
                    .opacity(page == pageCount - 1 ? 0 : 1)
                    .accessibilityHidden(page == pageCount - 1)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 12)

            TabView(selection: $page) {
                OnboardingPage(
                    title: "A real terminal.",
                    text: "Tern runs Unix tools compiled for iPhone and iPad: ssh, git, vim, curl, grep and a hundred more. No emulator, no server, works offline."
                ) { TerminalPreview(palette: model.settings.palette(for: colorScheme)) }
                .tag(0)

                OnboardingPage(
                    title: "Keys you actually need.",
                    text: "A bar above the keyboard adds esc, tab, ctrl, alt and arrows. Ctrl latches: tap ctrl, then c. Tab completes and lists. Hold an arrow or delete to repeat."
                ) { KeyboardPreview(model: model.keyboardBar) }
                .tag(1)

                OnboardingPage(
                    title: "Your files, in Files.",
                    text: "Home is this app's Documents folder. It shows up in the Files app, so you can drop files in, edit them with vim, and sync repositories with git. Type mount to attach Downloads or any other folder."
                ) { FilesPreview() }
                .tag(2)

                OnboardingPage(
                    title: "Connect in two steps.",
                    text: "Generate a key, add it to your server, connect. Keys and hosts also have their own screens, reachable from the menu or by typing keys and hosts."
                ) { SSHPreview() }
                .tag(3)

                OnboardingPage(
                    title: "Make it yours.",
                    text: "Light, dark or system. Eleven terminal palettes, three fonts, your own prompt. Everything is in Settings, or type tern in the terminal."
                ) { AppearancePicker(settings: model.settings) }
                .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)

            VStack(spacing: 18) {
                PageDots(count: pageCount, index: page)
                Button(page == pageCount - 1 ? "Start" : "Continue") {
                    if page < pageCount - 1 {
                        page += 1
                    } else {
                        finish()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 20)
        }
        .background(ChromeColor.background.ignoresSafeArea())
        .preferredColorScheme(model.settings.appearance.colorScheme)
    }

    private func finish() {
        model.completeOnboarding()
    }
}

private struct OnboardingPage<Visual: View>: View {
    let title: String
    let text: String
    @ViewBuilder var visual: Visual

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    visual
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title)
                            .font(Typography.display(34))
                            .foregroundStyle(ChromeColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(text)
                            .font(Typography.body(17))
                            .foregroundStyle(ChromeColor.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? ChromeColor.textPrimary : ChromeColor.hairline)
                    .frame(width: i == index ? 20 : 6, height: 6)
                    .animation(.easeOut(duration: 0.2), value: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}

/// A static rendering of a short terminal exchange in the user's palette.
struct TerminalPreview: View {
    let palette: TerminalPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            promptLine("ls")
            Text("Documents    notes.md    scripts")
                .foregroundStyle(palette.foreground.color)
            promptLine("git clone https://github.com/vim/vim.git")
            Text("Cloning into 'vim'...")
                .foregroundStyle(palette.foreground.color)
            Text("Receiving objects: 100% (3421/3421), done.")
                .foregroundStyle(palette.foreground.color)
            promptLine("ssh deploy@blue.example.net")
            Text("Welcome to Ubuntu 24.04.3 LTS")
                .foregroundStyle(palette.foreground.color)
            HStack(spacing: 0) {
                Text("deploy@blue:~$ ").foregroundStyle(palette.ansi[2].color)
                Rectangle().fill(palette.cursor.color).frame(width: 8, height: 15)
            }
        }
        .font(Typography.mono(13))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background.color, in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous).strokeBorder(ChromeColor.hairline, lineWidth: 1))
        .accessibilityLabel("Preview of the terminal running ls, git clone and ssh")
    }

    private func promptLine(_ command: String) -> some View {
        HStack(spacing: 0) {
            Text("~ ").foregroundStyle(palette.foreground.color.opacity(0.55))
            Text("\u{276F} ").foregroundStyle(palette.cursor.color).fontWeight(.bold)
            Text(command).foregroundStyle(palette.foreground.color)
        }
    }
}

/// The real keyboard bar, shown inert so people recognise it later.
private struct KeyboardPreview: View {
    let model: KeyboardBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A still life of the bar's first keys; the live bar scrolls and would not fit the card.
            HStack(spacing: 5) {
                ForEach(["esc", "tab", "ctrl", "alt", "\u{2190}", "\u{2193}", "\u{2191}", "\u{2192}", "^C"], id: \.self) { key in
                    Text(key)
                        .font(key.count > 2 ? Typography.body(12, weight: .medium) : Typography.mono(13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(key == "^C" ? ChromeColor.accent : ChromeColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(ChromeColor.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(8)
            .background(ChromeColor.surfaceElevated, in: RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                tip(key: "ctrl", text: "then c stops a command, then r searches history")
                tip(key: "tab", text: "completes commands and paths and lists what matches")
                tip(key: "\u{2191}", text: "recalls history, or searches it for what you typed")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tip(key: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(Typography.mono(13, weight: .medium))
                .foregroundStyle(ChromeColor.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ChromeColor.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text)
                .font(Typography.body(15))
                .foregroundStyle(ChromeColor.textSecondary)
        }
    }
}

private struct FilesPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("folder.fill", "On My iPhone", indent: 0, dim: true)
            // The Files app hides dotfiles, so show the kind of things people actually see there.
            row("folder.fill", "Tern", indent: 1, dim: false)
            row("folder", "projects", indent: 2, dim: false)
            row("folder", "scripts", indent: 2, dim: false)
            row("doc.text", "notes.md", indent: 2, dim: false)
            row("doc.text", "deploy.sh", indent: 2, dim: false)
            row("doc.zipper", "backup.tar.gz", indent: 2, dim: false)
        }
        .padding(.vertical, 8)
        .background(ChromeColor.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous).strokeBorder(ChromeColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The Files app showing the Tern folder with projects, scripts, notes.md, deploy.sh and backup.tar.gz")
    }

    private func row(_ icon: String, _ name: String, indent: Int, dim: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(dim ? ChromeColor.textTertiary : ChromeColor.accent)
                .frame(width: 22)
            Text(name)
                .font(Typography.body(15))
                .foregroundStyle(dim ? ChromeColor.textTertiary : ChromeColor.textPrimary)
            Spacer()
        }
        .padding(.leading, 16 + CGFloat(indent) * 22)
        .padding(.trailing, 16)
        .frame(height: 38)
    }
}

private struct SSHPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("1", "ssh-keygen -t ed25519")
            step("2", "pbcopy < ~/.ssh/id_ed25519.pub")
            step("3", "ssh user@host")
        }
        .accessibilityElement(children: .combine)
    }

    private func step(_ number: String, _ command: String) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .font(Typography.body(13, weight: .semibold))
                .foregroundStyle(ChromeColor.onAccent)
                .frame(width: 24, height: 24)
                .background(ChromeColor.accent, in: Circle())
            CodeLine(text: command)
        }
    }
}

/// Live appearance choice; also used in Settings.
struct AppearancePicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Appearance.allCases) { appearance in
                Button {
                    settings.appearance = appearance
                } label: {
                    VStack(spacing: 10) {
                        swatch(for: appearance)
                        Text(appearance.title)
                            .font(Typography.body(14, weight: settings.appearance == appearance ? .semibold : .regular))
                            .foregroundStyle(settings.appearance == appearance ? ChromeColor.textPrimary : ChromeColor.textSecondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(settings.appearance == appearance ? ChromeColor.control : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                            .strokeBorder(settings.appearance == appearance ? ChromeColor.accent : ChromeColor.hairline, lineWidth: settings.appearance == appearance ? 2 : 1)
                    )
                }
                .buttonStyle(PressableStyle(pressedScale: 0.97))
                .accessibilityLabel("\(appearance.title) appearance")
                .accessibilityAddTraits(settings.appearance == appearance ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func swatch(for appearance: Appearance) -> some View {
        let dark = settings.palette(for: .dark)
        let light = settings.palette(for: .light)
        ZStack {
            switch appearance {
            case .system:
                HStack(spacing: 0) {
                    light.background.color
                    dark.background.color
                }
            case .light:
                light.background.color
            case .dark:
                dark.background.color
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("~ ").foregroundStyle((appearance == .light ? light : dark).foreground.color.opacity(0.6))
                    Text("\u{276F}").foregroundStyle((appearance == .light ? light : dark).cursor.color).fontWeight(.bold)
                }
                Text("ls -la").foregroundStyle((appearance == .light ? light : dark).foreground.color)
            }
            .font(Typography.mono(11))
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ChromeColor.hairline, lineWidth: 1))
    }
}
