pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        write_index: u64,
        read_index: u64,

        pub fn init(buffer: []T) Self {
            return Self{
                .buffer = buffer,
                .write_index = 0,
                .read_index = 0,
            };
        }

        pub fn iter(self: *Self) RingIterator(T) {
            return RingIterator(T).init(self);
        }

        pub fn try_push_back(self: *Self, item: T) !*T {
            if (self.full()) {
                return error.BufferFull;
            }
            const ix: usize = @intCast(self.write_index % self.buffer.len);
            self.buffer[ix] = item;
            self.write_index += 1;
            return &self.buffer[ix];
        }

        pub fn index(self: *Self, ix: i32) ?*T {
            const len64: i64 = @intCast(self.len());
            if (ix + len64 < 0) {
                return null;
            }
            const i: u64 = if (ix < 0) @intCast(ix + len64) else @intCast(ix);
            if (i >= self.len()) {
                return null;
            }
            const buf_ix: usize = @intCast((self.read_index + i) % self.buffer.len);
            return &self.buffer[buf_ix];
        }

        pub fn pop_front(self: *Self) ?T {
            if (self.empty()) {
                return null;
            }
            const item = self.buffer[@as(usize, @intCast(self.read_index % self.buffer.len))];
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
            return @intCast(self.write_index - self.read_index);
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

pub fn RingIterator(T: type) type {
    return struct {
        pos_idx: u64,
        stop_idx: u64,
        rb: *RingBuffer(T),

        pub fn init(ring: *RingBuffer(T)) @This() {
            return .{ .pos_idx = ring.read_index, .stop_idx = ring.write_index, .rb = ring };
        }

        pub fn next(self: *RingIterator) ?T {
            if (self.pos_idx == self.stop_idx) {}
            self.pos_idx = (self.pos_idx + 1) % self.rb.capacity;
            return self.rb.index(self.pos_idx);
        }
    };
}

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
