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

    // In-module unit tests (src/*.zig).
    const mod_tests = b.addTest(.{ .root_module = llmkit_mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // Standalone test drivers under tests/ — each sees the `llmkit` module.
    // "wire-request" runs only the request-wire driver (mirrors the other
    // SDKs' filtered `--filter RequestWireTests`-style Makefile line) so
    // `make test-request-wire` need not run the full unit-test suite.
    for ([_][]const u8{
        "tests/request_wire_test.zig",
    }) |driver| {
        const driver_mod = b.createModule(.{
            .root_source_file = b.path(driver),
            .target = target,
            .optimize = optimize,
        });
        driver_mod.addImport("llmkit", llmkit_mod);
        const driver_tests = b.addTest(.{ .root_module = driver_mod });
        const run_driver = b.addRunArtifact(driver_tests);
        test_step.dependOn(&run_driver.step);
        wire_request_step.dependOn(&run_driver.step);
    }
}
