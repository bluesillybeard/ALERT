const std = @import("std");
const Io = std.Io;

const glfw = @import("zglfw");
const opengl = @import("opengl");

// TODO: perhaps put this in some kind of config?
// To be honest though, for this game I see no need to change it at runtime.
const MAX_LINES = 10;

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
    // whatever was left over such that the bit size of this type is 128 (also checked by the zig compiler)
    leftover: u24 = undefined,
};

// This is what ends up in the SSBO
const GpuSsboStruct = extern struct {
    lines: [MAX_LINES]GPULine,
};

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

    glfw.swapInterval(1);

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
    var ssbo_id: gl.Uint = 0;
    gl.genBuffers(1, &ssbo_id);
    gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo_id);
    // ask OpenGL to allocate the bytes we need but don't set them to anything yet
    // I am furiously considering switching to OpenGL 4.5 or newer with their MUCH MUCH MUCH nicer named buffer API, but I want compatibility if possible.
    gl.bufferData(gl.SHADER_STORAGE_BUFFER, @sizeOf(GpuSsboStruct), null, gl.DYNAMIC_DRAW);

    // Apparently I still need a VAO despite not using any vertex buffer of any sort
    // Seriously, OpenGL, I am literally creating an empty VAO for no reason
    var vao_id: c_uint = 0;
    gl.genVertexArrays(1, &vao_id);
    gl.bindVertexArray(vao_id);

    // Benchmark: Create all of the lines
    var rand_obj = std.Random.DefaultPrng.init(42069);
    const rand = rand_obj.random();
    const lines = try init.arena.allocator().alloc(CPULine, MAX_LINES);
    const window_size_start = window.getSize();
    for (0..MAX_LINES) |i| {
        lines[i] = CPULine{
            .color = .{ rand.int(u8), rand.int(u8), rand.int(u8), rand.int(u8) },
            .x0 = rand.int(u16) % @as(u16, @intCast(window_size_start[0])),
            .y0 = rand.int(u16) % @as(u16, @intCast(window_size_start[1])),
            .x1 = rand.int(u16) % @as(u16, @intCast(window_size_start[0])),
            .y1 = rand.int(u16) % @as(u16, @intCast(window_size_start[1])),
            .vx0 = rand.float(f32) * 20,
            .vy0 = rand.float(f32) * 20,
            .vx1 = rand.float(f32) * 20,
            .vy1 = rand.float(f32) * 20,
            .width = rand.int(u8) % 20 + 3,
        };
    }

    std.log.debug("{any}", .{lines});

    const gpu_lines = try init.arena.allocator().create(GpuSsboStruct);

    while (!window.shouldClose()) {
        glfw.pollEvents();

        const window_size = window.getSize();
        gl.viewport(0, 0, window_size[0], window_size[1]);

        for (0..lines.len) |i| {
            gpu_lines.lines[i] = lines[i].toGpu();
        }

        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo_id);
        gl.bufferSubData(gl.SHADER_STORAGE_BUFFER, 0, @sizeOf(GpuSsboStruct), gpu_lines);
        gl.clear(gl.COLOR_BUFFER_BIT);

        // Gosh I hate OpenGL what kind of loser dumbass idiots designed this stupid heaping pile of actual BS like what in the world
        const resource_index = gl.getProgramResourceIndex(program_id, gl.SHADER_STORAGE_BLOCK, "lines");
        gl.shaderStorageBlockBinding(program_id, resource_index, 0);

        gl.useProgram(program_id);
        gl.bindVertexArray(vao_id);
        gl.bindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo_id);
        gl.bindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, ssbo_id);
        gl.uniform1ui(0, @intCast(lines.len));
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        window.swapBuffers();
    }
}
