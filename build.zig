const std = @import("std");

const number_of_pages = 17;
pub fn build(b: *std.Build) void {
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    wasm_module.export_symbol_names = &.{"__heap_base"};

    const wasm = b.addExecutable(.{
        .name = "_7DRL2026",
        .root_module = wasm_module,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.initial_memory = std.wasm.page_size * number_of_pages;
    wasm.max_memory = std.wasm.page_size * number_of_pages * 10;

    const wasm_install = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build WASM module");
    wasm_step.dependOn(&wasm_install.step);

    const success_msg = b.addSystemCommand(&.{ "echo", "build success!\n" });
    success_msg.step.dependOn(&wasm_install.step);
    wasm_step.dependOn(&success_msg.step);
}
