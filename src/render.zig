const GL_VERSION_MAJOR = 2;
const GL_VERSION_MINOR = 1;

// It might make more sense to instead use some kind of circle mask texture but we'll see what happens
const CAP_POINTS = 8;

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

// There is no need for this to be packed anymore (at least for now) since we have completely switched how the rendering works.
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

    position_buffer_id: gl.Uint,
    color_buffer_id: gl.Uint,
    distance_buffer_id: gl.Uint,
    style_buffer_id: gl.Uint,
    index_buffer_id: gl.Uint,

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

        try opengl.loadCoreProfile(glfw.getProcAddress, GL_VERSION_MAJOR, GL_VERSION_MINOR);

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

        // attribute vec2 pos;
        // attribute vec4 col;
        // attribute float dis;
        // attribute float sty;

        var position_buffer: gl.Uint = 0;
        var color_buffer: gl.Uint = 0;
        var distance_buffer: gl.Uint = 0;
        var style_buffer: gl.Uint = 0;
        var index_buffer: gl.Uint = 0;
        gl.genBuffers(1, &position_buffer);
        gl.genBuffers(1, &color_buffer);
        gl.genBuffers(1, &distance_buffer);
        gl.genBuffers(1, &style_buffer);
        gl.genBuffers(1, &index_buffer);

        var vao_id: gl.Uint = 0;
        gl.genVertexArrays(1, &vao_id);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(f32), 0);
        gl.vertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, gl.TRUE, 4, 0);
        gl.vertexAttribPointer(2, 1, gl.FLOAT, gl.FALSE, 1 * @sizeOf(f32), 0);
        gl.vertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, 1 * @sizeOf(f32), 0);

        this.* = .{
            .window = window,
            .lines = .empty,
            .program_id = program_id,
            .position_buffer_id = position_buffer,
            .color_buffer_id = color_buffer,
            .distance_buffer_id = distance_buffer,
            .style_buffer_id = style_buffer,
            .index_buffer_id = index_buffer,
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

        const num_vertices = this.lines.items.len * (CAP_POINTS * 2 + 2);
        const num_elements = this.lines.items.len * (CAP_POINTS * 4);

        const pos_buffer_data = try temp_alloc.alloc(f32, num_vertices * 2);
        const color_buffer_data = try temp_alloc.alloc(u32, num_vertices);
        const distance_buffer_data = try temp_alloc.alloc(f32, num_vertices);
        const style_buffer_data = try temp_alloc.alloc(f32, num_vertices);
        const index_buffer_data = try temp_alloc.alloc(u32, num_elements);
        _ = pos_buffer_data;
        _ = color_buffer_data;
        _ = distance_buffer_data;
        _ = style_buffer_data;
        _ = index_buffer_data;

        for (this.lines.items, 0..) |line, i| {
            const vertex_buffer_offset = i * (CAP_POINTS * 2 + 2);
            const element_buffer_offset = i * (CAP_POINTS * 4);
            // Vertex Buffer ordering:
            // x start cap points
            // start cap point
            // x end cap points
            // end cap point
            // TODO: generate lines
            _ = vertex_buffer_offset;
            _ = element_buffer_offset;
            _ = line;
        }

        // Draw
        gl.clear(gl.COLOR_BUFFER_BIT);

        // TODO: draw
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
