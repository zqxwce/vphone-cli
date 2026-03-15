// ARM64Disassembler.swift — Capstone wrapper for ARM64 disassembly.

import Capstone
import Foundation

public final class ARM64Disassembler: Sendable {
    /// Shared singleton instance with detail mode enabled.
    public static let shared: ARM64Disassembler = .init()

    private let cs: Disassembler

    public init() {
        // CS_ARCH_AARCH64 and CS_MODE_LITTLE_ENDIAN are the correct constants
        cs = try! Disassembler(arch: CS_ARCH_AARCH64, mode: CS_MODE_LITTLE_ENDIAN)
        cs.detail = true
        cs.skipData = true
    }

    /// Disassemble instructions from data starting at the given virtual address.
    ///
    /// - Parameters:
    ///   - data: Raw instruction bytes.
    ///   - address: Virtual address of the first byte.
    ///   - count: Maximum number of instructions to disassemble (0 = all).
    /// - Returns: Array of disassembled instructions.
    public func disassemble(_ data: Data, at address: UInt64 = 0, count: Int = 0) -> [Instruction] {
        cs.disassemble(code: data, address: address, count: count)
    }

    /// Disassemble a single 4-byte instruction at the given address.
    public func disassembleOne(_ data: Data, at address: UInt64 = 0) -> Instruction? {
        let insns = cs.disassemble(code: data, address: address, count: 1)
        return insns.first
    }

    /// Disassemble a single instruction from a buffer at a file offset.
    public func disassembleOne(in buffer: Data, at offset: Int, address: UInt64? = nil) -> Instruction? {
        guard offset >= 0, offset + 4 <= buffer.count else { return nil }
        let slice = buffer[offset ..< offset + 4]
        let addr = address ?? UInt64(offset)
        return disassembleOne(Data(slice), at: addr)
    }

    /// Disassemble `count` instructions starting at file offset.
    public func disassemble(in buffer: Data, at offset: Int, count: Int, address: UInt64? = nil) -> [Instruction] {
        let byteCount = count * 4
        guard offset >= 0, offset + byteCount <= buffer.count else { return [] }
        let slice = buffer[offset ..< offset + byteCount]
        let addr = address ?? UInt64(offset)
        return disassemble(Data(slice), at: addr, count: count)
    }

    /// Return the canonical name string for an AArch64 register ID (e.g. "x0", "w1", "wzr").
    public func registerName(_ regID: UInt32) -> String? {
        cs.registerName(regID)
    }
}
