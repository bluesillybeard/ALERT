// TODO: perhaps put this in some kind of config?
// To be honest though, for this game I see no need to change it at runtime.
const MAX_LINES = 10000;

// The spatial partitioning tiles are NxN pixels in size
const TILE_SIZE = 64;

// The maximum distance a line may be to still be included in the
const TILE_MARGIN = @as(comptime_float, TILE_SIZE) / 2.0 * @sqrt(2.0);

// First version with SSBOs, so I can just excrete the line data into a buffer that the pixel shader refines
// A sane renderer would convert the lines to meshes or w/e but frankly I can't be bothered.
// (plus using what is basically a per-pixel compute shader has some neat benefits)
const GL_VERSION_MAJOR = 4;
const GL_VERSION_MINOR = 3;

const glfw = @import("zglfw");
const opengl = @import("opengl");
const gl = opengl.bindings;

const std = @import("std");

pub const LineStyle = enum(u8) {
    solid_color = 0,
    drop_linear,
    decay_linear,
    decay_quadratic,
    decay_quintic,
};

pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Pos = packed struct(u32) {
    x: u16,
    y: u16,
};

pub const BlendMode = enum(u8) {
    add = 0,
    mix,
};

pub const Line = packed struct(u128) {
    color: Color,
    // These are in pixel coordinates (if you have more than a 65k x 65k monitor playing this game... I'm sorry.)
    start: Pos,
    end: Pos,
    // width is in half pixels
    width: u8,
    style: LineStyle,
    blend_mode: BlendMode = .add,
    // whatever was left over such that the bit size of this type is 128 (also checked by the zig compiler)
    leftover: u8 = undefined,
};

// This is a one-to-one translation of the function found in the fragment shader to find line distance
fn line_segment_distance_square(start: Pos, end: Pos, p: Pos) f32 {
    const lx0: f32 = @floatFromInt(start.x);
    const ly0: f32 = @floatFromInt(start.y);
    const lx1: f32 = @floatFromInt(end.x);
    const ly1: f32 = @floatFromInt(end.y);
    const x: f32 = @floatFromInt(p.x);
    const y: f32 = @floatFromInt(p.y);

    const ux = lx1 - lx0;
    const uy = ly1 - ly0;

    if (ux == 0 and uy == 0) {
        const dx = x - lx1;
        const dy = y - ly1;
        return dx * dx + dy * dy;
    }

    const vx = x - lx0;
    const vy = y - ly0;

    const t = (ux * vx + uy * vy) / (ux * ux + uy * uy);

    if (t < 0) {
        const dx = x - lx0;
        const dy = y - ly0;
        return dx * dx + dy * dy;
    } else if (t > 1) {
        const dx = x - lx1;
        const dy = y - ly1;
        return dx * dx + dy * dy;
    } else {
        const zx = lx0 + t * ux;
        const zy = ly0 + t * uy;
        const dx = x - zx;
        const dy = y - zy;
        return dx * dx + dy * dy;
    }
}

// TODO: I don't think renderer is the right word here since it does both the window, graphics, and user-input
// Yes I am aware this violates the single responsibility principle but this is a game jam so screw you
pub const Renderer = struct {
    window: *glfw.Window,

    lines: std.ArrayList(Line),

    program_id: gl.Uint,

    lines_buffer_id: gl.Uint,
    tiles_buffer_id: gl.Uint,
    tile_indices_buffer_id: gl.Uint,

    vao_id: gl.Uint,

    pub fn init(this: *Renderer, allocator: std.mem.Allocator) !void {
        try glfw.init();
        glfw.windowHint(glfw.WindowHint.context_version_major, GL_VERSION_MAJOR);
        glfw.windowHint(glfw.WindowHint.context_version_minor, GL_VERSION_MINOR);
        glfw.windowHint(glfw.WindowHint.red_bits, 8);
        glfw.windowHint(glfw.WindowHint.green_bits, 8);
        glfw.windowHint(glfw.WindowHint.blue_bits, 8);
        glfw.windowHint(glfw.WindowHint.alpha_bits, 8);
        // We don't need a depth buffer... at all. No depth buffer. Don't give me one. Don't offer one. Don't even bother to allocate one.
        glfw.windowHint(glfw.WindowHint.depth_bits, 0);

        glfw.swapInterval(1);

        const window = try glfw.createWindow(800, 600, "ALERT", null, null);
        glfw.makeContextCurrent(window);

        try opengl.loadCoreProfile(glfw.getProcAddress, 4, 3);

        // This is so all this interesting stuff shows up in frame 1 in apitrace
        // GLFW and EGL end up creating a lot of noise on init, so this makes the actual init that we care about easier to find among all of that in a trace.
        gl.clearColor(0, 0, 0, 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        window.swapBuffers();

        // Load the shaders (which are rather basic)
        const vertex_shader_id = gl.createShader(gl.VERTEX_SHADER);
        const vertex_shader_source = @embedFile("shader.vert.glsl");
        const ptr_to_vertex_shader_source = &vertex_shader_source;
        gl.shaderSource(vertex_shader_id, 1, @ptrCast(ptr_to_vertex_shader_source), null);
        gl.compileShader(vertex_shader_id);
        var shader_result: c_int = gl.TRUE;
        gl.getShaderiv(vertex_shader_id, gl.COMPILE_STATUS, &shader_result);
        if (shader_result == gl.FALSE) {
            var log_length: c_int = 0;
            gl.getShaderiv(vertex_shader_id, gl.INFO_LOG_LENGTH, &log_length);
            const log = try allocator.alloc(u8, @intCast(log_length));
            gl.getShaderInfoLog(vertex_shader_id, log_length, &log_length, log.ptr);
            std.log.err("Failed to compile vertex shader: {s}\n", .{log});
            allocator.free(log);
            return error.init;
        }

        const fragment_shader_id = gl.createShader(gl.FRAGMENT_SHADER);
        const fragment_shader_source = @embedFile("shader.frag.glsl");
        const ptr_to_fragment_shader_source = &fragment_shader_source;
        const fragment_shader_source_len: c_int = @intCast(fragment_shader_source.len);
        gl.shaderSource(fragment_shader_id, 1, @ptrCast(ptr_to_fragment_shader_source), &fragment_shader_source_len);
        gl.compileShader(fragment_shader_id);
        shader_result = gl.TRUE;
        gl.getShaderiv(fragment_shader_id, gl.COMPILE_STATUS, &shader_result);
        if (shader_result == gl.FALSE) {
            var log_length: c_int = 0;
            gl.getShaderiv(fragment_shader_id, gl.INFO_LOG_LENGTH, &log_length);
            const log = try allocator.alloc(u8, @intCast(log_length));
            gl.getShaderInfoLog(fragment_shader_id, log_length, &log_length, log.ptr);
            std.log.err("Failed to compile fragment shader: {s}\n", .{log});
            allocator.free(log);
            return error.init;
        }

        const program_id = gl.createProgram();
        gl.attachShader(program_id, vertex_shader_id);
        gl.attachShader(program_id, fragment_shader_id);
        gl.linkProgram(program_id);
        shader_result = gl.TRUE;
        gl.getProgramiv(program_id, gl.LINK_STATUS, &shader_result);
        if (shader_result == gl.FALSE) {
            var log_length: c_int = 0;
            gl.getProgramiv(program_id, gl.INFO_LOG_LENGTH, &log_length);
            const log = try allocator.alloc(u8, @intCast(log_length));
            gl.getProgramInfoLog(program_id, log_length, null, log.ptr);
            std.log.err("Failed to link shaders: {s}\n", .{log});
            allocator.free(log);
            return error.init;
        }
        gl.deleteShader(vertex_shader_id);
        gl.deleteShader(fragment_shader_id);

        var lines_buffer: gl.Uint = 0;
        gl.genBuffers(1, &lines_buffer);

        var tiles_buffer: gl.Uint = 0;
        gl.genBuffers(1, &tiles_buffer);

        var tile_indices_buffer: gl.Uint = 0;
        gl.genBuffers(1, &tile_indices_buffer);

        // Apparently I still need a VAO despite not using any vertex buffer of any sort
        // Seriously, OpenGL, I am literally creating an empty VAO for no reason. I don't have as much as a single attribute.
        var vao_id: c_uint = 0;
        gl.genVertexArrays(1, &vao_id);

        this.* = .{
            .window = window,
            .lines = try .initCapacity(allocator, MAX_LINES),
            .program_id = program_id,
            .lines_buffer_id = lines_buffer,
            .tiles_buffer_id = tiles_buffer,
            .tile_indices_buffer_id = tile_indices_buffer,
            .vao_id = vao_id,
        };
    }

    pub fn drawLine(this: *Renderer, line: Line) !void {
        try this.lines.appendBounded(line);
    }

    pub fn frame(this: *Renderer, allocator: std.mem.Allocator, temp_alloc: std.mem.Allocator) !void {
        _ = allocator;
        const window_size = this.window.getSize();
        const window_width: f32 = @floatFromInt(window_size[0]);
        const window_height: f32 = @floatFromInt(window_size[1]);

        // Figure out the window size
        // Basically we need to reframe 1920x1080 into the size of the window while keeping the aspect ratio
        const ratio_x = window_width / 1920.0;
        const ratio_y = window_height / 1080.0;
        const scale = @min(ratio_x, ratio_y);

        // Set the viewport to clip everything outside the aspect ratio
        const new_width = scale * 1920;
        const new_height = scale * 1080;
        const offset_x = (window_width - new_width) / 2;
        const offset_y = (window_height - new_height) / 2;
        gl.viewport(@intFromFloat(offset_x), @intFromFloat(offset_y), @intFromFloat(new_width), @intFromFloat(new_height));

        // move all of the lines
        for (this.lines.items) |*line| {
            line.start.x = @intFromFloat(line.start.x * scale + offset_x);
            line.start.y = @intFromFloat(line.start.y * scale + offset_y);
            line.end.x = @intFromFloat(line.end.x * scale + offset_x);
            line.end.y = @intFromFloat(line.end.y * scale + offset_y);
            line.width = @max(@as(u8, @intFromFloat(line.width * scale)), 2);
        }

        // Upload new lines
        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, this.lines_buffer_id);
        gl.bufferData(gl.SHADER_STORAGE_BUFFER, @intCast(this.lines.items.len * @sizeOf(Line)), this.lines.items.ptr, gl.DYNAMIC_DRAW);

        // Update tile buffer
        const num_x_tiles: u32 = @intCast(@divTrunc(window_size[0] - 1, TILE_SIZE) + 1);
        const num_y_tiles: u32 = @intCast(@divTrunc(window_size[1] - 1, TILE_SIZE) + 1);
        const num_total_tiles = num_x_tiles * num_y_tiles;

        // Go through each tile and make a list of the lines that touch it.
        const tile_indices = try temp_alloc.alloc(u32, num_total_tiles);
        var tile_data = try std.ArrayList(u32).initCapacity(temp_alloc, num_total_tiles * (MAX_LINES + 1));
        for (0..num_total_tiles) |tile_index| {
            const tile_x = tile_index % num_x_tiles;
            const tile_y = tile_index / num_x_tiles;
            const tile_pixel_x: u16 = @intCast(tile_x * TILE_SIZE + TILE_SIZE / 2);
            const tile_pixel_y: u16 = @intCast(tile_y * TILE_SIZE + TILE_SIZE / 2);

            const start_index = tile_data.items.len;
            // Allocate the space for the #of lines in this tile
            try tile_data.appendBounded(0);
            var tile_num_lines: u32 = 0;
            for (0..this.lines.items.len) |line_index| {
                const line = this.lines.items[line_index];
                const distance_to_tile = line_segment_distance_square(line.start, line.end, .{ .x = tile_pixel_x, .y = tile_pixel_y });
                const compare_to = TILE_MARGIN + @as(f32, @floatFromInt(line.width)) / 2.0;
                if (distance_to_tile < compare_to * compare_to) {
                    try tile_data.appendBounded(@intCast(line_index));
                    tile_num_lines += 1;
                }
            }
            tile_data.items[start_index] = tile_num_lines;
            tile_indices[tile_index] = @intCast(start_index);
        }

        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, this.tile_indices_buffer_id);
        gl.bufferData(gl.SHADER_STORAGE_BUFFER, @intCast(tile_indices.len * @sizeOf(u32)), tile_indices.ptr, gl.DYNAMIC_DRAW);

        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, this.tiles_buffer_id);
        gl.bufferData(gl.SHADER_STORAGE_BUFFER, @intCast(tile_data.items.len * @sizeOf(u32)), tile_data.items.ptr, gl.DYNAMIC_DRAW);

        // Draw
        gl.clear(gl.COLOR_BUFFER_BIT);

        const lines_buffer_resource_index = gl.getProgramResourceIndex(this.program_id, gl.SHADER_STORAGE_BLOCK, "lines");
        gl.shaderStorageBlockBinding(this.program_id, lines_buffer_resource_index, 0);

        const tiles_buffer_resource_index = gl.getProgramResourceIndex(this.program_id, gl.SHADER_STORAGE_BLOCK, "tiles");
        gl.shaderStorageBlockBinding(this.program_id, tiles_buffer_resource_index, 1);

        const tile_indices_buffer_resource_index = gl.getProgramResourceIndex(this.program_id, gl.SHADER_STORAGE_BLOCK, "tile_indices");
        gl.shaderStorageBlockBinding(this.program_id, tile_indices_buffer_resource_index, 2);

        gl.useProgram(this.program_id);
        gl.bindVertexArray(this.vao_id);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, this.lines_buffer_id);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, this.tiles_buffer_id);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, this.tile_indices_buffer_id);
        gl.uniform1ui(0, @intCast(this.lines.items.len));
        gl.uniform1ui(1, @intCast(num_x_tiles));
        gl.uniform1ui(2, @intCast(num_y_tiles));
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        this.window.swapBuffers();

        this.lines.clearRetainingCapacity();

        // TODO: Polling events should really be done per-update and not per frame
        glfw.pollEvents();
    }

    pub fn deinit(this: *Renderer, allocator: std.mem.Allocator) void {
        this.lines.deinit(allocator);
        glfw.destroyWindow(this.window);
        glfw.terminate();
    }
};
