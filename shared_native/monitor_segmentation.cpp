#include "monitor_segmentation.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace MonitorSegmentation {

struct HistogramBar {
  int start;
  int height;
};

struct SeamCandidate {
  int index;
  double score;
};

static int clamp(int v, int min, int max) {
  return std::max(min, std::min(max, v));
}

static bool areRectsSimilar(const MonitorRect& a, const MonitorRect& b) {
  return std::abs(a.x - b.x) <= 10 &&
         std::abs(a.y - b.y) <= 10 &&
         std::abs(a.w - b.w) <= 16 &&
         std::abs(a.h - b.h) <= 16;
}

bool isDarkPixel(const uint8_t* view, size_t offset, int threshold) {
  int alpha = view[offset + 3];
  int brightness = view[offset] + view[offset + 1] + view[offset + 2];
  return alpha <= 8 || brightness <= threshold;
}

bool isHorizontalEdgeEmpty(int fbW, const MonitorRect& slot, const uint8_t* view, int y) {
  int litCount = 0;
  int samples = 0;
  int step = std::max(1, slot.w / 120);
  for (int x = slot.x; x < slot.x + slot.w; x += step) {
    samples++;
    if (!isDarkPixel(view, static_cast<size_t>((y * fbW) + x) * 4, 48)) {
      litCount++;
    }
  }
  return litCount <= std::max(4, static_cast<int>(samples * 0.12));
}

bool isVerticalEdgeEmpty(int fbW, const MonitorRect& slot, const uint8_t* view, int x) {
  int litCount = 0;
  int samples = 0;
  int step = std::max(1, slot.h / 120);
  for (int y = slot.y; y < slot.y + slot.h; y += step) {
    samples++;
    if (!isDarkPixel(view, static_cast<size_t>((y * fbW) + x) * 4, 48)) {
      litCount++;
    }
  }
  return litCount <= std::max(4, static_cast<int>(samples * 0.12));
}

static int findTopInset(int fbW, const MonitorRect& slot, const uint8_t* view) {
  int maxInset = 0;
  int consecutiveNonEmpty = 0;
  for (int inset = 0; inset < slot.h - 1; inset++) {
    int y = slot.y + inset;
    if (!isHorizontalEdgeEmpty(fbW, slot, view, y)) {
      consecutiveNonEmpty++;
      if (consecutiveNonEmpty > 6) break;
    } else {
      consecutiveNonEmpty = 0;
      maxInset = inset + 1;
    }
  }
  return maxInset;
}

static int findBottomInset(int fbW, const MonitorRect& slot, const uint8_t* view, int topInset) {
  int maxInset = 0;
  int consecutiveNonEmpty = 0;
  for (int inset = 0; inset < slot.h - topInset - 1; inset++) {
    int y = slot.y + slot.h - 1 - inset;
    if (!isHorizontalEdgeEmpty(fbW, slot, view, y)) {
      consecutiveNonEmpty++;
      if (consecutiveNonEmpty > 6) break;
    } else {
      consecutiveNonEmpty = 0;
      maxInset = inset + 1;
    }
  }
  return maxInset;
}

static int findLeftInset(int fbW, const MonitorRect& slot, const uint8_t* view) {
  int maxInset = 0;
  int consecutiveNonEmpty = 0;
  for (int inset = 0; inset < slot.w - 1; inset++) {
    int x = slot.x + inset;
    if (!isVerticalEdgeEmpty(fbW, slot, view, x)) {
      consecutiveNonEmpty++;
      if (consecutiveNonEmpty > 6) break;
    } else {
      consecutiveNonEmpty = 0;
      maxInset = inset + 1;
    }
  }
  return maxInset;
}

static int findRightInset(int fbW, const MonitorRect& slot, const uint8_t* view, int leftInset) {
  int maxInset = 0;
  int consecutiveNonEmpty = 0;
  for (int inset = 0; inset < slot.w - leftInset - 1; inset++) {
    int x = slot.x + slot.w - 1 - inset;
    if (!isVerticalEdgeEmpty(fbW, slot, view, x)) {
      consecutiveNonEmpty++;
      if (consecutiveNonEmpty > 6) break;
    } else {
      consecutiveNonEmpty = 0;
      maxInset = inset + 1;
    }
  }
  return maxInset;
}

static MonitorRect trimMonitorBlackMargins(int fbW, int fbH, const MonitorRect& slot, const uint8_t* view) {
  if (slot.w <= 0 || slot.h <= 0) return slot;
  int top = findTopInset(fbW, slot, view);
  int bottom = findBottomInset(fbW, slot, view, top);
  int left = findLeftInset(fbW, slot, view);
  int right = findRightInset(fbW, slot, view, left);
  
  MonitorRect trimmed = {
    slot.x + left,
    slot.y + top,
    std::max(1, slot.w - left - right),
    std::max(1, slot.h - top - bottom)
  };
  
  int minW = std::max(120, static_cast<int>(slot.w * 0.25));
  int minH = std::max(120, static_cast<int>(slot.h * 0.25));
  int trimW = slot.w - trimmed.w;
  int trimH = slot.h - trimmed.h;
  if (trimmed.w < minW || trimmed.h < minH) return slot;
  if (trimW < 12 && trimH < 12) return slot;
  return trimmed;
}

static std::vector<MonitorRect> getHeuristicMonitorRects(int fbW, int fbH) {
  std::vector<MonitorRect> next;
  if (fbW <= 0 || fbH <= 0) return next;

  double ratio = static_cast<double>(fbW) / fbH;
  if (ratio >= 2.1) {
    if (ratio >= 4.0) {
      int w = fbW / 3;
      next.push_back({0, 0, w, fbH});
      next.push_back({w, 0, w, fbH});
      next.push_back({w * 2, 0, fbW - (w * 2), fbH});
    } else {
      int w = fbW / 2;
      next.push_back({0, 0, w, fbH});
      next.push_back({w, 0, fbW - w, fbH});
    }
  } else {
    next.push_back({0, 0, fbW, fbH});
  }
  return next;
}

static std::vector<MonitorRect> sortMonitorRects(const std::vector<MonitorRect>& rects) {
  std::vector<MonitorRect> next = rects;
  if (next.size() <= 1) return next;

  double minCenterX = std::numeric_limits<double>::infinity();
  double maxCenterX = -std::numeric_limits<double>::infinity();
  double minCenterY = std::numeric_limits<double>::infinity();
  double maxCenterY = -std::numeric_limits<double>::infinity();

  for (const auto& rect : next) {
    double centerX = rect.x + (rect.w / 2.0);
    double centerY = rect.y + (rect.h / 2.0);
    minCenterX = std::min(minCenterX, centerX);
    maxCenterX = std::max(maxCenterX, centerX);
    minCenterY = std::min(minCenterY, centerY);
    maxCenterY = std::max(maxCenterY, centerY);
  }

  double horizontalSpread = maxCenterX - minCenterX;
  double verticalSpread = maxCenterY - minCenterY;

  std::sort(next.begin(), next.end(), [horizontalSpread, verticalSpread](const MonitorRect& a, const MonitorRect& b) {
    if (horizontalSpread >= verticalSpread * 1.25) {
      if (std::abs(a.x - b.x) > 40) return a.x < b.x;
      return a.y < b.y;
    }
    if (verticalSpread >= horizontalSpread * 1.25) {
      if (std::abs(a.y - b.y) > 40) return a.y < b.y;
      return a.x < b.x;
    }
    double ay = a.y + (a.h / 2.0);
    double by = b.y + (b.h / 2.0);
    if (std::abs(ay - by) > 40) return ay < by;
    return a.x < b.x;
  });

  return next;
}

static bool isHorizontalMonitorLayoutCandidate(const std::vector<MonitorRect>& rects, int fbH) {
  if (rects.size() <= 1 || rects.size() > 3) return false;
  std::vector<MonitorRect> sorted = sortMonitorRects(rects);
  for (size_t i = 0; i < sorted.size(); i++) {
    if (sorted[i].h < static_cast<int>(fbH * 0.72)) return false;
    if (i > 0 && sorted[i].x <= sorted[i - 1].x) return false;
  }
  return true;
}

static std::vector<double> buildColumnActivityProfile(int fbW, int fbH, const uint8_t* view, int sampleW, int sampleH) {
  std::vector<double> profile(sampleW, 0.0);
  int stepX = std::max(1, fbW / sampleW);
  int stepY = std::max(1, fbH / sampleH);

  for (int i = 0; i < sampleW; i++) {
    double activity = 0;
    int x = std::min(fbW - 1, i * stepX);
    int prevBright = -1;
    for (int j = 0; j < sampleH; j++) {
      int y = std::min(fbH - 1, j * stepY);
      size_t offset = static_cast<size_t>((y * fbW) + x) * 4;
      int bright = view[offset] + view[offset + 1] + view[offset + 2];
      if (prevBright >= 0) {
        activity += std::abs(bright - prevBright) / 765.0;
      }
      prevBright = bright;
    }
    profile[i] = activity / std::max(1, sampleH - 1);
  }
  return profile;
}

static std::vector<double> buildColumnBlacknessProfile(int fbW, int fbH, const uint8_t* view, int sampleW, int sampleH) {
  std::vector<double> profile(sampleW, 0.0);
  int stepX = std::max(1, fbW / sampleW);
  int stepY = std::max(1, fbH / sampleH);

  for (int i = 0; i < sampleW; i++) {
    int blackCount = 0;
    int x = std::min(fbW - 1, i * stepX);
    for (int j = 0; j < sampleH; j++) {
      int y = std::min(fbH - 1, j * stepY);
      if (isDarkPixel(view, static_cast<size_t>((y * fbW) + x) * 4)) {
        blackCount++;
      }
    }
    profile[i] = static_cast<double>(blackCount) / std::max(1, sampleH);
  }
  return profile;
}

static std::vector<int> readPixel(int fbW, int fbH, const uint8_t* view, int x, int y) {
  int xx = clamp(x, 0, std::max(0, fbW - 1));
  int yy = clamp(y, 0, std::max(0, fbH - 1));
  size_t offset = static_cast<size_t>((yy * fbW) + xx) * 4;
  return { view[offset], view[offset + 1], view[offset + 2] };
}

static std::vector<double> buildColumnBrightnessProfile(int fbW, int fbH, const uint8_t* view, int sampleW, int sampleH) {
  std::vector<double> profile(sampleW, 0.0);
  for (int sx = 0; sx < sampleW; sx++) {
    double brightnessSum = 0;
    for (int sy = 0; sy < sampleH; sy++) {
      int x = static_cast<int>((sx + 0.5) * fbW) / sampleW;
      int y = static_cast<int>((sy + 0.5) * fbH) / sampleH;
      std::vector<int> rgb = readPixel(fbW, fbH, view, x, y);
      brightnessSum += (rgb[0] + rgb[1] + rgb[2]) / 765.0;
    }
    profile[sx] = brightnessSum / std::max(1, sampleH);
  }
  return profile;
}

static std::vector<double> smoothProfile(const std::vector<double>& profile, int radius) {
  if (radius <= 0 || profile.size() <= 2) return profile;
  std::vector<double> smoothed(profile.size(), 0.0);
  for (size_t i = 0; i < profile.size(); i++) {
    double total = 0;
    int count = 0;
    int start = std::max(0, static_cast<int>(i) - radius);
    int end = std::min(static_cast<int>(profile.size() - 1), static_cast<int>(i) + radius);
    for (int j = start; j <= end; j++) {
      total += profile[j];
      count++;
    }
    smoothed[i] = total / std::max(1, count);
  }
  return smoothed;
}

static double averageProfileRange(const std::vector<double>& profile, int start, int end) {
  int clampedStart = clamp(start, 0, std::max(0, static_cast<int>(profile.size() - 1)));
  int clampedEnd = clamp(end, clampedStart, std::max(0, static_cast<int>(profile.size() - 1)));
  double total = 0;
  int count = 0;
  for (int i = clampedStart; i <= clampedEnd; i++) {
    total += profile[i];
    count++;
  }
  return total / std::max(1, count);
}

static std::vector<int> findStrongestHorizontalSeams(const std::vector<double>& profile, const std::vector<double>& brightness, const std::vector<double>& blackness, int seamCount,
  const std::vector<MonitorRect>& fallbackRects, int fbW) {
  if (seamCount <= 0) return {};
  
  std::vector<double> fallbackSeams;
  std::vector<MonitorRect> sortedFallback = sortMonitorRects(fallbackRects);
  for (size_t i = 0; i + 1 < sortedFallback.size(); i++) {
    fallbackSeams.push_back((static_cast<double>(sortedFallback[i].x + sortedFallback[i].w) / std::max(1, fbW)) * profile.size());
  }

  std::vector<SeamCandidate> candidates;
  int margin = std::max(12, static_cast<int>(profile.size() * 0.16));
  int band = std::max(4, static_cast<int>(profile.size() * 0.05));
  for (int i = margin; i < static_cast<int>(profile.size()) - margin; i++) {
    double leftActivity = averageProfileRange(profile, i - band, i - 1);
    double rightActivity = averageProfileRange(profile, i, i + band - 1);
    double leftBrightness = averageProfileRange(brightness, i - band, i - 1);
    double rightBrightness = averageProfileRange(brightness, i, i + band - 1);
    double leftBlackness = averageProfileRange(blackness, i - band, i - 1);
    double rightBlackness = averageProfileRange(blackness, i, i + band - 1);
    
    double leftMass = averageProfileRange(profile, 0, i - 1);
    double rightMass = averageProfileRange(profile, i, profile.size() - 1);
    
    double edgeScore = std::abs(profile[i] - profile[i - 1]) + std::abs(brightness[i] - brightness[i - 1]);
    double activityDiff = std::abs(leftActivity - rightActivity);
    double brightnessDiff = std::abs(leftBrightness - rightBrightness);
    double blacknessDiff = std::abs(leftBlackness - rightBlackness);
    
    double fallbackDistance = 0;
    if (!fallbackSeams.empty()) {
      fallbackDistance = std::numeric_limits<double>::infinity();
      for (double fs : fallbackSeams) {
        fallbackDistance = std::min(fallbackDistance, std::abs(i - fs));
      }
    }
    double fallbackPenalty = !fallbackSeams.empty() ? (fallbackDistance / std::max(1, static_cast<int>(profile.size()))) * 0.02 : 0;
    
    double score = (activityDiff * 0.30) +
      (brightnessDiff * 0.15) +
      (blacknessDiff * 0.40) +
      (edgeScore * 0.20) +
      (std::min(leftMass, rightMass) * 0.10) -
      fallbackPenalty;
      
    if (score >= 0.06) {
      candidates.push_back({ i, score });
    }
  }

  std::sort(candidates.begin(), candidates.end(), [](const SeamCandidate& a, const SeamCandidate& b) {
    return a.score > b.score;
  });

  std::vector<int> picked;
  int minGap = std::max(18, static_cast<int>(profile.size() * 0.12));
  for (const auto& candidate : candidates) {
    bool tooClose = false;
    for (int p : picked) {
      if (std::abs(candidate.index - p) < minGap) {
        tooClose = true;
        break;
      }
    }
    if (tooClose) continue;
    picked.push_back(candidate.index);
    if (static_cast<int>(picked.size()) >= seamCount) break;
  }

  std::sort(picked.begin(), picked.end());
  std::vector<int> seams;
  for (int p : picked) {
    int fullX = static_cast<int>((static_cast<double>(p) / profile.size()) * fbW);
    seams.push_back(clamp(fullX, static_cast<int>(fbW * 0.12), static_cast<int>(std::ceil(fbW * 0.88))));
  }
  return seams;
}

static std::vector<MonitorRect> buildFullHeightRectsFromSeams(int fbW, int fbH, const std::vector<int>& seams) {
  std::vector<int> sortedSeams = seams;
  std::sort(sortedSeams.begin(), sortedSeams.end());
  std::vector<MonitorRect> rects;
  int left = 0;
  for (int seamVal : sortedSeams) {
    int seam = clamp(seamVal, left + 1, fbW - 1);
    rects.push_back({left, 0, seam - left, fbH});
    left = seam;
  }
  rects.push_back({left, 0, fbW - left, fbH});
  
  std::vector<MonitorRect> filtered;
  for (const auto& rect : rects) {
    if (rect.w >= static_cast<int>(fbW * 0.12) && rect.h > 0) {
      filtered.push_back(rect);
    }
  }
  return filtered;
}

static std::vector<MonitorRect> detectHorizontalMonitorSpanRects(int fbW, int fbH, const uint8_t* view, const std::vector<MonitorRect>& fallbackRects) {
  std::vector<MonitorRect> fallback = sortMonitorRects(fallbackRects);
  if (!isHorizontalMonitorLayoutCandidate(fallback, fbH)) return {};
  
  int seamCount = fallback.size() - 1;
  int sampleW = std::max(static_cast<int>(fallback.size()) * 36, std::min(240, std::max(96, fbW / 24)));
  int sampleH = std::max(48, std::min(120, std::max(54, fbH / 30)));
  
  std::vector<double> profile = smoothProfile(buildColumnActivityProfile(fbW, fbH, view, sampleW, sampleH), 2);
  std::vector<double> brightness = smoothProfile(buildColumnBrightnessProfile(fbW, fbH, view, sampleW, sampleH), 2);
  std::vector<double> blackness = smoothProfile(buildColumnBlacknessProfile(fbW, fbH, view, sampleW, sampleH), 2);
  std::vector<int> seams = findStrongestHorizontalSeams(profile, brightness, blackness, seamCount, fallback, fbW);
  
  if (static_cast<int>(seams.size()) != seamCount) return {};
  
  std::vector<MonitorRect> fullHeightRects = buildFullHeightRectsFromSeams(fbW, fbH, seams);
  std::vector<MonitorRect> trimmedRects;
  for (const auto& rect : fullHeightRects) {
    trimmedRects.push_back(trimMonitorBlackMargins(fbW, fbH, rect, view));
  }
  return trimmedRects;
}

static double colorDistanceSq(const std::vector<int>& a, const std::vector<int>& b) {
  double dr = a[0] - b[0];
  double dg = a[1] - b[1];
  double db = a[2] - b[2];
  return (dr * dr) + (dg * dg) + (db * db);
}

static std::vector<int> estimateFrameBackground(int fbW, int fbH, const uint8_t* view) {
  if (fbW <= 0 || fbH <= 0) return {};
  std::vector<std::vector<int>> samples;
  int stepX = std::max(1, fbW / 32);
  int stepY = std::max(1, fbH / 24);
  
  for (int x = 0; x < fbW; x += stepX) {
    samples.push_back(readPixel(fbW, fbH, view, x, 0));
    samples.push_back(readPixel(fbW, fbH, view, x, fbH - 1));
  }
  for (int y = stepY; y < fbH - 1; y += stepY) {
    samples.push_back(readPixel(fbW, fbH, view, 0, y));
    samples.push_back(readPixel(fbW, fbH, view, fbW - 1, y));
  }
  if (samples.size() < 8) return {};

  std::vector<int> rs, gs, bs;
  for (const auto& s : samples) {
    rs.push_back(s[0]);
    gs.push_back(s[1]);
    bs.push_back(s[2]);
  }
  std::sort(rs.begin(), rs.end());
  std::sort(gs.begin(), gs.end());
  std::sort(bs.begin(), bs.end());
  
  std::vector<int> median = {
    rs[rs.size() / 2],
    gs[gs.size() / 2],
    bs[bs.size() / 2]
  };

  int stableCount = 0;
  for (const auto& s : samples) {
    if (colorDistanceSq(s, median) <= (28 * 28 * 3)) {
      stableCount++;
    }
  }
  double stableRatio = static_cast<double>(stableCount) / samples.size();
  if (stableRatio < 0.55) return {};
  return median;
}

static bool isForegroundPixel(int fbW, int fbH, const uint8_t* view, int x, int y, const std::vector<int>& bg) {
  std::vector<int> rgb = readPixel(fbW, fbH, view, x, y);
  int brightness = rgb[0] + rgb[1] + rgb[2];
  if (brightness >= 54) return true;
  return colorDistanceSq(rgb, bg) >= (22 * 22 * 3);
}

static std::vector<uint8_t> buildForegroundMask(int fbW, int fbH, const uint8_t* view, int sampleW, int sampleH, const std::vector<int>& bg) {
  std::vector<uint8_t> mask(sampleW * sampleH, 0);
  for (int sy = 0; sy < sampleH; sy++) {
    int y0 = (sy * fbH) / sampleH;
    int y1 = std::max(y0, ((sy + 1) * fbH) / sampleH - 1);
    int yc = (y0 + y1) / 2;
    for (int sx = 0; sx < sampleW; sx++) {
      int x0 = (sx * fbW) / sampleW;
      int x1 = std::max(x0, ((sx + 1) * fbW) / sampleW - 1);
      int xc = (x0 + x1) / 2;
      int fgHits = 0;
      fgHits += isForegroundPixel(fbW, fbH, view, x0, y0, bg) ? 1 : 0;
      fgHits += isForegroundPixel(fbW, fbH, view, x1, y0, bg) ? 1 : 0;
      fgHits += isForegroundPixel(fbW, fbH, view, x0, y1, bg) ? 1 : 0;
      fgHits += isForegroundPixel(fbW, fbH, view, x1, y1, bg) ? 1 : 0;
      fgHits += isForegroundPixel(fbW, fbH, view, xc, yc, bg) ? 1 : 0;
      if (fgHits >= 2) {
        mask[(sy * sampleW) + sx] = 1;
      }
    }
  }
  return mask;
}

static std::vector<uint8_t> dilateMask(const std::vector<uint8_t>& src, int width, int height) {
  std::vector<uint8_t> out(src.size(), 0);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      bool on = false;
      for (int dy = -1; dy <= 1 && !on; dy++) {
        int yy = y + dy;
        if (yy < 0 || yy >= height) continue;
        for (int dx = -1; dx <= 1; dx++) {
          int xx = x + dx;
          if (xx < 0 || xx >= width) continue;
          if (src[(yy * width) + xx] != 0) {
            on = true;
            break;
          }
        }
      }
      out[(y * width) + x] = on ? 1 : 0;
    }
  }
  return out;
}

static std::vector<uint8_t> erodeMask(const std::vector<uint8_t>& src, int width, int height) {
  std::vector<uint8_t> out(src.size(), 0);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      bool on = true;
      for (int dy = -1; dy <= 1 && on; dy++) {
        int yy = y + dy;
        if (yy < 0 || yy >= height) {
          on = false;
          break;
        }
        for (int dx = -1; dx <= 1; dx++) {
          int xx = x + dx;
          if (xx < 0 || xx >= width || src[(yy * width) + xx] == 0) {
            on = false;
            break;
          }
        }
      }
      out[(y * width) + x] = on ? 1 : 0;
    }
  }
  return out;
}

static std::vector<uint8_t> closeMask(const std::vector<uint8_t>& src, int width, int height) {
  return erodeMask(dilateMask(src, width, height), width, height);
}

static MonitorRect findLargestForegroundRect(const std::vector<uint8_t>& mask, int width, int height) {
  std::vector<int> heights(width, 0);
  MonitorRect best = {0, 0, 0, 0};
  int bestArea = 0;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      heights[x] = mask[(y * width) + x] != 0 ? (heights[x] + 1) : 0;
    }

    std::vector<HistogramBar> stack;
    for (int x = 0; x <= width; x++) {
      int currentHeight = x < width ? heights[x] : 0;
      int start = x;
      while (!stack.empty() && stack.back().height > currentHeight) {
        HistogramBar item = stack.back();
        stack.pop_back();
        int area = item.height * (x - item.start);
        if (area > bestArea) {
          bestArea = area;
          best = { item.start, y - item.height + 1, x - item.start, item.height };
        }
        start = item.start;
      }
      if (currentHeight > 0 && (stack.empty() || stack.back().height < currentHeight)) {
        stack.push_back({ start, currentHeight });
      }
    }
  }
  return best;
}

static bool normalizeMonitorRect(int fbW, int fbH, const MonitorRect& rect, MonitorRect& out) {
  int x = clamp(rect.x, 0, std::max(0, fbW - 1));
  int y = clamp(rect.y, 0, std::max(0, fbH - 1));
  int right = clamp(rect.x + rect.w, x + 1, fbW);
  int bottom = clamp(rect.y + rect.h, y + 1, fbH);
  int w = right - x;
  int h = bottom - y;
  int minW = std::max(120, static_cast<int>(fbW * 0.08));
  int minH = std::max(90, static_cast<int>(fbH * 0.08));
  if (w < minW || h < minH) return false;
  out = { x, y, w, h };
  return true;
}

static bool isRectContainedByAny(const MonitorRect& target, const std::vector<MonitorRect>& rects) {
  for (const auto& rect : rects) {
    if (target.x >= rect.x - 8 &&
        target.y >= rect.y - 8 &&
        (target.x + target.w) <= (rect.x + rect.w + 8) &&
        (target.y + target.h) <= (rect.y + rect.h + 8)) {
      return true;
    }
  }
  return false;
}

static std::vector<MonitorRect> mergeNearlyIdenticalRects(const std::vector<MonitorRect>& rects) {
  std::vector<MonitorRect> merged;
  for (const auto& rect : rects) {
    bool absorbed = false;
    for (auto& m : merged) {
      if (areRectsSimilar(rect, m)) {
        int nx = std::min(rect.x, m.x);
        int ny = std::min(rect.y, m.y);
        int nw = std::max(rect.x + rect.w, m.x + m.w) - nx;
        int nh = std::max(rect.y + rect.h, m.y + m.h) - ny;
        m = { nx, ny, nw, nh };
        absorbed = true;
        break;
      }
    }
    if (!absorbed) {
      merged.push_back(rect);
    }
  }
  return merged;
}

static std::vector<MonitorRect> resolveMonitorRectOverlaps(const std::vector<MonitorRect>& rects) {
  std::vector<MonitorRect> next = rects;
  std::sort(next.begin(), next.end(), [](const MonitorRect& a, const MonitorRect& b) {
    return a.x < b.x;
  });

  for (size_t i = 0; i + 1 < next.size(); i++) {
    MonitorRect& left = next[i];
    MonitorRect& right = next[i + 1];
    int overlapStart = std::max(left.x, right.x);
    int overlapEnd = std::min(left.x + left.w, right.x + right.w);
    int overlapWidth = overlapEnd - overlapStart;
    if (overlapWidth <= 0) continue;

    int verticalOverlap = std::min(left.y + left.h, right.y + right.h) - std::max(left.y, right.y);
    if (verticalOverlap <= std::max(24, static_cast<int>(std::min(left.h, right.h) * 0.35))) continue;

    int leftMinWidth = std::max(48, static_cast<int>(left.w * 0.25));
    int rightMinWidth = std::max(48, static_cast<int>(right.w * 0.25));
    int rightEdge = right.x + right.w;
    int minSeam = left.x + leftMinWidth;
    int maxSeam = rightEdge - rightMinWidth;
    if (minSeam >= maxSeam) continue;

    int seam = clamp((overlapStart + overlapEnd) / 2, minSeam, maxSeam);
    left.w = std::max(1, seam - left.x);
    right.x = seam;
    right.w = std::max(1, rightEdge - seam);
  }
  return next;
}

static std::vector<MonitorRect> extractMonitorRectsFromMask(int fbW, int fbH, const std::vector<uint8_t>& mask, int sampleW, int sampleH, const uint8_t* view) {
  std::vector<uint8_t> working = mask;
  int minArea = std::max(24, static_cast<int>(sampleW * sampleH * 0.02));
  double scaleX = static_cast<double>(fbW) / sampleW;
  double scaleY = static_cast<double>(fbH) / sampleH;
  std::vector<MonitorRect> rects;

  for (int i = 0; i < 8; i++) {
    MonitorRect sampleRect = findLargestForegroundRect(working, sampleW, sampleH);
    if (sampleRect.w == 0 || sampleRect.h == 0) break;
    if ((sampleRect.w * sampleRect.h) < minArea) break;

    for (int y = sampleRect.y; y < sampleRect.y + sampleRect.h; y++) {
      for (int x = sampleRect.x; x < sampleRect.x + sampleRect.w; x++) {
        working[(y * sampleW) + x] = 0;
      }
    }

    MonitorRect expanded = {
      std::max(0, static_cast<int>(sampleRect.x * scaleX) - static_cast<int>(std::ceil(scaleX * 1.5))),
      std::max(0, static_cast<int>(sampleRect.y * scaleY) - static_cast<int>(std::ceil(scaleY * 1.5))),
      std::min(fbW, static_cast<int>(sampleRect.w * scaleX) + static_cast<int>(std::ceil(scaleX * 3))),
      std::min(fbH, static_cast<int>(sampleRect.h * scaleY) + static_cast<int>(std::ceil(scaleY * 3)))
    };
    expanded.w = std::max(1, std::min(fbW - expanded.x, expanded.w));
    expanded.h = std::max(1, std::min(fbH - expanded.y, expanded.h));
    
    MonitorRect trimmed = trimMonitorBlackMargins(fbW, fbH, expanded, view);
    MonitorRect normalized;
    if (normalizeMonitorRect(fbW, fbH, trimmed, normalized) && !isRectContainedByAny(normalized, rects)) {
      rects.push_back(normalized);
    }
  }

  if (rects.empty()) return {};
  return resolveMonitorRectOverlaps(mergeNearlyIdenticalRects(rects));
}

static bool shouldPreferHorizontalSpanRects(const std::vector<MonitorRect>& rects, int fbW, int fbH, const std::vector<MonitorRect>& fallbackRects) {
  if (rects.empty() || fallbackRects.size() <= 1) return false;
  if (rects.size() != fallbackRects.size()) return true;

  double totalArea = 0;
  int severelyShortCount = 0;
  std::vector<MonitorRect> sortedRects = sortMonitorRects(rects);
  std::vector<MonitorRect> sortedFallback = sortMonitorRects(fallbackRects);

  for (size_t i = 0; i < sortedRects.size(); i++) {
    const auto& rect = sortedRects[i];
    totalArea += static_cast<double>(rect.w) * rect.h;
    const auto& fallback = sortedFallback[std::min(i, sortedFallback.size() - 1)];
    if (rect.w < static_cast<int>(fallback.w * 0.72) || rect.h < static_cast<int>(fbH * 0.68)) {
      severelyShortCount++;
    }
  }

  double coverage = totalArea / std::max(1, fbW * fbH);
  if (coverage < 0.45) return true;
  return rects.size() == fallbackRects.size() && severelyShortCount > 0;
}

std::vector<MonitorRect> detectMonitorRectsFromRgbaFrame(int fbW, int fbH, const uint8_t* view, const std::vector<MonitorRect>& fallbackRects) {
  std::vector<MonitorRect> fallback = !fallbackRects.empty() ? sortMonitorRects(fallbackRects) : getHeuristicMonitorRects(fbW, fbH);
  if (fbW <= 0 || fbH <= 0 || !view) return {};

  std::vector<MonitorRect> seamRects = detectHorizontalMonitorSpanRects(fbW, fbH, view, fallback);
  std::vector<int> bg = estimateFrameBackground(fbW, fbH, view);
  
  if (bg.empty()) {
    return seamRects.empty() ? fallback : seamRects;
  }

  int sampleW = std::max(1, std::min(fbW, std::max(24, std::min(180, fbW / 6))));
  int sampleH = std::max(1, std::min(fbH, std::max(18, std::min(120, fbH / 6))));
  
  std::vector<uint8_t> mask = buildForegroundMask(fbW, fbH, view, sampleW, sampleH, bg);
  std::vector<uint8_t> cleaned = closeMask(mask, sampleW, sampleH);
  std::vector<MonitorRect> rects = extractMonitorRectsFromMask(fbW, fbH, cleaned, sampleW, sampleH, view);
  
  if (rects.empty()) {
    return seamRects.empty() ? fallback : seamRects;
  }
  
  bool preferSeam = shouldPreferHorizontalSpanRects(rects, fbW, fbH, fallback);
  if (!seamRects.empty() && preferSeam) {
    return seamRects;
  }
  return rects;
}

} // namespace MonitorSegmentation
