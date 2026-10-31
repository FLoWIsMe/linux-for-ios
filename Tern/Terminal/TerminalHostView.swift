import SwiftUI
import UIKit
import SwiftTerm

/// Hosts a session's `TerminalView` inside SwiftUI. The view is owned by the session controller, so
/// this representable only attaches and detaches it; nothing is recreated when tabs switch.
struct TerminalHostView: UIViewRepresentable {
    let controller: TerminalSessionController
    let keyboardBar: KeyboardBarModel
    let showKeyboardBar: Bool
    let compact: Bool
    let becomeFirstResponder: Bool

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.attach(controller.terminalView)
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.attach(controller.terminalView)
        let terminalView = controller.terminalView
        keyboardBar.terminalView = terminalView
        keyboardBar.send = { [weak controller] bytes in controller?.send(bytes) }
        keyboardBar.hideKeyboard = { [weak terminalView] in _ = terminalView?.resignFirstResponder() }

        if showKeyboardBar {
            if !(terminalView.inputAccessoryView is KeyboardBarInputView) {
                terminalView.inputAccessoryView = KeyboardBarInputView(model: keyboardBar, compact: compact)
                if terminalView.isFirstResponder { terminalView.reloadInputViews() }
            }
        } else if terminalView.inputAccessoryView != nil {
            terminalView.inputAccessoryView = nil
            if terminalView.isFirstResponder { terminalView.reloadInputViews() }
        }

        // The view is not in a window during the first update; the container asks again once it is.
        container.wantsFocus = becomeFirstResponder
        if becomeFirstResponder && !terminalView.isFirstResponder && terminalView.window != nil {
            DispatchQueue.main.async {
                _ = terminalView.becomeFirstResponder()
            }
        }
        container.onLayout = { [weak controller] in
            controller?.applyPaletteIfNeeded()
        }
    }

    static func dismantleUIView(_ container: TerminalContainerView, coordinator: ()) {
        container.detach()
    }
}

/// Plain container so a `TerminalView` can be moved between hosts without being torn down.
final class TerminalContainerView: UIView {
    private weak var terminalView: TerminalView?
    /// Called after the first layout with a real size and whenever the view moves to a window.
    var onLayout: (() -> Void)?
    /// Whether the terminal should take keyboard focus as soon as it is on screen.
    var wantsFocus = false
    private var lastLayoutSize: CGSize = .zero

    private func focusIfWanted() {
        guard wantsFocus, let view = terminalView, view.window != nil, !view.isFirstResponder else { return }
        _ = view.becomeFirstResponder()
    }

    func attach(_ view: TerminalView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        terminalView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func detach() {
        terminalView?.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        terminalView?.frame = bounds
        if bounds.size != lastLayoutSize, bounds.width > 0, window != nil {
            lastLayoutSize = bounds.size
            DispatchQueue.main.async { [weak self] in
                self?.onLayout?()
                self?.focusIfWanted()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.onLayout?()
                self?.focusIfWanted()
            }
        }
    }
}
