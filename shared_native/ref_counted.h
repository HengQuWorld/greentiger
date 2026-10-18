#ifndef __SHARED_REF_COUNTED_H__
#define __SHARED_REF_COUNTED_H__

#include <atomic>
#include <cstddef>

namespace shared {

// Intrusive reference count for objects handed out to callers that may hold
// them across threads (the VNC client handle is one).
//
// The count starts at 1: whoever created the object owns one reference and is
// responsible for releasing it. Additional references are taken with AddRef and
// must be paired with Release; the object is destroyed by whoever performs the
// Release that brings the count to zero.
class RefCounted {
 public:
  RefCounted() = default;
  RefCounted(const RefCounted&) = delete;
  RefCounted& operator=(const RefCounted&) = delete;

  void AddRef() { count_.fetch_add(1, std::memory_order_relaxed); }

  // Returns true exactly once, for the caller that dropped the last reference.
  // That caller is then responsible for destroying the object.
  bool Release() { return count_.fetch_sub(1, std::memory_order_acq_rel) == 1; }

  // Only meaningful in tests and diagnostics; not synchronised with Release.
  long UseCount() const { return count_.load(std::memory_order_relaxed); }

 private:
  std::atomic<long> count_{1};
};

}  // namespace shared

#endif  // __SHARED_REF_COUNTED_H__
