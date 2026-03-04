import AppKit

// MARK: - Battery Menu

extension VPhoneMenuController {
    func buildBatteryMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Battery")

        // Charge level presets
        for level in [100, 75, 50, 25, 10, 5] {
            let mi = makeItem("\(level)%", action: #selector(setBatteryLevel(_:)))
            mi.tag = level
            mi.state = level == 100 ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(NSMenuItem.separator())

        // Connectivity: 1=charging, 2=disconnected
        let charging = makeItem("Charging", action: #selector(setBatteryConnectivity(_:)))
        charging.tag = 1
        charging.state = .on
        let disconnected = makeItem("Disconnected", action: #selector(setBatteryConnectivity(_:)))
        disconnected.tag = 2

        menu.addItem(charging)
        menu.addItem(disconnected)

        item.submenu = menu
        return item
    }

    @objc func setBatteryLevel(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        for mi in menu.items {
            if mi.isSeparatorItem { break }
            mi.state = mi === sender ? .on : .off
        }
        let charge = Double(sender.tag)
        let connectivity = currentBatteryConnectivity(in: menu)
        vm?.setBattery(charge: charge, connectivity: connectivity)
        print("[battery] set \(sender.tag)%, connectivity=\(connectivity)")
    }

    @objc func setBatteryConnectivity(_ sender: NSMenuItem) {
        guard let menu = sender.menu else { return }
        var pastSeparator = false
        for mi in menu.items {
            if mi.isSeparatorItem { pastSeparator = true; continue }
            if pastSeparator { mi.state = mi === sender ? .on : .off }
        }
        let charge = currentBatteryCharge(in: menu)
        vm?.setBattery(charge: charge, connectivity: sender.tag)
        print("[battery] set \(Int(charge))%, connectivity=\(sender.tag)")
    }

    private func currentBatteryCharge(in menu: NSMenu) -> Double {
        for mi in menu.items {
            if mi.isSeparatorItem { break }
            if mi.state == .on { return Double(mi.tag) }
        }
        return 100.0
    }

    private func currentBatteryConnectivity(in menu: NSMenu) -> Int {
        var pastSeparator = false
        for mi in menu.items {
            if mi.isSeparatorItem { pastSeparator = true; continue }
            if pastSeparator && mi.state == .on { return mi.tag }
        }
        return 1
    }
}
