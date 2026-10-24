const std = @import("std");
const Io = std.Io;
const render = @import("render.zig");
const svgimport = @import("svgimport.zig");

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

    while (!renderer.window.shouldClose()) {
        // Draw everything from all the frames cause yeah
        for(level.frames) |frame| {
            for(frame.lines) |line| {
                try renderer.drawLine(.{
                    .color = line.color,
                    .style = .solid_color,
                    .blend_mode = .mix,
                    .width = line.width,
                    .start = .{.x = @intFromFloat(line.x0), .y = @intFromFloat(line.y0)},
                    .end = .{.x = @intFromFloat(line.x1), .y = @intFromFloat(line.y1)},
                });
            }
        }

        inline for (@typeInfo(render.LineStyle).@"enum".fields, 0..) |st, i| {
            try renderer.drawLine(.{
                .color = .{ .r = 100, .g = 50, .b = 100, .a = 255 },
                .start = .{ .x = 200 + 120 * i, .y = 50 },
                .end = .{ .x = 50 + 120 * i, .y = 550 },
                .style = @enumFromInt(st.value),
                .width = 50,
            });
        }

        inline for (@typeInfo(render.LineStyle).@"enum".fields, 0..) |st, i| {
            try renderer.drawLine(.{
                .color = .{ .r = 150, .g = 25, .b = 25, .a = 250 },
                .start = .{ .x = 50, .y = 200 + 80 * i },
                .end = .{ .x = 750, .y = 50 + 80 * i},
                .style = @enumFromInt(st.value),
                .width = 40,
                .blend_mode = .mix,
            });
        }

        try renderer.frame(init.gpa, frame_arena);

        _ = frame_arena_obj.reset(.retain_capacity);
    }
}
