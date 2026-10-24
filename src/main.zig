const std = @import("std");
const Io = std.Io;
const render = @import("render.zig");
const svgimport = @import("svgimport.zig");
const levelplayer = @import("levelplayer.zig");

pub fn main(init: std.process.Init) !void {
    var renderer: render.Renderer = undefined;
    try renderer.init(init.gpa);
    defer renderer.deinit(init.gpa);

    var frame_arena_obj = std.heap.ArenaAllocator.init(init.gpa);
    const frame_arena = frame_arena_obj.allocator();
    defer frame_arena_obj.deinit();

    var level: svgimport.ImportedLevel = .{};
    try level.init("asset/template.svg", init.io, init.gpa);
    defer level.deinit();

    var player: levelplayer.LevelPlayer = undefined;
    try player.load(&level, init.gpa);
    defer player.deinit();

    var playback_frame: u64 = 0;
    while (!renderer.window.shouldClose()) {
        const frame = try player.generateFrame(playback_frame);

        for (frame.lines) |line| {
            try renderer.drawLine(.{
                .color = line.color,
                .style = .solid_color,
                .blend_mode = .mix,
                .width = line.width,
                .start = .{ .x = @intFromFloat(line.x0), .y = @intFromFloat(line.y0) },
                .end = .{ .x = @intFromFloat(line.x1), .y = @intFromFloat(line.y1) },
            });
        }

        try renderer.frame(init.gpa, frame_arena);
        playback_frame += 1;
        playback_frame = @mod(playback_frame, level.length);

        _ = frame_arena_obj.reset(.retain_capacity);
    }
}
