const std = @import("std");

/// Eigenstaendiger Bau des Moduls plus die Hosttests.
///
/// `zig build` erzeugt JSON.R4P allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS - so wie alle 38 R4D- und R4P-Projekte. Die Abhaengigkeit auf das
/// SDK laeuft als Pfad in build.zig.zon.
///
/// `zig build test` faehrt Kern- und Conformance-Tests. Die brauchen benannte
/// Importe, weil Zig ein Root-File nicht aus seinem eigenen Baum
/// herausimportieren laesst und der Conformance-Test beide Seiten des
/// Vertrags sehen muss.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json_core.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const abi_module = b.createModule(.{
        .root_source_file = b.path("Tests/Conformance/CheckJsonAbi.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    abi_module.addImport("core", b.createModule(.{
        .root_source_file = b.path("src/json_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    abi_module.addImport("facade", b.createModule(.{
        .root_source_file = sdk_dep.path("r4os/json.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    const abi_tests = b.addTest(.{ .root_module = abi_module });
    const run_abi_tests = b.addRunArtifact(abi_tests);

    const test_step = b.step("test", "Run JSON protocol core and ABI conformance tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_abi_tests.step);
}
