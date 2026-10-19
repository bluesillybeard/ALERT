const std = @import("std");
const Io = std.Io;

const glfw = @import("zglfw");
const opengl = @import("opengl");

// TODO: perhaps put this in some kind of config?
// To be honest though, for this game I see no need to change it at runtime.
const MAX_LINES = 10000;

// The spatial partitioning tiles are NxN pixels in size
const TILE_SIZE = 64;

// The maximum distance a line may be to still be included in the
const TILE_MARGIN = @as(comptime_float, TILE_SIZE) / 2.0 * @sqrt(2.0);

const LineStyle = enum(u8) {
    solid_color = 0,
    drop_linear,
    decay_linear,
    decay_quadratic,
    decay_quintic,
};

const CPULine = struct {
    color: [4]u8,
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
    vx0: f32,
    vy0: f32,
    vx1: f32,
    vy1: f32,
    width: u8,
    style: LineStyle,

    pub fn toGpu(this: *const CPULine) GPULine {
        return GPULine{
            .r = this.color[0],
            .g = this.color[1],
            .b = this.color[2],
            .a = this.color[3],
            .x0 = this.x0,
            .y0 = this.y0,
            .x1 = this.x1,
            .y1 = this.y1,
            .width = this.width,
            .style = @intFromEnum(this.style),
        };
    }
};

const GPULine = packed struct(u128) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    // These are in pixel coordinates (if you have more than a 65k x 65k monitor playing this game... I'm sorry.)
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
    // width is in half pixels
    width: u8,
    style: u8,
    // whatever was left over such that the bit size of this type is 128 (also checked by the zig compiler)
    leftover: u16 = undefined,
};

// This is what ends up in the SSBO
const GpuLinesBufferStruct = extern struct {
    lines: [MAX_LINES]GPULine,
};

const GpuTile = extern struct {
    num_lines: u32 = 0,
    lines: [MAX_LINES]u32 = [_]u32{0} ** MAX_LINES,
};

// This is a one-to-one translation of the function found in the fragment shader to find line distance
fn line_segment_distance_square(line: *const CPULine, x: f32, y: f32) f32 {
    const lx0: f32 = @floatFromInt(line.x0);
    const ly0: f32 = @floatFromInt(line.y0);
    const lx1: f32 = @floatFromInt(line.x1);
    const ly1: f32 = @floatFromInt(line.y1);

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

// First version with SSBOs, so I can just excrete the line data into a buffer that the pixel shader refines
// A sane renderer would convert the lines to meshes or w/e but frankly I can't be bothered.
// (plus using what is basically a per-pixel compute shader has some neat benefits)
const GL_VERSION_MAJOR = 4;
const GL_VERSION_MINOR = 3;

pub fn main(init: std.process.Init) !void {
    try glfw.init();
    defer glfw.terminate();

    glfw.windowHint(glfw.WindowHint.context_version_major, GL_VERSION_MAJOR);
    glfw.windowHint(glfw.WindowHint.context_version_minor, GL_VERSION_MINOR);
    glfw.windowHint(glfw.WindowHint.red_bits, 8);
    glfw.windowHint(glfw.WindowHint.green_bits, 8);
    glfw.windowHint(glfw.WindowHint.blue_bits, 8);
    glfw.windowHint(glfw.WindowHint.alpha_bits, 8);
    // We don't need a depth buffer... at all. No depth buffer. Don't give me one. Don't offer one. Don't even bother to allocate one.
    glfw.windowHint(glfw.WindowHint.depth_bits, 0);

    glfw.swapInterval(0);

    const window = try glfw.createWindow(800, 600, "ALERT", null, null);
    defer glfw.destroyWindow(window);
    glfw.makeContextCurrent(window);

    try opengl.loadCoreProfile(glfw.getProcAddress, 4, 3);

    const gl = opengl.bindings;

    // This is so all the interesting stuff shows up in frame 1 in apitrace
    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    window.swapBuffers();

    // Load the shaders (which are rather basic)
    const vertex_shader_id = gl.createShader(gl.VERTEX_SHADER);
    const vertex_shader_source = @embedFile("shader.vert.glsl");
    const ptr_to_vertex_shader_source = &vertex_shader_source;
    // const vertex_shader_source_len: c_int = @intCast(vertex_shader_source.len);
    gl.shaderSource(vertex_shader_id, 1, @ptrCast(ptr_to_vertex_shader_source), null);
    gl.compileShader(vertex_shader_id);
    var shader_result: c_int = gl.TRUE;
    gl.getShaderiv(vertex_shader_id, gl.COMPILE_STATUS, &shader_result);
    if (shader_result == gl.FALSE) {
        var log_length: c_int = 0;
        gl.getShaderiv(vertex_shader_id, gl.INFO_LOG_LENGTH, &log_length);
        const log = try init.arena.allocator().alloc(u8, @intCast(log_length));
        gl.getShaderInfoLog(vertex_shader_id, log_length, &log_length, log.ptr);
        std.log.err("Failed to compile vertex shader: {s}\n", .{log});
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
        const log = try init.arena.allocator().alloc(u8, @intCast(log_length));
        gl.getShaderInfoLog(fragment_shader_id, log_length, &log_length, log.ptr);
        std.log.err("Failed to compile fragment shader: {s}\n", .{log});
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
        const log = try init.arena.allocator().alloc(u8, @intCast(log_length));
        gl.getProgramInfoLog(program_id, log_length, null, log.ptr);
        std.log.err("Failed to link shaders: {s}\n", .{log});
        return error.init;
    }
    gl.deleteShader(vertex_shader_id);
    gl.deleteShader(fragment_shader_id);

    // Make sure there is enough SSBO space to put all the lines
    var lines_buffer: gl.Uint = 0;
    gl.genBuffers(1, &lines_buffer);
    gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, lines_buffer);
    // ask OpenGL to allocate the bytes we need but don't set them to anything yet
    // I am furiously considering switching to OpenGL 4.5 or newer with their MUCH MUCH MUCH nicer named buffer API, but I want compatibility if possible.
    gl.bufferData(gl.SHADER_STORAGE_BUFFER, @sizeOf(GpuLinesBufferStruct), null, gl.DYNAMIC_DRAW);

    // unfortunately unlike the lines buffer, the size of the tiles buffer may change each frame so we cannot pre-allocate (sad)
    var tiles_buffer: gl.Uint = 0;
    gl.genBuffers(1, &tiles_buffer);

    var tile_indices_buffer: gl.Uint = 0;
    gl.genBuffers(1, &tile_indices_buffer);

    // Apparently I still need a VAO despite not using any vertex buffer of any sort
    // Seriously, OpenGL, I am literally creating an empty VAO for no reason
    var vao_id: c_uint = 0;
    gl.genVertexArrays(1, &vao_id);
    gl.bindVertexArray(vao_id);

    // Benchmark: Create all of the lines
    var rand_obj = std.Random.DefaultPrng.init(42069);
    const rand = rand_obj.random();

    const gpu_lines = try init.arena.allocator().create(GpuLinesBufferStruct);

    var frame_arena_obj = std.heap.ArenaAllocator.init(init.gpa);
    const frame_arena = frame_arena_obj.allocator();
    defer frame_arena_obj.deinit();

    var lines: []CPULine = &[0]CPULine{};
    defer if (lines.len > 0) {
        init.gpa.free(lines);
    };

    var start = glfw.getTime();
    var count: usize = 0;
    var total_upload: usize = 0;
    while (!window.shouldClose()) {
        _ = frame_arena_obj.reset(.retain_capacity);

        glfw.pollEvents();

        const window_size = window.getSize();
        gl.viewport(0, 0, window_size[0], window_size[1]);

        // randomize lines
        if (count == 0 and lines.len == 0) {
            const num_lines = 5; //rand.intRangeAtMost(usize, 5, 10);
            if (lines.len > 0) {
                init.gpa.free(lines);
            }
            const color = [4]u8{ 50, 10, 10, 255 };
            lines = try init.gpa.alloc(CPULine, num_lines);
            lines[0] = .{
                .color = color,
                .x0 = 50,
                .y0 = 50,
                .x1 = 50,
                .y1 = 500,
                .vx0 = 0,
                .vy0 = 0,
                .vx1 = 0,
                .vy1 = 0,
                .width = 30,
                .style = .solid_color,
            };
            lines[1] = .{
                .color = color,
                .x0 = 150,
                .y0 = 50,
                .x1 = 150,
                .y1 = 500,
                .vx0 = 0,
                .vy0 = 0,
                .vx1 = 0,
                .vy1 = 0,
                .width = 30,
                .style = .drop_linear,
            };
            lines[2] = .{
                .color = color,
                .x0 = 250,
                .y0 = 50,
                .x1 = 250,
                .y1 = 500,
                .vx0 = 0,
                .vy0 = 0,
                .vx1 = 0,
                .vy1 = 0,
                .width = 30,
                .style = .decay_linear,
            };
            lines[3] = .{
                .color = color,
                .x0 = 350,
                .y0 = 50,
                .x1 = 350,
                .y1 = 500,
                .vx0 = 0,
                .vy0 = 0,
                .vx1 = 0,
                .vy1 = 0,
                .width = 30,
                .style = .decay_quadratic,
            };
            lines[4] = .{
                .color = color,
                .x0 = 450,
                .y0 = 50,
                .x1 = 450,
                .y1 = 500,
                .vx0 = 0,
                .vy0 = 0,
                .vx1 = 0,
                .vy1 = 0,
                .width = 30,
                .style = .decay_quintic,
            };
            _ = rand;
            // for (0..num_lines) |i| {
            //     lines[i] = CPULine{
            //         .color = .{ rand.int(u8), rand.int(u8), rand.int(u8), rand.int(u8) },
            //         .x0 = rand.int(u16) % @as(u16, @intCast(window_size[0])),
            //         .y0 = rand.int(u16) % @as(u16, @intCast(window_size[1])),
            //         .x1 = rand.int(u16) % @as(u16, @intCast(window_size[0])),
            //         .y1 = rand.int(u16) % @as(u16, @intCast(window_size[1])),
            //         .vx0 = rand.float(f32) * 20,
            //         .vy0 = rand.float(f32) * 20,
            //         .vx1 = rand.float(f32) * 20,
            //         .vy1 = rand.float(f32) * 20,
            //         .width = rand.int(u8) % 20 + 3,
            //         .style = @enumFromInt(i),
            //     };
            // }
        }
        for (0..lines.len) |i| {
            gpu_lines.lines[i] = lines[i].toGpu();
        }

        // Upload new lines
        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, lines_buffer);
        gl.bufferSubData(gl.SHADER_STORAGE_BUFFER, 0, @sizeOf(GpuLinesBufferStruct), gpu_lines);

        // Update tile buffer
        const num_x_tiles: u32 = @intCast(@divTrunc(window_size[0] - 1, TILE_SIZE) + 1);
        const num_y_tiles: u32 = @intCast(@divTrunc(window_size[1] - 1, TILE_SIZE) + 1);
        const num_total_tiles = num_x_tiles * num_y_tiles;

        // Go through each tile and make a list of the lines that touch it.
        const tile_indices = try frame_arena.alloc(u32, num_total_tiles);
        var tile_data = try std.ArrayList(u32).initCapacity(frame_arena, num_total_tiles * (MAX_LINES + 1));
        for (0..num_total_tiles) |tile_index| {
            const tile_x = tile_index % num_x_tiles;
            const tile_y = tile_index / num_x_tiles;
            const tile_pixel_x = @as(f32, @floatFromInt(tile_x)) * @as(f32, @floatFromInt(TILE_SIZE)) + @as(f32, @floatFromInt(TILE_SIZE)) / 2.0;
            const tile_pixel_y = @as(f32, @floatFromInt(tile_y)) * @as(f32, @floatFromInt(TILE_SIZE)) + @as(f32, @floatFromInt(TILE_SIZE)) / 2.0;

            const start_index = tile_data.items.len;
            // Allocate the space for the #of lines in this tile
            tile_data.appendAssumeCapacity(0);
            var tile_num_lines: u32 = 0;
            for (0..lines.len) |line_index| {
                const line = lines[line_index];
                const distance_to_tile = line_segment_distance_square(&line, tile_pixel_x, tile_pixel_y);
                const compare_to = TILE_MARGIN + @as(f32, @floatFromInt(line.width)) / 2.0;
                if (distance_to_tile < compare_to * compare_to) {
                    tile_data.appendAssumeCapacity(@intCast(line_index));
                    tile_num_lines += 1;
                }
            }
            tile_data.items[start_index] = tile_num_lines;
            tile_indices[tile_index] = @intCast(start_index);
        }

        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, tile_indices_buffer);
        gl.bufferData(gl.SHADER_STORAGE_BUFFER, @intCast(tile_indices.len * @sizeOf(u32)), tile_indices.ptr, gl.DYNAMIC_DRAW);

        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, tiles_buffer);
        gl.bufferData(gl.SHADER_STORAGE_BUFFER, @intCast(tile_data.items.len * @sizeOf(u32)), tile_data.items.ptr, gl.DYNAMIC_DRAW);

        total_upload += @sizeOf(GpuLinesBufferStruct) + @sizeOf(u32) * tile_indices.len + @sizeOf(u32) * tile_data.items.len;

        // Draw
        gl.clear(gl.COLOR_BUFFER_BIT);

        const lines_buffer_resource_index = gl.getProgramResourceIndex(program_id, gl.SHADER_STORAGE_BLOCK, "lines");
        gl.shaderStorageBlockBinding(program_id, lines_buffer_resource_index, 0);

        const tiles_buffer_resource_index = gl.getProgramResourceIndex(program_id, gl.SHADER_STORAGE_BLOCK, "tiles");
        gl.shaderStorageBlockBinding(program_id, tiles_buffer_resource_index, 1);

        const tile_indices_buffer_resource_index = gl.getProgramResourceIndex(program_id, gl.SHADER_STORAGE_BLOCK, "tile_indices");
        gl.shaderStorageBlockBinding(program_id, tile_indices_buffer_resource_index, 2);

        gl.useProgram(program_id);
        gl.bindVertexArray(vao_id);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, lines_buffer);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, tiles_buffer);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, tile_indices_buffer);
        gl.uniform1ui(0, @intCast(lines.len));
        gl.uniform1ui(1, @intCast(num_x_tiles));
        gl.uniform1ui(2, @intCast(num_y_tiles));
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        count += 1;
        const end = glfw.getTime();
        const diff = end - start;
        if (diff > 1) {
            std.log.info("Rendered {} frames in 1 second, uploaded {} bytes to GPU", .{ count, total_upload });
            start += diff;
            count = 0;
            total_upload = 0;
        }

        window.swapBuffers();
    }
}
