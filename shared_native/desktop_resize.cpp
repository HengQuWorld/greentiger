#include "desktop_resize.h"

#include <algorithm>
#include <cmath>

namespace shared {

namespace {

bool IsUsableDimension(int value)
{
  return value >= 1 && value <= kMaxRfbDesktopSide;
}

}  // namespace

DesktopResizePlan PlanDesktopResize(bool connected,
                                    bool supportsResize,
                                    const DesktopScreen* screens,
                                    int screenCount,
                                    int currentWidth,
                                    int currentHeight,
                                    int requestedWidth,
                                    int requestedHeight)
{
  DesktopResizePlan plan;

  if (!connected) {
    plan.result = DesktopResizeResult::kNotConnected;
    return plan;
  }

  if (!IsUsableDimension(requestedWidth) || !IsUsableDimension(requestedHeight)) {
    plan.result = DesktopResizeResult::kInvalidSize;
    return plan;
  }

  if (currentWidth == requestedWidth && currentHeight == requestedHeight) {
    plan.result = DesktopResizeResult::kUnchanged;
    return plan;
  }

  if (!supportsResize) {
    plan.result = DesktopResizeResult::kUnsupported;
    return plan;
  }

  if (screenCount > 1) {
    plan.result = DesktopResizeResult::kMultiScreen;
    return plan;
  }

  // Reuse the existing screen's identity so the server treats this as the same
  // display rather than a new one; before the first update there is nothing to
  // reuse and RFB allows a placeholder entry.
  if (screenCount == 1 && screens != nullptr) {
    plan.screenId = screens[0].id;
    plan.screenFlags = screens[0].flags;
  }

  plan.result = DesktopResizeResult::kOk;
  plan.width = requestedWidth;
  plan.height = requestedHeight;
  return plan;
}

bool ComputeDesktopTarget(double viewportWidth,
                          double viewportHeight,
                          double pixelRatio,
                          int* outWidth,
                          int* outHeight)
{
  if (outWidth == nullptr || outHeight == nullptr)
    return false;

  if (!std::isfinite(viewportWidth) || !std::isfinite(viewportHeight) ||
      !std::isfinite(pixelRatio))
    return false;

  if (viewportWidth <= 0.0 || viewportHeight <= 0.0 || pixelRatio <= 0.0)
    return false;

  const double width = std::round(viewportWidth * pixelRatio);
  const double height = std::round(viewportHeight * pixelRatio);
  if (width < 1.0 || height < 1.0)
    return false;

  double scale = 1.0;
  if (width > kMaxDesktopSide || height > kMaxDesktopSide) {
    scale = std::min(kMaxDesktopSide / width, kMaxDesktopSide / height);
  }
  const double scaledPixels = (width * scale) * (height * scale);
  if (scaledPixels > kMaxDesktopPixels) {
    scale *= std::sqrt(kMaxDesktopPixels / scaledPixels);
  }

  int targetWidth = static_cast<int>(std::floor(width * scale));
  int targetHeight = static_cast<int>(std::floor(height * scale));

  targetWidth = std::min(std::max(targetWidth, kMinDesktopWidth), kMaxRfbDesktopSide);
  targetHeight = std::min(std::max(targetHeight, kMinDesktopHeight), kMaxRfbDesktopSide);

  *outWidth = targetWidth;
  *outHeight = targetHeight;
  return true;
}

}  // namespace shared
