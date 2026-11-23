import AppKit

/// Quick Look preview extensions may not launch other apps from their own sandbox.
/// This small helper service, embedded in the extension, opens the URL on its behalf.
@objc protocol LauncherProtocol {
    func open(_ url: URL, reply: @escaping (Bool) -> Void)
}

final class Launcher: NSObject, LauncherProtocol, NSXPCListenerDelegate {
    func open(_ url: URL, reply: @escaping (Bool) -> Void) {
        // Only our own scheme: the service must not become a general "open anything" hole.
        guard url.scheme == "nakami" else { reply(false); return }
        reply(NSWorkspace.shared.open(url))
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: LauncherProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }
}

let delegate = Launcher()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
