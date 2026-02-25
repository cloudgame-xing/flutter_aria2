#include "aria2_core.h"

#include <chrono>
#include <thread>

namespace flutter_aria2::core {

namespace {
struct RunInProgressGuard {
  explicit RunInProgressGuard(std::atomic<bool>* flag) : flag_(flag) {
    if (flag_ != nullptr) {
      flag_->store(true);
    }
  }

  ~RunInProgressGuard() {
    if (flag_ != nullptr) {
      flag_->store(false);
    }
  }

 private:
  std::atomic<bool>* flag_;
};
}  // namespace

int LibraryInit(RuntimeState* state) {
  if (state == nullptr) {
    return -1;
  }
  const int ret = aria2_library_init();
  if (ret == 0) {
    state->library_initialized = true;
  }
  return ret;
}

int LibraryDeinit(RuntimeState* state) {
  if (state == nullptr) {
    return -1;
  }
  StopRunLoop(state);
  WaitForPendingRun(state);
  if (state->session != nullptr) {
    aria2_session_final(state->session);
    state->session = nullptr;
  }
  const int ret = aria2_library_deinit();
  state->library_initialized = false;
  return ret;
}

const char* SessionNew(RuntimeState* state, const aria2_key_val_t* options,
                       size_t options_count, bool keep_running,
                       DownloadEventCallback callback, void* user_data) {
  if (state == nullptr) {
    return "INVALID_STATE";
  }
  if (!state->library_initialized) {
    return "NOT_INITIALIZED";
  }
  if (state->session != nullptr) {
    return "SESSION_EXISTS";
  }

  aria2_session_config_t config;
  aria2_session_config_init(&config);
  config.keep_running = keep_running ? 1 : 0;
  config.download_event_callback = callback;
  config.user_data = user_data;

  state->session = aria2_session_new(options, options_count, &config);
  if (state->session == nullptr) {
    return "SESSION_FAILED";
  }
  return nullptr;
}

const char* SessionFinal(RuntimeState* state, int* out_ret) {
  if (state == nullptr) {
    return "INVALID_STATE";
  }
  if (state->session == nullptr) {
    return "NO_SESSION";
  }
  StopRunLoop(state);
  WaitForPendingRun(state);
  const int ret = aria2_session_final(state->session);
  if (out_ret != nullptr) {
    *out_ret = ret;
  }
  state->session = nullptr;
  return nullptr;
}

int RunOnce(RuntimeState* state) {
  if (state == nullptr || state->session == nullptr) {
    return -1;
  }
  if (state->run_in_progress.load()) {
    return 1;
  }
  RunInProgressGuard guard(&state->run_in_progress);
  return aria2_run(state->session, ARIA2_RUN_ONCE);
}

void StartRunLoop(RuntimeState* state) {
  if (state == nullptr || state->session == nullptr ||
      state->run_loop_active.load()) {
    return;
  }

  state->run_loop_active.store(true);
  aria2_session_t* session = state->session;
  if (state->run_thread.joinable()) {
    state->run_thread.join();
  }
  state->run_thread = std::thread([state, session]() {
    aria2_run(session, ARIA2_RUN_DEFAULT);
    state->run_loop_active.store(false);
  });
}

void StopRunLoop(RuntimeState* state) {
  if (state == nullptr || !state->run_loop_active.load()) {
    return;
  }
  state->run_loop_active.store(false);
  if (state->session != nullptr) {
    aria2_shutdown(state->session, 1);
  }
  if (state->run_thread.joinable()) {
    state->run_thread.join();
  }
}

const char* Shutdown(RuntimeState* state, bool force, int* out_ret) {
  if (state == nullptr) {
    return "INVALID_STATE";
  }
  if (state->session == nullptr) {
    return "NO_SESSION";
  }
  const int ret = aria2_shutdown(state->session, force ? 1 : 0);
  if (out_ret != nullptr) {
    *out_ret = ret;
  }
  return nullptr;
}

void WaitForPendingRun(RuntimeState* state) {
  if (state == nullptr) {
    return;
  }
  while (state->run_in_progress.load()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

void CleanupState(RuntimeState* state) {
  if (state == nullptr) {
    return;
  }
  StopRunLoop(state);
  WaitForPendingRun(state);
  if (state->session != nullptr) {
    aria2_session_final(state->session);
    state->session = nullptr;
  }
  if (state->library_initialized) {
    aria2_library_deinit();
    state->library_initialized = false;
  }
}

}  // namespace flutter_aria2::core
