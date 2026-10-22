const std = @import("std");
const Io = std.Io;
const render = @import("render.zig");

pub fn main(init: std.process.Init) !void {
    var renderer: render.Renderer = undefined;
    try renderer.init(init.gpa);
    defer renderer.deinit(init.gpa);

    var frame_arena_obj = std.heap.ArenaAllocator.init(init.gpa);
    const frame_arena = frame_arena_obj.allocator();
    defer frame_arena_obj.deinit();

    while(!renderer.window.shouldClose()) {
        try renderer.lines.append(init.gpa, .{
            .color = .{.r = 100, .g = 50, .b = 100, .a = 255},
            .start = .{.x = 50, .y = 50},
            .end = .{.x = 50, .y = 100},
            .style = .decay_linear,
            .width = 20,
        });
        
        try renderer.frame(init.gpa, frame_arena);

        _ = frame_arena_obj.reset(.retain_capacity);
    }
}
