#version 400
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable

layout(set = 1, binding = 0) uniform sampler2D imageSampler;

layout(location = 0) in struct fragment_in {
    vec4 vColor;
    vec2 uv;
} IN;

layout (location = 0) out vec4 uFragColor;

void main() {
    uFragColor = IN.vColor * texture(imageSampler, IN.uv);
}