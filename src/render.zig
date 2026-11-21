const GL_VERSION_MAJOR = 2;
const GL_VERSION_MINOR = 1;

// It might make more sense to instead use some kind of circle mask texture but we'll see what happens
const CAP_POINTS = 4;

const glfw = @import("zglfw");
const opengl = @import("opengl");
const gl = opengl.bindings;

const std = @import("std");

// TODO: There is no need for this to be packed anymore (at least for now) since we have completely switched how the rendering works.
pub const LineStyle = enum(u8) {
    solid_color = 0,
    drop_linear,
    decay_linear,
    decay_quadratic,
    decay_quintic,
};

// TODO: There is no need for this to be packed anymore (at least for now) since we have completely switched how the rendering works.
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

// TODO: There is no need for this to be packed anymore (at least for now) since we have completely switched how the rendering works.
pub const Pos = packed struct(u32) {
    x: i16,
    y: i16,
};

// TODO: There is no need for this to be packed anymore (at least for now) since we have completely switched how the rendering works.
pub const BlendMode = enum(u8) {
    add = 0,
    mix,
};

// TODO: There is no need for this to be packed anymore (at least for now) since we have completely switched how the rendering works.
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
    element_buffer_id: gl.Uint,

    // vao_id: gl.Uint,

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

        gl.bindAttribLocation(program_id, 0, "pos");
        gl.bindAttribLocation(program_id, 1, "col");
        gl.bindAttribLocation(program_id, 2, "dis");
        gl.bindAttribLocation(program_id, 3, "sty");

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

        // Dang vaos don't exist yet (OpenGL 2.1)
        //var vao_id: gl.Uint = 0;
        //gl.genVertexArrays(1, &vao_id);

        this.* = .{
            .window = window,
            .lines = .empty,
            .program_id = program_id,
            .position_buffer_id = position_buffer,
            .color_buffer_id = color_buffer,
            .distance_buffer_id = distance_buffer,
            .style_buffer_id = style_buffer,
            .element_buffer_id = index_buffer,
            // .vao_id = vao_id,
        };
    }

    pub fn drawLine(this: *Renderer, temp_alloc: std.mem.Allocator, line: Line) !void {
        try this.lines.append(temp_alloc, line);
    }

    pub fn frame(this: *Renderer, allocator: std.mem.Allocator, temp_alloc: std.mem.Allocator) !void {
        // This entire area is purely visual; no need for deterministic or precise behavior
        // I do really really REALLY appreciate that in Zig you can do this, because over in C land we are stuck either manually thinking about clock cycles and FMA or just throwing -ffast-math over the whole program and hoping for the best (rarely goes well for large projects)
        @setFloatMode(.optimized);
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
        const num_elements = this.lines.items.len * ((CAP_POINTS - 1) * 6 + 6);

        const pos_buffer_data = try temp_alloc.alloc(f32, num_vertices * 2);
        const color_buffer_data = try temp_alloc.alloc(u32, num_vertices);
        const distance_buffer_data = try temp_alloc.alloc(f32, num_vertices);
        const style_buffer_data = try temp_alloc.alloc(f32, num_vertices);
        const element_buffer_data = try temp_alloc.alloc(u32, num_elements);

        for (this.lines.items, 0..) |line, i| {
            const main_vertex_buffer_offset = i * (CAP_POINTS * 2 + 2);
            const main_element_buffer_offset = i * ((CAP_POINTS - 1) * 6 + 6);
            // Vertex Buffer ordering:
            // x start cap points
            // start cap point
            // x end cap points
            // end cap point

            // dx is reversed for a good reason, it's just how the math works out.
            const dx: f32 = @floatFromInt(line.start.x - line.end.x);
            const dy: f32 = @floatFromInt(line.end.y - line.start.y);
            const len = @sqrt(dx * dx + dy * dy);
            if (len == 0) {
                // TODO: point line
                continue;
            }
            for (0..2) |start_or_end| {
                const vertex_buffer_offset = main_vertex_buffer_offset + start_or_end * (CAP_POINTS + 1);
                // Really I ought to just switch this while thing to use floats, they are easier to deal with and I don't need scale-independent precision.
                const sx: f32 = @floatFromInt(if (start_or_end == 0) line.start.x else line.end.x);
                const sy: f32 = @floatFromInt(if (start_or_end == 0) line.start.y else line.end.y);
                const dir_multiplier: f32 = if (start_or_end == 0) 1 else -1;

                pos_buffer_data[vertex_buffer_offset * 2 + 0] = (sx * 2 / window_width) - 1;
                pos_buffer_data[vertex_buffer_offset * 2 + 1] = -(sy * 2 / window_height) + 1;
                color_buffer_data[vertex_buffer_offset] = @bitCast(line.color);
                distance_buffer_data[vertex_buffer_offset] = 0.0;
                style_buffer_data[vertex_buffer_offset] = @floatFromInt(@intFromEnum(line.style));

                for (0..CAP_POINTS) |pi| {
                    // Angle in radians around the cap, in a particular direction from the bottom cap point
                    const angle: f32 = @as(f32, std.math.pi) * @as(f32, @floatFromInt(pi)) / @as(f32, @floatFromInt(CAP_POINTS - 1)) * dir_multiplier;
                    const cos = @cos(angle);
                    const sin = @sin(angle);
                    // TODO: how does the compiler optimize this? Does it use FMA instructions or SIMD or whatever?
                    const px = sx + line.width * (dx * sin + dy * cos) / len / 2;
                    const py = sy + dir_multiplier * line.width * (dx * cos + dy * sin) / len / 2;

                    pos_buffer_data[(vertex_buffer_offset + pi + 1) * 2 + 0] = (px * 2 / window_width) - 1;
                    pos_buffer_data[(vertex_buffer_offset + pi + 1) * 2 + 1] = -(py * 2 / window_height) + 1;
                    color_buffer_data[vertex_buffer_offset + pi + 1] = @bitCast(line.color);
                    distance_buffer_data[vertex_buffer_offset + pi + 1] = 1.0;
                    style_buffer_data[vertex_buffer_offset + pi + 1] = @floatFromInt(@intFromEnum(line.style));
                }
            }

            // For a cap size of two, it looks like this:
            // 1 0 2,2 0 3,3 0 4 | 6 5 7,7 5 8,8 5 9 | 1 9 6,6 4 1
            // For the start cap, end cap, and beam respectively.
            // To help compress the code a bit the start and end beams are done at once.
            // Caps
            for (0..2) |start_or_end| {
                const element_buffer_offset = main_element_buffer_offset + start_or_end * (CAP_POINTS - 1) * 3;
                const point_index = main_element_buffer_offset + start_or_end * (CAP_POINTS + 1);
                for (0..(CAP_POINTS - 1)) |pi| {
                    element_buffer_data[element_buffer_offset + pi * 3] = @intCast(point_index + pi + 1);
                    element_buffer_data[element_buffer_offset + pi * 3 + 1] = @intCast(point_index);
                    element_buffer_data[element_buffer_offset + pi * 3 + 2] = @intCast(point_index + pi + 2);
                }
            }

            // Beam
            const element_buffer_offset = main_element_buffer_offset + 2 * (CAP_POINTS - 1) * 3;
            const start_point_index = main_element_buffer_offset;
            const end_point_index = main_element_buffer_offset + CAP_POINTS + 1;
            element_buffer_data[element_buffer_offset + 0] = @intCast(start_point_index + 1);
            element_buffer_data[element_buffer_offset + 1] = @intCast(end_point_index + CAP_POINTS);
            element_buffer_data[element_buffer_offset + 2] = @intCast(end_point_index + 1);
            element_buffer_data[element_buffer_offset + 3] = @intCast(end_point_index + 1);
            element_buffer_data[element_buffer_offset + 4] = @intCast(start_point_index + CAP_POINTS);
            element_buffer_data[element_buffer_offset + 5] = @intCast(start_point_index + 1);
        }

        // std.log.debug("Element buffer: {any}", .{element_buffer_data});

        gl.bindBuffer(gl.ARRAY_BUFFER, this.position_buffer_id);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(num_vertices * 2 * @sizeOf(f32)), pos_buffer_data.ptr, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.color_buffer_id);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(num_vertices * @sizeOf(u32)), color_buffer_data.ptr, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.distance_buffer_id);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(num_vertices * @sizeOf(f32)), distance_buffer_data.ptr, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.style_buffer_id);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(num_vertices * @sizeOf(f32)), style_buffer_data.ptr, gl.DYNAMIC_DRAW);
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.element_buffer_id);
        gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(num_elements * @sizeOf(u32)), element_buffer_data.ptr, gl.DYNAMIC_DRAW);

        // Draw
        gl.clear(gl.COLOR_BUFFER_BIT);

        gl.useProgram(this.program_id);

        gl.bindBuffer(gl.ARRAY_BUFFER, this.position_buffer_id);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(f32), null);

        gl.bindBuffer(gl.ARRAY_BUFFER, this.color_buffer_id);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, gl.TRUE, 4, null);

        gl.bindBuffer(gl.ARRAY_BUFFER, this.distance_buffer_id);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 1, gl.FLOAT, gl.FALSE, @sizeOf(f32), null);

        gl.bindBuffer(gl.ARRAY_BUFFER, this.style_buffer_id);
        gl.enableVertexAttribArray(3);
        gl.vertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, @sizeOf(f32), null);

        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.element_buffer_id);
        gl.drawElements(gl.TRIANGLES, @intCast(num_elements), gl.UNSIGNED_INT, null);

        this.window.swapBuffers();

        this.lines.clearRetainingCapacity();

        // TODO: Polling events should really be done per-update and not per frame
        glfw.pollEvents();
    }

    pub fn deinit(this: *Renderer, allocator: std.mem.Allocator) void {
        _ = allocator;
        glfw.destroyWindow(this.window);
        glfw.terminate();
    }
};
