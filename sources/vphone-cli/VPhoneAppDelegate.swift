import AppKit
import Foundation
import Virtualization

class VPhoneAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneBootCLI
    private var vm: VPhoneVirtualMachine?
    private var control: VPhoneControl?
    private var windowController: VPhoneWindowController?
    private var menuController: VPhoneMenuController?
    private var fileWindowController: VPhoneFileWindowController?
    private var keychainWindowController: VPhoneKeychainWindowController?
    private var appWindowController: VPhoneAppWindowController?
    private var locationProvider: VPhoneLocationProvider?
    private var hostControl: VPhoneHostControl?
    private var cameraServer: VPhoneCameraServer?
    private var sigintSource: DispatchSourceSignal?
    private var didAttemptAutoInstall = false

    init(cli: VPhoneBootCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(cli.noGraphics ? .prohibited : .regular)

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            print("\n[vphone] SIGINT — shutting down")
            NSApp.terminate(nil)
        }
        src.activate()
        sigintSource = src

        Task { @MainActor in
            do {
                try await self.startVirtualMachine()
            } catch {
                print("[vphone] Fatal: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    // MARK: - Fetch mode (headless: pull guest files over vphoned, then exit)

    @MainActor
    private func startFetchMode(control: VPhoneControl) {
        let paths = cli.fetch
        let outDir = URL(fileURLWithPath: cli.fetchOut)
        print("[fetch] awaiting vphoned to pull \(paths.count) path(s) -> \(outDir.path)")

        let timeout = DispatchWorkItem {
            print("[fetch] ERROR: vphoned did not connect within 180s; giving up")
            exit(2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)

        control.onConnect = { caps in
            timeout.cancel()
            Task { @MainActor in
                print("[fetch] vphoned connected (caps: \(caps))")
                guard caps.contains("file") else {
                    print("[fetch] ERROR: guest vphoned lacks the 'file' capability")
                    exit(3)
                }
                try? FileManager.default.createDirectory(
                    at: outDir, withIntermediateDirectories: true
                )
                for p in paths {
                    await Self.fetchGuestPath(control: control, guestPath: p, into: outDir)
                }
                print("[fetch] done -> \(outDir.path)")
                exit(0)
            }
        }
    }

    /// Fetch a guest path (file or directory, recursive) into `hostBase`, preserving its basename.
    @MainActor
    private static func fetchGuestPath(
        control: VPhoneControl, guestPath: String, into hostBase: URL
    ) async {
        let ns = guestPath as NSString
        let parent = ns.deletingLastPathComponent.isEmpty ? "/" : ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        // Determine type by listing the parent directory.
        if let entries = try? await control.listFiles(path: parent),
           let rf = entries.compactMap({ VPhoneRemoteFile(dir: parent, entry: $0) })
               .first(where: { $0.name == name })
        {
            await fetchRemoteFile(control: control, file: rf, into: hostBase)
        } else {
            // Parent not listable (e.g. permission) — try a direct file download.
            await downloadOne(control: control, guestPath: guestPath, name: name, into: hostBase)
        }
    }

    @MainActor
    private static func fetchRemoteFile(
        control: VPhoneControl, file: VPhoneRemoteFile, into hostBase: URL
    ) async {
        if file.isDirectoryLike {
            let localDir = hostBase.appendingPathComponent(file.name)
            try? FileManager.default.createDirectory(
                at: localDir, withIntermediateDirectories: true
            )
            guard let entries = try? await control.listFiles(path: file.path) else {
                print("[fetch] WARN: could not list \(file.path)")
                return
            }
            for e in entries {
                if let child = VPhoneRemoteFile(dir: file.path, entry: e) {
                    await fetchRemoteFile(control: control, file: child, into: localDir)
                }
            }
        } else {
            await downloadOne(control: control, guestPath: file.path, name: file.name, into: hostBase)
        }
    }

    @MainActor
    private static func downloadOne(
        control: VPhoneControl, guestPath: String, name: String, into hostBase: URL
    ) async {
        do {
            let data = try await control.downloadFile(path: guestPath)
            let dest = hostBase.appendingPathComponent(name)
            try data.write(to: dest)
            print("[fetch] \(guestPath) -> \(dest.path) (\(data.count) bytes)")
        } catch {
            print("[fetch] FAILED \(guestPath): \(error)")
        }
    }

    @MainActor
    private func startVirtualMachine() async throws {
        let options = try cli.resolveOptions()

        guard options.romURL == nil || FileManager.default.fileExists(atPath: options.romURL!.path) else {
            throw VPhoneError.romNotFound(options.romURL!.path)
        }

        print("=== vphone-cli ===")
        print("Variant : \(options.variant)")
        print("ROM     : \(options.romURL?.path ?? "None")")
        print("Disk    : \(options.diskURL.path)")
        print("NVRAM   : \(options.nvramURL.path)")
        print("Config  : \(options.configURL.path)")
        print("CPU     : \(options.cpuCount)")
        print("Memory  : \(options.memorySize / 1024 / 1024) MB")
        print(
            "Screen: \(options.screenWidth)x\(options.screenHeight) @ \(options.screenPPI) PPI (scale \(options.screenScale)x)"
        )
        if let kernelDebugPort = options.kernelDebugPort {
            print("Kernel debug stub : 127.0.0.1:\(kernelDebugPort)")
        } else {
            print("Kernel debug stub : auto-assigned")
        }
        print("SEP               : enabled")
        print("  storage         : \(options.sepStorageURL.path)")
        print("  rom             : \(options.sepRomURL?.path ?? "None")")
        print("")

        let vm = try VPhoneVirtualMachine(options: options)
        self.vm = vm

        try await vm.start(forceDFU: cli.dfu)

        let control = VPhoneControl(variant: options.variant)
        self.control = control
        if !cli.dfu {
            // Fetch mode keeps vphoned as-installed: skip the auto-update, whose
            // push+restart otherwise drops the connection right when we need it.
            if cli.fetch.isEmpty {
                let vphonedURL = URL(fileURLWithPath: cli.vphonedBin)
                if FileManager.default.fileExists(atPath: vphonedURL.path) {
                    control.guestBinaryURL = vphonedURL
                }
            }

            let provider = VPhoneLocationProvider(control: control)
            locationProvider = provider

            let camServer = VPhoneCameraServer()
            cameraServer = camServer

            if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                control.connect(device: device)
                if cli.fetch.isEmpty { camServer.connect(device: device) }
            }

            // Fetch mode: pull the requested guest paths once vphoned connects, then exit.
            if !cli.fetch.isEmpty {
                startFetchMode(control: control)
                return
            }
        }

        if !cli.noGraphics {
            let keyHelper = VPhoneKeyHelper(vm: vm, control: control)
            let wc = VPhoneWindowController()
            wc.showWindow(
                for: vm.virtualMachine,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight,
                screenScale: options.screenScale,
                keyHelper: keyHelper,
                control: control,
                ecid: vm.ecidHex
            )
            windowController = wc

            let fileWC = VPhoneFileWindowController()
            fileWindowController = fileWC

            let keychainWC = VPhoneKeychainWindowController()
            keychainWindowController = keychainWC

            let appWC = VPhoneAppWindowController()
            appWindowController = appWC

            let mc = VPhoneMenuController(keyHelper: keyHelper, control: control)
            mc.vm = vm
            mc.captureView = wc.captureView
            mc.touchIDMonitor = wc.touchIDMonitor
            mc.onFilesPressed = { [weak fileWC, weak control] in
                guard let fileWC, let control else { return }
                fileWC.showWindow(control: control)
            }
            mc.onKeychainPressed = { [weak keychainWC, weak control] in
                guard let keychainWC, let control else { return }
                keychainWC.showWindow(control: control)
            }
            mc.onAppsPressed = { [weak appWC, weak control] in
                guard let appWC, let control else { return }
                appWC.showWindow(control: control)
            }
            if let provider = locationProvider {
                mc.locationProvider = provider
            }
            if let camServer = cameraServer {
                mc.cameraServer = camServer
                camServer.onConnectionStateChange = { [weak mc] connected in
                    Task { @MainActor in
                        mc?.updateCameraConnectionState(connected: connected)
                    }
                }
            }
            let recorder = VPhoneScreenRecorder()
            mc.screenRecorder = recorder
            menuController = mc

            let socketPath = options.configURL
                .deletingLastPathComponent()
                .appendingPathComponent("vphone.sock").path
            let hc = VPhoneHostControl(socketPath: socketPath)
            hc.start(
                captureView: wc.captureView!,
                screenRecorder: recorder,
                control: control,
                screenWidth: options.screenWidth,
                screenHeight: options.screenHeight
            )
            hostControl = hc

            // Wire location toggle through onConnect/onDisconnect
            control.onConnect = { [weak mc, weak provider = locationProvider] caps in
                mc?.updateConnectAvailability(available: true)
                mc?.updateInstallAvailability(available: caps.contains("ipa_install"))
                mc?.updateAppsAvailability(available: caps.contains("apps"))
                mc?.updateURLAvailability(available: caps.contains("url"))
                mc?.updateClipboardAvailability(available: caps.contains("clipboard"))
                mc?.updateSettingsAvailability(available: true)
                if caps.contains("location") {
                    mc?.updateLocationCapability(available: true)
                    // Auto-resume if user had toggle on
                    if mc?.locationMenuItem?.state == .on {
                        provider?.startForwarding()
                    }
                } else {
                    print("[location] guest does not support location simulation")
                }
                mc?.syncBatteryFromHost()
                mc?.syncLowPowerModeFromHost()
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak mc, weak provider = locationProvider] in
                mc?.updateConnectAvailability(available: false)
                mc?.updateInstallAvailability(available: false)
                mc?.updateAppsAvailability(available: false)
                mc?.updateURLAvailability(available: false)
                mc?.updateClipboardAvailability(available: false)
                mc?.updateSettingsAvailability(available: false)
                provider?.stopReplay()
                provider?.stopForwarding()
                mc?.updateLocationCapability(available: false)
            }
        } else if !cli.dfu {
            // Headless mode: auto-start location as before (no menu exists)
            control.onConnect = { [weak provider = locationProvider] caps in
                if caps.contains("location") {
                    provider?.startForwarding()
                } else {
                    print("[location] guest does not support location simulation")
                }
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                }
            }
            control.onDisconnect = { [weak provider = locationProvider] in
                provider?.stopReplay()
                provider?.stopForwarding()
            }
        }
    }

    @MainActor
    private func installPackageIfRequested(caps: [String]) async {
        guard !didAttemptAutoInstall else { return }
        guard let packageURL = cli.installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            didAttemptAutoInstall = true
            print("[install] requested package not found: \(packageURL.path)")
            return
        }
        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            didAttemptAutoInstall = true
            print("[install] unsupported package type: \(packageURL.path)")
            return
        }
        guard caps.contains("ipa_install") else {
            print(
                "[install] guest does not advertise ipa_install; reconnect or reboot the guest so the updated daemon can take over"
            )
            return
        }
        guard let control else {
            print("[install] control channel is not ready")
            return
        }

        didAttemptAutoInstall = true
        print("[install] auto-installing \(packageURL.lastPathComponent)")
        do {
            let result = try await control.installIPA(localURL: packageURL)
            print("[install] \(result)")
        } catch {
            print("[install] failed: \(error)")
        }
    }

    func applicationWillTerminate(_: Notification) {
        hostControl?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        !cli.noGraphics
    }
}
