const std = @import("std");
const RingBuffer = @import("ringbuffer.zig").RingBuffer;

pub var buffer: [20][]const u8 = undefined;
pub var storage: RingBuffer([]const u8) = undefined;
var printBuffer: [8192]u8 = .{0} ** 8192;
var fba: std.heap.FixedBufferAllocator = .init(&printBuffer);
const allocator = fba.allocator();

pub fn log(comptime message: []const u8, args: anytype) void {
    // format message
    const slice = std.fmt.allocPrint(allocator, message, args) catch {
        return;
    };
    if (storage.full()) {
        if (storage.pop_front()) |m| {
            allocator.free(m);
        }
    }
    _ = storage.try_push_back(slice) catch {
        std.log.err("out of storage", {});
        unreachable;
    };
}
