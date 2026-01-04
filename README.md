# Orchard Swift

Telemetry client for PIE (Proxy Inference Engine).

A minimal Swift library for subscribing to real-time engine telemetry. Designed for SwiftUI HUD integration. For inference requests, use Grand Central with orchard-rs.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/TheProxyCompany/orchard-swift.git", from: "2026.1.0")
]
```

## Usage

```swift
import Orchard

let telemetry = try OrchardTelemetry()

for await snapshot in telemetry.snapshots {
    let tokensPerSecond = snapshot.totalTokensPerSecond
    let gpuUtilization = snapshot.memory.gpuUtilization  // 0.0 - 1.0
    let powerWatts = snapshot.health.systemWattage
}
```

### SwiftUI Integration

```swift
struct EngineHUD: View {
    @State private var snapshot: TelemetrySnapshot?

    var body: some View {
        HStack {
            Text("\(snapshot?.totalTokensPerSecond ?? 0, specifier: "%.1f") tok/s")
            Text("\(Int((snapshot?.memory.gpuUtilization ?? 0) * 100))% GPU")
            Text("\(snapshot?.health.systemWattage ?? 0, specifier: "%.1f")W")
        }
        .task {
            guard let telemetry = try? OrchardTelemetry() else { return }
            for await s in telemetry.snapshots {
                snapshot = s
            }
        }
    }
}
```

## Available Telemetry

| Category | Fields |
|----------|--------|
| **Performance** | `tokensPerSecond`, `avgStepLatencyMs` |
| **Memory** | `gpuTotalBytes`, `gpuReservedBytes`, `kvCachePagesUsed` |
| **Power** | `systemWattage`, `systemTemperature`, `cpuUsagePercent` |
| **Engine** | `activeRequests`, `activeRuntimes`, `uptimeNs` |

## Scope

**This library provides:**
- NNG SUB socket subscription to PIE telemetry events
- Codable types for telemetry snapshots
- AsyncStream for SwiftUI integration

**This library does NOT provide:**
- Inference requests
- Model management
- Engine lifecycle control

For full inference capabilities, use orchard-rs via Grand Central.

## Requirements

- macOS 14.0+
- Swift 6.0+

## License

Apache 2.0
