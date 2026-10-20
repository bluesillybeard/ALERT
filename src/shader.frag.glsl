#version 430

layout(std430, binding = 0) buffer lines {
    uint line_data[];
};

layout(std430, binding = 1) buffer tiles {
    uint line_ids[];
};

layout(std430, binding = 2) buffer tile_indices {
    // This is a list with a length equal to the number of tiles, each item is the index into tiles where that tile starts.
    uint tile_index_buffer[];
};

layout(location = 0) uniform uint num_lines;
layout(location = 1) uniform uint num_x_tiles;
layout(location = 2) uniform uint num_y_tiles;

out vec4 color;

// source: https://github.com/tobspr/GLSL-Color-Spaces/blob/master/ColorSpaces.inc.glsl
// TODO: compare results between this exact version v.s the fast but approximate version

const float SRGB_ALPHA = 0.055;

// Used to convert from linear RGB to XYZ space
const mat3 RGB_2_XYZ = (mat3(
    0.4124564, 0.2126729, 0.0193339,
    0.3575761, 0.7151522, 0.1191920,
    0.1804375, 0.0721750, 0.9503041
));

// Used to convert from XYZ to linear RGB space
const mat3 XYZ_2_RGB = (mat3(
     3.2404542,-0.9692660, 0.0556434,
    -1.5371385, 1.8760108,-0.2040259,
    -0.4985314, 0.0415560, 1.0572252
));

// Converts a color from linear RGB to XYZ space
vec3 rgb_to_xyz(vec3 rgb) {
    return RGB_2_XYZ * rgb;
}

// Converts a color from XYZ to linear RGB space
vec3 xyz_to_rgb(vec3 xyz) {
    return XYZ_2_RGB * xyz;
}

// Converts a single linear channel to srgb
float linear_to_srgb(float channel) {
    if(channel <= 0.0031308)
        return 12.92 * channel;
    else
        return (1.0 + SRGB_ALPHA) * pow(channel, 1.0/2.4) - SRGB_ALPHA;
}

// Converts a single srgb channel to rgb
float srgb_to_linear(float channel) {
    if (channel <= 0.04045)
        return channel / 12.92;
    else
        return pow((channel + SRGB_ALPHA) / (1.0 + SRGB_ALPHA), 2.4);
}

// Converts a linear rgb color to a srgb color (exact, not approximated)
vec3 rgb_to_srgb(vec3 rgb) {
    return vec3(
        linear_to_srgb(rgb.r),
        linear_to_srgb(rgb.g),
        linear_to_srgb(rgb.b)
    );
}

// Converts a srgb color to a linear rgb color (exact, not approximated)
vec3 srgb_to_rgb(vec3 srgb) {
    return vec3(
        srgb_to_linear(srgb.r),
        srgb_to_linear(srgb.g),
        srgb_to_linear(srgb.b)
    );
}

vec3 xyz_to_srgb(vec3 xyz)  { return rgb_to_srgb(xyz_to_rgb(xyz)); }
vec3 srgb_to_xyz(vec3 srgb) { return rgb_to_xyz(srgb_to_rgb(srgb)); }

struct line {
    // In linear color space
    vec4 color;
    vec2 p0;
    vec2 p1;
    float width;
    uint style;
};

uint calculate_tile_index(vec2 pixel_pos) {
    uint tid = uint(pixel_pos.x) / 64 + num_x_tiles * (uint(pixel_pos.y) / 64);
    return tile_index_buffer[tid];
}

uint tile_num_lines(uint tile_index) {
    return line_ids[tile_index];
}

line extract_line(uint tile, uint index) {
    uint line_id = line_ids[tile + index + 1] * 4;
    uint d0 = line_data[line_id];
    uint d1 = line_data[line_id + 1];
    uint d2 = line_data[line_id + 2];
    uint d3 = line_data[line_id + 3];

    vec4 color = vec4(
        float(d0 & uint(255)),
        float((d0 >> 8) & uint(255)),
        float((d0 >> 16) & uint(255)),
        float((d0 >> 24) & uint(255))
    );
    color /= 255.0;
    color = vec4(srgb_to_xyz(color.rgb), color.a);

    vec2 p0 = vec2(d1 & uint(65535), (d1 >> 16) & uint(65535)) + vec2(0.5, 0.5);
    vec2 p1 = vec2(d2 & uint(65535), (d2 >> 16) & uint(65535)) + vec2(0.5, 0.5);

    float width = float(d3 & uint(255)) / 2.0;

    uint style = d3 >> 8 & uint(255);

    return line(color, p0, p1, width, style);
}

float line_segment_distance_square(vec2 ls, vec2 le, vec2 p) {
    vec2 u = le - ls;

    if(u == vec2(0)) {
        vec2 d = p - ls;
        return dot(d, d);
    }

    vec2 v = p - ls;

    float t = dot(u, v) / (u.x * u.x + u.y * u.y);
    
    if(t < 0){
        vec2 d = p - ls;
        return dot(d, d);
    } else if(t > 1) {
        vec2 d = p - le;
        return dot(d, d);
    } else {
        vec2 z = ls + t * u;
        vec2 d = p - z;
        return dot(d, d);
    }
}

float determine_factor(uint style, float dist_sq, float width) {
    if(dist_sq > width * width) {
        return 0;
    } else if (dist_sq < 0.25) {
        dist_sq = 0.25;
    }
    float dist = sqrt(dist_sq);
    if (style == 0) {
        // Solid color
        return 1;
    } else if (style == 1) {
        // linear drop
        return (width - dist) / width;
    } else if (style == 2) {
        // linear decay, note the extra component to guarantee it smoothly transitions to zero
        float factor_at_width = 1 / width;
        return width * (1 / dist - factor_at_width);
    } else if (style == 3) {
        // quadratic decay
        float factor_at_width = 1 / (width * width);
        return width * (1 / dist_sq - factor_at_width);
    } else if (style == 4) {
        // quintic decay
        float factor_at_width = 1 / (width * width * width * width);
        return width * (1 / (dist_sq * dist_sq) - factor_at_width);
    } else {
        return -1;
    }
}

vec3 determine_line_color(line line_data, float dist_sq) {
    float factor = determine_factor(line_data.style, dist_sq, line_data.width);
    float aa_factor = clamp((line_data.width - sqrt(dist_sq)), 0, 1);
    return line_data.color.rgb * factor * aa_factor;
}

void main() {
    color = vec4(0, 0, 0, 1);

    vec2 pixel_pos = gl_FragCoord.xy;
    uint tile = calculate_tile_index(pixel_pos);
    uint num = tile_num_lines(tile);
    for(uint index = 0; index < num; index += 1) {
        line line_data = extract_line(tile, index);
        float dist = line_segment_distance_square(line_data.p0, line_data.p1, pixel_pos);
        vec3 result = determine_line_color(line_data, dist);
        color += vec4(result * line_data.color.a, line_data.color.a);
    }
    color = vec4(xyz_to_srgb(color.rgb), 1);
}
