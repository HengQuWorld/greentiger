#ifndef __SHARED_TESTS_TEST_SUPPORT_H__
#define __SHARED_TESTS_TEST_SUPPORT_H__

// Minimal assertion helpers so the native tests need no test framework beyond
// the compiler and a C++17 standard library.

#include <cstdio>
#include <cstdlib>
#include <string>

namespace testing {

inline int& FailureCount()
{
  static int failures = 0;
  return failures;
}

inline const char*& CurrentCase()
{
  static const char* name = "";
  return name;
}

inline void BeginCase(const char* name)
{
  CurrentCase() = name;
}

inline void ReportFailure(const char* file, int line, const std::string& message)
{
  std::fprintf(stderr, "FAIL [%s] %s:%d: %s\n", CurrentCase(), file, line, message.c_str());
  FailureCount()++;
}

inline int Finish(const char* suite)
{
  if (FailureCount() == 0) {
    std::printf("PASS %s\n", suite);
    return 0;
  }
  std::fprintf(stderr, "FAILED %s (%d failure(s))\n", suite, FailureCount());
  return 1;
}

}  // namespace testing

#define CHECK(cond)                                                              \
  do {                                                                           \
    if (!(cond)) {                                                               \
      ::testing::ReportFailure(__FILE__, __LINE__, "CHECK(" #cond ")");          \
    }                                                                            \
  } while (0)

#define CHECK_EQ(actual, expected)                                               \
  do {                                                                           \
    const auto __a = (actual);                                                    \
    const auto __e = (expected);                                                  \
    if (!(__a == __e)) {                                                          \
      char __buf[512];                                                            \
      std::snprintf(__buf, sizeof(__buf), "CHECK_EQ(%s, %s) -> %lld vs %lld",     \
                    #actual, #expected,                                           \
                    static_cast<long long>(__a), static_cast<long long>(__e));    \
      ::testing::ReportFailure(__FILE__, __LINE__, __buf);                        \
    }                                                                             \
  } while (0)

#define CHECK_STR_EQ(actual, expected)                                           \
  do {                                                                           \
    const std::string __a = (actual);                                             \
    const std::string __e = (expected);                                           \
    if (__a != __e) {                                                             \
      ::testing::ReportFailure(__FILE__, __LINE__,                                \
                               std::string("CHECK_STR_EQ -> \"") + __a +          \
                                 "\" vs \"" + __e + "\"");                         \
    }                                                                             \
  } while (0)

#endif  // __SHARED_TESTS_TEST_SUPPORT_H__
