import XCTest
@testable import Orchard

final class TelemetryTests: XCTestCase {

    func testVersionExists() {
        XCTAssertFalse(Orchard.version.isEmpty)
    }

    func testTelemetrySnapshotDecoding() throws {
        let json = """
        {
            "version": 1,
            "health": {
                "snapshot_version": 1,
                "uptime_ns": 1000000000,
                "monotonic_timestamp_ns": 1000000000,
                "pid": 12345,
                "active_runtimes": 1,
                "active_requests": 2,
                "cpu_usage_percent": 15.5,
                "system_wattage": 25.3,
                "system_temperature": 45.0,
                "shutting_down": false,
                "health_message": "OK"
            },
            "queues": {
                "request_slots_used": 1,
                "request_slots_capacity": 64,
                "response_slots_used": 2,
                "response_slots_capacity": 64,
                "raw_request_queue_depth": 0,
                "processed_sequence_queue_depth": 1,
                "postprocessor_backlog": 0,
                "pending_management_commands": 0
            },
            "memory": {
                "gpu_total_bytes": 137438953472,
                "gpu_reserved_bytes": 68719476736,
                "kv_cache_pages_total": 1000,
                "kv_cache_pages_used": 500,
                "prompt_cache_pages": 100,
                "prompt_cache_evictions": 5
            },
            "models": [
                {
                    "requested_id": "qwen-2.5-coder-32b",
                    "canonical_id": "Qwen/Qwen2.5-Coder-32B-Instruct",
                    "load_state": "Ready",
                    "runtime_active": true,
                    "waiting_sequences": 0,
                    "running_sequences": 1,
                    "overflow_buffer": 0,
                    "tokens_per_second": 45.5,
                    "avg_step_latency_ms": 22.0
                }
            ]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(TelemetrySnapshot.self, from: json)

        // Verify health
        XCTAssertEqual(snapshot.health.pid, 12345)
        XCTAssertEqual(snapshot.health.systemWattage, 25.3, accuracy: 0.01)
        XCTAssertEqual(snapshot.health.activeRequests, 2)

        // Verify memory
        XCTAssertEqual(snapshot.memory.gpuUtilization, 0.5, accuracy: 0.01)

        // Verify models
        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertEqual(snapshot.models[0].tokensPerSecond, 45.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.totalTokensPerSecond, 45.5, accuracy: 0.01)
    }

    func testGPUUtilizationCalculation() throws {
        let json = """
        {
            "gpu_total_bytes": 100,
            "gpu_reserved_bytes": 75,
            "kv_cache_pages_total": 0,
            "kv_cache_pages_used": 0,
            "prompt_cache_pages": 0,
            "prompt_cache_evictions": 0
        }
        """.data(using: .utf8)!

        let memory = try JSONDecoder().decode(MemoryTelemetry.self, from: json)
        XCTAssertEqual(memory.gpuUtilization, 0.75, accuracy: 0.001)
    }

    func testGPUUtilizationZeroTotal() throws {
        let json = """
        {
            "gpu_total_bytes": 0,
            "gpu_reserved_bytes": 0,
            "kv_cache_pages_total": 0,
            "kv_cache_pages_used": 0,
            "prompt_cache_pages": 0,
            "prompt_cache_evictions": 0
        }
        """.data(using: .utf8)!

        let memory = try JSONDecoder().decode(MemoryTelemetry.self, from: json)
        XCTAssertEqual(memory.gpuUtilization, 0.0)
    }

    func testIPCEndpoints() {
        XCTAssertTrue(IPCEndpoints.requestURL.hasPrefix("ipc://"))
        XCTAssertTrue(IPCEndpoints.responseURL.hasPrefix("ipc://"))
        XCTAssertTrue(IPCEndpoints.managementURL.hasPrefix("ipc://"))
        XCTAssertEqual(IPCEndpoints.eventTopicPrefix, Data("__PIE_EVENT__:".utf8))
    }
}
