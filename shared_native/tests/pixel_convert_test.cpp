// Tests for shared/pixel_convert.h.
//
// The conversion replaced a per-pixel branching loop, so the primary test is a
// byte-exact comparison against that original loop kept here as an oracle. The
// remaining cases pin down the contract callers rely on (opaque alpha, source
// untouched, no writes for empty/degenerate requests).

#include "pixel_convert.h"

#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

#include "test_support.h"

namespace {

// The implementation that shipped before the word-at-a-time rewrite, kept
// verbatim as the reference for equivalence.
void LegacyConvert(const uint8_t* rgba, size_t src_stride,
                   uint8_t* dst, size_t dst_stride,
                   int width, int height, int32_t byte_order, bool want_bgra)
{
  for (int y = 0; y < height; y++) {
    const uint8_t* src_row = rgba + static_cast<size_t>(y) * src_stride;
    uint8_t* dst_row = dst + static_cast<size_t>(y) * dst_stride;
    for (int x = 0; x < width; x++) {
      const uint8_t* sp = src_row + static_cast<size_t>(x) * 4u;
      uint8_t* dp = dst_row + static_cast<size_t>(x) * 4u;

      uint8_t r;
      uint8_t g;
      uint8_t b;
      if (byte_order == 0) {
        r = sp[0];
        g = sp[1];
        b = sp[2];
      } else if (byte_order == 1) {
        b = sp[0];
        g = sp[1];
        r = sp[2];
      } else if (byte_order == 2) {
        r = sp[1];
        g = sp[2];
        b = sp[3];
      } else {
        b = sp[1];
        g = sp[2];
        r = sp[3];
      }

      if (!want_bgra) {
        dp[0] = r;
        dp[1] = g;
        dp[2] = b;
        dp[3] = 255;
      } else {
        dp[0] = b;
        dp[1] = g;
        dp[2] = r;
        dp[3] = 255;
      }
    }
  }
}

std::vector<uint8_t> RandomBytes(std::mt19937& rng, size_t count)
{
  std::vector<uint8_t> bytes(count);
  for (auto& b : bytes) {
    b = static_cast<uint8_t>(rng() & 0xFF);
  }
  return bytes;
}

void CaseMatchesOracleAcrossShapes()
{
  testing::BeginCase("matches oracle across shapes, offsets and formats");

  std::mt19937 rng(20261017);
  const int widths[] = {1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 33, 64, 127, 320};
  const int heights[] = {1, 2, 3, 5, 9};
  const int32_t byte_orders[] = {0, 1, 2, 3, -1, 7, 100};
  const bool swaps[] = {false, true};

  for (int width : widths) {
    for (int height : heights) {
      const std::vector<uint8_t> source = RandomBytes(rng, static_cast<size_t>(width) * height * 4u);

      // Offsets exercise non-aligned rect starts inside a wider frame, which is
      // what copyRectRGBA does for partial damage updates.
      for (int offset_x : {0, 1, 2}) {
        for (int offset_y : {0, 1}) {
          const int frame_w = width + offset_x;
          const int frame_h = height + offset_y;
          const size_t frame_stride = static_cast<size_t>(frame_w) * 4u;
          std::vector<uint8_t> frame(static_cast<size_t>(frame_w) * frame_h * 4u);
          for (size_t i = 0; i < frame.size(); i++) {
            frame[i] = source[i % source.size()];
          }

          const uint8_t* src = frame.data() +
                               static_cast<size_t>(offset_y) * frame_stride +
                               static_cast<size_t>(offset_x) * 4u;

          for (int32_t bo : byte_orders) {
            for (bool swap : swaps) {
              std::vector<uint8_t> expected(static_cast<size_t>(width) * height * 4u, 0xCD);
              std::vector<uint8_t> actual(expected.size(), 0xCD);

              LegacyConvert(src, frame_stride, expected.data(), static_cast<size_t>(width) * 4u,
                            width, height, bo, swap);
              shared::pixel::ConvertRectPixels(src, frame_stride, actual.data(),
                                               static_cast<size_t>(width) * 4u,
                                               width, height, bo, swap);

              if (std::memcmp(expected.data(), actual.data(), expected.size()) != 0) {
                testing::ReportFailure(__FILE__, __LINE__,
                                       "mismatch width=" + std::to_string(width) +
                                         " height=" + std::to_string(height) +
                                         " offset=" + std::to_string(offset_x) + "," +
                                         std::to_string(offset_y) +
                                         " byteOrder=" + std::to_string(bo) +
                                         " swap=" + (swap ? "true" : "false"));
                return;
              }
            }
          }
        }
      }
    }
  }
}

void CaseAlphaIsAlwaysOpaque()
{
  testing::BeginCase("alpha byte is forced to 255");

  std::mt19937 rng(4242);
  const int width = 37;
  const int height = 11;
  std::vector<uint8_t> source = RandomBytes(rng, static_cast<size_t>(width) * height * 4u);
  // Make sure at least some source pixels have a non-opaque alpha to overwrite.
  for (size_t i = 3; i < source.size(); i += 4) {
    source[i] = 0;
  }

  for (int32_t bo : {0, 1, 2, 3}) {
    for (bool swap : {false, true}) {
      std::vector<uint8_t> out(static_cast<size_t>(width) * height * 4u, 0);
      shared::pixel::ConvertRectPixels(source.data(), static_cast<size_t>(width) * 4u,
                                       out.data(), static_cast<size_t>(width) * 4u,
                                       width, height, bo, swap);
      for (size_t i = 3; i < out.size(); i += 4) {
        CHECK_EQ(static_cast<int>(out[i]), 255);
      }
    }
  }
}

void CaseChannelMappingContract()
{
  testing::BeginCase("documented channel mapping");

  // One pixel: bytes (1,2,3,4).
  const uint8_t pixel[4] = {1, 2, 3, 4};

  struct Expectation {
    int32_t byte_order;
    bool swap;
    uint8_t r;
    uint8_t g;
    uint8_t b;
  };

  const Expectation cases[] = {
    {0, false, 1, 2, 3},
    {0, true, 3, 2, 1},
    {1, false, 3, 2, 1},
    {1, true, 1, 2, 3},
    {2, false, 2, 3, 4},
    {2, true, 4, 3, 2},
    {3, false, 4, 3, 2},
    {3, true, 2, 3, 4},
    {-1, false, 4, 3, 2},  // out-of-range falls back to byte order 3
    {9, true, 2, 3, 4},
  };

  for (const auto& e : cases) {
    uint8_t out[4] = {0, 0, 0, 0};
    shared::pixel::ConvertRectPixels(pixel, 4, out, 4, 1, 1, e.byte_order, e.swap);
    CHECK_EQ(static_cast<int>(out[0]), static_cast<int>(e.r));
    CHECK_EQ(static_cast<int>(out[1]), static_cast<int>(e.g));
    CHECK_EQ(static_cast<int>(out[2]), static_cast<int>(e.b));
    CHECK_EQ(static_cast<int>(out[3]), 255);
  }
}

void CaseSourceIsNotModified()
{
  testing::BeginCase("source buffer is read-only");

  std::mt19937 rng(99);
  const int width = 23;
  const int height = 7;
  const size_t bytes = static_cast<size_t>(width) * height * 4u;
  std::vector<uint8_t> source = RandomBytes(rng, bytes);
  const std::vector<uint8_t> before = source;

  std::vector<uint8_t> out(bytes, 0);
  shared::pixel::ConvertRectPixels(source.data(), static_cast<size_t>(width) * 4u,
                                   out.data(), static_cast<size_t>(width) * 4u,
                                   width, height, 2, true);

  CHECK(std::memcmp(source.data(), before.data(), bytes) == 0);
}

void CaseDegenerateRequestsWriteNothing()
{
  testing::BeginCase("degenerate requests are no-ops");

  uint8_t src[16] = {0};
  uint8_t dst[16];
  std::memset(dst, 0xAB, sizeof(dst));

  shared::pixel::ConvertRectPixels(src, 16, dst, 16, 0, 4, 0, false);
  shared::pixel::ConvertRectPixels(src, 16, dst, 16, 4, 0, 0, false);
  shared::pixel::ConvertRectPixels(src, 16, dst, 16, -3, 4, 0, false);
  shared::pixel::ConvertRectPixels(src, 16, dst, 16, 4, -1, 0, false);
  shared::pixel::ConvertRectPixels(nullptr, 16, dst, 16, 4, 1, 0, false);
  shared::pixel::ConvertRectPixels(src, 16, nullptr, 16, 4, 1, 0, false);

  for (unsigned char byte : dst) {
    CHECK_EQ(static_cast<int>(byte), 0xAB);
  }
}

void CaseSingleRowAndColumn()
{
  testing::BeginCase("single row and single column render every pixel");

  // A 1-pixel-wide column will catch a loop that assumes at least one full
  // vector of pixels per row.
  const int width = 1;
  const int height = 40;
  std::vector<uint8_t> source(static_cast<size_t>(width) * height * 4u);
  for (int y = 0; y < height; y++) {
    source[static_cast<size_t>(y) * 4u + 0] = static_cast<uint8_t>(y);
    source[static_cast<size_t>(y) * 4u + 1] = static_cast<uint8_t>(y + 1);
    source[static_cast<size_t>(y) * 4u + 2] = static_cast<uint8_t>(y + 2);
    source[static_cast<size_t>(y) * 4u + 3] = 0;
  }

  std::vector<uint8_t> out(source.size(), 0);
  shared::pixel::ConvertRectPixels(source.data(), 4, out.data(), 4,
                                   width, height, 0, false);

  for (int y = 0; y < height; y++) {
    CHECK_EQ(static_cast<int>(out[static_cast<size_t>(y) * 4u + 0]), y);
    CHECK_EQ(static_cast<int>(out[static_cast<size_t>(y) * 4u + 3]), 255);
  }
}

}  // namespace

int main()
{
  CaseMatchesOracleAcrossShapes();
  CaseAlphaIsAlwaysOpaque();
  CaseChannelMappingContract();
  CaseSourceIsNotModified();
  CaseDegenerateRequestsWriteNothing();
  CaseSingleRowAndColumn();
  return testing::Finish("pixel_convert");
}
