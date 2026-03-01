const std = @import("std");
const func = @import("func.zig");
const ringbuffer = @import("ringbuffer.zig");

pub fn eval_hermite(
    p: struct {
        h00: f32 = 0, // value at x = 0
        h10: f32 = 0, // value at x = 1
        h01: f32 = 0, // derivative at x=0
        h11: f32 = 0, // derivative at x=1
    },
    x: f32,
) f32 {
    const x2 = x * x;
    const x3 = x2 * x;
    return (2 * x3 - 3 * x2 + 1) * p.h00 + (x3 - 2 * x2 + x) * p.h10 + (-2 * x3 + 3 * x2) * p.h01 + (x3 - x2) * p.h11;
}

pub const Exit = error{Exit};
pub const Queue = struct {
    buffer: ringbuffer.RingBuffer(Animation),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Queue {
        const buffer = try allocator.alloc(Animation, n);
        return .{
            .buffer = .init(buffer),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Queue) void {
        for (0..self.buffer.len()) |ix| {
            if (self.buffer.index(@intCast(ix))) |animation| {
                animation.deinit(self.allocator);
            }
        }
        self.allocator.free(self.buffer.buffer);
    }

    pub fn push(self: *Queue, anim: Animation) !*Animation {
        return self.buffer.try_push_back(anim) catch {
            return error.AnimationQueueFull;
        };
    }

    pub fn add(
        self: *Queue,
        options: struct {
            duration: f32 = 0,
            speed: f32 = 1,
            lock: AnimationLock = .EMPTY,
            on_wake: func.Callback = func.nil,
            on_finish: func.Callback = func.nil,
        },
        f: anytype,
        captures: anytype,
    ) !*Animation {
        errdefer options.on_wake.deinit(self.allocator);
        errdefer options.on_finish.deinit(self.allocator);
        const closure: Fn = try .closure(self.allocator, f, captures);
        errdefer closure.deinit(self.allocator);
        return try self.push(.{
            .duration = options.duration,
            .speed = options.speed,
            .func = closure,
            .lock = options.lock,
            .on_wake = options.on_wake,
            .on_finish = options.on_finish,
        });
    }

    pub fn sync(self: *Queue) !void {
        const a = try self.push(Animation.EMPTY);
        _ = a.lock_exclusive(.initFull());
    }

    pub fn full(self: *Queue) bool {
        return self.buffer.full();
    }

    pub fn len(self: *Queue) usize {
        return self.buffer.len();
    }

    pub fn tick(self: *Queue, dt: f32) void {
        var lock: AnimationLock = .EMPTY;
        var can_chain = true;
        for (0..self.buffer.len()) |ix| {
            if (self.buffer.index(@intCast(ix))) |animation| {
                animation.try_wake(lock, can_chain);
                animation.tick(dt);
                if (animation.state == .Finished) {
                    can_chain = true;
                } else {
                    can_chain = false;
                    lock.merge(animation.lock);
                }
            }
        }

        while (self.buffer.index(0)) |first| {
            if (first.state == .Finished) {
                first.deinit(self.allocator);
                _ = self.buffer.pop_front();
            } else {
                break;
            }
        }
    }
};

pub const Time = struct {
    elapsed: f32,
    duration: f32,
    delta: f32,

    pub fn progress(t: Time) f32 {
        return std.math.clamp(t.elapsed / t.duration, 0, 1);
    }
};

pub const AnimationState = enum {
    Waiting,
    // An animation in the chain state does not start playing unless
    // the immediately preceding animation is finished;
    Chain,
    Active,
    Finished,
};

pub const LockData = std.StaticBitSet(AnimationLock.BITCOUNT);

pub fn singleton(bit: usize) LockData {
    var x: LockData = .initEmpty();
    x.set(bit);
    return x;
}

pub const AnimationLock = struct {
    const BITCOUNT = 512;

    exclusive: LockData = .initEmpty(),
    shared: LockData = .initEmpty(),

    pub const EMPTY: AnimationLock = .{};
    pub const FULL: AnimationLock = .{
        .exclusive = .initFull(),
        .shared = .initFull(),
    };

    pub fn conflicts(self: AnimationLock, other: AnimationLock) bool {
        for (0..self.exclusive.masks.len) |i| {
            const self_any = self.exclusive.masks[i] | self.shared.masks[i];
            const other_any = other.exclusive.masks[i] | other.shared.masks[i];
            if ((self.exclusive.masks[i] & other_any) != 0) return true;
            if ((other.exclusive.masks[i] & self_any) != 0) return true;
        }
        return false;
    }

    pub fn merge(self: *AnimationLock, other: AnimationLock) void {
        self.exclusive.setUnion(other.exclusive);
        self.shared.setUnion(other.shared);
    }
};

pub const Fn = func.Fn(struct { Time }, Exit!void);

pub const Animation = struct {
    duration: f32 = 0,
    elapsed: f32 = 0,
    speed: f32 = 1,
    // The lock is for determining which animations can play concurrently.
    // If two animations have conflicting locks, the earlier one in the queue has to finish playing before
    // the later one starts.
    lock: AnimationLock = .EMPTY,
    func: Fn = .constant({}),
    on_wake: func.Callback = func.nil,
    on_finish: func.Callback = func.nil,
    state: AnimationState = .Waiting,

    pub const EMPTY: Animation = .{};

    pub fn lock_exclusive(self: *Animation, lockdata: LockData) *Animation {
        self.lock.exclusive.setUnion(lockdata);
        return self;
    }
    pub fn lock_shared(self: *Animation, lockdata: LockData) *Animation {
        self.lock.shared.setUnion(lockdata);
        return self;
    }
    pub fn chain(self: *Animation) *Animation {
        self.state = .Chain;
        return self;
    }

    pub fn try_wake(self: *Animation, lock: AnimationLock, has_chain: bool) void {
        if (lock.conflicts(self.lock)) {
            return;
        }
        const woke = switch (self.state) {
            .Waiting => true,
            .Chain => has_chain,
            .Finished, .Active => false,
        };
        if (woke) {
            self.state = .Active;
            self.on_wake.call(.{});
        }
    }

    pub fn tick(self: *Animation, dt: f32) void {
        if (self.state != .Active) {
            return;
        }
        var progress = dt * self.speed;
        self.elapsed += progress;
        const finish_over = self.elapsed - self.duration;
        if (finish_over >= 0) {
            self.elapsed = self.duration;
            self.state = .Finished;
        }
        progress -= @max(finish_over, 0);
        self.func.call(.{.{
            .elapsed = self.elapsed,
            .duration = self.duration,
            .delta = progress,
        }}) catch {
            self.state = .Finished;
        };
        if (self.state == .Finished) {
            self.on_finish.call(.{});
        }
    }

    pub fn deinit(self: *Animation, allocator: std.mem.Allocator) void {
        self.func.deinit(allocator);
        self.on_wake.deinit(allocator);
        self.on_finish.deinit(allocator);
    }
};
