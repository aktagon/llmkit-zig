//! Build script for the llmkit Zig SDK (Zig 0.16.0).
//!
//! One library module (`llmkit`, root `src/root.zig`) and a `test` step that
//! runs both the in-module unit tests and every standalone driver under
//! `tests/` (each imported with the `llmkit` module in scope). Zero external
//! dependencies — HTTP, JSON, and HMAC all come from the standard library
//! (ADR-069 ZIG-003).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const llmkit_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "llmkit",
        .root_module = llmkit_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run the unit + wire-driver tests");
    const wire_request_step = b.step(
        "wire-request",
        "Run the request-wire driver and drop target/wire/request/<fixture>/zig.json artifacts",
    );
    const wire_response_step = b.step(
        "wire-response",
        "Run the response-wire driver and drop target/wire/response/<fixture>/zig.json artifacts",
    );
    const wire_lifecycle_step = b.step(
        "wire-lifecycle",
        "Run the lifecycle-wire driver and drop target/wire/lifecycle/<fixture>/zig.json artifacts",
    );
    const wire_sigv4_step = b.step(
        "wire-sigv4",
        "Run the sigv4-wire driver and drop target/wire/sigv4/<fixture>/zig.json artifacts",
    );
    const wire_catalogue_step = b.step(
        "wire-catalogue",
        "Run the catalogue-wire driver and drop target/wire/catalogue/<case>/zig.json artifacts",
    );
    const wire_telemetry_step = b.step(
        "wire-telemetry",
        "Run the telemetry-wire driver and drop target/wire/telemetry/<fixture>/zig.json artifacts",
    );

    // In-module unit tests (src/*.zig).
    const mod_tests = b.addTest(.{ .root_module = llmkit_mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // Standalone test drivers under tests/ — each sees the `llmkit` module.
    // Each driver joins `test` plus its own filtered wire step (mirrors the
    // other SDKs' `--filter RequestWireTests`-style Makefile lines), so
    // `make test-{request,response}-wire` need not run the full unit suite.
    const Driver = struct { path: []const u8, wire_step: *std.Build.Step };
    for ([_]Driver{
        .{ .path = "tests/request_wire_test.zig", .wire_step = wire_request_step },
        .{ .path = "tests/response_wire_test.zig", .wire_step = wire_response_step },
        .{ .path = "tests/lifecycle_wire_test.zig", .wire_step = wire_lifecycle_step },
        .{ .path = "tests/sigv4_wire_test.zig", .wire_step = wire_sigv4_step },
        .{ .path = "tests/catalogue_wire_test.zig", .wire_step = wire_catalogue_step },
        .{ .path = "tests/telemetry_wire_test.zig", .wire_step = wire_telemetry_step },
    }) |driver| {
        const driver_mod = b.createModule(.{
            .root_source_file = b.path(driver.path),
            .target = target,
            .optimize = optimize,
        });
        driver_mod.addImport("llmkit", llmkit_mod);
        const driver_tests = b.addTest(.{ .root_module = driver_mod });
        const run_driver = b.addRunArtifact(driver_tests);
        test_step.dependOn(&run_driver.step);
        driver.wire_step.dependOn(&run_driver.step);
    }
}
