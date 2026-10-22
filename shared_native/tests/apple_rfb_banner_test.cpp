// Tests for shared/apple_rfb_banner.h.
//
// The banner check is what replaced the desktop-name guess for "is the remote a
// Mac?", so it has to be exact: a false positive rewrites Ctrl+C/V to Cmd+C/V
// on a Windows or X11 host, where those shortcuts then stop working.

#include "apple_rfb_banner.h"

#include <cstring>
#include <string>

#include "test_support.h"

namespace {

bool IsApple(const std::string& banner)
{
  return shared::IsAppleRfbBanner(banner.data(), banner.size());
}

void TestAppleBanner()
{
  testing::BeginCase("apple banner");
  CHECK(IsApple("RFB 003.889\n"));
}

void TestOtherVersions()
{
  testing::BeginCase("other versions");
  CHECK(!IsApple("RFB 003.008\n"));
  CHECK(!IsApple("RFB 003.007\n"));
  CHECK(!IsApple("RFB 003.003\n"));
  CHECK(!IsApple("RFB 004.889\n"));
  CHECK(!IsApple("RFB 003.890\n"));
  CHECK(!IsApple("RFB 003.889"));
  CHECK(!IsApple("rfb 003.889\n"));
}

void TestDegenerateInput()
{
  testing::BeginCase("degenerate input");
  CHECK(!shared::IsAppleRfbBanner(nullptr, 12));
  CHECK(!shared::IsAppleRfbBanner("", 0));

  // A truncated banner must not match: the check is on the full 12 bytes.
  CHECK(!shared::IsAppleRfbBanner("RFB 003.889\n", 11));
  CHECK(!shared::IsAppleRfbBanner("RFB 003", 7));
}

void TestLongerBuffer()
{
  testing::BeginCase("longer buffer");
  // Only the leading banner matters if the caller hands over a bigger read.
  CHECK(shared::IsAppleRfbBanner("RFB 003.889\nxxxx", 16));
  CHECK(!shared::IsAppleRfbBanner("xxxxRFB 003.889\n", 16));
}

void TestStreamedBannerClassification()
{
  testing::BeginCase("banner read from a socket");

  // A reader that has part of the banner must be told to wait, not to give up.
  CHECK(shared::MatchAppleRfbBanner("RFB 003.889\n", 4) ==
        shared::AppleBannerMatch::kPartial);
  CHECK(shared::MatchAppleRfbBanner("RFB 003.889\n", 11) ==
        shared::AppleBannerMatch::kPartial);
  CHECK(shared::MatchAppleRfbBanner(nullptr, 0) == shared::AppleBannerMatch::kPartial);

  // Anything that already contradicts the prefix can be dismissed at once;
  // waiting for the rest of a wrong banner only delays the connection. The
  // first byte that differs is index 8 ("3.008" against "3.889").
  CHECK(shared::MatchAppleRfbBanner("RFB 003.008\n", 8) ==
        shared::AppleBannerMatch::kPartial);
  CHECK(shared::MatchAppleRfbBanner("RFB 003.008\n", 9) ==
        shared::AppleBannerMatch::kNo);
  CHECK(shared::MatchAppleRfbBanner("HTTP/1.1\r\n", 10) ==
        shared::AppleBannerMatch::kNo);

  // The full banner completes the match.
  CHECK(shared::MatchAppleRfbBanner("RFB 003.889\n", 12) ==
        shared::AppleBannerMatch::kYes);
}

}  // namespace

int main()
{
  TestAppleBanner();
  TestOtherVersions();
  TestDegenerateInput();
  TestLongerBuffer();
  TestStreamedBannerClassification();
  return testing::Finish("apple_rfb_banner");
}
