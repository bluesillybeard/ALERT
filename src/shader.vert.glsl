#version 120

// Legacy OpenGL moment
attribute vec2 pos;
attribute vec4 col;
attribute float dis;
// style
attribute float sty;

varying vec4 color;
varying float distance;
varying float style;

void main() {
    gl_Position = vec4(pos, 0.5, 1);
    color = col;
    distance = dis;
    style = sty;
}
