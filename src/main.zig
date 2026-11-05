const std = @import("std");
const Io = std.Io;
const render = @import("render.zig");
const svgimport = @import("svgimport.zig");
const levelplayer = @import("levelplayer.zig");

const level_path = "asset/animation_tests.svg";

pub fn main(init: std.process.Init) !void {
    var renderer: render.Renderer = undefined;
    try renderer.init(init.gpa);
    defer renderer.deinit(init.gpa);

    var frame_arena_obj = std.heap.ArenaAllocator.init(init.gpa);
    const frame_arena = frame_arena_obj.allocator();
    defer frame_arena_obj.deinit();

    var level: svgimport.ImportedLevel = .{};
    try level.init(level_path, init.io, init.gpa);
    defer level.deinit();

    var player: levelplayer.LevelPlayer = undefined;
    try player.load(&level, init.gpa);
    defer player.deinit();

    var reload_key_was_down: bool = false;
    var playback_frame: u64 = 0;
    var tick_time: i96 = std.Io.Clock.awake.now(init.io).toNanoseconds();
    var last_frame_time: i96 = 0;
    const fixed_step_delta: i96 = std.time.ns_per_s / 60;
    while (!renderer.window.shouldClose()) {
        const fstart = std.Io.Clock.awake.now(init.io).toNanoseconds();
        last_frame_time = fstart;
        
        var num_ticks: usize = 0;
        if(fstart - tick_time >= fixed_step_delta*10) {
            std.log.info("Really bad lag frame: {}ns too long. Skipping.", .{fstart - tick_time - fixed_step_delta});
            tick_time = fstart - fixed_step_delta*9;
        } else if(fstart - tick_time >= fixed_step_delta*2) {
            std.log.info("Lag frame: {}ns too long", .{fstart - tick_time - fixed_step_delta});
        }
        while(fstart - tick_time >= fixed_step_delta) {
            const frame = try player.generateFrame(playback_frame, 0);
            _ = frame;
            // TODO: this is where tick logic shall go

            playback_frame += 1;
            playback_frame = @mod(playback_frame, level.length);
            tick_time += fixed_step_delta;
            num_ticks += 1;
        }

        if (!reload_key_was_down and renderer.window.getKey(.h) == .press) {
            std.log.info("Reloading {s}", .{level_path});
            player.deinit();
            level.deinit();
            try level.init(level_path, init.io, init.gpa);
            try player.load(&level, init.gpa);
        }
        reload_key_was_down = renderer.window.getKey(.h) == .press;

        const partial = @as(f32, @floatFromInt(fstart - tick_time)) / @as(f32, @floatFromInt(fixed_step_delta));
        const frame = try player.generateFrame(playback_frame, partial);

        for (frame.lines) |line| {
            var style: render.LineStyle = undefined;
            var mode: render.BlendMode = undefined;
            switch (line.style) {
                .basic => {
                    style = .solid_color;
                    mode = .add;
                },
                .blended => {
                    style = .solid_color;
                    mode = .mix;
                },
                .glowing => {
                    style = .decay_quadratic;
                    mode = .add;
                },
                .both => {
                    style = .decay_quadratic;
                    mode = .mix;
                },
            }
            try renderer.drawLine(.{
                .color = line.color,
                .style = style,
                .blend_mode = mode,
                .width = line.width,
                .start = .{ .x = @intFromFloat(line.x0), .y = @intFromFloat(line.y0) },
                .end = .{ .x = @intFromFloat(line.x1), .y = @intFromFloat(line.y1) },
            });
        }

        try renderer.frame(init.gpa, frame_arena);

        _ = frame_arena_obj.reset(.retain_capacity);
    }
}
