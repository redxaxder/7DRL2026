const std = @import("std");
const RingBuffer = @import("ringbuffer.zig").RingBuffer;
const main = @import("main.zig");

pub const Entry = struct {
    text: []const u8,
    turn: i64,
};

pub var buffer: [20]Entry = undefined;
pub var storage: RingBuffer(Entry) = undefined;
var printBuffers: [2][8192]u8 = .{.{0} ** 8192} ** 2;
var fbas: [2]std.heap.FixedBufferAllocator = .{ .init(&printBuffers[0]), .init(&printBuffers[1]) };
var active: u1 = 0;

pub fn log(comptime message: []const u8, args: anytype) void {
    const slice = std.fmt.allocPrint(fbas[active].allocator(), message, args) catch blk: {
        active +%= 1;
        fbas[active].reset();
        break :blk std.fmt.allocPrint(fbas[active].allocator(), message, args) catch return;
    };
    if (storage.full()) {
        _ = storage.pop_front();
    }
    _ = storage.try_push_back(.{ .text = slice, .turn = main.globals.turn }) catch {
        std.log.err("out of storage", .{});
        unreachable;
    };
}
