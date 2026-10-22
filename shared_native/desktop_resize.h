#ifndef __SHARED_DESKTOP_RESIZE_H__
#define __SHARED_DESKTOP_RESIZE_H__

#include <stdint.h>

namespace shared {

// Mirrors vncclient_desktop_resize_result. Kept independent of the public C
// header so the planning rules can be exercised by the host tests without
// TigerVNC or a socket.
enum class DesktopResizeResult {
  kOk = 0,
  // The server already reports the requested size.
  kUnchanged = 1,
  kNotConnected = -1,
  kInvalidSize = -2,
  // The server never announced ExtendedDesktopSize support.
  kUnsupported = -3,
  // The server reports more than one screen; its layout must not be collapsed.
  kMultiScreen = -4,
};

// One screen of the layout the server last reported. Only the identity fields
// matter for a resize: the new rectangle is always the whole desktop.
struct DesktopScreen {
  uint32_t id = 0;
  uint32_t flags = 0;
};

struct DesktopResizePlan {
  DesktopResizeResult result = DesktopResizeResult::kNotConnected;
  int width = 0;
  int height = 0;
  // Screen entry to put in the request. Only meaningful when result is kOk.
  uint32_t screenId = 0;
  uint32_t screenFlags = 0;
};

// RFB carries desktop dimensions as unsigned 16-bit values.
constexpr int kMaxRfbDesktopSide = 65535;

// Largest remote desktop the viewer will ask for, and the smallest. Kept here
// so the client and the host tests agree on one set of numbers.
constexpr int kMaxDesktopSide = 4096;
constexpr int kMaxDesktopPixels = 3840 * 2160;
constexpr int kMinDesktopWidth = 320;
constexpr int kMinDesktopHeight = 240;

// Decides whether a resize request should be sent, and which screen entry to
// send with it.
//
// Checks run in this order, and the first match decides the result:
//   not connected, invalid size, already at the requested size, unsupported,
//   multi-screen. "Already at the requested size" comes before the capability
//   checks because a desktop that needs no change is not a failure, even when
//   the server could not have honoured a change.
//
// `screens` is the layout the server reported and may be empty before the first
// update, in which case the request carries a placeholder screen.
DesktopResizePlan PlanDesktopResize(bool connected,
                                    bool supportsResize,
                                    const DesktopScreen* screens,
                                    int screenCount,
                                    int currentWidth,
                                    int currentHeight,
                                    int requestedWidth,
                                    int requestedHeight);

// Converts a viewport size in logical units into the remote desktop size that
// fills it 1:1 in physical pixels, then clamps it to the limits above. Returns
// false for a viewport or pixel ratio that cannot produce a usable size.
bool ComputeDesktopTarget(double viewportWidth,
                          double viewportHeight,
                          double pixelRatio,
                          int* outWidth,
                          int* outHeight);

}  // namespace shared

#endif
