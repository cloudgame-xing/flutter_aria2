#ifndef FLUTTER_ARIA2_COMMON_ARIA2_CORE_H_
#define FLUTTER_ARIA2_COMMON_ARIA2_CORE_H_

#include <aria2_c_api.h>

#include <atomic>
#include <cstddef>
#include <thread>

namespace flutter_aria2 {
namespace core {

struct RuntimeState {
  aria2_session_t* session = nullptr;
  bool library_initialized = false;
  std::thread run_thread;
  std::atomic<bool> run_loop_active{false};
  std::atomic<bool> run_in_progress{false};

  RuntimeState() = default;

  RuntimeState(RuntimeState&& other) noexcept
      : session(other.session),
        library_initialized(other.library_initialized),
        run_thread(std::move(other.run_thread)),
        run_loop_active(other.run_loop_active.load()),
        run_in_progress(other.run_in_progress.load()) {
    other.session = nullptr;
    other.library_initialized = false;
  }

  RuntimeState& operator=(RuntimeState&& other) noexcept {
    if (this == &other) return *this;
    session = other.session;
    library_initialized = other.library_initialized;
    run_thread = std::move(other.run_thread);
    run_loop_active.store(other.run_loop_active.load());
    run_in_progress.store(other.run_in_progress.load());
    other.session = nullptr;
    other.library_initialized = false;
    return *this;
  }

  RuntimeState(const RuntimeState&) = delete;
  RuntimeState& operator=(const RuntimeState&) = delete;
};

using DownloadEventCallback =
    int (*)(aria2_session_t*, aria2_download_event_t, aria2_gid_t, void*);

int LibraryInit(RuntimeState* state);
int LibraryDeinit(RuntimeState* state);

// Returns nullptr on success; otherwise returns a static error code string.
const char* SessionNew(RuntimeState* state, const aria2_key_val_t* options,
                       size_t options_count, bool keep_running,
                       DownloadEventCallback callback, void* user_data);

const char* SessionFinal(RuntimeState* state, int* out_ret);

// Mirrors existing plugin behavior: returns 1 when a run is already in progress.
int RunOnce(RuntimeState* state);

void StartRunLoop(RuntimeState* state);
void StopRunLoop(RuntimeState* state);

const char* Shutdown(RuntimeState* state, bool force, int* out_ret);

void WaitForPendingRun(RuntimeState* state);
void CleanupState(RuntimeState* state);

// ─── State checks (return error code string or nullptr if OK) ───
const char* RequireSession(const RuntimeState* state);
const char* RequireInitialized(const RuntimeState* state);
const char* RequireNoSession(const RuntimeState* state);

}  // namespace core
}  // namespace flutter_aria2

#endif  // FLUTTER_ARIA2_COMMON_ARIA2_CORE_H_
