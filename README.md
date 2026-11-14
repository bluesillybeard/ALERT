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
The only objects that are parsed by the level loader are paths and layers. Groups and all other objects are not considered. Putting paths inside groups might work as long as that group holds no transform. I don't recommend risking it until we get proper group transform support in the level parser.

Objects that you do not intend to show up in the actual level must start with "IGNORE:", otherwise the parser will attempt to parse that object and fail.

Objects that do show up in the level follow a specific convention:
- T -> One of S, E, I for Solid, Evil, Ignore
- RRGGBBAA -> 16 digit hex color code (Yes, the SVG color is fully ignored)
- S -> one of B, G, M, L for Simple, Glowing, mBlended, gLowing&bLended
- WWW -> width of the line in decimal half-pixels
- PP -> Percent of the line's width to be considered a hitbox for player collision
- IIII -> optional many-character ID for animation interpolation - objects with the same ID will be interpolated between frames.
- R -> optional indicator to reset the interpolation. if an 'R' is present, the interpolation is reset which can be useful to teleport lines around.
- .name -> optional human-readable name for the object

So for example "S FF0000FF B 040 80 GROUND0 .main floor" is an object that:
- has the Solid type, so the player may hold on to it
- Color 0xFF0000FF which is pure red (RGBA)
- type B which is basic aka solid color
- width of 40 half pixels (20 pixels)
- the collision for this line only goes to 80 percent of this lines width
- animation/interpolation id GROUND0 so any other lines named GROUND0 will be this same line in a different location
- human-readable comment "main floor"

The interpolation ID is of particular importance if you do not want to redraw the entire level for every frame. Two objects with the same interpolation ID may not show up in the same frame. An object may be interpolated between frames linearly, so for example of frame 0 has an object on the left side with the id LINE0, and frame 60 has an object on the right side with the same id, the level player will automatically fill out that line for frames 1 - 59, and the line will take one second and one frame to go from the left side to the right side.

Note that the last instance of an interpolation ID will persist to future frames, use the 'R' or interpolation reset flag with will remove that persistence.

## TODO
- player movement
- player collision & game-over state
- audio playback
- some kind of main menu
- actual levels to play

