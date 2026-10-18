// Tests for shared/ref_counted.h.
//
// The client handle relies on this to survive teardown while an asynchronous
// connect is still running, so the interesting cases are concurrent acquires and
// the single guaranteed zero crossing.

#include "ref_counted.h"

#include <thread>
#include <vector>

#include "test_support.h"

namespace {

void CaseStartsAtOne()
{
  testing::BeginCase("a fresh object owns one reference");

  shared::RefCounted refs;
  CHECK_EQ(refs.UseCount(), 1);
  // Releasing the creation reference drops it to zero exactly once.
  CHECK(refs.Release());
}

void CaseAcquireAndReleaseBalance()
{
  testing::BeginCase("acquire and release are balanced");

  shared::RefCounted refs;
  refs.AddRef();
  refs.AddRef();
  CHECK_EQ(refs.UseCount(), 3);
  CHECK(!refs.Release());
  CHECK(!refs.Release());
  CHECK_EQ(refs.UseCount(), 1);
  CHECK(refs.Release());
}

void CaseOnlyOneThreadSeesZero()
{
  testing::BeginCase("exactly one releasing thread observes zero");

  shared::RefCounted refs;
  constexpr int kThreads = 8;
  constexpr int kPerThread = 2000;

  for (int i = 0; i < kThreads * kPerThread; i++) {
    refs.AddRef();
  }

  std::atomic<int> zeroSeen{0};
  std::vector<std::thread> workers;
  workers.reserve(kThreads);
  for (int t = 0; t < kThreads; t++) {
    workers.emplace_back([&refs, &zeroSeen]() {
      for (int i = 0; i < kPerThread; i++) {
        if (refs.Release()) {
          zeroSeen.fetch_add(1);
        }
      }
    });
  }
  for (auto& w : workers) {
    w.join();
  }

  // The creation reference is still outstanding, so no thread should have hit
  // zero yet, and the count must be exactly 1.
  CHECK_EQ(zeroSeen.load(), 0);
  CHECK_EQ(refs.UseCount(), 1);
  CHECK(refs.Release());
}

void CaseConcurrentAcquireWhileReleasing()
{
  testing::BeginCase("concurrent acquire and release keep the count consistent");

  shared::RefCounted refs;
  constexpr int kIterations = 20000;

  std::atomic<bool> stop{false};
  std::thread acquirer([&refs, &stop]() {
    while (!stop.load()) {
      refs.AddRef();
      refs.Release();
    }
  });

  for (int i = 0; i < kIterations; i++) {
    refs.AddRef();
    refs.Release();
  }

  stop.store(true);
  acquirer.join();

  // Every pairing balanced out, so only the creation reference remains.
  CHECK_EQ(refs.UseCount(), 1);
  CHECK(refs.Release());
}

}  // namespace

int main()
{
  CaseStartsAtOne();
  CaseAcquireAndReleaseBalance();
  CaseOnlyOneThreadSeesZero();
  CaseConcurrentAcquireWhileReleasing();
  return testing::Finish("ref_counted");
}
