import SwiftUI
import UIKit
import Observation
import SwiftTerm

/// State shared between the keyboard bar and the terminal: which modifier keys are latched.
@Observable
@MainActor
final class KeyboardBarModel {
    var controlLatched = false
    var altLatched = false
    weak var terminalView: TerminalView?
    var send: (([UInt8]) -> Void)?
    var hideKeyboard: (() -> Void)?
    var hapticsEnabled = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .light)

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.controlLatched = false }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .terminalViewMetaModifierReset, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.altLatched = false }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func tap() {
        guard hapticsEnabled else { return }
        impact.impactOccurred(intensity: 0.6)
    }

    func toggleControl() {
        controlLatched.toggle()
        terminalView?.controlModifier = controlLatched
        if controlLatched { altLatched = false; terminalView?.metaModifier = false }
    }

    func toggleAlt() {
        altLatched.toggle()
        terminalView?.metaModifier = altLatched
        if altLatched { controlLatched = false; terminalView?.controlModifier = false }
    }

    /// Sends bytes, applying latched modifiers to arrow keys and plain characters.
    func press(_ key: KeyboardBarKey) {
        tap()
        switch key.action {
        case .bytes(let bytes):
            send?(bytes)
        case .text(let text):
            if controlLatched, let scalar = text.unicodeScalars.first, text.count == 1 {
                let value = scalar.value
                if value >= 0x40 && value <= 0x7f {
                    send?([UInt8(value & 0x1f)])
                    clearModifiers()
                    return
                }
            }
            if altLatched {
                send?([0x1b] + Array(text.utf8))
                clearModifiers()
                return
            }
            send?(Array(text.utf8))
        case .arrow(let arrow):
            send?(arrow.sequence(control: controlLatched, alt: altLatched))
            if controlLatched || altLatched { clearModifiers() }
        case .escape:
            send?([0x1b])
        case .tab:
            send?([0x09])
        case .control:
            toggleControl()
        case .alt:
            toggleAlt()
        case .interrupt:
            send?([0x03])
        case .hideKeyboard:
            hideKeyboard?()
        }
    }

    private func clearModifiers() {
        controlLatched = false
        altLatched = false
        terminalView?.controlModifier = false
        terminalView?.metaModifier = false
    }
}

enum ArrowKey {
    case up, down, left, right

    func sequence(control: Bool, alt: Bool) -> [UInt8] {
        let letter: UInt8
        switch self {
        case .up: letter = 0x41
        case .down: letter = 0x42
        case .right: letter = 0x43
        case .left: letter = 0x44
        }
        if control { return [0x1b, 0x5b, 0x31, 0x3b, 0x35, letter] }
        if alt { return [0x1b, 0x5b, 0x31, 0x3b, 0x33, letter] }
        return [0x1b, 0x5b, letter]
    }

    var symbol: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    var label: String {
        switch self {
        case .up: return "Up arrow"
        case .down: return "Down arrow"
        case .left: return "Left arrow"
        case .right: return "Right arrow"
        }
    }
}

struct KeyboardBarKey: Identifiable {
    enum Action {
        case bytes([UInt8])
        case text(String)
        case arrow(ArrowKey)
        case escape, tab, control, alt, interrupt, hideKeyboard
    }

    let id: String
    let title: String
    let systemImage: String?
    let action: Action
    var isModifier: Bool = false
    var repeats: Bool = false
    var monospaced: Bool = true
    var accessibilityLabel: String

    static let escape = KeyboardBarKey(id: "esc", title: "esc", systemImage: nil, action: .escape, monospaced: false, accessibilityLabel: "Escape")
    static let tab = KeyboardBarKey(id: "tab", title: "tab", systemImage: nil, action: .tab, monospaced: false, accessibilityLabel: "Tab")
    static let control = KeyboardBarKey(id: "ctrl", title: "ctrl", systemImage: nil, action: .control, isModifier: true, monospaced: false, accessibilityLabel: "Control")
    static let alt = KeyboardBarKey(id: "alt", title: "alt", systemImage: nil, action: .alt, isModifier: true, monospaced: false, accessibilityLabel: "Alt")
    static let interrupt = KeyboardBarKey(id: "intr", title: "^C", systemImage: nil, action: .interrupt, accessibilityLabel: "Interrupt, Control C")
    static let hide = KeyboardBarKey(id: "hide", title: "", systemImage: "keyboard.chevron.compact.down", action: .hideKeyboard, accessibilityLabel: "Hide keyboard")

    static func arrow(_ arrow: ArrowKey) -> KeyboardBarKey {
        KeyboardBarKey(id: "arrow-\(arrow.symbol)", title: "", systemImage: arrow.symbol, action: .arrow(arrow), repeats: true, accessibilityLabel: arrow.label)
    }

    static func symbol(_ text: String, label: String? = nil) -> KeyboardBarKey {
        KeyboardBarKey(id: "sym-\(text)", title: text, systemImage: nil, action: .text(text), accessibilityLabel: label ?? text)
    }

    static let symbols: [KeyboardBarKey] = [
        .symbol("-", label: "Dash"), .symbol("|", label: "Pipe"), .symbol("/", label: "Slash"), .symbol("~", label: "Tilde"),
        .symbol(":", label: "Colon"), .symbol("'", label: "Single quote"), .symbol("\"", label: "Double quote"),
        .symbol("$", label: "Dollar"), .symbol("`", label: "Backtick"), .symbol("\\", label: "Backslash"),
        .symbol("*", label: "Asterisk"), .symbol(">", label: "Greater than"), .symbol("<", label: "Less than"),
        .symbol("&", label: "Ampersand"), .symbol("{", label: "Open brace"), .symbol("}", label: "Close brace"),
    ]
}

/// The bar above the software keyboard: modifiers, arrows and the symbols a shell needs most.
struct KeyboardBarView: View {
    @Bindable var model: KeyboardBarModel
    var compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                keyButton(.escape)
                keyButton(.tab)
                keyButton(.control)
                keyButton(.alt)
            }
            HStack(spacing: 4) {
                keyButton(.arrow(.left))
                keyButton(.arrow(.down))
                keyButton(.arrow(.up))
                keyButton(.arrow(.right))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(KeyboardBarKey.symbols) { key in
                        keyButton(key)
                    }
                    keyButton(.interrupt)
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
            keyButton(.hide)
        }
        .padding(.horizontal, 6)
        .frame(height: Metrics.keyboardBarHeight)
        .background(Color.clear)
    }

    @ViewBuilder
    private func keyButton(_ key: KeyboardBarKey) -> some View {
        let latched = (key.id == "ctrl" && model.controlLatched) || (key.id == "alt" && model.altLatched)
        BarKey(key: key, latched: latched, compact: compact) {
            model.press(key)
        }
    }
}

/// One key cap. Supports press and hold repeat for arrows.
private struct BarKey: View {
    let key: KeyboardBarKey
    let latched: Bool
    let compact: Bool
    let action: () -> Void

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .frame(minWidth: minWidth, maxWidth: key.id.hasPrefix("sym") ? nil : .infinity)
            .frame(height: 34)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(latched ? Color.clear : ChromeColor.hairline.opacity(0.6), lineWidth: 0.5)
            )
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
            .contentShape(Rectangle())
            .gesture(pressGesture)
            .accessibilityLabel(key.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(latched ? .isSelected : [])
    }

    private var minWidth: CGFloat {
        if key.systemImage != nil { return compact ? 34 : 40 }
        if key.isModifier || key.id == "esc" || key.id == "tab" { return compact ? 40 : 52 }
        return 34
    }

    @ViewBuilder
    private var content: some View {
        if let systemImage = key.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ChromeColor.textPrimary)
        } else {
            Text(key.title)
                .font(key.monospaced ? Typography.mono(15, weight: .medium) : Typography.body(13, weight: .semibold))
                .foregroundStyle(latched ? ChromeColor.onAccent : (key.id == "intr" ? ChromeColor.danger : ChromeColor.textPrimary))
                .padding(.horizontal, 8)
        }
    }

    private var background: Color {
        if latched { return ChromeColor.accent }
        return pressed ? ChromeColor.controlPressed : ChromeColor.control
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                action()
                if key.repeats {
                    repeatTask?.cancel()
                    repeatTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(380))
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(for: .milliseconds(55))
                        }
                    }
                }
            }
            .onEnded { _ in
                pressed = false
                repeatTask?.cancel()
                repeatTask = nil
            }
    }
}

/// UIKit container that puts the SwiftUI bar into `TerminalView.inputAccessoryView`.
final class KeyboardBarInputView: UIInputView {
    private let hosting: UIHostingController<KeyboardBarView>

    init(model: KeyboardBarModel, compact: Bool) {
        hosting = UIHostingController(rootView: KeyboardBarView(model: model, compact: compact))
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Metrics.keyboardBarHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.keyboardBarHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.keyboardBarHeight)
    }
}
