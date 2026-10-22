// Tests for the remote-desktop resize rules. A wrong answer here either sends a
// request the server will reject, or silently leaves the picture letterboxed,
// and both are invisible until someone looks at a real session.

#include "desktop_resize.h"

#include "test_support.h"

namespace {

using shared::DesktopResizePlan;
using shared::DesktopResizeResult;
using shared::DesktopScreen;

DesktopScreen Screen(uint32_t id, uint32_t flags)
{
  DesktopScreen s;
  s.id = id;
  s.flags = flags;
  return s;
}

bool ResultIs(const DesktopResizePlan& plan, DesktopResizeResult expected)
{
  return plan.result == expected;
}

void CaseNotConnected()
{
  testing::BeginCase("a closed session is refused");

  const DesktopScreen screens[] = { Screen(7, 0) };
  const DesktopResizePlan plan =
      shared::PlanDesktopResize(false, true, screens, 1, 1920, 1080, 2560, 1600);
  CHECK(ResultIs(plan, DesktopResizeResult::kNotConnected));
}

void CaseInvalidRequestedSize()
{
  testing::BeginCase("dimensions RFB cannot carry are refused");

  const DesktopScreen screens[] = { Screen(7, 0) };
  for (int bad : {0, -1, -1920, shared::kMaxRfbDesktopSide + 1}) {
    const DesktopResizePlan plan =
        shared::PlanDesktopResize(true, true, screens, 1, 1920, 1080, bad, 1080);
    CHECK(ResultIs(plan, DesktopResizeResult::kInvalidSize));
  }
  const DesktopResizePlan plan =
      shared::PlanDesktopResize(true, true, screens, 1, 1920, 1080, 1920, 0);
  CHECK(ResultIs(plan, DesktopResizeResult::kInvalidSize));
}

void CaseUnchangedSizeWins()
{
  testing::BeginCase("an already matching desktop is not a failure");

  // Reported before the capability checks: nothing needs to be sent, so a
  // server that cannot resize is not described as unable to.
  const DesktopScreen screens[] = { Screen(7, 0) };
  const DesktopResizePlan plan =
      shared::PlanDesktopResize(true, false, screens, 1, 1920, 1080, 1920, 1080);
  CHECK(ResultIs(plan, DesktopResizeResult::kUnchanged));
}

void CaseUnsupportedServer()
{
  testing::BeginCase("a server without ExtendedDesktopSize is reported as such");

  const DesktopScreen screens[] = { Screen(7, 0) };
  const DesktopResizePlan plan =
      shared::PlanDesktopResize(true, false, screens, 1, 1920, 1080, 2560, 1600);
  CHECK(ResultIs(plan, DesktopResizeResult::kUnsupported));
}

void CaseMultiScreenLeftAlone()
{
  testing::BeginCase("a multi-screen desktop is never collapsed");

  const DesktopScreen screens[] = { Screen(7, 0), Screen(8, 0) };
  const DesktopResizePlan plan =
      shared::PlanDesktopResize(true, true, screens, 2, 3840, 1080, 2560, 1600);
  CHECK(ResultIs(plan, DesktopResizeResult::kMultiScreen));
}

void CaseSingleScreenKeepsIdentity()
{
  testing::BeginCase("the existing screen id and flags are reused");

  const DesktopScreen screens[] = { Screen(0xdeadbeef, 0x2) };
  const DesktopResizePlan plan =
      shared::PlanDesktopResize(true, true, screens, 1, 1920, 1080, 3296, 2405);
  CHECK(ResultIs(plan, DesktopResizeResult::kOk));
  CHECK_EQ(plan.width, 3296);
  CHECK_EQ(plan.height, 2405);
  CHECK_EQ(plan.screenId, 0xdeadbeefu);
  CHECK_EQ(plan.screenFlags, 0x2u);
}

void CaseNoLayoutYetUsesPlaceholder()
{
  testing::BeginCase("before the first update a placeholder screen is sent");

  const DesktopResizePlan nullScreens =
      shared::PlanDesktopResize(true, true, nullptr, 0, 1920, 1080, 2560, 1600);
  CHECK(ResultIs(nullScreens, DesktopResizeResult::kOk));
  CHECK_EQ(nullScreens.screenId, 0u);
  CHECK_EQ(nullScreens.screenFlags, 0u);

  // A count of one without storage is malformed input, not a crash.
  const DesktopResizePlan missingScreens =
      shared::PlanDesktopResize(true, true, nullptr, 1, 1920, 1080, 2560, 1600);
  CHECK(ResultIs(missingScreens, DesktopResizeResult::kOk));
  CHECK_EQ(missingScreens.screenId, 0u);
}

void CaseTargetMatchesViewport()
{
  testing::BeginCase("the target is the viewport in physical pixels");

  int w = 0;
  int h = 0;
  CHECK(shared::ComputeDesktopTarget(824.0, 601.25, 4.0, &w, &h));
  CHECK_EQ(w, 3296);
  CHECK_EQ(h, 2405);

  // A 1x ratio leaves the viewport untouched.
  CHECK(shared::ComputeDesktopTarget(1280.0, 800.0, 1.0, &w, &h));
  CHECK_EQ(w, 1280);
  CHECK_EQ(h, 800);
}

void CaseTargetClampsToLimits()
{
  testing::BeginCase("targets are clamped to the supported range");

  int w = 0;
  int h = 0;
  // A 5K-wide window hits the side limit before the pixel budget applies.
  CHECK(shared::ComputeDesktopTarget(1400.0, 900.0, 4.0, &w, &h));
  CHECK(w <= shared::kMaxDesktopSide);
  CHECK(h <= shared::kMaxDesktopSide);
  CHECK(w * h <= shared::kMaxDesktopPixels);

  // A very wide window is bounded by the same limits.
  CHECK(shared::ComputeDesktopTarget(2000.0, 300.0, 3.0, &w, &h));
  CHECK(w <= shared::kMaxDesktopSide);
  CHECK(w * h <= shared::kMaxDesktopPixels);

  // A tiny window is raised to the minimum so the server is not asked for a
  // desktop it would reject or render uselessly small.
  CHECK(shared::ComputeDesktopTarget(20.0, 10.0, 1.0, &w, &h));
  CHECK_EQ(w, shared::kMinDesktopWidth);
  CHECK_EQ(h, shared::kMinDesktopHeight);
}

void CaseTargetRejectsBadInput()
{
  testing::BeginCase("unusable viewports produce no target");

  int w = 0;
  int h = 0;
  CHECK(!shared::ComputeDesktopTarget(0.0, 600.0, 4.0, &w, &h));
  CHECK(!shared::ComputeDesktopTarget(-10.0, 600.0, 4.0, &w, &h));
  CHECK(!shared::ComputeDesktopTarget(824.0, 601.0, 0.0, &w, &h));
  CHECK(!shared::ComputeDesktopTarget(824.0, 601.0, -1.0, &w, &h));

  const double nan = 0.0 / 0.0;
  const double inf = 1.0 / 0.0;
  CHECK(!shared::ComputeDesktopTarget(nan, 601.0, 4.0, &w, &h));
  CHECK(!shared::ComputeDesktopTarget(inf, 601.0, 4.0, &w, &h));
  CHECK(!shared::ComputeDesktopTarget(824.0, 601.0, inf, &w, &h));

  CHECK(!shared::ComputeDesktopTarget(824.0, 601.0, 4.0, nullptr, &h));
  CHECK(!shared::ComputeDesktopTarget(824.0, 601.0, 4.0, &w, nullptr));
}

void CaseTargetNeverLeavesRfbRange()
{
  testing::BeginCase("computed sizes always fit the 16-bit RFB fields");

  for (double ratio : {0.5, 1.0, 1.5, 2.0, 3.0, 4.0}) {
    for (double width : {1.0, 320.0, 1024.0, 4096.0, 16384.0}) {
      int w = 0;
      int h = 0;
      if (!shared::ComputeDesktopTarget(width, width * 0.75, ratio, &w, &h))
        continue;
      CHECK(w >= shared::kMinDesktopWidth);
      CHECK(h >= shared::kMinDesktopHeight);
      CHECK(w <= shared::kMaxRfbDesktopSide);
      CHECK(h <= shared::kMaxRfbDesktopSide);
      CHECK(w * h <= shared::kMaxDesktopPixels);
    }
  }
}

}  // namespace

int main()
{
  CaseNotConnected();
  CaseInvalidRequestedSize();
  CaseUnchangedSizeWins();
  CaseUnsupportedServer();
  CaseMultiScreenLeftAlone();
  CaseSingleScreenKeepsIdentity();
  CaseNoLayoutYetUsesPlaceholder();
  CaseTargetMatchesViewport();
  CaseTargetClampsToLimits();
  CaseTargetRejectsBadInput();
  CaseTargetNeverLeavesRfbRange();
  return testing::Finish("desktop_resize");
}
