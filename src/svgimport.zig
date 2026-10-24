// Do not let the name of this file fool you. This is not a valid SVG implementation. Not even close.
// - It expects an SVG file from Inkscape. Svg files from any other software are not likely to work.
// - Each layer is treated as a frame, the name of that layer a timestamp in the form "mm:ss:ff"
// - Naming Convention for objects: "TRRGGBBAASWWWPPIIII.name"
//    - T -> One of S, E, I for Solid, Evil, Ignore
//    - RRGGBBAA -> 16 digit hex color code (Yes, the SVG color is fully ignored) (only does anything for ignore lines as lines that effect the player have their own coloring)
//    - S -> one of B, G, B, L for Basic, Glowing, Blended, gLowing&bLended
//    - WWW -> width of the line in decimal half-pixels
//    - PP -> Percent of the line's width to be considered a hitbox for player collision
//    - IIII -> optional many-character ID for animation interpolation - objects with the same ID will be interpolated between frames. That interpolation resets if that object is not present for a frame.
//    - .name -> optional human-readable name for the object
//    - Spaces are ignored when parsing
//    - Example: S FF0000FF B 040 80 GROUND0 .main floor
// - Only basic paths are considered. All other objects are skipped. Bezier curves will cause a runtime error. Only straight lines. Screw you.
// - do not use groups. At all. Under no circumstances should the input file contain any groups, ever. Groups will cause issues.
// - The one place you may use other forms of objects are ones whose name starts with "IGNORE:".
// This game is intended to be played at 16:9 so make sure your inkscape canvas is exactly 16 units wide and 9 units tall. In this folder is a template that you shall use.

// This is a hackjob abomination thrown together in a matter of hours. Screw you.

const render = @import("render.zig");
const Color = render.Color;

pub const LineType = enum {
    safe,
    evil,
};

pub const LineStyle = enum {
    basic,
    glowing,
    blended,
    both,
};

pub const LevelLine = struct {
    T: LineType,
    color: Color,
    style: LineStyle,
    width: u8,
    width_percent: f32,
    // You have to be insane to have an ID longer than 32 characters.
    id: u8[50],
    // We store this for debugging purposes
    name: u8[50],
};

pub const LevelFrame = struct {};

pub const ImportedLevel = struct {};
