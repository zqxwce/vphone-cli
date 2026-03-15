# libimg4-spm

Pure Swift library for parsing and manipulating Apple IMG4/IM4P firmware containers.

## Features

- ASN.1 DER parsing for IMG4, IM4P, IM4M containers
- Payload extraction with LZSS/LZFSE decompression
- AES-256-CBC decryption (CommonCrypto) and signature validation (Security.framework)
- Container construction and modification
- All Apple platforms supported (macOS, iOS, tvOS, watchOS, visionOS)

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Lakr233/libimg4-spm.git", from: "0.1.1"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "Img4tool", package: "libimg4-spm"),
        ]
    ),
]
```

## Usage

```swift
import Img4tool

// Detect container type
let data = try Data(contentsOf: url)
let type = img4DetectType(data) // .img4, .im4p, .im4m, .unknown

// Parse and extract IM4P payload (auto-decompresses LZSS/LZFSE)
let im4p = try IM4P(data)
print(im4p.fourcc)       // "krnl"
print(im4p.description)  // "KernelManagement_host-487.60.1"
let payload = try im4p.payload()

// Decrypt encrypted IM4P
let decrypted = try im4p.payload(iv: "00112233...", key: "aabbccdd...")

// Create and rename IM4P
let new = try IM4P(fourcc: "rkrn", description: "kernel", payload: rawData)
let renamed = try im4p.renamed(to: "rkrn")

// Work with IMG4 containers
let img4 = try IMG4(data)
let extractedIM4P = try img4.im4p()
let extractedIM4M = try img4.im4m()
let built = try IMG4(im4p: im4p, im4m: im4m)

// Validate IM4M signature
let im4m = try IM4M(data)
print(im4m.isSignatureValid)
```

## License

MIT
