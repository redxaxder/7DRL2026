const std = @import("std");

pub const CTX_WORDS = 4;
pub const Ctx = union {
    ptr: *anyopaque,
    data: [CTX_WORDS]u64,

    const ZERO: Ctx = .{ .data = .{ 0, 0, 0, 0 } };
};

pub fn noop_dealloc(_: Ctx, _: std.mem.Allocator) void {}

pub const Unit = @TypeOf(.{});
pub const unit: Unit = .{};

pub fn noop_callback(_: Ctx, _: Unit) void {}
pub const Callback = Fn(Unit, void);
pub const nil: Callback = .{
    .call_impl = noop_callback,
};

pub fn Fn(Args: type, Ret: type) type {
    return struct {
        ctx: Ctx = .ZERO,
        call_impl: *const fn (Ctx, Args) Ret,
        deinit_impl: *const fn (Ctx, std.mem.Allocator) void = noop_dealloc,

        pub const Self = @This();

        pub fn call(self: Self, args: Args) Ret {
            return self.call_impl(self.ctx, args);
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            self.deinit_impl(self.ctx, allocator);
        }

        pub fn constant(r: Ret) Self {
            return .{
                .call_impl = &struct {
                    pub fn f(_: Ctx, _: Args) Ret {
                        return r;
                    }
                }.f,
            };
        }

        pub fn from(comptime f: *const fn (Args) Ret) Self {
            return .{
                .call_impl = &struct {
                    pub fn wrapped(_: Ctx, args: Args) Ret {
                        return f(args);
                    }
                }.wrapped,
            };
        }

        pub fn closure(allocator: std.mem.Allocator, f: anytype, captures: anytype) !Self {
            const C = Closure(f, Len(@TypeOf(captures)));
            return C.init(allocator, @as(C.Captures, captures));
        }

        pub fn lambda(f: anytype, captures: anytype) Self {
            const C = Closure(f, Len(@TypeOf(captures)));
            return C.initInline(@as(C.Captures, captures));
        }
    };
}

pub fn Len(c: type) comptime_int {
    return std.meta.fields(c).len;
}

pub fn closure(allocator: std.mem.Allocator, f: anytype, captures: anytype) !Closure(f, Len(@TypeOf(captures))).Signature {
    const C = Closure(f, Len(@TypeOf(captures)));
    return C.init(allocator, @as(C.Captures, captures));
}

pub fn lambda(f: anytype, captures: anytype) Closure(f, Len(@TypeOf(captures))).Signature {
    const C = Closure(f, Len(@TypeOf(captures)));
    return C.initInline(@as(C.Captures, captures));
}

pub fn Closure(f: anytype, m: comptime_int) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const all_params = info.params;
    const n = all_params.len;
    const r = n - m;

    const capture_types: [m]type = blk: {
        var types: [m]type = undefined;
        for (all_params[0..m], 0..) |p, i| {
            types[i] = p.type.?;
        }
        break :blk types;
    };
    const remaining_types: [r]type = blk: {
        var types: [r]type = undefined;
        for (all_params[m..], 0..) |p, i| {
            types[i] = p.type.?;
        }
        break :blk types;
    };

    return struct {
        const Args = std.meta.Tuple(&remaining_types);
        const Ret = info.return_type.?;
        pub const Captures = std.meta.Tuple(&capture_types);
        pub const Signature = Fn(Args, Ret);

        fn callImpl(ctx: Ctx, args: Args) Ret {
            const captures_ptr: *Captures = @ptrCast(@alignCast(ctx.ptr));
            return @call(.auto, f, captures_ptr.* ++ args);
        }

        fn deinitImpl(ctx: Ctx, allocator: std.mem.Allocator) void {
            const captures_ptr: *Captures = @ptrCast(@alignCast(ctx.ptr));
            allocator.destroy(captures_ptr);
        }

        pub fn init(alloc: std.mem.Allocator, captures: Captures) !Signature {
            const heap = try alloc.create(Captures);
            heap.* = captures;
            return .{
                .ctx = .{ .ptr = @ptrCast(heap) },
                .call_impl = callImpl,
                .deinit_impl = deinitImpl,
            };
        }

        fn inlineCallImpl(ctx: Ctx, args: Args) Ret {
            const captures: *const Captures = @ptrCast(&ctx.data);
            return @call(.auto, f, captures.* ++ args);
        }

        pub fn initInline(captures: Captures) Signature {
            comptime {
                if (@sizeOf(Captures) > @sizeOf(Ctx))
                    @compileError("captures too large for inline closure");
                if (@alignOf(Captures) > @alignOf(Ctx))
                    @compileError("align too large for inline closure");
            }
            var ctx = Ctx{ .data = .{ 0, 0, 0, 0 } };
            const ptr: *Captures = @ptrCast(&ctx.data);
            ptr.* = captures;
            return .{
                .ctx = ctx,
                .call_impl = inlineCallImpl,
            };
        }
    };
}

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn mul3(a: i32, b: i32, c: i32) i32 {
    return a * b * c;
}

test "partial application of one argument" {
    const alloc = std.testing.allocator;
    const add5 = try closure(alloc, add, .{5});
    defer add5.deinit(alloc);

    try std.testing.expectEqual(8, add5.call(.{3}));
    try std.testing.expectEqual(5, add5.call(.{0}));
    try std.testing.expectEqual(-5, add5.call(.{-10}));
}

test "capture all arguments" {
    const alloc = std.testing.allocator;
    const always8 = try closure(alloc, add, .{ 5, 3 });
    defer always8.deinit(alloc);

    try std.testing.expectEqual(8, always8.call(.{}));
    try std.testing.expectEqual(8, always8.call(.{}));
}

test "capture two of three arguments" {
    const alloc = std.testing.allocator;
    const mul_2_3 = try closure(alloc, mul3, .{ 2, 3 });
    defer mul_2_3.deinit(alloc);

    try std.testing.expectEqual(24, mul_2_3.call(.{4}));
    try std.testing.expectEqual(0, mul_2_3.call(.{0}));
}

test "no captures wraps a plain function" {
    const alloc = std.testing.allocator;
    const wrapped = try closure(alloc, add, .{});
    defer wrapped.deinit(alloc);

    try std.testing.expectEqual(7, wrapped.call(.{ 3, 4 }));
}

test "type erasure: different closures stored uniformly" {
    const alloc = std.testing.allocator;
    const add5 = try closure(alloc, add, .{5});
    defer add5.deinit(alloc);
    const add10 = try closure(alloc, add, .{10});
    defer add10.deinit(alloc);

    const both = [_]@TypeOf(add5){ add5, add10 };
    try std.testing.expectEqual(8, both[0].call(.{3}));
    try std.testing.expectEqual(13, both[1].call(.{3}));
}

test "inline closure - no allocation" {
    const add5 = lambda(add, .{5});
    // no defer needed
    try std.testing.expectEqual(8, add5.call(.{3}));
    try std.testing.expectEqual(5, add5.call(.{0}));
}

test "inline and heap closures have the same type" {
    const alloc = std.testing.allocator;
    const heap = try closure(alloc, add, .{5});
    defer heap.deinit(alloc);
    const inl = lambda(add, .{10});

    const both = [_]@TypeOf(heap){ heap, inl };
    try std.testing.expectEqual(8, both[0].call(.{3}));
    try std.testing.expectEqual(13, both[1].call(.{3}));
}
