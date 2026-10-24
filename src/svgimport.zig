// Do not let the name of this file fool you. This is not a valid SVG implementation. Not even close.
// - It expects an SVG file from Inkscape. Svg files from any other software are not likely to work.
// - Each layer is treated as a frame, the name of that layer a timestamp in the form "mm:ss:ff"
// - Naming Convention for objects: "T RRGGBBAA S WWW PP IIII R.name"
//    - T -> One of S, E, I for Solid, Evil, Ignore
//    - RRGGBBAA -> 16 digit hex color code (Yes, the SVG color is fully ignored) (only does anything for ignore lines as lines that effect the player have their own coloring)
//    - S -> one of B, G, M, L for Simple, Glowing, mBlended, gLowing&bLended
//    - WWW -> width of the line in decimal half-pixels
//    - PP -> Percent of the line's width to be considered a hitbox for player collision
//    - IIII -> optional many-character ID for animation interpolation - objects with the same ID will be interpolated between frames.
//    - R -> optional indicator to reset the interpolation. if an 'R' is present, the interpolation is reset which can be useful to teleport lines around.
//    - .name -> optional human-readable name for the object
//    - Spaces are ignored when parsing
//    - Example: S FF0000FF B 040 80 GROUND0 .main floor
// - Only basic paths are considered. All other objects are skipped. Bezier curves will cause a runtime error. Only straight lines. Screw you.
// - do not use groups. At all. Under no circumstances should the input file contain any groups, ever. Groups will cause issues.
// - The one place you may use other forms of objects are ones whose name starts with "IGNORE:".
// This game is intended to be played at 16:9 so make sure your inkscape canvas is exactly 16 units wide and 9 units tall. In this folder is a template that you shall use.

// This is a hackjob abomination thrown together in a matter of hours. Screw you.

const std = @import("std");
const xml = @import("xml");
const render = @import("render.zig");
const Color = render.Color;
const polygon = @import("polygon.zig");
const PolyBuilder = polygon.PolygonBuilder;

pub const LineType = enum {
    solid,
    evil,
    ignore,
};

pub const LineStyle = enum {
    basic,
    glowing,
    blended,
    both,
};

pub const LevelLine = struct {
    T: LineType,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    color: Color,
    style: LineStyle,
    width: u8,
    width_percent: f32,
    // You have to be insane to have an ID longer than 32 characters.
    id: [50]u8,
    interpolate_reset: bool,
    // We store this for debugging purposes
    name: [50]u8,
};

pub const LevelFrame = struct {
    // timestamp in 60fps frames after the start of the level
    timestamp: u64,
    // Allocated using the allocator for the overall level
    lines: []LevelLine,
};

pub const InProgressLevelFrame = struct {
    // timestamp in 60fps frames after the start of the level
    timestamp: u64,
    // Allocated temporarily
    lines: std.ArrayList(LevelLine),
};

pub const ImportedLevel = struct {
    // An arena that can be cleared to free all data owned by this level
    arena: std.heap.ArenaAllocator = undefined,
    // Total length of this level in 60fps frames
    length: u64 = undefined,
    // Frames in this level. This is likely to be much less than the actual number of frames of animation due to the potential use of interpolation.
    frames: []LevelFrame = undefined,
    // Name of this level
    name: []const u8 = undefined,

    pub fn init(this: *ImportedLevel, path: []const u8, io: std.Io, allocator: std.mem.Allocator) !void {
        this.arena = .init(allocator);
        this.length = 0;
        this.frames.len = 0;
        this.name = path;

        var import_arena = std.heap.ArenaAllocator.init(allocator);
        defer import_arena.deinit();

        var input_file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer input_file.close(io);
        var input_buf: [4096]u8 = undefined;
        var input_reader = input_file.reader(io, &input_buf);
        var streaming_reader: xml.Reader.Streaming = .init(import_arena.allocator(), &input_reader.interface, .{});
        defer streaming_reader.deinit();
        const reader = &streaming_reader.interface;

        // PARSER STATE
        // If we are in a layer, what is the name of that layer. If we are not in a layer, NULL
        var layer_name: ?[]const u8 = null;
        var layer_depth: usize = 0;
        // How many layers deep are we
        var depth: usize = 0;
        // When we see an element with a label that starts with IGNORE, make note of what depth that is here.
        var ignore_depth: ?usize = null;
        var iteration_limit: usize = 1000000;

        var frames: std.ArrayList(InProgressLevelFrame) = .empty;

        NODE_LOOP: while(iteration_limit > 0) {
            iteration_limit -= 1;
            const node = reader.read() catch |e| {
                if(e == error.MalformedXml) {
                    const loc = reader.errorLocation();
                    std.log.err("Failed to parse SVG file {s} at {}:{}: {}", .{path, loc.line, loc.column, reader.errorCode()});
                } else {
                    std.log.err("Failed to parse SVG file {s}: {}", .{path, e});
                }
                return e;
            };
            NODE_SWITCH: switch(node) {
                .eof => break :NODE_LOOP,
                .xml_declaration, .comment, .text, .entity_reference => {},
                .element_start => {
                    depth += 1;
                    const element_type = reader.elementName();
                    if(ignore_depth) |some_ignore_depth| {
                        if(some_ignore_depth < depth) {
                            break :NODE_SWITCH;
                        }
                    }
                    if(std.mem.eql(u8, element_type, "g")) {
                        // Group
                        var is_layer: bool = false;
                        // For whatever reason Inkscape stores the name of nodes completely differently from how the svg standard assumes.
                        var inkscape_label: ?[]const u8 = null;

                        for(0..reader.attributeCount()) |attr_index| {
                            const attr_name = reader.attributeName(attr_index);
                            const attr_value = try reader.attributeValue(attr_index);

                            if(std.mem.eql(u8, attr_name, "inkscape:label")) {
                                inkscape_label = try import_arena.allocator().dupe(u8, attr_value);
                            } else if(std.mem.eql(u8, attr_name, "inkscape:groupmode")) {
                                if(std.mem.eql(u8, attr_value, "layer")) {
                                    is_layer = true;
                                }
                            }
                        }

                        if(inkscape_label == null or std.mem.startsWith(u8, inkscape_label.?, "IGNORE")) {
                            ignore_depth = depth;
                            break :NODE_SWITCH;
                        }

                        if(is_layer) {
                            layer_name = inkscape_label;
                            layer_depth = depth;
                            try frames.append(import_arena.allocator(), .{
                                .lines = .empty,
                                // TODO: parse timestamp
                                .timestamp = 0,
                            });
                        }
                        // End group handling
                    } else if(std.mem.eql(u8, element_type, "path")) {
                        // Path
                        var inkscape_label: ?[]const u8 = null;
                        var path_code: ?[]const u8 = null;
                        for(0..reader.attributeCount()) |attr_index| {
                            const attr_name = reader.attributeName(attr_index);
                            const attr_value = try reader.attributeValue(attr_index);

                            if(std.mem.eql(u8, attr_name, "inkscape:label")) {
                                inkscape_label = try import_arena.allocator().dupe(u8, attr_value);
                            } else if(std.mem.eql(u8, attr_name, "d")) {
                                path_code = try import_arena.allocator().dupe(u8, attr_value);
                            }
                        }
                        if(inkscape_label == null or std.mem.startsWith(u8, inkscape_label.?, "IGNORE")) {
                            break :NODE_SWITCH;
                        }

                        if(path_code == null) {
                            std.log.err("Failed to parse SVG file {s}: path node with no path code", .{path});
                            return error.MalformedSvg;
                        }

                        if(inkscape_label == null) {
                            std.log.warn("Skipped node missing inkscape label", .{});
                            break :NODE_SWITCH;
                        }

                        const line_properties = blk: {
                            //T RRGGBBAA S WWW PP IIII R.name
                            const end_index = std.mem.indexOf(u8, inkscape_label.?, ".") orelse inkscape_label.?.len;
                            var encoded: [15 + 50 + 1]u8 = undefined;
                            var nencoded: usize = 0;
                            for(0..end_index) |i| {
                                const c = inkscape_label.?[i];
                                if(c != ' ') {
                                    if(nencoded >= encoded.len) {
                                        std.log.err("Failed to parse line in SVG file {s}: properties to long \"{s}\"", .{path, inkscape_label.?[0..end_index]});
                                        return error.MalformedLine;
                                    }
                                    encoded[nencoded] = c;
                                    nencoded += 1;
                                }
                            }

                            if(nencoded < 15) {
                                std.log.err("failed to parse line in SVG file {s}: properties too short \"{s}\"", .{path, encoded[0..nencoded]});
                            }

                            const line_type = switch(encoded[0]) {
                                'S' => LineType.solid,
                                'E' => LineType.evil,
                                'I' => LineType.ignore,
                                else => {
                                    std.log.err("failed to parse line in SVG file {s}: invalid line type {c}", .{path, encoded[0]});
                                    return error.MalformedLine;
                                }
                            };
                            
                            const red = std.fmt.parseInt(u8, encoded[1..3], 16) catch {
                                std.log.err("failed to parse line in SVG file {s}: invalid color channel {s}", .{path, encoded[1..3]});
                                return error.MalformedLine;
                            };

                            const green = std.fmt.parseInt(u8, encoded[3..5], 16) catch {
                                std.log.err("failed to parse line in SVG file {s}: invalid color channel {s}", .{path, encoded[1..3]});
                                return error.MalformedLine;
                            };

                            const blue = std.fmt.parseInt(u8, encoded[5..7], 16) catch {
                                std.log.err("failed to parse line in SVG file {s}: invalid color channel {s}", .{path, encoded[1..3]});
                                return error.MalformedLine;
                            };

                            const alpha = std.fmt.parseInt(u8, encoded[7..9], 16) catch {
                                std.log.err("failed to parse line in SVG file {s}: invalid color channel {s}", .{path, encoded[1..3]});
                                return error.MalformedLine;
                            };

                            const style = switch(encoded[9]) {
                                'B' => LineStyle.basic,
                                'G' => LineStyle.glowing,
                                'M' => LineStyle.blended,
                                'L' => LineStyle.both,
                                else => {
                                    std.log.err("failed to parse line in SVG file {s}: invalid style {c}", .{path, encoded[9]});
                                    return error.MalformedLine;
                                }
                            };

                            const width = std.fmt.parseInt(u8, encoded[10..13], 10) catch {
                                std.log.err("failed to parse line in SVG file {s}: invalid width {s}", .{path, encoded[10..14]});
                                return error.MalformedLine;
                            };

                            const width_percent = std.fmt.parseInt(u8, encoded[13..15], 10) catch {
                                std.log.err("failed to parse line in SVG file {s}: invalid width percent {s}", .{path, encoded[14..16]});
                                return error.MalformedLine;
                            };

                            const interp_reset = encoded[nencoded-1] == 'R';

                            var interp_id = try import_arena.allocator().dupe(u8, encoded[15..nencoded]);
                            if(interp_reset) {
                                interp_id = interp_id[0..interp_id.len-1];
                            }

                            break :blk .{
                                .line_type = line_type,
                                .red = red,
                                .green = green,
                                .blue = blue,
                                .alpha = alpha,
                                .style = style,
                                .width = width,
                                .width_percent = width_percent,
                                .interp_reset = interp_reset,
                                .interp_id = interp_id,
                                .name = inkscape_label.?[end_index..],
                            };
                        };

                        var poly = PolyBuilder.init(import_arena.allocator());
                        var path_tokens = std.mem.tokenizeAny(u8, path_code.?, " ,");
                        var command: u8 = 0;
                        var args_so_far: [64] f64 = undefined;
                        var nargs: usize = 0;
                        while(path_tokens.next()) |token| {
                            if(std.mem.indexOfAny(u8, token, "MmZzLlHhVvCcSsQqTtAa")) |_| {
                                if(token.len != 1) {
                                    std.log.warn("Unusual SVG path command: {s}", .{token});
                                }
                                if(command != 0) {
                                    poly.runSvgCommand(command, args_so_far[0..nargs]);
                                    nargs = 0;
                                }
                                command = token[0];
                            } else {
                                const arg = std.fmt.parseFloat(f32, token) catch {
                                    std.log.err("Failed to parse SVG file {s}: {s} is not a valid float", .{path, token});
                                    return error.MalformedSvg;
                                };
                                if(nargs >= 64) {
                                    std.log.err("Failed to parse SVG file {s}: too many args in SVG path command", .{path});
                                    return error.MalformedSvg;
                                }
                                args_so_far[nargs] = arg;
                                nargs += 1;
                            }
                            poly.runSvgCommand(command, args_so_far[0..nargs]);
                        }

                        for(poly.segments.items) |segment| {
                            const start = poly.points.items[segment.a];
                            const end = poly.points.items[segment.b];
                            var id = [_]u8{0} ** 50;
                            var name = [_]u8{0} ** 50;
                            if(line_properties.interp_id.len >= 50) {
                                std.log.err("failed to parse svg file {s}: Interpolation ID {s} is too long", .{path, line_properties.interp_id});
                                return error.MalformedLine;
                            }
                            if(line_properties.name.len >= 50) {
                                std.log.err("failed to parse svg file {s}: Interpolation ID {s} is too long", .{path, line_properties.interp_id});
                                return error.MalformedLine;
                            }
                            @memcpy((&id)[0..line_properties.interp_id.len], line_properties.interp_id);
                            id[line_properties.interp_id.len] = 0;
                            @memcpy((&name)[0..line_properties.name.len], line_properties.name);
                            name[line_properties.name.len] = 0;
                            try frames.items[frames.items.len-1].lines.append(import_arena.allocator(), LevelLine{
                                .T = line_properties.line_type,
                                .x0 = @floatCast(start.x),
                                .y0 = @floatCast(1080 - start.y),
                                .x1 = @floatCast(end.x),
                                .y1 = @floatCast(1080 - end.y),
                                .color = .{
                                    .r = line_properties.red,
                                    .g = line_properties.green,
                                    .b = line_properties.blue,
                                    .a = line_properties.alpha,
                                },
                                .style = line_properties.style,
                                .width = line_properties.width,
                                .width_percent = line_properties.width_percent / 100,
                                .id = id,
                                .interpolate_reset = line_properties.interp_reset,
                                .name = name,
                            });
                        }
                        // End path handling
                    }
                },
                .element_end => {
                    if(depth == 0) {
                        std.log.err("Failed to parse SVG file {s}: isolated element_end", .{path});
                        return error.MalformedXml;
                    }
                    if(layer_name) |_| {
                        if(layer_depth == depth) {
                            layer_name = null;
                        }
                    }
                    if(ignore_depth) |some_ignore_depth| {
                        if(some_ignore_depth == depth) {
                            ignore_depth = null;
                        }
                    }
                    depth -= 1;
                },
                else => {
                    std.log.info("Element {}", .{node});
                }
            }
        }
        if(iteration_limit == 0) {
            std.log.err("Failed to parse SVG file: {s}: Reached iteration limit", .{path});
            return error.IterationLimit;
        }

        var finished_frames = std.ArrayList(LevelFrame).empty;
        for(frames.items) |frame| {
            try finished_frames.append(import_arena.allocator(), .{
                .timestamp = frame.timestamp,
                .lines = try this.arena.allocator().dupe(LevelLine, frame.lines.items),
            });
        }
        this.frames = try this.arena.allocator().dupe(LevelFrame, finished_frames.items);
    }

    pub fn deinit(this: *ImportedLevel) void {
        this.arena.deinit();
    }
};