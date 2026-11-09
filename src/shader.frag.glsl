#version 120

varying vec4 color;
varying float distance;
varying float style;

void main() {
    if(style == 0) {
        gl_FragColor = color;
    } else if(style == 1) {
        gl_FragColor = color * (1 - distance);
    } else if(style == 2) {
        float dist_clamp = clamp(distance, 0.001, 1);
        gl_FragColor = color / dist_clamp;
    } else if(style == 3) {
        float dist_clamp = 1.0 / clamp(distance, 0.001, 1);
        gl_FragColor = color * dist_clamp * dist_clamp;
    } else if(style == 3) {
        float dist_clamp = 1.0 / clamp(distance, 0.001, 1);
        gl_FragColor = color * dist_clamp * dist_clamp * dist_clamp * dist_clamp;
    } else {
        gl_FragColor = vec4(1, 0, 1, 1);
    }
}
