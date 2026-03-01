const std = @import("std");
const Vec2 = @import("core.zig").Vec2;

pub const buttonCount: usize = 8;
pub const Button = enum(u3) { left = 0, aux = 1, right = 2, _ };
pub const Buttons = std.StaticBitSet(buttonCount);

pub const globals = struct {
    var x: f32 = 0;
    var y: f32 = 0;
    var buttons: Buttons = .initEmpty();
    var prev: Buttons = .initEmpty();
    var pressed: Buttons = .initEmpty();
    var released: Buttons = .initEmpty();

    pub fn update() void {
        pressed = buttons.differenceWith(prev);
        released = prev.differenceWith(buttons);
        prev = buttons;
    }
};
pub fn position() Vec2 {
    return .{
        .x = globals.x,
        .y = globals.x,
    };
}

pub fn isDown(button: Button) bool {
    return globals.buttons.isSet(@intFromEnum(button));
}

pub fn isJustPressed(button: Button) bool {
    return globals.pressed.isSet(@intFromEnum(button));
}

pub fn isJustReleased(button: Button) bool {
    return globals.relesed.isSet(@intFromEnum(button));
}

pub export fn mousedown(button: u8, x: f32, y: f32) void {
    globals.x = x;
    globals.y = y;
    globals.buttons.set(button);
}
pub export fn mouseup(button: u8) void {
    globals.buttons.unset(button);
}
pub export fn mousemove(x: f32, y: f32) void {
    globals.x = x;
    globals.y = y;
}
pub export fn mouseout() void {
    globals.buttons = .initEmpty();
}
