#version 430

const vec2 vertices[] = {
    vec2(-1, -1),
    vec2(-1, 1),
    vec2(1, -1),
    vec2(-1, 1),
    vec2(1, 1),
    vec2(1, -1)
};
void main() {
    gl_Position = vec4(vertices[gl_VertexID], 0.5, 1);
}
