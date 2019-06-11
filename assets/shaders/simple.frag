#version 400
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable

layout(location = 0) in struct fragment_in {
    vec4 vColor;
    vec2 uv;
} IN;

layout (location = 0) out vec4 uFragColor;

void main() {
    uFragColor = vec4( 0.5, 0.5, 0.5, 1.0 );
}