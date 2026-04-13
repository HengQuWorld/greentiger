#ifndef __SHARED_MONITOR_SEGMENTATION_H__
#define __SHARED_MONITOR_SEGMENTATION_H__

#include <stdint.h>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int x;
  int y;
  int w;
  int h;
} MonitorRect;

// Exported for testing/integration.
// C-API wrappers can be added if needed, but since our JNI/NAPI uses C++ directly,
// we can expose the C++ interface.

#ifdef __cplusplus
} // extern "C"

namespace MonitorSegmentation {

std::vector<MonitorRect> detectMonitorRectsFromRgbaFrame(int width, int height, const uint8_t* rgba, const std::vector<MonitorRect>& fallbackRects = {});

// Core utility functions for edge emptiness checks
bool isHorizontalEdgeEmpty(int fbW, const MonitorRect& slot, const uint8_t* view, int y);
bool isVerticalEdgeEmpty(int fbW, const MonitorRect& slot, const uint8_t* view, int x);
bool isDarkPixel(const uint8_t* view, size_t offset, int threshold = 18);

} // namespace MonitorSegmentation

#endif

#endif // __SHARED_MONITOR_SEGMENTATION_H__
