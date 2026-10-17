// Tests for MonitorSegmentation. These pin down the contract the viewer relies
// on when it decides how many screens to render, rather than the exact heuristic
// output, so the segmentation can keep being tuned.

#include "monitor_segmentation.h"

#include <cstdint>
#include <random>
#include <vector>

#include "test_support.h"

namespace {

struct Frame {
  int width = 0;
  int height = 0;
  std::vector<uint8_t> rgba;

  Frame(int w, int h, uint8_t r = 0, uint8_t g = 0, uint8_t b = 0)
    : width(w), height(h), rgba(static_cast<size_t>(w) * h * 4u)
  {
    for (size_t i = 0; i < rgba.size(); i += 4) {
      rgba[i + 0] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }

  void FillRect(int x, int y, int w, int h, uint8_t r, uint8_t g, uint8_t b)
  {
    for (int yy = y; yy < y + h && yy < height; yy++) {
      for (int xx = x; xx < x + w && xx < width; xx++) {
        if (xx < 0 || yy < 0) continue;
        const size_t o = (static_cast<size_t>(yy) * width + xx) * 4u;
        rgba[o + 0] = r;
        rgba[o + 1] = g;
        rgba[o + 2] = b;
        rgba[o + 3] = 255;
      }
    }
  }
};

bool RectsFitFrame(const std::vector<MonitorRect>& rects, int w, int h)
{
  for (const auto& r : rects) {
    if (r.w <= 0 || r.h <= 0) return false;
    if (r.x < 0 || r.y < 0) return false;
    if (r.x + r.w > w || r.y + r.h > h) return false;
  }
  return true;
}

void CaseDegenerateInputs()
{
  testing::BeginCase("degenerate frames return no rects");

  Frame f(8, 8);
  CHECK(MonitorSegmentation::detectMonitorRectsFromRgbaFrame(0, 8, f.rgba.data()).empty());
  CHECK(MonitorSegmentation::detectMonitorRectsFromRgbaFrame(8, 0, f.rgba.data()).empty());
  CHECK(MonitorSegmentation::detectMonitorRectsFromRgbaFrame(-4, 8, f.rgba.data()).empty());
  CHECK(MonitorSegmentation::detectMonitorRectsFromRgbaFrame(8, 8, nullptr).empty());
}

void CaseAlwaysReturnsUsableRects()
{
  testing::BeginCase("results always fit inside the frame");

  std::mt19937 rng(7);
  const int sizes[][2] = {{1, 1}, {2, 3}, {16, 9}, {320, 200}, {1024, 768}, {1920, 1080}, {3840, 1080}};

  for (const auto& size : sizes) {
    const int w = size[0];
    const int h = size[1];
    Frame f(w, h);
    for (auto& byte : f.rgba) {
      byte = static_cast<uint8_t>(rng() & 0xFF);
    }

    const auto rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(w, h, f.rgba.data());
    if (rects.empty()) {
      testing::ReportFailure(__FILE__, __LINE__,
                             "no rects for " + std::to_string(w) + "x" + std::to_string(h));
      continue;
    }
    if (!RectsFitFrame(rects, w, h)) {
      testing::ReportFailure(__FILE__, __LINE__,
                             "rect outside frame for " + std::to_string(w) + "x" + std::to_string(h));
    }
    if (rects.size() > 4) {
      testing::ReportFailure(__FILE__, __LINE__,
                             "unexpected rect count " + std::to_string(rects.size()));
    }
  }
}

void CaseBlankFrameUsesFallback()
{
  testing::BeginCase("a blank frame falls back to one full-screen rect");

  Frame f(1024, 768);
  const auto rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(1024, 768, f.rgba.data());

  CHECK_EQ(static_cast<int>(rects.size()), 1);
  if (rects.size() == 1) {
    CHECK_EQ(rects[0].x, 0);
    CHECK_EQ(rects[0].y, 0);
    CHECK_EQ(rects[0].w, 1024);
    CHECK_EQ(rects[0].h, 768);
  }
}

void CaseExplicitFallbackIsHonoured()
{
  testing::BeginCase("explicit fallback rects are used for a blank frame");

  Frame f(800, 400);
  const std::vector<MonitorRect> fallback = {{0, 0, 400, 400}, {400, 0, 400, 400}};
  const auto rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(800, 400, f.rgba.data(), fallback);

  CHECK_EQ(static_cast<int>(rects.size()), 2);
  if (rects.size() == 2) {
    CHECK_EQ(rects[0].x, 0);
    CHECK_EQ(rects[1].x, 400);
    CHECK_EQ(rects[0].h, 400);
    CHECK_EQ(rects[1].h, 400);
  }
}

void CaseUltraWideFrameSplitsInTwo()
{
  testing::BeginCase("a 3840x1080 frame splits into two screens");

  // A 32:9 desktop is two 1920x1080 screens side by side; the heuristic default
  // and the content-based detection should agree on two equal halves.
  Frame f(3840, 1080);
  f.FillRect(0, 0, 1270, 1080, 40, 90, 160);
  f.FillRect(1280, 0, 1270, 1080, 60, 120, 90);
  f.FillRect(2560, 0, 1270, 1080, 120, 80, 80);

  const auto rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(3840, 1080, f.rgba.data());
  CHECK(RectsFitFrame(rects, 3840, 1080));
  CHECK_EQ(static_cast<int>(rects.size()), 2);
  if (rects.size() == 2) {
    CHECK_EQ(rects[0].x, 0);
    CHECK_EQ(rects[0].w, 1920);
    CHECK_EQ(rects[1].x, 1920);
    CHECK_EQ(rects[1].w, 1920);
    CHECK_EQ(rects[0].h, 1080);
    CHECK_EQ(rects[1].h, 1080);
  }
}

void CaseContentCropsToWindow()
{
  testing::BeginCase("a single window on black crops to the window area");

  Frame f(1024, 768);
  f.FillRect(100, 100, 800, 600, 40, 90, 160);

  const auto rects = MonitorSegmentation::detectMonitorRectsFromRgbaFrame(1024, 768, f.rgba.data());
  CHECK_EQ(static_cast<int>(rects.size()), 1);
  if (rects.size() == 1) {
    // Tolerate small differences from threshold tuning; catch gross regressions.
    CHECK(rects[0].x >= 80 && rects[0].x <= 120);
    CHECK(rects[0].y >= 80 && rects[0].y <= 120);
    CHECK(rects[0].w >= 760 && rects[0].w <= 820);
    CHECK(rects[0].h >= 560 && rects[0].h <= 620);
  }
}

void CaseDarkPixelThreshold()
{
  testing::BeginCase("isDarkPixel honours alpha and brightness");

  uint8_t opaque_black[4] = {0, 0, 0, 255};
  uint8_t transparent[4] = {255, 255, 255, 0};
  uint8_t bright[4] = {90, 90, 90, 255};
  uint8_t dim[4] = {4, 4, 4, 255};

  // A fully transparent pixel counts as dark regardless of its colour.
  CHECK(MonitorSegmentation::isDarkPixel(opaque_black, 0));
  CHECK(MonitorSegmentation::isDarkPixel(transparent, 0));
  CHECK(!MonitorSegmentation::isDarkPixel(bright, 0));
  // The default threshold applies to the summed RGB value.
  CHECK(MonitorSegmentation::isDarkPixel(dim, 0));
  CHECK(!MonitorSegmentation::isDarkPixel(dim, 0, 5));
}

void CaseEdgeEmptinessOnUniformRows()
{
  testing::BeginCase("edge emptiness follows row and column content");

  Frame f(64, 64);
  const MonitorRect slot{0, 0, 64, 64};

  CHECK(MonitorSegmentation::isHorizontalEdgeEmpty(64, slot, f.rgba.data(), 0));
  CHECK(MonitorSegmentation::isVerticalEdgeEmpty(64, slot, f.rgba.data(), 0));

  f.FillRect(0, 32, 64, 1, 255, 255, 255);
  CHECK(!MonitorSegmentation::isHorizontalEdgeEmpty(64, slot, f.rgba.data(), 32));

  f.FillRect(48, 0, 1, 64, 255, 255, 255);
  CHECK(!MonitorSegmentation::isVerticalEdgeEmpty(64, slot, f.rgba.data(), 48));
}

}  // namespace

int main()
{
  CaseDegenerateInputs();
  CaseAlwaysReturnsUsableRects();
  CaseBlankFrameUsesFallback();
  CaseExplicitFallbackIsHonoured();
  CaseUltraWideFrameSplitsInTwo();
  CaseContentCropsToWindow();
  CaseDarkPixelThreshold();
  CaseEdgeEmptinessOnUniformRows();
  return testing::Finish("monitor_segmentation");
}
