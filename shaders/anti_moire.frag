#version 320 es

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_dst_size;
uniform vec2 u_src_size;
uniform vec2 u_texels_per_px;

uniform sampler2D u_texture;

layout(location = 0) out vec4 fragColor;

void main() {
  vec2 inv_src = 1.0 / max(u_src_size, vec2(1.0));
  vec2 half_texel = 0.5 * inv_src;
  vec2 uv = FlutterFragCoord().xy / max(u_dst_size, vec2(1.0));
  uv = clamp(uv, half_texel, 1.0 - half_texel);

  float downscale = max(u_texels_per_px.x, u_texels_per_px.y);
  if (downscale <= 1.12) {
    fragColor = texture(u_texture, uv);
    return;
  }

  vec2 clamped_scale = clamp(u_texels_per_px, vec2(1.0), vec2(10.0));
  float strength = smoothstep(1.10, 1.50, downscale);

  vec2 radius = clamped_scale * (1.00 * strength);
  vec2 sigma = max(vec2(0.001), clamped_scale * (0.52 * strength));
  vec2 inv_2_sigma2 = 0.5 / (sigma * sigma);
  vec2 step_texel = radius * 0.5;

  // Knight's-move rotation (~26.57 deg) avoids beating with 0/45/90 deg manga screentones.
  const float cos_r = 0.89442719;
  const float sin_r = 0.44721360;

  vec4 accum = vec4(0.0);
  float w_sum = 0.0;

  for (int iy = -2; iy <= 2; iy++) {
    for (int ix = -2; ix <= 2; ix++) {
      vec2 grid = vec2(float(ix), float(iy)) * step_texel;
      vec2 offset_texel = vec2(
        grid.x * cos_r - grid.y * sin_r,
        grid.x * sin_r + grid.y * cos_r
      );
      float weight = exp(-dot(offset_texel * offset_texel, inv_2_sigma2));
      vec2 sample_uv = clamp(uv + offset_texel * inv_src, half_texel, 1.0 - half_texel);
      accum += weight * texture(u_texture, sample_uv);
      w_sum += weight;
    }
  }

  fragColor = accum / max(w_sum, 0.0001);
}
