import AppKit

// MARK: - USB Menu

extension VPhoneMenuController {
    func buildUSBMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "USB", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "USB")
        let delegate = VPhoneUSBMenuDelegate(owner: self)
        menu.delegate = delegate
        usbMenuDelegate = delegate
        usbMenu = menu

        // Empty by default; menuNeedsUpdate populates on open.
        let placeholder = NSMenuItem(title: "(No host USB enumerated yet)", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)

        item.submenu = menu
        return item
    }

    /// Rebuild the USB submenu in place from the current host enumeration
    /// and currently-attached set.
    func refreshUSBMenu() {
        guard let menu = usbMenu else { return }
        menu.removeAllItems()

        guard let passthrough = usbPassthrough else {
            let warn = NSMenuItem(
                title: "(VM not running — passthrough unavailable)",
                action: nil,
                keyEquivalent: ""
            )
            warn.isEnabled = false
            menu.addItem(warn)
            return
        }

        let devices = passthrough.enumerate()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "(No host USB devices found)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let header = NSMenuItem(
            title: "Toggle to attach/detach (checked = attached to guest)",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for dev in devices {
            let row = NSMenuItem(
                title: dev.displayName,
                action: #selector(toggleUSBDevice(_:)),
                keyEquivalent: ""
            )
            row.target = self
            row.tag = Int(bitPattern: UInt(dev.locationID))
            row.state = passthrough.isAttached(locationID: dev.locationID) ? .on : .off
            menu.addItem(row)
        }
    }

    @objc func toggleUSBDevice(_ sender: NSMenuItem) {
        guard let passthrough = usbPassthrough else { return }
        let locationID = UInt32(truncatingIfNeeded: UInt(bitPattern: sender.tag))
        let attaching = (sender.state == .off)

        sender.isEnabled = false
        if attaching {
            passthrough.attach(locationID: locationID) { [weak self] err in
                sender.isEnabled = true
                if let err {
                    print("[usb] attach 0x\(String(locationID, radix: 16)) failed: \(err.localizedDescription)")
                } else {
                    print("[usb] attached 0x\(String(locationID, radix: 16))")
                    sender.state = .on
                }
                self?.refreshUSBMenu()
            }
        } else {
            passthrough.detach(locationID: locationID) { [weak self] err in
                sender.isEnabled = true
                if let err {
                    print("[usb] detach 0x\(String(locationID, radix: 16)) failed: \(err.localizedDescription)")
                } else {
                    print("[usb] detached 0x\(String(locationID, radix: 16))")
                    sender.state = .off
                }
                self?.refreshUSBMenu()
            }
        }
    }
}

// MARK: - NSMenuDelegate bridge

@MainActor
final class VPhoneUSBMenuDelegate: NSObject, NSMenuDelegate {
    private weak var owner: VPhoneMenuController?

    init(owner: VPhoneMenuController) {
        self.owner = owner
    }

    nonisolated func menuNeedsUpdate(_: NSMenu) {
        MainActor.assumeIsolated {
            owner?.refreshUSBMenu()
        }
    }
}
