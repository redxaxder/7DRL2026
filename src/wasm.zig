const std = @import("std");
const keyboard = @import("keyboard.zig");
const audio = @import("audio.zig");
const mouse = @import("mouse.zig");
const func = @import("func.zig");
const RenderBuffer = @import("render.zig");
const Sprite = RenderBuffer.Sprite;
const main = @import("main.zig");
const combat_log = @import("combat_log.zig");
const map = @import("map.zig");
const inventory = @import("inventory.zig");
const RingBuffer = @import("ringbuffer.zig").RingBuffer;
const sector = @import("sector.zig");
const Color = RenderBuffer.Color;

const ui = @import("ui.zig");

const core = @import("core.zig");
const Vec2 = core.Vec2;
const IVec2 = core.IVec2;
const Rect = core.Rect;
const IRect = core.IRect;

pub const std_options: std.Options = .{
    .logFn = log,
};

pub const js = struct {
    pub extern "util" fn log(strPtr: i32, strLen: i32) void;
    pub extern "util" fn time() u64;
};

var printBuffer: [8192]u8 = .{0} ** 8192;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = comptime level.asText();
    const slice = std.fmt.bufPrint(printBuffer[0..], prefix ++ ": " ++ format, args) catch {
        std.log.err("log failed: message too long", .{});
        return;
    };
    const len: usize = slice.len;
    const ptr = slice.ptr;
    js.log(@intCast(@intFromPtr(ptr)), @intCast(len));
}

var prev_time: f64 = 0;

var render_buffer: RenderBuffer = undefined;
var prng: std.Random.DefaultPrng = undefined;
var camera: Vec2 = .ZERO;
var camera_target: Vec2 = .ZERO;
const camera_w: f32 = 64;
const camera_h: f32 = 64;
var screen_offset: Vec2 = .ZERO;
var screen_w: f32 = 0;
var screen_h: f32 = 0;

pub export fn init(buffer_size: i32, screenW: f32, screenH: f32) i32 {
    const allocator = std.heap.wasm_allocator;
    resize(screenW, screenH);

    prng = std.Random.DefaultPrng.init(@bitCast(js.time()));

    render_buffer = RenderBuffer.init(allocator, @intCast(buffer_size)) catch return -1;

    return game_init();
}

fn game_init() i32 {
    main.init(prng.random()) catch return -1;

    combat_log.storage = .init(&combat_log.buffer);

    camera = main.globals.player().position.float();
    camera.x -= camera_w / 2;
    camera.y -= camera_h / 2;
    camera_target = camera;
    return 0;
}

pub export fn resize(w: f32, h: f32) void {
    screen_w = w;
    screen_h = h;
    RenderBuffer.setTransform(w, h, 128 * SPRITE_SCALE, 72 * SPRITE_SCALE);
}

fn splat_wrap_string(x: f32, y: f32, text: []const u8, color: Color, size: f32, width: i16) usize {
    for (wrapText(text, width), 0..) |lineText, line| {
        if (lineText.len == 0) {
            return line;
        }
        const vshift = size * @as(f32, @floatFromInt(line));
        splat_string(x, y + vshift, lineText, color, size);
    }
    // we splat at most four lines
    return 4;
}

fn splat_string(x: f32, y: f32, text: []const u8, color: Color, size: f32) void {
    var cx = x;
    for (text) |ch| {
        render_buffer.push(.{
            .pos = .{ .x = cx, .y = y },
            .size = .{ .x = size, .y = size },
            .src_idx = ch,
            .color = color,
        });
        cx += size;
    }
}

const IterSpace = struct {
    src: []const u8,
    ix: usize = 0,

    pub fn init(src: []const u8) IterSpace {
        return .{ .src = src };
    }

    pub fn next(self: *IterSpace) ?usize {
        if (self.ix == self.src.len) {
            return null;
        }
        self.ix += 1;
        while (self.ix < self.src.len) {
            if (self.src[self.ix] == ' ') {
                return self.ix;
            }
            self.ix += 1;
        }
        return self.ix;
    }
};

fn wrapText(text: []const u8, width: i16) [4][]const u8 {
    const asdf: []const u8 = "";
    var results: [4][]const u8 = .{asdf} ** 4;
    var start: usize = 0;
    var cursor = IterSpace.init(text);
    var end: usize = start;
    outer: for (0..4) |i| {
        while (cursor.next()) |position| {
            const w = position - start - 1;
            if (w <= width) {
                end = position;
            } else {
                results[i] = text[start..end];
                start = end + 1;
                end = position;
                continue :outer;
            }
        }
        results[i] = text[start..end];
        break;
    }
    return results;
}

const SPRITE_SCALE = 16;
const SPRITE_DIM = Vec2{ .x = SPRITE_SCALE, .y = SPRITE_SCALE };

const DrawOptions = struct {
    size: f32 = 1,
    color: Color = .white,
    bgcolor: ?Color = null,
    pixel_shift: bool = false,
    origin: Vec2 = .ZERO,
};

pub fn fmt_draw_text(screen_pos: Vec2, comptime fmt: []const u8, options: DrawOptions, max_width: f32, args: anytype) f32 {
    var buffer: [256]u8 = .{0} ** 256;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch {
        return 0;
    };
    return draw_text(screen_pos, text, options, max_width);
}

pub fn draw_text(screen_pos: Vec2, text: []const u8, options: DrawOptions, max_width: f32) f32 {
    const size = SPRITE_SCALE * options.size;
    const width: i16 = @intFromFloat(@trunc(max_width / size));
    for (wrapText(text, width), 0..) |lineText, line| {
        const vshift = size * @as(f32, @floatFromInt(line));
        if (lineText.len == 0) {
            return vshift;
        }

        var at = screen_pos;
        at.y += vshift;
        for (lineText) |ch| {
            draw_glyph(at, ch, options);
            at.x += size;
        }
    }

    return size * 4;
}

pub fn draw_glyph(screen_pos: Vec2, src_idx: u8, options: DrawOptions) void {
    const dim = SPRITE_DIM.scaled(options.size);

    if (options.bgcolor) |bgcolor| {
        render_buffer.push(.{
            .pos = screen_pos.plus(options.origin),
            .size = dim,
            .color = bgcolor,
            .src_idx = 0xDB,
        });
    }

    const offset: f32 = if (options.pixel_shift)
        (SPRITE_SCALE / 16.0) * options.size
    else
        0;

    render_buffer.push(.{
        .pos = screen_pos.plus(Vec2.ONE.scaled(offset)).plus(options.origin),
        .size = dim,
        .color = options.color,
        .src_idx = src_idx,
    });
}

pub fn draw_world_glyph(world_pos: Vec2, src_idx: u8, options: DrawOptions) void {
    const screen_pos = world_pos.minus(camera.rounded(SPRITE_SCALE)).scaled(SPRITE_SCALE);
    draw_glyph(screen_pos, src_idx, options);
}

fn draw_kaiju_icon(screen_pos: Vec2, size: u8, border_color: Color, origin: Vec2) void {
    var dy: i16 = 0;
    while (dy < size) : (dy += 1) {
        var dx: i16 = 0;
        while (dx < size) : (dx += 1) {
            const pos = screen_pos.plus(.{
                .x = @as(f32, @floatFromInt(dx)) * SPRITE_SCALE,
                .y = @as(f32, @floatFromInt(dy)) * SPRITE_SCALE,
            });
            const is_top = dy == 0;
            const is_bottom = dy == size - 1;
            const is_left = dx == 0;
            const is_right = dx == size - 1;

            const glyph: u8 =
                if (is_top and is_left) 0xDA // ┌
                else if (is_top and is_right) 0xBF // ┐
                else if (is_bottom and is_left) 0xC0 // └
                else if (is_bottom and is_right) 0xD9 // ┘
                else if (is_top or is_bottom) 0xC4 // ─
                else if (is_left or is_right) 0xB3 // │
                else ' ';

            draw_glyph(pos, glyph, .{ .bgcolor = .black, .color = border_color, .origin = origin });
        }
    }
    render_buffer.flush();

    const icon: u8 = "ABCDEFGHIJKLMNOPQRS"[size - main.MIN_KAIJU_SIZE];
    draw_glyph(screen_pos.plus(.{ .x = SPRITE_SCALE, .y = SPRITE_SCALE }), icon, .{
        .bgcolor = .black,
        .color = .red,
        .size = @floatFromInt(size - 2),
        .pixel_shift = true,
        .origin = origin,
    });
    render_buffer.flush();
}

fn render_kaiju(kaiju: *const main.Unit, origin: Vec2) void {
    const is_target = main.globals.focus != 0 and
        kaiju.get_id() == main.globals.focus;
    const border_color: Color = if (is_target) .green else .magenta;
    const screen_pos = kaiju.render_position.minus(camera.rounded(SPRITE_SCALE)).scaled(SPRITE_SCALE);
    draw_kaiju_icon(screen_pos, kaiju.size, border_color, origin);
}

fn update_camera() void {
    const player = main.globals.player();
    var center = player.position.float();
    if (player.mounted()) {
        const moto = player.mount();
        const vel = moto.orientation.ivec().scaled(@intCast(moto.speed));
        const max_offset = main.FOV_RANGE - @max(camera_w, camera_h) / 2;
        var ox = @as(f32, @floatFromInt(vel.x)) * 2;
        var oy = @as(f32, @floatFromInt(vel.y)) * 2;
        ox = std.math.clamp(ox, -max_offset, max_offset);
        oy = std.math.clamp(oy, -max_offset, max_offset);
        center.x += ox;
        center.y += oy;
    }
    const ideal = Vec2{
        .x = center.x - camera_w / 2,
        .y = center.y - camera_h / 2,
    };
    const BUFFER: f32 = 5;
    const dx = ideal.x - camera_target.x;
    const dy = ideal.y - camera_target.y;
    var target = camera_target;
    if (dx > BUFFER) target.x = ideal.x - BUFFER;
    if (dx < -BUFFER) target.x = ideal.x + BUFFER;
    if (dy > BUFFER) target.y = ideal.y - BUFFER;
    if (dy < -BUFFER) target.y = ideal.y + BUFFER;
    animate_camera_to(target);
}
fn animate_camera_to(target: Vec2) void {
    const dist = camera.distance(target);
    _ = main.globals.animation_queue.force_add(
        .{ .duration = dist * 20 },
        main.animlib.linear_slide,
        .{ camera_target, target, &camera },
    ).lock_exclusive(main.animlib.lock_camera);
    camera_target = target;
}

fn render_unit(unit: *const main.Unit, origin: Vec2, t: f64) void {
    switch (unit.tag) {
        .Player => {
            draw_world_glyph(
                unit.render_position,
                '@',
                .{
                    .bgcolor = .black,
                    .origin = origin,
                },
            );
        },
        .Motorcycle => {
            const p0 = unit.render_position;
            const p1 = p0.plus(unit.render_orientation.ivec().float());
            if (map.get_render_terrain_payload_at(unit.position).seen) {
                draw_world_glyph(p0, 'o', .{ .bgcolor = .black, .origin = origin, .color = .orange });
            }
            if (map.get_render_terrain_payload_at(unit.handlepos()).seen) {
                draw_world_glyph(p1, '%', .{ .bgcolor = .black, .origin = origin, .color = .orange });
            }
        },
        .Kaiju => render_kaiju(unit, origin),
        .PendingRubble => {
            const pos = unit.render_position;
            const period = 600;
            const phase = @mod(pos.x + 3 * pos.y, 5) * period / 5;
            const blink = @mod(t + phase, period) < period / 2;
            const seen = map.get_render_terrain_payload_at(unit.position).seen;
            if (blink and seen) {
                draw_world_glyph(unit.render_position, 'X', .{
                    .color = .yellow,
                    .bgcolor = .black,
                    .origin = origin,
                });
            }
        },
        .PendingExplosion => {
            const r: f32 = @floatFromInt(unit.size);
            var iter = unit.get_rect().iter();
            while (iter.next()) |pos| {
                if (pos.float().manhattan_distance(unit.render_position) <= r) {
                    const period = 700;
                    const phase = @mod(pos.float().x + 3 * pos.float().y, 5) * period / 5;
                    const blink = @mod(t + phase, period) < period / 2;
                    const seen = map.get_render_terrain_payload_at(pos).seen;
                    if (blink and seen) {
                        draw_world_glyph(pos.float(), 'X', .{
                            .color = .red,
                            .bgcolor = .black,
                            .origin = origin,
                        });
                    }
                }
            }
        },
        else => {
            return;
        },
    }
}

pub fn bounding_box(positions: []const Vec2) Rect {
    var min_x = positions[0].x;
    var min_y = positions[0].y;
    var max_x = positions[0].x;
    var max_y = positions[0].y;
    for (positions[1..]) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    }
    return .{
        .x = min_x,
        .y = min_y,
        .w = max_x - min_x,
        .h = max_y - min_y,
    };
}

pub fn draw_rect(rect: IRect, draw_options: DrawOptions) void {
    var it = rect.iter();
    while (it.next()) |pos| {
        const is_top = pos.y == rect.y;
        const is_bottom = pos.y == rect.y + rect.h - 1;
        const is_left = pos.x == rect.x;
        const is_right = pos.x == rect.x + rect.w - 1;

        const glyph: u8 = if (is_top and is_left) 0xDA // ┌
            else if (is_top and is_right) 0xBF // ┐
            else if (is_bottom and is_left) 0xC0 // └
            else if (is_bottom and is_right) 0xD9 // ┘
            else if (is_top or is_bottom) 0xC4 // ─
            else if (is_left or is_right) 0xB3 // │
            else continue;
        draw_glyph(pos.float(), glyph, draw_options);
    }
    render_buffer.flush();
}

pub fn draw_world_rect(rect: IRect, draw_options: DrawOptions) void {
    var it = rect.iter();
    while (it.next()) |pos| {
        const is_top = pos.y == rect.y;
        const is_bottom = pos.y == rect.y + rect.h - 1;
        const is_left = pos.x == rect.x;
        const is_right = pos.x == rect.x + rect.w - 1;

        const glyph: u8 = if (is_top and is_left) 0xDA // ┌
            else if (is_top and is_right) 0xBF // ┐
            else if (is_bottom and is_left) 0xC0 // └
            else if (is_bottom and is_right) 0xD9 // ┘
            else if (is_top or is_bottom) 0xC4 // ─
            else if (is_left or is_right) 0xB3 // │
            else continue;
        draw_world_glyph(pos.float(), glyph, draw_options);
    }
    render_buffer.flush();
}

pub fn render_debug(val: anytype) void {
    const T = @TypeOf(val);
    const fields = @typeInfo(T).@"struct".fields;
    const size: f32 = 12;
    const width = 30;
    const height = 10;

    const x = 10;
    var y: f32 = 10;

    const rect: Rect = .{ .x = x, .y = y, .w = size * width, .h = size * height };
    RenderBuffer.clear_rect(rect, .blue);
    inline for (fields) |field| {
        const field_val = @field(val, field.name);
        const text = std.fmt.bufPrint(&printBuffer, "{s}: {any}", .{ field.name, field_val }) catch "...";
        _ = splat_wrap_string(x, y, text, .magenta, size, width);
        render_buffer.flush();
        y += size;
    }
}

pub fn draw_status() !void {
    const r: Rect = ui.MAIN_VIEW.get("status").float().scaled(SPRITE_SCALE);
    RenderBuffer.clear_rect(r.expand(-SPRITE_SCALE / 2), .dark_gray);
    const interior = r.expand(-SPRITE_SCALE);
    const w = interior.w;

    const player = main.globals.player();

    const opts = DrawOptions{ .origin = interior.pos() };

    var cursor: Vec2 = .ZERO;

    cursor.y += fmt_draw_text(cursor, "You", opts, w, .{});
    cursor.y += fmt_draw_text(cursor, "Hp: {}", opts, w, .{player.hp});
    cursor.y += fmt_draw_text(cursor, "\x9D: {}", opts, w, .{main.globals.money});
    cursor.y += SPRITE_SCALE;

    if (player.mounted()) {
        const mount = player.mount();
        cursor.y += fmt_draw_text(cursor, "{s}", opts, w, .{mount.model.name()});
        cursor.y += fmt_draw_text(
            cursor,
            "Hp: {}",
            opts,
            w,
            .{mount.hp},
        );
        cursor.y += draw_attrs(
            cursor.plus(.{ .x = SPRITE_SCALE * 2 }),
            false,
            &mount.model.stats(),
            "",
            opts,
            w,
        );

        cursor.y += SPRITE_SCALE;
    }

    if (inventory.has_psi()) {
        cursor.y += fmt_draw_text(
            cursor,
            "Psi: {}",
            opts,
            w,
            .{main.globals.psi},
        );
    }

    if (main.globals.combo_count > 0) {
        cursor.y += fmt_draw_text(
            cursor,
            "Precision: {}",
            opts,
            w,
            .{main.globals.combo_count},
        );
    }

    const bonuses = inventory.bonuses();
    if (bonuses.readfield(.crit3_bonus) > 0 or
        bonuses.readfield(.crit4_bonus) > 0 or
        bonuses.readfield(.crit5_bonus) > 0)
    {
        cursor.y += fmt_draw_text(
            cursor,
            "Crit Mul: {}",
            opts,
            w,
            .{main.crit_bonus()},
        );
        cursor.y += SPRITE_SCALE;
    }
}

fn draw_log() void {
    const r: Rect = ui.MAIN_VIEW.get("log").float().scaled(SPRITE_SCALE);
    RenderBuffer.clear_rect(r.expand(-SPRITE_SCALE / 2), .dark_gray);
    const interior = r.expand(-SPRITE_SCALE);

    RenderBuffer.scissor(interior);
    defer RenderBuffer.unscissor();

    var vshift: f32 = 0;
    var ix: i32 = @as(i32, @intCast(combat_log.storage.len())) - 1;
    while (ix >= 0) : (ix -= 1) {
        const entry = combat_log.storage.index(ix) orelse continue;
        const options: DrawOptions = .{
            .origin = interior.pos(),
            .color = if (entry.turn + 1 >= main.globals.turn) .white else .gray,
        };
        const h = draw_text(.{ .y = vshift, .x = 0 }, entry.text, options, interior.w - SPRITE_SCALE);
        vshift += h;
        vshift += SPRITE_SCALE;
        if (vshift >= interior.h) break;
    }
    render_buffer.flush();
}

fn draw_item_desc(pos: Vec2, item: *const inventory.Item, opts: DrawOptions, w: f32) f32 {
    var cursor: Vec2 = pos;
    if (item.tag == .Nil) {
        return 0;
    }
    cursor.y += fmt_draw_text(cursor, "{s}", opts, w, .{item.tag.name()});
    cursor.y += draw_attrs(cursor, item.tag.is_trinket(), &item.attrs, item.tag.prefix(), opts, w);
    return cursor.y - pos.y;
}

fn draw_attrs(pos: Vec2, is_bonus: bool, attrs: *const inventory.Attributes, strip_prefix: []const u8, opts: DrawOptions, w: f32) f32 {
    var cursor: Vec2 = pos;
    const bonuses = inventory.bonuses();
    for (std.enums.values(inventory.Attribute)) |attr| {
        const val = attrs.readfield(attr);
        const extra = bonuses.readfield(attr);
        if (val != 0) {
            const full_name = attr.name();
            const display_name = if (strip_prefix.len > 0 and std.mem.startsWith(u8, full_name, strip_prefix))
                full_name[strip_prefix.len..]
            else
                full_name;
            if (is_bonus or attr == .psi_reservoir) {
                cursor.y += fmt_draw_text(cursor, "{s} +{}", opts, w, .{ display_name, val });
            } else {
                if (extra != 0) {
                    cursor.y += fmt_draw_text(cursor, "{s} {} [+{}]", opts, w, .{ display_name, val, extra });
                } else {
                    cursor.y += fmt_draw_text(cursor, "{s} {}", opts, w, .{ display_name, val });
                }
            }
        }
    }
    return cursor.y - pos.y;
}

fn draw_inventory() void {
    const r: Rect = ui.MAIN_VIEW.get("inventory").float().scaled(SPRITE_SCALE);
    RenderBuffer.clear_rect(r.expand(-SPRITE_SCALE / 2), .dark_gray);
    const interior = r.expand(-SPRITE_SCALE);
    const w = interior.w;

    var cursor: Vec2 = .ZERO;
    const indent = SPRITE_SCALE * 2;

    // Pending pickups prompt
    if (inventory.has_pending_pickups()) {
        const opts = DrawOptions{ .origin = interior.pos(), .color = .orange };
        cursor.y += fmt_draw_text(cursor, "Replace an item?", opts, w, .{});
        cursor.y += draw_item_desc(
            .{ .x = indent, .y = cursor.y },
            &inventory.next_item,
            opts,
            w - indent,
        );
        cursor.y += SPRITE_SCALE;
    }

    for (0..inventory.item_capacity) |i| {
        const item = inventory.inventory[i];
        if (item.tag == .Nil) {
            _ = fmt_draw_text(cursor, "- free", .{ .origin = interior.pos() }, w, .{});
            cursor.y += 3 * SPRITE_SCALE;
            continue;
        }

        const is_active = if (inventory.get_active_index()) |s| s == i else false;
        const is_weapon = item.tag.is_weapon();

        const color: Color = if (is_active) .green else if (is_weapon) .white else Color.gray;

        const opts = DrawOptions{ .origin = interior.pos(), .color = color };

        const slot_number = (i + 1) % 10;
        _ = fmt_draw_text(cursor, "{}", opts, w, .{slot_number});
        cursor.y += draw_item_desc(
            .{ .x = SPRITE_SCALE * 2, .y = cursor.y },
            &item,
            opts,
            w,
        );
        cursor.y += SPRITE_SCALE;
    }

    render_buffer.flush();
}

fn draw_target_info() void {
    const r: Rect = ui.MAIN_VIEW.get("unitinfo").float().scaled(SPRITE_SCALE);
    RenderBuffer.clear_rect(r.expand(-SPRITE_SCALE / 2), .dark_gray);
    const interior = r.expand(-SPRITE_SCALE);

    const target_id = main.globals.focus;
    const target = main.globals.unit(target_id);
    if (target.tag == .Nil) return;
    if (!target.alive) return;

    indicate_unit(target);
    const w = interior.w;
    const opts = DrawOptions{ .origin = interior.pos() };
    var cursor: Vec2 = .ZERO;

    draw_kaiju_icon(cursor, target.size, .green, interior.pos());

    const text_x = @as(f32, @floatFromInt(target.size)) * SPRITE_SCALE + SPRITE_SCALE;
    cursor.y += SPRITE_SCALE;
    cursor.y += fmt_draw_text(.{ .x = text_x, .y = cursor.y }, "Hp: {}", opts, w, .{target.hp});
    render_buffer.flush();
}

fn draw_gamefield(t: f64) void {
    // restrict drawing to viewport interior
    const viewport: Rect = ui.MAIN_VIEW.get("viewport").float();
    const margin2 = viewport.w - camera_w;
    const interior = viewport.expand(-(margin2 / 2)).scaled(SPRITE_SCALE);
    RenderBuffer.scissor(interior);
    const origin: Vec2 = interior.pos();
    defer RenderBuffer.unscissor();

    const seen_rect = IRect{
        .x = @intFromFloat(@floor(camera.x)),
        .y = @intFromFloat(@floor(camera.y)),
        .w = @intFromFloat(camera_w + 1),
        .h = @intFromFloat(camera_h + 1),
    };

    // Draw threat indicators
    {
        var iter = sector.get_occupants_rect(seen_rect);
        while (iter.next()) |uid| {
            const u = main.globals.unit(uid);
            if (u.tag == .Kaiju) {
                const offset = u.render_position.minus(u.position.float());
                for (u.threat()) |threat_rect| {
                    var it = threat_rect.iter();
                    while (it.next()) |pos| {
                        draw_world_glyph(
                            pos.float().plus(offset),
                            0xDB,
                            .{ .color = .shadow, .origin = origin },
                        );
                    }
                }
            }
        }
    }

    // Draw the terrain
    var terrain_iter = seen_rect.iter();
    while (terrain_iter.next()) |world_pos| {
        const to_draw = map.rendered_glyph(world_pos);
        draw_world_glyph(
            world_pos.float(),
            to_draw.glyph,
            .{ .color = to_draw.color, .origin = origin },
        );
    }

    // The render buffer assumes that all images in the same batch
    // are the same size. So we flush before drawing anything at
    // a different size. (If we don't, that will resize the previous
    // images.)
    render_buffer.flush();

    // Draw units over the terrain
    {
        // motorcycles
        var iter = sector.get_occupants_rect(seen_rect);
        while (iter.next()) |uid| {
            const u = main.globals.unit(uid);
            if (u.tag == .Motorcycle) {
                render_unit(u, origin, t);
            }
        }

        // kaiju
        iter = sector.get_occupants_rect(seen_rect);
        while (iter.next()) |uid| {
            const u = main.globals.unit(uid);
            if (u.tag == .Kaiju) {
                render_unit(u, origin, t);
            }
        }

        // player
        render_unit(main.globals.player(), origin, t);

        // booms
        iter = sector.get_occupants_rect(seen_rect);
        while (iter.next()) |uid| {
            const u = main.globals.unit(uid);
            if (u.tag == .PendingExplosion or u.tag == .PendingRubble) {
                render_unit(u, origin, t);
            }
        }

        // particles
        for (main.globals.particles.data) |proj| {
            if (!proj.active) continue;
            const options: DrawOptions = .{ .origin = origin, .color = proj.color };
            draw_world_glyph(proj.pos, proj.glyph, options);
        }
    }

    // Draw movement preview reticles
    const reticles: ?[5]IVec2 = main.get_reticle_positions();
    const reticle_blink = @mod(t, 1000) < 500;
    if (reticle_blink) {
        if (reticles) |highlight| {
            const mount = main.globals.player().mount();
            const p0 = mount.position;
            const p1 = mount.position.plus(mount.orientation.ivec());
            for (highlight) |pos| {
                if (pos.eq(p0)) {
                    continue;
                }
                if (pos.eq(p1)) {
                    continue;
                }
                draw_world_glyph(pos.float(), 0x09, .{
                    .color = .cyan,
                    .origin = origin,
                });
            }
        }
    }
    render_buffer.flush();
}

pub fn draw_main_screen(t: f64) void {
    draw_gamefield(t);
    draw_status() catch |e| {
        std.log.err("draw status err {}", .{e});
    };

    indicate_unit(main.globals.kmom());

    draw_inventory();

    draw_target_info();

    // render_debug(.{ .p = inventory.has_psi() });
    var weap: ?inventory.ItemTag = null;
    if (inventory.active_weapon()) |w| {
        weap = w.tag;
    }

    draw_log();

    render_buffer.flush();
}

pub export fn frame(t: f64) void {
    const rawdt = t - prev_time;
    const dt: f32 = @floatCast(@min(20, rawdt));
    prev_time = t;

    audio.tick(dt);
    keyboard.globals.update();
    mouse.globals.update();
    main.globals.animation_queue.tick(dt);

    RenderBuffer.clear();
    switch (main.globals.gamestate) {
        .Victory, .Death => {
            if (keyboard.firstJustPressed()) |key| {
                if (key == .KeyR) {
                    _ = game_init();
                }
            }
            draw_main_screen(t);
        },
        .MainGame => {
            if (keyboard.firstJustPressed()) |key| {
                main.logic_tick(key, prng.random());
                update_camera();
            }
            draw_main_screen(t);
        },
        .TitleScreen => {
            if (keyboard.firstJustPressed()) |_| {
                main.globals.gamestate = .MainGame;
            }
            draw_title_screen(t);
        },
    }
}

pub fn draw_title_screen(t: f64) void {
    _ = t;
    const w: f32 = 1000;
    var cursor: f32 = 20;
    cursor += draw_text(.{ .x = 0, .y = cursor }, "THE STOMPING GROUNDS", .{ .color = .red }, w);
    cursor += draw_text(.{ .x = 0, .y = cursor }, "press the any key", .{ .color = .white }, w);
    render_buffer.flush();
}

pub fn indicate_unit(u: *const main.Unit) void {
    if (u.tag != .Kaiju) {
        return;
    }
    const uvec = u.get_rect().float().center()
        .minus(camera.plus(Vec2.ONE.scaled(camera_w / 2)));
    const norm = uvec.max_norm();
    const glyph: u8 = "ABCDEFGHIJKLMNOPQRS"[u.size - main.MIN_KAIJU_SIZE];
    if (norm > 30) {
        draw_indicator(uvec, glyph);
    }
}

pub fn draw_indicator(v: Vec2, glyph: u8) void {
    const r = ui.MAIN_VIEW.get("viewport").float().scaled(SPRITE_SCALE);
    const center = edge_point(r.expand(-SPRITE_SCALE * 2), v);
    const corner = center.minus(Vec2.ONE.scaled(SPRITE_SCALE / 2));
    draw_glyph(corner, glyph, .{ .color = .red });
}

// Casts a ray from the center of `rect` in the given `dir`ection,
// returning the point where it exits the rectangle boundary.
fn edge_point(rect: Rect, dir: Vec2) Vec2 {
    const cx = rect.x + rect.w * 0.5;
    const cy = rect.y + rect.h * 0.5;
    const hw = rect.w * 0.5;
    const hh = rect.h * 0.5;

    // Scale factor needed to reach each edge
    const tx: f32 = if (dir.x > 0) hw / dir.x else if (dir.x < 0) -hw / dir.x else std.math.inf(f32);
    const ty: f32 = if (dir.y > 0) hh / dir.y else if (dir.y < 0) -hh / dir.y else std.math.inf(f32);

    const t = @min(tx, ty);

    return .{
        .x = cx + dir.x * t,
        .y = cy + dir.y * t,
    };
}
