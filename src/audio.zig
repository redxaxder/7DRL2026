const std = @import("std");
const func = @import("func.zig");

pub const DSL = struct {
    pub const Opcode = enum(u8) {
        create_oscillator = 0,
        create_gain = 1,
        create_biquad_filter = 2,
        create_stereo_panner = 3,
        create_delay = 4,
        create_buffer_source = 5,
        set_value = 6,
        linear_ramp = 7,
        exp_ramp = 8,
        set_target = 9,
        connect = 10,
        connect_param = 11,
        connect_output = 12,
        start = 13,
        stop = 14,
    };

    pub const Param = enum(u8) {
        frequency = 0,
        detune = 1,
        gain = 2,
        Q = 3,
        pan = 4,
        delay_time = 5,
    };

    pub const WaveType = enum(u8) {
        sine = 0,
        square = 1,
        sawtooth = 2,
        triangle = 3,
    };

    // 16-byte instruction: 4 bytes of u8 operands + 3 f32 args.
    // Operand semantics vary per opcode.
    pub const Instruction = extern struct {
        opcode: Opcode,
        arg1: u8 = 0,
        arg2: u8 = 0,
        arg3: u8 = 0,
        farg1: f32 = 0,
        farg2: f32 = 0,
        farg3: f32 = 0,
    };

    pub const Node = struct {
        id: u8,
        b: *Builder,

        pub fn envelope(self: Node, param: Param, values: []const f32, durations: []const f32) void {
            std.debug.assert(values.len == durations.len + 1);
            self.b.emit(.{ .opcode = .set_value, .arg1 = self.id, .arg2 = @intFromEnum(param), .farg1 = values[0], .farg2 = 0.0 });
            var t: f32 = 0;
            for (durations, 0..) |dur, i| {
                t += dur;
                self.b.emit(.{ .opcode = .linear_ramp, .arg1 = self.id, .arg2 = @intFromEnum(param), .farg1 = values[i + 1], .farg2 = t });
            }
        }

        pub fn connect(self: Node, to: Node) void {
            self.b.emit(.{ .opcode = .connect, .arg1 = self.id, .arg2 = to.id });
        }

        pub fn connectParam(self: Node, to: Node, param: Param) void {
            self.b.emit(.{ .opcode = .connect_param, .arg1 = self.id, .arg2 = to.id, .arg3 = @intFromEnum(param) });
        }

        pub fn toOutput(self: Node) void {
            self.b.emit(.{ .opcode = .connect_output, .arg1 = self.id });
        }

        pub fn play(self: Node, start_time: f32, stop_time: f32) void {
            self.b.emit(.{ .opcode = .start, .arg1 = self.id, .farg1 = start_time });
            self.b.emit(.{ .opcode = .stop, .arg1 = self.id, .farg1 = stop_time });
        }
    };

    pub const Builder = struct {
        instructions: [MAX]Instruction = undefined,
        len: usize = 0,
        node_count: u8 = 0,

        const MAX = 64;

        fn emit(self: *Builder, inst: Instruction) void {
            self.instructions[self.len] = inst;
            self.len += 1;
        }

        fn addNode(self: *Builder, inst: Instruction) Node {
            const id = self.node_count;
            self.node_count += 1;
            self.emit(inst);
            return .{ .id = id, .b = self };
        }

        pub fn oscillator(self: *Builder, wave: WaveType) Node {
            return self.addNode(.{ .opcode = .create_oscillator, .arg1 = @intFromEnum(wave) });
        }

        pub fn gain(self: *Builder) Node {
            return self.addNode(.{ .opcode = .create_gain });
        }

        pub fn biquadFilter(self: *Builder, filter_type: u8) Node {
            return self.addNode(.{ .opcode = .create_biquad_filter, .arg1 = filter_type });
        }

        pub fn stereoPanner(self: *Builder) Node {
            return self.addNode(.{ .opcode = .create_stereo_panner });
        }

        pub fn delay(self: *Builder, max_time: f32) Node {
            return self.addNode(.{ .opcode = .create_delay, .farg1 = max_time });
        }

        pub fn done(self: *const Builder) [self.len]Instruction {
            return self.instructions[0..self.len].*;
        }
    };
};

pub const defns = struct {
    pub const move = blk: {
        var b = DSL.Builder{};
        const osc = b.oscillator(.triangle);
        const env = b.gain();
        osc.envelope(.frequency, &.{ 300, 500 }, &.{0.05});
        env.envelope(.gain, &.{ 0.15, 0.0 }, &.{0.08});
        osc.connect(env);
        env.toOutput();
        osc.play(0.0, 0.1);
        break :blk b.done();
    };

    pub const collide = blk: {
        var b = DSL.Builder{};
        const osc = b.oscillator(.square);
        const env = b.gain();
        osc.envelope(.frequency, &.{ 150, 60 }, &.{0.1});
        env.envelope(.gain, &.{ 0.2, 0.0 }, &.{0.15});
        osc.connect(env);
        env.toOutput();
        osc.play(0.0, 0.2);
        break :blk b.done();
    };

    pub const click = blk: {
        var b = DSL.Builder{};
        const osc = b.oscillator(.square);
        const env = b.gain();
        osc.envelope(.frequency, &.{1000}, &.{});
        env.envelope(.gain, &.{ 0.1, 0.0 }, &.{0.03});
        osc.connect(env);
        env.toOutput();
        osc.play(0.0, 0.05);
        break :blk b.done();
    };
};

pub const SoundId: type = std.meta.DeclEnum(defns);
const sound_count = @typeInfo(SoundId).@"enum".fields.len;

fn getRecipe(comptime id: SoundId) []const DSL.Instruction {
    const name = @tagName(id);
    return &@field(defns, name);
}

pub const RecipeIndex = extern struct {
    offset: u32,
    count: u32,
};

const RecipeTable = struct {
    data: [total_instructions]DSL.Instruction,
    index: [sound_count]RecipeIndex,
    durations: [sound_count]f32,

    const total_instructions: usize = blk: {
        var total: usize = 0;
        for (0..sound_count) |i| {
            total += getRecipe(@as(SoundId, @enumFromInt(i))).len;
        }
        break :blk total;
    };
};

const recipes: RecipeTable = blk: {
    var result: RecipeTable = undefined;
    var offset: u32 = 0;
    for (0..sound_count) |i| {
        const recipe = getRecipe(@as(SoundId, @enumFromInt(i)));
        result.index[i] = .{ .offset = offset, .count = @intCast(recipe.len) };
        var max_time: f32 = 0;
        for (recipe, 0..) |inst, j| {
            result.data[offset + j] = inst;
            if (inst.opcode == .stop) {
                max_time = @max(max_time, inst.farg1);
            }
        }
        result.durations[i] = max_time * 1000;
        offset += @intCast(recipe.len);
    }
    break :blk result;
};

pub const SoundConfig = struct {
    id: SoundId,
    pan: f32 = 0,
    pitch_shift: f32 = 0,
    gain_scale: f32 = 1,
};

pub fn play(sound: SoundConfig) bool {
    const i = @intFromEnum(sound.id);
    if (globals.cooldowns[i] > 0) return false;
    if (globals.active_counts[i] >= MAX_ACTIVE) return false;
    const played = js.playSound(@intFromEnum(sound.id), sound.pan, sound.pitch_shift, sound.gain_scale) == 1;
    if (!played) {
        return false;
    }
    globals.cooldowns[i] = COOLDOWN_MS;
    globals.active_counts[i] += 1;
    return true;
}

pub fn play_(sound: SoundConfig) void {
    _ = play(sound);
}

pub fn tick(dt: f32) void {
    for (0..sound_count) |i| {
        globals.cooldowns[i] = @max(0, globals.cooldowns[i] - dt);
        const duration = recipes.durations[i];
        if (duration > 0) {
            globals.active_counts[i] = @max(0, globals.active_counts[i] - dt / duration);
        }
    }
}

pub const COOLDOWN_MS: f32 = 30;
pub const MAX_ACTIVE: f32 = 3;
pub const globals = struct {
    pub var cooldowns: [sound_count]f32 = [_]f32{0} ** sound_count;
    pub var active_counts: [sound_count]f32 = [_]f32{0} ** sound_count;
};

pub const js = struct {
    pub extern "audio" fn playSound(sound_id: u8, pan: f32, pitch_shift: f32, gain_scale: f32) u32;
};

pub export fn getRecipeDataPtr() i32 {
    return @intCast(@intFromPtr(&recipes.data));
}
pub export fn getRecipeIndexPtr() i32 {
    return @intCast(@intFromPtr(&recipes.index));
}
pub export fn getInstructionStride() u32 {
    return @sizeOf(DSL.Instruction);
}
