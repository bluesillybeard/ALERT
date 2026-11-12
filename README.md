# Advanced Line Effect Rendering Technology

So basically this is a scuffed line renderer (despite the fact that I have literally called it advanced lol) with some kind of game attached to it.

I started it for the 2026 Mines game dev club october game jam.

## MINIMUM REQUIREMENTS
- OpenGL 2.1

## MAKING LEVELS
It expects an SVG file from Inkscape. Svg files from any other software are not likely to work.

### Frames
Each layer is treated as a frame, the name of that layer a timestamp in the form "mm:ss:ff". There are 60 frames in a second. Fractions of frames are not allowed - the entire game and all of its logic runs at 60 frames per second. Faster monitors are supported using interpolation.

A layer may optionally have a name by following the timestamp with a period. So for example, "00:00:00.start" may be common so the first frame of the animation is called start. These names are entirely ignored and in fact removed in the process of loading a level from its SVG document.

You do not need to (and in fact I advice against) having a layer for every frame. Interpolation should be used wherever possible.

### Objects and interpolation
The only objects that are parsed by the level loader are paths and layers. Groups and all other objects are not considered. Putting paths inside groups might work if you get lucky.
// - Naming Convention for objects: "T RRGGBBAA S WWW PP IIII R.name"
//    - T -> One of S, E, I for Solid, Evil, Ignore
//    - RRGGBBAA -> 16 digit hex color code (Yes, the SVG color is fully ignored)
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

## TODO
- player movement
- player collision & game-over state
- audio playback
- some kind of main menu
- actual levels to play

