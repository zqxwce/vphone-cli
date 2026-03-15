import Foundation
import CommonCrypto
import Security

// MARK: - AES-256-CBC Decryption

enum Img4Crypto {
    /// Decrypt data using AES-256-CBC.
    /// - Parameters:
    ///   - data: Ciphertext bytes.
    ///   - ivHex: 32-character hex string (128-bit IV).
    ///   - keyHex: 64-character hex string (256-bit key).
    /// - Returns: Decrypted plaintext.
    static func aesDecrypt(_ data: Data, ivHex: String, keyHex: String) throws -> Data {
        let iv = try hexToBytes(ivHex)
        let key = try hexToBytes(keyHex)

        guard iv.count == kCCBlockSizeAES128 else {
            throw Img4Error.operationFailed("IV must be 16 bytes (32 hex chars)")
        }
        guard key.count == kCCKeySizeAES256 else {
            throw Img4Error.operationFailed("Key must be 32 bytes (64 hex chars)")
        }

        var outLength = 0
        var outData = Data(count: data.count + kCCBlockSizeAES128)

        let status = outData.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    key, key.count,
                    iv,
                    inBuf.baseAddress, data.count,
                    outBuf.baseAddress, outBuf.count,
                    &outLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw Img4Error.operationFailed("AES decryption failed (CCCrypt status: \(status))")
        }

        outData.count = outLength
        return outData
    }

    /// Parse a hex string into bytes.
    static func hexToBytes(_ hex: String) throws -> [UInt8] {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else {
            throw Img4Error.operationFailed("invalid hex string length")
        }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i ... i + 1]), radix: 16) else {
                throw Img4Error.operationFailed("invalid hex character")
            }
            bytes.append(byte)
        }
        return bytes
    }
}

// MARK: - Signature Verification

enum Img4SignatureVerifier {
    /// Verify an IM4M signature using Security.framework.
    /// Returns true if the signature is valid, false otherwise.
    static func verifyIM4MSignature(_ im4mData: Data) -> Bool {
        guard let element = try? DERElement.parse(im4mData),
              element.tag == DERTag.sequence
        else {
            return false
        }

        guard let children = try? element.children(),
              children.count >= 5
        else {
            return false
        }

        // children[0] = IA5String "IM4M"
        // children[1] = INTEGER version
        // children[2] = SET (manifest body) - this is the signed data
        // children[3] = OCTET STRING (signature)
        // children[4] = SEQUENCE (certificate chain)

        let signedDataElement = children[2]
        let signatureElement = children[3]
        let certChainElement = children[4]

        guard signatureElement.tag == DERTag.octetString else { return false }

        let signedData = signedDataElement.raw
        let signature = signatureElement.value

        // Extract the first certificate from the chain
        guard let certChildren = try? certChainElement.children(),
              let firstCertElement = certChildren.first
        else {
            return false
        }

        let certData = firstCertElement.raw

        // Use Security.framework for verification
        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            return false
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
        guard status == errSecSuccess, let trust else { return false }

        let publicKey: SecKey?
        if #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
            publicKey = SecTrustCopyKey(trust)
        } else {
            publicKey = SecTrustCopyPublicKey(trust)
        }
        guard let publicKey else { return false }

        // Try SHA-384 first (newer devices), then SHA-1 (older)
        for algorithm in [SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA384,
                          SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA1] {
            if SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) {
                var error: Unmanaged<CFError>?
                let result = SecKeyVerifySignature(
                    publicKey,
                    algorithm,
                    signedData as CFData,
                    signature as CFData,
                    &error
                )
                if result { return true }
            }
        }

        return false
    }
}
