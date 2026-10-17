#version 430

layout(std430, binding = 0) buffer lines {
    uint line_data[];
};

layout(std430, binding = 1) buffer tiles {
    // Each tile has a single uint for the number of lines in that tile, then num_lines more uints each a tile ID for a line.
    // I will admit, this is an obnoxious over-allocation of GPU memory, but lines are cheap as.
    uint line_ids[];
};

layout(location = 0) uniform uint num_lines;
layout(location = 1) uniform uint num_x_tiles;
layout(location = 2) uniform uint num_y_tiles;

out vec4 color;

struct line {
    vec4 color;
    vec2 p0;
    vec2 p1;
    float width;
};

uint calculate_tile_index(vec2 pixel_pos) {
    return uint(pixel_pos.x) / 32 + num_x_tiles * (uint(pixel_pos.y) / 32);
}

uint tile_num_lines(uint tile_index) {
    return line_ids[tile_index * (num_lines + 1)];
}

uint tile_line_id(uint tile_index, uint index) {
    return line_ids[tile_index * (num_lines + 1) + index + 1];
}

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
    uint tile = calculate_tile_index(pixel_pos);
    uint num = tile_num_lines(tile);
    for(uint index = 0; index < num; index += 1) {
        uint id = tile_line_id(tile, index);
        line line_data = extract_line(id);
        float dist = line_segment_distance(line_data.p0, line_data.p1, pixel_pos);
        float diff = dist - line_data.width;
        color += mix(determine_line_color(line_data, dist), vec4(0), max(min(diff, 1), 0));
    }
}
