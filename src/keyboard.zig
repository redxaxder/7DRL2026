const std = @import("std");
const keyCount = @typeInfo(Code).@"enum".fields.len;
pub const Keys = std.StaticBitSet(keyCount);

pub const globals = struct {
    var keys: Keys = .initEmpty();
    var prev: Keys = .initEmpty();
    var released: Keys = .initEmpty();
    var pressed: Keys = .initEmpty();
    var last_pressed: ?Code = null;
    var key_code_buf: [32]u8 = undefined;

    pub fn update() void {
        pressed = keys.differenceWith(prev);
        released = prev.differenceWith(keys);
        prev = keys;
    }
};

pub fn lastPressed() ?Code {
    return globals.last_pressed;
}

pub fn isDown(key: Code) bool {
    return globals.keys.isSet(@intFromEnum(key));
}

pub fn firstJustPressed() ?Code {
    if (globals.pressed.findFirstSet()) |ix| {
        return @enumFromInt(ix);
    }
    return null;
}

pub fn isJustPressed(key: Code) bool {
    return globals.pressed.isSet(@intFromEnum(key));
}

pub fn isJustReleased(key: Code) bool {
    return globals.released.isSet(@intFromEnum(key));
}

pub const Code = enum {
    KeyA,
    KeyB,
    KeyC,
    KeyD,
    KeyE,
    KeyF,
    KeyG,
    KeyH,
    KeyI,
    KeyJ,
    KeyK,
    KeyL,
    KeyM,
    KeyN,
    KeyO,
    KeyP,
    KeyQ,
    KeyR,
    KeyS,
    KeyT,
    KeyU,
    KeyV,
    KeyW,
    KeyX,
    KeyY,
    KeyZ,
    Digit0,
    Digit1,
    Digit2,
    Digit3,
    Digit4,
    Digit5,
    Digit6,
    Digit7,
    Digit8,
    Digit9,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    ShiftLeft,
    ShiftRight,
    ControlLeft,
    ControlRight,
    AltLeft,
    AltRight,
    MetaLeft,
    MetaRight,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    Backspace,
    Tab,
    Enter,
    Space,
    Escape,
    CapsLock,
    Minus,
    Equal,
    BracketLeft,
    BracketRight,
    Semicolon,
    Quote,
    Backquote,
    Backslash,
    Comma,
    Period,
    Slash,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    Numpad0,
    Numpad1,
    Numpad2,
    Numpad3,
    Numpad4,
    Numpad5,
    Numpad6,
    Numpad7,
    Numpad8,
    Numpad9,
    NumpadAdd,
    NumpadSubtract,
    NumpadMultiply,
    NumpadDivide,
    NumpadDecimal,
    NumpadEnter,
    NumpadEqual,
    NumLock,
    ScrollLock,
    Pause,
    PrintScreen,
    ContextMenu,
};

pub export fn getKeyCodeBufPtr() [*]u8 {
    return &globals.key_code_buf;
}

pub export fn clearKeys() void {
    globals.keys = .initEmpty();
}
pub export fn keydown(len: u32) void {
    if (len > globals.key_code_buf.len) return;
    if (std.meta.stringToEnum(Code, globals.key_code_buf[0..len])) |code| {
        globals.keys.set(@intFromEnum(code));
        globals.last_pressed = code;
    }
}
pub export fn keyup(len: u32) void {
    if (len > globals.key_code_buf.len) return;
    if (std.meta.stringToEnum(Code, globals.key_code_buf[0..len])) |code| {
        globals.keys.unset(@intFromEnum(code));
    }
}
