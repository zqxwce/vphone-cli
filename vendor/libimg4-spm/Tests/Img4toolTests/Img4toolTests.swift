import Img4tool
import Foundation
import XCTest

final class Img4toolTests: XCTestCase {

    // MARK: - Version

    func testVersion() {
        let ver = img4Version()
        XCTAssertTrue(ver.contains("img4tool"), "version string should contain 'img4tool', got: \(ver)")
    }

    // MARK: - Type Detection

    func testDetectGarbage() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(img4DetectType(garbage), .unknown)
    }

    func testDetectIM4P() {
        let im4p = buildMinimalIM4P(fourcc: "test", description: "d", payload: Data([0xAA, 0xBB]))
        XCTAssertEqual(img4DetectType(im4p), .im4p)
    }

    func testDetectIM4PInvalid() {
        let notIm4p = buildDERSequence([
            buildDERIA5String("NOPE"),
        ])
        XCTAssertNotEqual(img4DetectType(notIm4p), .im4p)
    }

    // MARK: - IM4P Parsing

    func testIM4PInitInvalid() {
        XCTAssertThrowsError(try IM4P(Data([0x00, 0x01]))) { error in
            XCTAssertTrue(error is Img4Error)
        }
    }

    func testIM4PParseFourcc() throws {
        let data = buildMinimalIM4P(fourcc: "rkrn", description: "kernel", payload: Data(repeating: 0x42, count: 8))
        let im4p = try IM4P(data)
        XCTAssertEqual(im4p.fourcc, "rkrn")
    }

    func testIM4PParseDescription() throws {
        let data = buildMinimalIM4P(fourcc: "dtre", description: "DeviceTree", payload: Data(repeating: 0, count: 4))
        let im4p = try IM4P(data)
        XCTAssertEqual(im4p.description, "DeviceTree")
    }

    func testIM4PExtractPayload() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        let data = buildMinimalIM4P(fourcc: "test", description: "desc", payload: payload)
        let im4p = try IM4P(data)
        let extracted = try im4p.payload()
        XCTAssertEqual(extracted, payload)
    }

    func testIM4PNotEncrypted() throws {
        let data = buildMinimalIM4P(fourcc: "test", description: "desc", payload: Data([0x01]))
        let im4p = try IM4P(data)
        XCTAssertFalse(im4p.isEncrypted)
    }

    // MARK: - IM4P Creation

    func testIM4PCreateRoundtrip() throws {
        let originalPayload = Data(repeating: 0x55, count: 64)
        let created = try IM4P(fourcc: "tst1", description: "test desc", payload: originalPayload)

        XCTAssertEqual(img4DetectType(created.data), .im4p)
        XCTAssertEqual(created.fourcc, "tst1")

        let extracted = try created.payload()
        XCTAssertEqual(extracted, originalPayload)
    }

    func testIM4PCreateEmpty() throws {
        let created = try IM4P(fourcc: "empt", description: "empty", payload: Data())
        XCTAssertEqual(created.fourcc, "empt")
    }

    // MARK: - IM4P Rename

    func testIM4PRename() throws {
        let data = buildMinimalIM4P(fourcc: "aaaa", description: "original", payload: Data([0x01, 0x02]))
        let im4p = try IM4P(data)
        let renamed = try im4p.renamed(to: "bbbb")
        XCTAssertEqual(renamed.fourcc, "bbbb")

        let p1 = try im4p.payload()
        let p2 = try renamed.payload()
        XCTAssertEqual(p1, p2)
    }

    // MARK: - IM4M

    func testIM4MInitInvalid() {
        XCTAssertThrowsError(try IM4M(Data([0x00, 0x01]))) { error in
            XCTAssertTrue(error is Img4Error)
        }
    }

    // MARK: - IMG4

    func testIMG4InitInvalid() {
        XCTAssertThrowsError(try IMG4(Data([0x30, 0x00]))) { error in
            XCTAssertTrue(error is Img4Error)
        }
    }

    // MARK: - Larger Payload

    func testIM4PLargerPayload() throws {
        let payload = Data(repeating: 0xAB, count: 4096)
        let created = try IM4P(fourcc: "big1", description: "large payload test", payload: payload)
        let extracted = try created.payload()
        XCTAssertEqual(extracted, payload)
    }

    // MARK: - Helpers

    /// Build a minimal valid IM4P DER structure (uncompressed, no KBAG).
    /// Note: img4tool requires non-empty description for isIM4P validation.
    private func buildMinimalIM4P(fourcc: String, description: String, payload: Data) -> Data {
        buildDERSequence([
            buildDERIA5String("IM4P"),
            buildDERIA5String(fourcc),
            buildDERIA5String(description),
            buildDEROctetString(payload),
        ])
    }

    private func buildDERSequence(_ elements: [Data]) -> Data {
        let content = elements.reduce(Data()) { $0 + $1 }
        return Data([0x30]) + derLength(content.count) + content
    }

    private func buildDERIA5String(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        return Data([0x16]) + derLength(bytes.count) + Data(bytes)
    }

    private func buildDEROctetString(_ d: Data) -> Data {
        Data([0x04]) + derLength(d.count) + d
    }

    private func derLength(_ len: Int) -> Data {
        if len < 0x80 {
            return Data([UInt8(len)])
        } else if len < 0x100 {
            return Data([0x81, UInt8(len)])
        } else if len < 0x10000 {
            return Data([0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
        } else if len < 0x1000000 {
            return Data([0x83, UInt8(len >> 16), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        } else {
            return Data([0x84, UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        }
    }
}
