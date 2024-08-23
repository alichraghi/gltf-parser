const std = @import("std");
const build_options = @import("build_options");
const gltf = @import("gltf");

pub const BENCHMARK_GLTF = {};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const runs = if (build_options.enable_tracy) 1 else 500;

    const file = try std.fs.cwd().openFile("../sponza/sponza.glb", .{});
    defer file.close();
    const data = try file.readToEndAllocOptions(allocator, 100 * 1024 * 1024, null, @alignOf(u8), 0);
    defer allocator.free(data);

    var timer = try std.time.Timer.start();
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var mean: u64 = 0;
    var total: u64 = 0;

    for (0..runs) |_| {
        timer.reset();
        const model = try gltf.parseGLB(allocator, data);
        defer model.deinit(allocator);
        const took = timer.read();
        min = @min(took, min);
        max = @max(took, max);
        total += took;
    }

    mean = total / runs;

    try std.io.getStdErr().writer().print("min: {}\nmax: {}\nmean: {}\n", .{
        std.fmt.fmtDuration(min),
        std.fmt.fmtDuration(max),
        std.fmt.fmtDuration(mean),
    });
}
