#ifndef __SHARED_APPLE_RFB_BANNER_H__
#define __SHARED_APPLE_RFB_BANNER_H__

#include <cstddef>
#include <cstring>

namespace shared {

// Size of the RFB version banner the server sends first ("RFB 003.008\n").
constexpr size_t kRfbBannerLength = 12;

enum class AppleBannerMatch {
  // The bytes received so far cannot be Apple's banner.
  kNo,
  // The prefix matches, but the banner is not complete yet.
  kPartial,
  // The complete banner was received.
  kYes,
};

// Classifies whatever part of the version banner has arrived.
//
// Apple's Screen Sharing / ARD server is the only server that announces 3.889,
// which makes the banner the one reliable way to recognise a Mac remotely: the
// desktop name is just the computer name, and TigerVNC rewrites the version to
// 3.8 during the handshake, so callers can never observe it afterwards.
//
// A caller reading from a socket needs the three-way answer: a mismatch can be
// reported as soon as it shows up, while a matching but short read only means
// "wait for the rest".
inline AppleBannerMatch MatchAppleRfbBanner(const char* banner, size_t length)
{
  static const char kApplePrefix[] = "RFB 003.889";
  constexpr size_t kApplePrefixLength = sizeof(kApplePrefix) - 1;

  if (!banner || length == 0)
    return AppleBannerMatch::kPartial;

  const size_t compared = length < kApplePrefixLength ? length : kApplePrefixLength;
  if (std::memcmp(banner, kApplePrefix, compared) != 0)
    return AppleBannerMatch::kNo;

  return length >= kRfbBannerLength ? AppleBannerMatch::kYes
                                    : AppleBannerMatch::kPartial;
}

// True when an RFB version banner is Apple's private 3.889 version.
inline bool IsAppleRfbBanner(const char* banner, size_t length)
{
  return MatchAppleRfbBanner(banner, length) == AppleBannerMatch::kYes;
}

}  // namespace shared

#endif
