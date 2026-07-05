// USB Audio Class 2.0 descriptors for a stereo 48 kHz / 16-bit OUTPUT (speaker) device.
//
// iOS 26's modern USB-audio path (usbaudiod / AUASD, useAUASD=on) detects UAC2 devices; the
// prior UAC1 device enumerated but was never bound (usbaudiod found no AC interface to service).
// UAC2 requires: AC interface protocol 0x20, a Clock Source descriptor, and the UAC2 terminal /
// AS-general / format / endpoint layouts (different byte layouts than UAC1).
//
// Topology (2 interfaces — AudioControl + one AudioStreaming):
//   Device → Config → IAD → AC iface (proto 0x20)
//                              → AC Header (bcdADC 2.00)
//                              → Clock Source (id 9)
//                              → Input Terminal  (USB streaming, id 1, clock 9)
//                              → Output Terminal (Speaker,       id 2, src 1, clock 9)
//                          → AS iface 1 alt 0 (zero-bandwidth)
//                          → AS iface 1 alt 1 (spk OUT, iso EP 0x01) → AS General + Format Type I + EP + CS-EP
//
// Format: PCM, 2 ch, 48000 Hz, 16-bit → 192 bytes per 1 ms iso frame.

import Foundation

enum USBAudioDescriptors {
    static let sampleRateHz: UInt32 = 48000
    static let channels: UInt8 = 2
    static let bytesPerSample: UInt8 = 2                  // 16-bit
    static let isoPacketSize: UInt16 = 192                // 48000/1000 * 2ch * 2B

    static let spkEndpointAddr: UInt8 = 0x01              // OUT EP1 (direction bit 7 = 0)
    static let micEndpointAddr: UInt8 = 0x81              // (unused in output-only; kept for API compat)

    // IDs
    private static let CLOCK_ID: UInt8 = 0x09
    private static let TID_USB_IT: UInt8 = 0x01           // USB streaming input terminal (data into device)
    private static let TID_SPK_OT: UInt8 = 0x02           // Speaker output terminal

    // Descriptor type / subtype constants
    private static let CS_INTERFACE: UInt8 = 0x24
    private static let CS_ENDPOINT: UInt8 = 0x25
    private static let UAC2_PROTO: UInt8 = 0x20           // IP_VERSION_02_00

    // MARK: Device
    static func device(vid: UInt16, pid: UInt16) -> [UInt8] {
        [
            18, 0x01,                              // bLength, DEVICE
            0x00, 0x02,                            // bcdUSB = 2.00
            0xEF, 0x02, 0x01,                      // class Misc / Common / IAD
            64,                                    // bMaxPacketSize0
            UInt8(vid & 0xFF), UInt8(vid >> 8),
            UInt8(pid & 0xFF), UInt8(pid >> 8),
            0x00, 0x01,                            // bcdDevice = 1.00
            0x01, 0x02, 0x00,                      // iManufacturer, iProduct, iSerial
            0x01,                                  // bNumConfigurations
        ]
    }

    // MARK: Configuration
    static func configuration() -> [UInt8] {
        // --- AudioControl class-specific block ---
        let acCS = acHeader() + clockSource() + inputTerminal() + outputTerminal()
        let acIface = stdInterface(num: 0, alt: 0, numEP: 0, sub: 0x01)   // AudioControl

        // --- AudioStreaming interface (num 1): alt 0 (idle) + alt 1 (streaming) ---
        let asAlt0 = stdInterface(num: 1, alt: 0, numEP: 0, sub: 0x02)
        let asAlt1 = stdInterface(num: 1, alt: 1, numEP: 1, sub: 0x02) + asGeneral() + formatTypeI() + isoEndpoint() + csIsoEndpoint()

        let inner = iad() + acIface + acCS + asAlt0 + asAlt1
        let total = 9 + inner.count
        let cfg: [UInt8] = [
            9, 0x02,
            UInt8(total & 0xFF), UInt8(total >> 8),
            0x02,                                  // bNumInterfaces = 2 (AC + 1 AS)
            0x01, 0x00,                            // bConfigurationValue, iConfiguration
            0xA0, 50,                              // bmAttributes (bus-powered + remote wakeup), 100 mA
        ]
        return cfg + inner
    }

    // MARK: Pieces
    private static func iad() -> [UInt8] {
        [ 8, 0x0B, 0x00, 0x02, 0x01, 0x00, UAC2_PROTO, 0x00 ]  // 2 interfaces, Audio fn, UAC2 proto
    }

    private static func stdInterface(num: UInt8, alt: UInt8, numEP: UInt8, sub: UInt8) -> [UInt8] {
        [ 9, 0x04, num, alt, numEP, 0x01, sub, UAC2_PROTO, 0x00 ]
    }

    private static func acHeader() -> [UInt8] {
        let total: UInt16 = 9 + 8 + 17 + 12       // header + clock + IT + OT
        return [
            9, CS_INTERFACE, 0x01,                 // HEADER
            0x00, 0x02,                            // bcdADC = 2.00
            0x01,                                  // bCategory = DESKTOP_SPEAKER
            UInt8(total & 0xFF), UInt8(total >> 8),
            0x00,                                  // bmControls
        ]
    }

    private static func clockSource() -> [UInt8] {
        [
            8, CS_INTERFACE, 0x0A,                 // CLOCK_SOURCE
            CLOCK_ID,
            0x01,                                  // bmAttributes = internal fixed clock
            0x01,                                  // bmControls = clock freq read-only
            0x00,                                  // bAssocTerminal
            0x00,                                  // iClockSource
        ]
    }

    private static func inputTerminal() -> [UInt8] {
        [
            17, CS_INTERFACE, 0x02,                // INPUT_TERMINAL
            TID_USB_IT,
            0x01, 0x01,                            // wTerminalType = USB streaming
            0x00,                                  // bAssocTerminal
            CLOCK_ID,                              // bCSourceID
            channels,                              // bNrChannels
            0x03, 0x00, 0x00, 0x00,                // bmChannelConfig = FL+FR
            0x00,                                  // iChannelNames
            0x00, 0x00,                            // bmControls
            0x00,                                  // iTerminal
        ]
    }

    private static func outputTerminal() -> [UInt8] {
        [
            12, CS_INTERFACE, 0x03,                // OUTPUT_TERMINAL
            TID_SPK_OT,
            0x01, 0x03,                            // wTerminalType = Speaker
            0x00,                                  // bAssocTerminal
            TID_USB_IT,                            // bSourceID
            CLOCK_ID,                              // bCSourceID
            0x00, 0x00,                            // bmControls
            0x00,                                  // iTerminal
        ]
    }

    private static func asGeneral() -> [UInt8] {
        [
            16, CS_INTERFACE, 0x01,                // AS_GENERAL
            TID_USB_IT,                            // bTerminalLink = USB streaming IT
            0x00,                                  // bmControls
            0x01,                                  // bFormatType = FORMAT_TYPE_I
            0x01, 0x00, 0x00, 0x00,                // bmFormats = PCM
            channels,                              // bNrChannels
            0x03, 0x00, 0x00, 0x00,                // bmChannelConfig = FL+FR
            0x00,                                  // iChannelNames
        ]
    }

    private static func formatTypeI() -> [UInt8] {
        [
            6, CS_INTERFACE, 0x02,                 // FORMAT_TYPE
            0x01,                                  // FORMAT_TYPE_I
            bytesPerSample,                        // bSubslotSize = 2
            bytesPerSample * 8,                    // bBitResolution = 16
        ]
    }

    private static func isoEndpoint() -> [UInt8] {
        let mps = isoPacketSize
        return [
            7, 0x05,                               // ENDPOINT
            spkEndpointAddr,                       // OUT EP1
            0x05,                                  // bmAttributes = iso, async
            UInt8(mps & 0xFF), UInt8(mps >> 8),
            0x01,                                  // bInterval = 1 (full-speed 1ms frame)
        ]
    }

    private static func csIsoEndpoint() -> [UInt8] {
        [
            8, CS_ENDPOINT, 0x01,                  // EP_GENERAL
            0x00,                                  // bmAttributes
            0x00,                                  // bmControls
            0x00,                                  // bLockDelayUnits
            0x00, 0x00,                            // wLockDelay
        ]
    }
}
