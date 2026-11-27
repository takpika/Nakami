#if os(iOS)
import SwiftUI
import UIKit

// The iOS launch screen's look: the hex field (HexLens.swift) behind the system's title and Files card,
// and its magnifier, driven by presses on the window.

@available(iOS 18.0, *)
enum LaunchLook {
    /// Returns the object driving the magnifier; keep it as long as the screen.
    @MainActor static func apply(to options: UIDocumentViewController.LaunchOptions, in controller: UIViewController) -> AnyObject {
        var bg = UIBackgroundConfiguration.clear()
        bg.backgroundColor = HexPalette.baseColor
        options.background = bg

        // The words are spread over the top of the screen, where the field shows above the Files card.
        let lens = HexLens(band: 400)
        options.backgroundAccessoryView = host(HexField(lens: lens))
        options.foregroundAccessoryView = host(HexMagnifier(lens: lens))
        return LaunchPress(lens: lens, overlay: options.foregroundAccessoryView!)
    }

    @MainActor private static func host<V: View>(_ v: V) -> UIView {
        let host = UIHostingController(rootView: v)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return host.view
    }
}

/// Feeds presses to the magnifier. The system's title area sits over the field and keeps touches from the views
/// inside the launch screen, so the press is watched on the window. It takes nothing away from the system, and
/// the Files card never reaches it (the system shows the card separately).
@MainActor private final class LaunchPress: NSObject, UIGestureRecognizerDelegate {
    private let lens: HexLens
    private weak var overlay: UIView?
    private let press = UILongPressGestureRecognizer()

    init(lens: HexLens, overlay: UIView) {
        self.lens = lens
        self.overlay = overlay
        super.init()
        press.addTarget(self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.25
        press.cancelsTouchesInView = false
        press.delegate = self
        attach(tries: 40)
    }

    /// The overlay gets its window a moment after the screen is built.
    private func attach(tries: Int) {
        if let window = overlay?.window { window.addGestureRecognizer(press); return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.attach(tries: tries - 1) }
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard let overlay else { return }
        switch g.state {
        case .began, .changed: lens.move(to: g.location(in: overlay))
        default: lens.end()
        }
    }

    /// Buttons keep their touches.
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            var v = touch.view
            while let cur = v { if cur is UIControl { return false }; v = cur.superview }
            return true
        }
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
