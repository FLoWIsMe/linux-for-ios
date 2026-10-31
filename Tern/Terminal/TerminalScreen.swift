import SwiftUI
import TernCore

/// The main screen: tab strip on top, the selected session's terminal below, keyboard bar attached
/// to the software keyboard.
struct TerminalScreen: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let palette = model.settings.palette(for: colorScheme)
        ZStack {
            palette.background.color.ignoresSafeArea()
            VStack(spacing: 0) {
                TabStrip(model: model)
                Rectangle().fill(ChromeColor.hairline).frame(height: Metrics.hairline)
                if let controller = model.selected {
                    TerminalHostView(
                        controller: controller,
                        keyboardBar: model.keyboardBar,
                        showKeyboardBar: model.settings.keyboardBarEnabled,
                        compact: sizeClass == .compact,
                        // Keep the keyboard down while onboarding or a sheet covers the terminal.
                        becomeFirstResponder: !model.showsOnboarding && model.presentedSheet == nil
                    )
                    .id(controller.id)
                    .background(palette.background.color)
                } else {
                    Color.clear
                }
            }
            if model.bellFlash {
                palette.foreground.color.opacity(0.18).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .background(keyboardShortcuts)
        .onAppear {
            model.update(colorScheme: colorScheme)
            model.ensureSession()
        }
        .onChange(of: colorScheme) { _, scheme in model.update(colorScheme: scheme) }
        .onOpenURL { url in URLCommands.handle(url, model: model) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enteredBackground()
            case .active: model.enteredForeground()
            default: break
            }
        }
        .sheet(item: $model.presentedSheet) { sheet in
            switch sheet {
            case .settings: SettingsView(model: model)
            case .hosts: HostsView(model: model)
            case .keys: KeysView(model: model)
            case .help: HelpView()
            }
        }
        .fullScreenCover(isPresented: $model.showsOnboarding) {
            OnboardingView(model: model)
        }
        .preferredColorScheme(model.settings.appearance.colorScheme)
    }

    /// Invisible buttons that give hardware keyboards the usual tab and view shortcuts.
    private var keyboardShortcuts: some View {
        Group {
            Button("New Tab") { model.newSession() }.keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { if let selected = model.selected { model.close(selected) } }.keyboardShortcut("w", modifiers: .command)
            Button("Clear") { model.selected?.clearScreen() }.keyboardShortcut("k", modifiers: .command)
            Button("Next Tab") { model.selectNextTab(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.selectNextTab(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Bigger") { changeFontSize(by: 1) }.keyboardShortcut("=", modifiers: .command)
            Button("Smaller") { changeFontSize(by: -1) }.keyboardShortcut("-", modifiers: .command)
            Button("Settings") { model.presentedSheet = .settings }.keyboardShortcut(",", modifiers: .command)
            ForEach(1..<10) { index in
                Button("Tab \(index)") { model.selectTab(at: index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func changeFontSize(by delta: Double) {
        let range = SettingsStore.fontSizeRange
        model.settings.fontSize = min(max(model.settings.fontSize + delta, range.lowerBound), range.upperBound)
        model.refreshAppearance()
    }
}

/// Tabs plus the new tab and menu buttons.
struct TabStrip: View {
    @Bindable var model: AppModel
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.sessions) { session in
                            TabChip(
                                controller: session,
                                isSelected: session.id == model.selected?.id,
                                canClose: true,
                                select: { model.select(session) },
                                close: { model.close(session) }
                            )
                            .id(session.id)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: model.sessions.count) { _, _ in
                    if let id = model.selectedID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }

            Button {
                model.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(ChromeColor.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("New tab")

            Menu {
                Button { model.presentedSheet = .hosts } label: { Label("Hosts", systemImage: "network") }
                    .accessibilityIdentifier("menu.hosts")
                Button { model.presentedSheet = .keys } label: { Label("SSH Keys", systemImage: "key") }
                    .accessibilityIdentifier("menu.keys")
                Button { model.presentedSheet = .help } label: { Label("Help", systemImage: "questionmark.circle") }
                    .accessibilityIdentifier("menu.help")
                Divider()
                Button { model.presentedSheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("menu.settings")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(ChromeColor.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("More")
            .padding(.trailing, 12)
        }
        .frame(height: 46)
        .background(ChromeColor.background)
    }
}

/// One tab. Shows the directory or the running command, a dot while a command runs, and a close
/// button on the selected tab.
struct TabChip: View {
    let controller: TerminalSessionController
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if controller.isRunningCommand {
                Circle()
                    .fill(ChromeColor.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Running")
            }
            Text(controller.title)
                .font(Typography.body(13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? ChromeColor.textPrimary : ChromeColor.textSecondary)
            if isSelected && canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ChromeColor.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, isSelected && canClose ? 6 : 12)
        .frame(height: 34)
        .background(isSelected ? ChromeColor.control : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button(role: .destructive, action: close) { Label("Close Tab", systemImage: "xmark") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(controller.title) tab")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Renders the `help` text in a sheet for people who prefer reading it outside the terminal.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    private let topics: [(String, String?)] = [("Overview", nil), ("Keyboard", "keys"), ("SSH", "ssh"), ("Git", "git"), ("Files", "files"), ("Shell", "shell"), ("Commands", "commands")]
    @State private var topic: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(topics, id: \.0) { item in
                                Button(item.0) { topic = item.1 }
                                    .font(Typography.body(14, weight: .medium))
                                    .foregroundStyle(topic == item.1 ? ChromeColor.onAccent : ChromeColor.textPrimary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background(topic == item.1 ? ChromeColor.accent : ChromeColor.control, in: Capsule())
                                    .buttonStyle(PressableStyle())
                            }
                        }
                        .screenPadding()
                    }
                    Text(HelpText.text(for: topic).strippingANSI)
                        .font(Typography.mono(13))
                        .foregroundStyle(ChromeColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .screenPadding()
                }
                .padding(.vertical, 12)
            }
            .background(ChromeColor.background)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension String {
    /// Removes SGR escape sequences so terminal text can be shown in a SwiftUI Text.
    var strippingANSI: String {
        var result = ""
        var iterator = makeIterator()
        while let character = iterator.next() {
            if character == "\u{1b}" {
                // Skip ESC [ ... final byte
                while let next = iterator.next() {
                    if next.isLetter { break }
                }
                continue
            }
            result.append(character)
        }
        return result
    }
}
