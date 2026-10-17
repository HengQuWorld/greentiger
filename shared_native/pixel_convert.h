#ifndef __SHARED_PIXEL_CONVERT_H__
#define __SHARED_PIXEL_CONVERT_H__

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace shared {
namespace pixel {

// Converts a rectangle of TigerVNC's little-endian 32bpp RGB buffer into the
// byte order the platform image API expects, forcing alpha to opaque.
//
// The source buffer holds one pixel per 32-bit word whose bytes are
// (sp[0], sp[1], sp[2], sp[3]); the destination word is written as
// (dp[0], dp[1], dp[2], dp[3]) with dp[3] always 255.
//
// `byte_order` mirrors the historical NAPI parameter:
//   0 -> r,g,b = sp[0],sp[1],sp[2]
//   1 -> r,g,b = sp[2],sp[1],sp[0]
//   2 -> r,g,b = sp[1],sp[2],sp[3]
//   3 -> r,g,b = sp[3],sp[2],sp[1]
//   any other value is treated as 3.
// `want_bgra` swaps the red and blue channels on output.
//
// `src` must point at the first pixel of the rectangle, `src_stride` and
// `dst_stride` are byte strides. The destination is written densely:
// `dst_stride` is expected to be `width * 4`.

template <int kMode>
inline uint32_t ConvertPixelWord(uint32_t v)
{
  if (kMode == 0) {
    // (r,g,b,X) -> (r,g,b,255)
    return (v & 0x00FFFFFFu) | 0xFF000000u;
  }
  if (kMode == 1) {
    // (r,g,b,X) -> (b,g,r,255)
    return ((v >> 16) & 0x000000FFu) | (v & 0x0000FF00u) |
           ((v & 0x000000FFu) << 16) | 0xFF000000u;
  }
  if (kMode == 2) {
    // channels start at sp[1]: (X,r,g,b) -> (r,g,b,255)
    return ((v >> 8) & 0x00FFFFFFu) | 0xFF000000u;
  }
  // (X,b,g,r) -> (b,g,r,255)
  return ((v >> 24) & 0x000000FFu) | (((v >> 16) & 0x000000FFu) << 8) |
         (((v >> 8) & 0x000000FFu) << 16) | 0xFF000000u;
}

// Word-at-a-time inner loop. Working on 32-bit words instead of four separate
// byte loads/stores lets the compiler emit NEON for the whole row.
template <int kMode>
inline void ConvertRectWords(const uint8_t* src, size_t src_stride,
                             uint8_t* dst, size_t dst_stride,
                             int width, int height)
{
  for (int y = 0; y < height; y++) {
    const uint8_t* src_row = src + static_cast<size_t>(y) * src_stride;
    uint8_t* dst_row = dst + static_cast<size_t>(y) * dst_stride;
    for (int x = 0; x < width; x++) {
      const size_t offset = static_cast<size_t>(x) * 4u;
      uint32_t v = 0;
      std::memcpy(&v, src_row + offset, sizeof(v));
      const uint32_t out = ConvertPixelWord<kMode>(v);
      std::memcpy(dst_row + offset, &out, sizeof(out));
    }
  }
}

inline void ConvertRectPixels(const uint8_t* src, size_t src_stride,
                              uint8_t* dst, size_t dst_stride,
                              int width, int height,
                              int32_t byte_order, bool want_bgra)
{
  if (!src || !dst || width <= 0 || height <= 0)
    return;

  const int bo = (byte_order < 0 || byte_order > 3) ? 3 : static_cast<int>(byte_order);
  const int swap = want_bgra ? 1 : 0;
  // byte orders 0/1 share one channel layout, 2/3 share the shifted one.
  const int mode = (bo < 2 ? 0 : 2) + ((bo & 1) ^ swap);

  switch (mode) {
    case 0: ConvertRectWords<0>(src, src_stride, dst, dst_stride, width, height); break;
    case 1: ConvertRectWords<1>(src, src_stride, dst, dst_stride, width, height); break;
    case 2: ConvertRectWords<2>(src, src_stride, dst, dst_stride, width, height); break;
    default: ConvertRectWords<3>(src, src_stride, dst, dst_stride, width, height); break;
  }
}

}  // namespace pixel
}  // namespace shared

#endif  // __SHARED_PIXEL_CONVERT_H__
