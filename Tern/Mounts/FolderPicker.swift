import UIKit
import UniformTypeIdentifiers

/// Shows the system folder picker (the Files app, inside Tern) and hands back the folder the user chose.
/// Used by the `mount` command; the shell thread waits while the picker is up.
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    private static var active: FolderPicker?
    private let completion: (URL?) -> Void

    private init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    /// Presents the picker over whatever is on screen. `completion` gets nil when the user cancels or
    /// when there is nothing to present from (no window yet); it is always called exactly once.
    static func present(completion: @escaping (URL?) -> Void) {
        guard active == nil else {
            completion(nil)
            return
        }
        present(attempt: 0, completion: completion)
    }

    private static func present(attempt: Int, completion: @escaping (URL?) -> Void) {
        guard let presenter = topViewController() else {
            // Right after launch the window may not be up yet; try again briefly before giving up.
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    present(attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(nil)
            }
            return
        }
        let picker = FolderPicker(completion: completion)
        active = picker
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        controller.delegate = picker
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = true
        presenter.present(controller, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    private func finish(_ url: URL?) {
        FolderPicker.active = nil
        completion(url)
    }

    /// The view controller to present from: the deepest presented controller of the key window.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.keyWindow,
              let root = window.rootViewController else { return nil }
        var presenter = root
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }
}
