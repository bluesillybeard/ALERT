#version 430

layout(std430, binding = 0) buffer lines {
    uint line_data[];
};

layout(location = 0) uniform uint num_lines;

out vec4 color;

struct line {
    vec4 color;
    vec2 p0;
    vec2 p1;
    float width;
};

line extract_line(uint line_id) {
    uint d0 = line_data[line_id * 4];
    uint d1 = line_data[line_id * 4 + 1];
    uint d2 = line_data[line_id * 4 + 2];
    uint d3 = line_data[line_id * 4 + 3];

    vec4 color = vec4(
        float(d0 & uint(255)),
        float((d0 >> 8) & uint(255)),
        float((d0 >> 16) & uint(255)),
        float((d0 >> 24) & uint(255))
    );
    color /= 255.0;

    vec2 p0 = vec2(d1 & uint(65535), (d1 >> 16) & uint(65535));
    vec2 p1 = vec2(d2 & uint(65535), (d2 >> 16) & uint(65535));

    float width = float(d3 & uint(255)) / 2.0;

    return line(color, p0, p1, width);
}

float line_segment_distance(vec2 ls, vec2 le, vec2 p) {
    vec2 u = le - ls;

    if(u == vec2(0)) {
        return length(p - ls);
    }

    vec2 v = p - ls;

    float t = dot(u, v) / (u.x * u.x + u.y * u.y);
    
    if(t < 0){
        return length(p - ls);
    } else if(t > 1) {
        return length(p - le);
    } else {
        vec2 z = ls + t * u;
        return length(p - z);
    }
}

vec4 determine_line_color(line line_data, float dist) {
    if (dist < 0.001) {
        dist = 0.001;
    }
    return line_data.width * line_data.color / (dist * dist);
}

void main() {
    color = vec4(0, 0, 0, 1);

    vec2 pixel_pos = gl_FragCoord.xy;
    for(uint id=0; id < num_lines; id += 1) {
        line line_data = extract_line(id);
        float dist = line_segment_distance(line_data.p0, line_data.p1, pixel_pos);
        float diff = dist - line_data.width;
        color += mix(determine_line_color(line_data, dist), vec4(0), max(min(diff, 1), 0));
    }
}
