// This file contains the code required to take a level and actually play it out frame-by-frame
const std = @import("std");
const svgimport = @import("svgimport.zig");

pub const FrameData = struct {
    lines: []svgimport.LevelLine,
};

pub const LevelPlayer = struct {
    /// Loads a level and prepares it for playback
    /// Holds a reference to the given level until the player is freed.
    pub fn load(this: *LevelPlayer, level: *const svgimport.ImportedLevel, gpa: std.mem.Allocator) !void {
        this.gpa = gpa;
        this.level = level;
        this.frame_data_arena = .init(gpa);
        this.interp_lines = .init(this.gpa);

        for (level.frames, 0..) |frame, frame_index| {
            for (frame.lines, 0..) |line, line_index| {
                if (line.id[0] != 0) {
                    const ref_id: []const u8 = std.mem.sliceTo(&line.id, 0);
                    const ref = LineRef{
                        .frame_index = frame_index,
                        .line_index = line_index,
                    };

                    if (this.interp_lines.getPtr(ref_id)) |existing| {
                        try existing.frames_referenced.append(gpa, ref);
                    } else {
                        var frames_referenced = std.ArrayList(LineRef).empty;
                        try frames_referenced.append(gpa, ref);
                        try this.interp_lines.put(try gpa.dupe(u8, ref_id), LineData{
                            .interp_id = ref_id,
                            .frames_referenced = frames_referenced,
                        });
                    }
                }
            }
        }
    }

    /// The generated frame data is freed on the next call to generateFrame
    pub fn generateFrame(this: *LevelPlayer, timestamp: u64) !FrameData {
        _ = this.frame_data_arena.reset(.retain_capacity);
        // find the first frame with a timestamp greater than the one we are looking for
        var frame_index = std.sort.partitionPoint(svgimport.LevelFrame, this.level.frames, timestamp, compare_timestamps);
        // subtract one unless we are already on the first frame, so this is the frame that we are playing back
        if (frame_index > 0) {
            frame_index -= 1;
        }

        // interpolated lines get a bit tricky
        // collect lines and their prev/next references
        var active_references = std.ArrayList(ActiveInterpolation).empty;
        var lines_iterator = this.interp_lines.valueIterator();
        while (lines_iterator.next()) |line| {
            var start_ref_index: usize = undefined;
            // find the first reference whose timestamp is greater than or equal to ours
            const end_ref_index = std.sort.partitionPoint(LineRef, line.frames_referenced.items, CompareLinerefTimestamp{ .timestamp = timestamp, .parent = this }, CompareLinerefTimestamp.compare);
            if (end_ref_index > 0) {
                start_ref_index = end_ref_index - 1;
            } else {
                start_ref_index = end_ref_index;
            }
            if (this.level.frames[line.frames_referenced.items[start_ref_index].frame_index].timestamp > timestamp) {
                continue;
            }

            if (start_ref_index != end_ref_index) {
                if (end_ref_index == line.frames_referenced.items.len) {
                    try active_references.append(this.frame_data_arena.allocator(), .{ .start = line.frames_referenced.items[start_ref_index], .end = line.frames_referenced.items[end_ref_index - 1] });
                } else {
                    try active_references.append(this.frame_data_arena.allocator(), .{ .start = line.frames_referenced.items[start_ref_index], .end = line.frames_referenced.items[end_ref_index] });
                }
            } else {
                try active_references.append(this.frame_data_arena.allocator(), .{ .start = line.frames_referenced.items[end_ref_index], .end = null });
            }
        }

        // Combine everything together
        var lines = std.ArrayList(svgimport.LevelLine).empty;

        // render out non-interpolated lines
        for (this.level.frames[frame_index].lines) |polyline| {
            try lines.appendSlice(this.frame_data_arena.allocator(), polyline.lines);
        }

        // render out interpolated lines
        // TODO: actually interpolate
        for (active_references.items) |ref| {
            try lines.appendSlice(this.frame_data_arena.allocator(), this.level.frames[ref.start.frame_index].lines[ref.start.line_index].lines);
        }

        return .{
            .lines = lines.items,
        };
    }

    const CompareLinerefTimestamp = struct {
        timestamp: u64,
        parent: *const LevelPlayer,

        fn compare(ctx: CompareLinerefTimestamp, ref: LineRef) bool {
            return ctx.parent.level.frames[ref.frame_index].timestamp < ctx.timestamp;
        }
    };

    fn compare_timestamps(cmp: u64, frame: svgimport.LevelFrame) bool {
        return frame.timestamp < cmp;
    }

    pub fn deinit(this: *LevelPlayer) void {
        this.frame_data_arena.deinit();
        var lines_iter = this.interp_lines.iterator();
        while (lines_iter.next()) |line| {
            line.value_ptr.frames_referenced.deinit(this.gpa);
            this.gpa.free(line.key_ptr.*);
        }
        this.interp_lines.deinit();
    }

    frame_data_arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    level: *const svgimport.ImportedLevel,
    interp_lines: std.StringHashMap(LineData),
};

const ActiveInterpolation = struct {
    start: LineRef,
    end: ?LineRef,
};

const LineRef = struct {
    frame_index: usize,
    line_index: usize,
};

const LineData = struct {
    // a place to store the interpolation ID of this line, IMPORTANT: this is a DIRECT reference to memory allocated within the imported level!
    interp_id: []const u8,
    // A list of indices to frames + line where this line is referenced, allocated on the gpa, sorted by timestamp
    frames_referenced: std.ArrayList(LineRef),
};
