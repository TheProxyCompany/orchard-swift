# Orchard Swift

Swift client library for the Orchard inference platform.

## Overview

Orchard Swift provides:
- PIE (Proxy Inference Engine) binary management
- NNG IPC communication with PIE
- Swift-native async/await API for inference

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/TheProxyCompany/orchard-swift", from: "0.1.0")
]
```

## Usage

```swift
import Orchard

let engine = try await InferenceEngine()
let client = engine.client(model: "your-model-id")

for try await token in client.generate(prompt: "Hello, world!") {
    print(token, terminator: "")
}
```

## Requirements

- macOS 14.0+
- Swift 6.0+
