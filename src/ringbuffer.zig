pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        write_index: usize,
        read_index: usize,

        pub fn init(buffer: []T) Self {
            return Self{
                .buffer = buffer,
                .write_index = 0,
                .read_index = 0,
            };
        }

        pub fn try_push_back(self: *Self, item: T) !*T {
            if (self.full()) {
                return error.BufferFull;
            }
            const ix = self.write_index % self.buffer.len;
            self.buffer[ix] = item;
            self.write_index += 1;
            return &self.buffer[ix];
        }

        pub fn index(self: *Self, ix: i32) ?*T {
            const len32: i32 = @intCast(self.len());
            if (ix + len32 < 0) {
                return null;
            }
            const i: usize = if (ix < 0) @intCast(ix + len32) else @intCast(ix);
            if (i >= self.len()) {
                return null;
            }
            return &self.buffer[(self.read_index + i) % self.buffer.len];
        }

        pub fn pop_front(self: *Self) ?T {
            if (self.empty()) {
                return null;
            }
            const item = self.buffer[self.read_index % self.buffer.len];
            self.read_index += 1;
            return item;
        }

        pub fn empty(self: *const Self) bool {
            return self.write_index == self.read_index;
        }

        pub fn full(self: *const Self) bool {
            return self.write_index - self.read_index == self.buffer.len;
        }

        pub fn len(self: *const Self) usize {
            return self.write_index - self.read_index;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        pub fn clear(self: *Self) void {
            self.read_index = 0;
            self.write_index = 0;
        }
    };
}

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
