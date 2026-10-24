// IMPORTANT: this is a pile of crap I wrote in 2024 for a project to turn SVG files into triangle meshes
// That project is still ongoing in 2026 believe it or not, but this code was abandoned back then since I ended up creating an Inkscape extension instead
// Anyways I necromanced this code for this game jam thing, hopefully it works well enough.
// It did need some adjustment due to changes from the last two years of Zig evolving as a language.

// Structures for 2D geometry data (polygons and meshes)

const std = @import("std");

/// Takes path commands to build the polygon of that path.
pub const PolygonBuilder = struct {
    allocator: std.mem.Allocator,
    // TODO: it might be worth changing the data structure.
    // Since the triangulation wants to find points within a radius, spatial partitioning may be useful,
    // and since a point can only connect to one incoming segment and one outgoing segment, that may be used to increase efficiency.
    /// The polygon data works like an OpenGL vertex buffer + element buffer. Except, each primitive is a segment instead of a triangle.
    points: std.ArrayList(Vertex2D),
    segments: std.ArrayList(Segment),
    /// element of the starting point (index into points list)
    startPoint: ?usize,
    /// element of the position of the pen
    penPos: ?usize,

    pub fn init(allocator: std.mem.Allocator) PolygonBuilder {
        return PolygonBuilder{
            .allocator = allocator,
            .points = .empty,
            .segments = .empty,
            .startPoint = null,
            .penPos = null,
        };
    }

    pub fn deinit(this: *PolygonBuilder) void {
        this.points.deinit(this.allocator);
        this.segments.deinit(this.allocator);
        this.startPoint = null;
        this.penPos = null;
    }

    /// Runs a single SVG command.
    /// Command repeats - when commands are implicitly repeated when there are enough arguments to do it multiple times - are not supported.
    /// Never fails, although this may lead to unusual results. This is for a CLI, not a library, so who cares anyway.
    pub fn runSvgCommand(this: *PolygonBuilder, command: u8, params: []const f64) void {
        switch (command) {
            'M' => {
                if (params.len < 2) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                this.points.append(this.allocator, .{
                    .x = params[0],
                    .y = params[1],
                }) catch unreachable;
                this.startPoint = this.points.items.len - 1;
                this.penPos = this.points.items.len - 1;
            },
            'm' => {
                if (params.len < 2) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                if (this.penPos) |pen| {
                    const penPosPoint = this.points.items[pen];
                    this.points.append(this.allocator, .{
                        .x = params[0] + penPosPoint.x,
                        .y = params[1] + penPosPoint.y,
                    }) catch unreachable;
                } else {
                    this.points.append(this.allocator, .{
                        .x = params[0],
                        .y = params[1],
                    }) catch unreachable;
                }
                this.startPoint = this.points.items.len - 1;
                this.penPos = this.points.items.len - 1;
            },
            'Z', 'z' => {
                this.segments.append(this.allocator, .{ .a = this.penPos.?, .b = this.startPoint.? }) catch unreachable;
                this.penPos = this.startPoint;
            },
            'L' => {
                if (params.len < 2) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                this.addSegment(.{
                    .x = params[0],
                    .y = params[1],
                });
            },
            'l' => {
                if (params.len < 2) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                const penPosReal = this.points.items[@intCast(this.penPos.?)];
                this.addSegment(.{
                    .x = params[0] + penPosReal.x,
                    .y = params[1] + penPosReal.y,
                });
            },
            'H' => {
                if (params.len < 1) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                const penPosReal = this.points.items[@intCast(this.penPos.?)];
                this.addSegment(.{
                    .x = params[0],
                    .y = penPosReal.y,
                });
            },
            'h' => {
                if (params.len < 1) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                const penPosReal = this.points.items[@intCast(this.penPos.?)];
                this.addSegment(.{
                    .x = params[0] + penPosReal.x,
                    .y = penPosReal.y,
                });
            },
            'V' => {
                if (params.len < 1) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                const penPosReal = this.points.items[@intCast(this.penPos.?)];
                this.addSegment(.{
                    .x = penPosReal.x,
                    .y = params[0],
                });
            },
            'v' => {
                if (params.len < 1) {
                    std.log.warn("Skipping command {c} {any} due to too few arguments", .{ command, params });
                    return;
                }
                const penPosReal = this.points.items[@intCast(this.penPos.?)];
                this.addSegment(.{
                    .x = penPosReal.x,
                    .y = params[0] + penPosReal.y,
                });
            },
            // TODO: implement the rest of the path commands.
            // These are all curves, so some kind of resolution option is a good idea.
            // Keep it simple - build the lines over time, not over distance. Doing proper distance integration will be a huge waste of time.
            'C' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'c' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'S' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            's' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'Q' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'q' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'T' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            't' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'A' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            'a' => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
            else => {
                std.log.warn("Command {c} {any} is either invalid or not yet supported", .{ command, params });
            },
        }
    }

    // Add a segment that goes from the pen pos to the given pos, and moves the pen to the given pos.
    // Do not use to end the shape - instead send a Z command.
    pub fn addSegment(this: *PolygonBuilder, pos: Vertex2D) void {
        const a = this.penPos.?;
        this.points.append(this.allocator, pos) catch unreachable;
        const b = this.points.items.len - 1;
        this.segments.append(this.allocator, .{ .a = a, .b = b }) catch unreachable;
        this.penPos = b;
    }

    pub fn mergeNearby(this: *PolygonBuilder, epsilon: f64) void {
        const eps = epsilon * epsilon;
        // For every point (except the very last one, since the last one was already checked against every previous one)
        var i: usize = 0;
        while (i < this.points.items.len - 1) {
            // Apparently Zig "Optimizes" for loops, which makes them stupidly broken when the endpoint moves mid-loop.
            // That's why this botch is here.
            if (i >= (this.points.items.len - 1)) break;
            const p1 = this.points.items[i];
            var j: usize = i + 1;
            while (j < this.points.items.len) {
                const p2 = this.points.items[j];
                const dx = p1.x - p2.x;
                const dy = p1.y - p2.y;
                if (dx * dx + dy * dy <= eps) {
                    // This point is a duplicate of one that comes earlier in the list,
                    // For now just delete this point.
                    // This will cause segments involved with this point to either be the same,
                    // Or if there was a segment between this point and its duplicate,
                    _ = this.points.swapRemove(j);
                    for (this.segments.items) |*seg| {
                        // Anything that was referencing J should now reference the "original" point i.
                        if (seg.a == j) seg.a = i;
                        if (seg.b == j) seg.b = i;
                        // Since we swapped j with the last point,
                        // anything that was referencing the last point should now reference j.
                        if (seg.a == this.points.items.len) seg.a = j;
                        if (seg.b == this.points.items.len) seg.b = j;
                    }
                } else {
                    j += 1;
                }
            }
            i += 1;
        }
        // Segments between the two duplicate points are now a segment from a point to itself, which is definitely wrong.
        // So just remove those.
        var si: usize = 0;
        while (si < this.segments.items.len) {
            const seg = this.segments.items[si];
            if (seg.a == seg.b) {
                _ = this.segments.swapRemove(si);
            } else {
                si += 1;
            }
        }
    }
};

pub const Vertex2D = struct {
    x: f64,
    y: f64,
};

pub const Segment = extern struct {
    /// index of the starting position
    a: usize,
    /// index of the ending position
    b: usize,

    /// Check if two segments are equivalent, ignoring directionality (so AB == BA, even though that would change the direction of the segment)
    pub inline fn equals(a: Segment, b: Segment) bool {
        return (a.a == b.a and a.b == b.b) or (a.b == b.a and a.a == b.b);
    }
};
