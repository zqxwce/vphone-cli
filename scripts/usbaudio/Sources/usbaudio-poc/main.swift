// Step 2 POC — synthetic USB Audio Class 1.0 device.
//
// Builds a USB UAC1 device (stereo 48 kHz / 16-bit duplex) that fully enumerates
// on the macOS host with audio class code 0x01. Audio data is silent for now —
// mic IN returns zeros, speaker OUT bytes are discarded. CoreAudio bridging is
// a separate step (Task #22).
//
// Verify on host:  ioreg -p IOUSB -l | grep -B 2 -A 20 'vphone Audio'

import Foundation
import Darwin

setbuf(stdout, nil)

let vid: UInt16 = 0x05AC
let pid: UInt16 = 0x0711

let descriptors = USBDeviceDescriptors(
    device: USBAudioDescriptors.device(vid: vid, pid: pid),
    configuration: USBAudioDescriptors.configuration(),
    hidReport: [],
    manufacturer: "Anthropic Research",
    product: "vphone Audio")

final class SyntheticUAC: SyntheticIOUSBDevice {
    private let silentFrame: [UInt8] = [UInt8](
        repeating: 0,
        count: Int(USBAudioDescriptors.isoPacketSize))
    private var outBytesReceived: Int = 0
    private var inBytesDelivered: Int = 0
    private var lastReport = Date()

    override func deviceINData(endpoint: UInt8, maxLength: Int) -> [UInt8] {
        if endpoint == USBAudioDescriptors.micEndpointAddr {
            inBytesDelivered += maxLength
            reportThroughput()
            return Array(silentFrame.prefix(maxLength))
        }
        return []
    }

    override func deviceOUTData(endpoint: UInt8, data: Data) {
        if endpoint == USBAudioDescriptors.spkEndpointAddr {
            outBytesReceived += data.count
            reportThroughput()
        }
    }

    private func reportThroughput() {
        let now = Date()
        if now.timeIntervalSince(lastReport) > 1 {
            print("[UAC] mic→host: \(inBytesDelivered) B  |  spk←host: \(outBytesReceived) B  /sec")
            inBytesDelivered = 0
            outBytesReceived = 0
            lastReport = now
        }
    }
}

let device = SyntheticUAC(descriptors: descriptors)
do {
    try device.start()
    print("[poc] running UAC1 — press ^C to exit")
    print("[poc] config descriptor length: \(descriptors.configuration.count) bytes")
} catch {
    print("[poc] start failed: \(error)")
    exit(1)
}

RunLoop.main.run()
