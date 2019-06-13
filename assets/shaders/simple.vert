#version 400
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable

layout(std140, set= 0, binding = 0) uniform buffer {
    mat4 matrix;
} UBO;

layout(location = 0) in vec4 pos;
layout(location = 1) in vec2 uv;

layout(location = 0) out struct vertex_out {
    vec4 vColor;
    vec2 uv;
} OUT;

void main() {
    gl_Position = pos * UBO.matrix;

    OUT.uv = uv;
}