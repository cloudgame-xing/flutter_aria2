# flutter_aria2 代码审查报告（2026-02-25）

## 审查范围与重点

- 范围：`lib/`、`android/`、`ios/`、`macos/`、`linux/`、`windows/`、`test/`、工程配置与文档。
- 重点：
  - 重复代码是否可合并；
  - 架构分层是否合理；
  - 内存/资源泄漏风险；
  - 其他可改进项（测试、文档、CI、可维护性）。

---

## 主要结论（先看这里）

1. **跨平台原生实现重复度非常高**，尤其 `ios` 与 `macos` 几乎同构，Linux/Windows/Android 也重复了大量 aria2 调用与数据转换逻辑。
2. **架构上“平台适配层”承载了大量业务逻辑**，导致修改成本高、跨平台一致性风险高。
3. **存在资源管理高风险点**：JNI 局部引用管理粗放，iOS/macOS 回调对象生命周期约束不足，长时间运行/大数据量场景有稳定性隐患。
4. **Dart 层错误处理策略不一致**（`?? 默认值` 与强制 `!` 混用），容易产生“静默错误”或 NPE 崩溃。
5. **测试、文档、CI 仍处于模板/起步状态**，对回归风险防护不足。

---

## 详细发现

## A. 重复代码与可合并点

### A1（高）iOS 与 macOS 原生实现几乎重复

- 证据：
  - `ios/Classes/FlutterAria2Native.mm`
  - `macos/Classes/FlutterAria2Native.mm`
- 两文件结构与方法分支基本一致，主要差异集中在 `getPlatformVersion` 的平台字符串来源。
- 影响：同一逻辑要双处维护，修复 bug 容易遗漏一端。
- 建议：
  - 抽取共享 Objective-C++ 核心（如 `FlutterAria2NativeCore`），平台文件只保留最薄桥接层；
  - 或将绝大部分逻辑下沉到共享 C++ Core，iOS/macOS 只做参数转换与回调分发。

### A2（高）各平台重复实现同构辅助函数与数据转换

- 证据（示例）：
  - `KeyValHelper`：`android/src/main/cpp/flutter_aria2_native_jni.cpp`、`linux/flutter_aria2_plugin.cc`、`windows/flutter_aria2_plugin.cpp`、`ios/Classes/FlutterAria2Native.mm`、`macos/Classes/FlutterAria2Native.mm`
  - `GidToHex/gid_to_hex`：同上多平台均有
  - `FileDataTo*` 映射函数：多平台均重复
- 影响：重复逻辑扩大维护面，行为一致性依赖“人工同步”。
- 建议：
  - 提炼共享 `common/aria2_helpers.(h|cc)`；
  - 统一 `gid`/`fileData`/`options` 转换策略，平台层只保留容器类型适配。

### A3（中）method 分发表中的状态检查重复冗长

- 证据：
  - 多平台中大量 `NO_SESSION` / `NOT_INITIALIZED` 的重复判定分支。
- 影响：新 API 添加时容易漏掉状态校验，且可读性差。
- 建议：
  - 引入统一 guard helper（例如 `RequireSession`、`RequireInitialized`）；
  - 将重复检查集中化，减少样板代码。

---

## B. 架构合理性

### B1（高）平台适配层耦合业务逻辑，缺少共享 Core

- 现状：
  - `FlutterAria2Native.mm`、`flutter_aria2_native_jni.cpp`、`flutter_aria2_plugin.cc/cpp` 都在直接执行 aria2 业务逻辑（session 生命周期、查询与转换）。
- 问题：适配层过重，业务逻辑不能复用。
- 建议目标架构：
  - `Dart API` -> `Platform Channel` -> `Platform Adapter(薄)` -> `Aria2 Core(共享 C++)` -> `aria2 C API`

### B2（中）状态与线程控制分散，实现不统一

- 现状：各平台都有自己的 `run_loop_active / run_in_progress / run_thread` 管理。
- 风险：状态机不一致，后续行为差异与并发问题难排查。
- 建议：
  - 统一状态机语义（`Init -> SessionReady -> Running -> Stopped -> Finalized`）；
  - 封装成跨平台共享的生命周期管理组件。

### B3（中）Dart 错误处理语义不一致 ✅ 已处理

- 证据：`lib/flutter_aria2_method_channel.dart`
  - 大量 `result ?? -1` / `result ?? ''`（静默降级）
  - 部分接口直接 `result!`（可能触发崩溃）
- 影响：调用方难以建立稳定错误处理策略。
- **已做修改**：
  - 在 `lib/flutter_aria2.dart` 中新增 [Aria2Exception]，包装 [PlatformException]，暴露 `code`、`message` 及可选的 `platformException`，便于调用方统一 catch 并区分错误码（如 NO_SESSION、NOT_INITIALIZED、ARIA2_ERROR 等）。
  - 在 [MethodChannelFlutterAria2] 中：
    - 使用 `_invoke<T>()` 调用原生方法，在 catch 到 [PlatformException] 时统一 rethrow 为 [Aria2Exception]；
    - 使用 `_invokeRequired<T>()` 要求非 null 结果，若平台返回 null 则抛出 [Aria2Exception] 而非默认值；
    - 仅当协议明确允许 null 的接口（如 [getGlobalOption]、[getDownloadOption]、[getPlatformVersion]）仍返回 `String?`/null。
  - 移除所有 `result ?? -1`、`result ?? ''`、`result?.cast<String>() ?? []` 等静默降级，以及 `result!` 的强制解包；错误路径一律通过异常暴露。
- 建议：调用方可通过 `try { await aria2.addUri(...); } on Aria2Exception catch (e) { switch (e.code) { case 'NO_SESSION': ... } }` 建立稳定错误处理策略。

---

## C. 内存/资源泄漏与生命周期风险

### C1（高）Android JNI 局部引用管理粗放（大数据场景风险高）✅ 已处理

- 文件：`android/src/main/cpp/flutter_aria2_native_jni.cpp`
- 现象：
  - `NewInteger/NewLong/NewBoolean/NewHashMap/NewArrayList` 等辅助函数创建对象后，多处调用链未显式 `DeleteLocalRef`；
  - 在 `getDownloadInfo/getDownloadFiles/getDownloadOptions` 等循环/批量构建 map/list 逻辑中，局部引用数量可能快速增长。
- 说明：
  - JNI 局部引用通常在 native 方法返回时清理，但在**单次调用内部大量创建**时仍可能触发 local reference table overflow。
- **已做修改**：
  - 增加 RAII 辅助类型 `ScopedLocalRef`（析构时自动 `DeleteLocalRef`），便于后续扩展；
  - 在 `FileDataToJavaMap`、`getGlobalOptions`、`getGlobalStat`、`getDownloadInfo`、`getDownloadOptions`、`getDownloadBtMetaInfo` 等批量/循环路径中，对每次 `HashMapPut`/`ArrayListAdd` 使用的临时 key/value 在 put 后显式 `DeleteLocalRef`，避免单次调用内局部引用堆积。
- 建议（可选）：
  - 对批量场景增加压力测试；
  - 使用 Memory Profiler / JNI local ref 监控做二次验证。

### C2（高）iOS/macOS 回调持有 `self` 的生命周期边界不够安全 ✅ 已处理

- 文件：
  - `ios/Classes/FlutterAria2Native.mm`
  - `macos/Classes/FlutterAria2Native.mm`
- 现象：
  - `config.user_data = (__bridge void*)self`；
  - 回调和线程 lambda 中直接使用 `native/self` 指针。
- 风险：
  - 若析构、停止回调、线程退出顺序边界控制不严，存在悬挂引用访问风险（极端并发/销毁时序下）。
- **已做修改**：
  - 在 `DownloadEventCallback` 中改为使用 `__weak FlutterAria2Native* weakNative = (__bridge __weak FlutterAria2Native*)user_data`，在 `dispatch_async` 的 block 内先取 strong 引用再使用，若对象已释放则 `weakNative == nil` 时直接 return，避免悬挂指针。
- 说明：
  - 共享 core 中 `SessionFinal`/`CleanupState` 已保证“先 StopRunLoop（停线程）-> WaitForPendingRun -> session_final”，回调在 session 销毁后不再被调用；`__weak` 主要防护“block 尚未执行时对象已被释放”的边界情况。

### C3（中）`run_in_progress` 重置依赖 happy path ✅ 已由共享 Core 覆盖

- 文件：`common/aria2_core.cpp`（Android 通过 `RunOnce(state)` 调用）
- 现象：原 Android 侧 `run()` 中 `run_in_progress=true` 后直接调用 `aria2_run(...)`，缺少统一 finally/guard 语义。
- **现状**：
  - 共享 core 中 `RunOnce` 已使用 `RunInProgressGuard`（RAII）在作用域结束时复位 `run_in_progress`，异常/早退路径也会正确复位，Android 侧无需额外修改。

### C4（中）线程退出与销毁流程建议进一步规范化 ✅ 已明确并注释

- 文件：`common/aria2_core.cpp`，多平台通过 core 复用。
- 现象：存在 `stop -> shutdown -> join` 模式，各平台细节曾不完全一致。
- **已做修改**：
  - 在 `SessionFinal`、`CleanupState` 中补充注释，明确统一流程：**StopRunLoop（停线程并 join）-> WaitForPendingRun -> session_final（及 library_deinit）**；
  - 各平台（Android/iOS/macOS/Linux/Windows）均通过 `CleanupState`/`SessionFinal`/`StopRunLoop` 使用该流程。
- 建议（可选）：
  - 为重复 stop 调用、并发 stop/start 添加测试。

---

## D. 其他改进项

### D1（高）测试覆盖不足

- 现状：
  - Dart 测试主要是模板级（`getPlatformVersion`）；
  - Android Kotlin 测试亦为模板级；
  - 原生核心逻辑基本无针对性测试。
- 影响：重构时回归风险高。
- 建议：
  - 增加 API 行为测试（`libraryInit/sessionNew/addUri/getDownloadInfo/...`）；
  - 增加异常路径与生命周期测试（重复 init/final、并发 run/stop）。

### D2（中）工程文档仍是模板

- 证据：
  - `README.md`、`CHANGELOG.md`、`pubspec.yaml` 描述均为模板内容。
- 建议：
  - 补齐真实能力边界、平台支持、初始化顺序、常见错误码；
  - 更新版本策略与变更日志。

### D3（中）缺少 CI 工作流

- 现状：未发现 `.github/workflows/*.yml`
- 建议：
  - 最小 CI：`flutter analyze` + `flutter test` + Android 单测；
  - 可选：跨平台构建 smoke check。

### D4（低）Android ABI 支持策略需要明确

- 证据：
  - `android/build.gradle` 仅 `arm64-v8a`
  - `android/CMakeLists.txt` 对非 arm64 直接 `FATAL_ERROR`
- 建议：
  - 若这是产品决策，请在 README 明确声明；
  - 若需扩大兼容性，规划多 ABI 库产物与构建流程。

---

## 优先级整改清单（Top 8）

1. **抽取共享 Aria2 Core（C++）**，平台层变薄（最高优先级）。
2. **合并 iOS/macOS 重复实现**，减少双份维护。
3. **统一错误处理语义**（去掉静默默认值、统一异常类型）。
4. **修复 JNI 局部引用管理**（重点是循环与批量创建对象路径）。
5. **统一生命周期状态机与 stop/start 流程**。
6. **补齐核心 API 的自动化测试与并发/销毁边界测试**。
7. **建立基础 CI 工作流**（分析+测试）。
8. **完善 README/CHANGELOG/pubspec 描述与平台限制说明**。

---

## 建议执行路线

- 第 1 阶段（1~2 周）：错误处理统一 + JNI 引用管理 + 测试基线。
- 第 2 阶段（2~4 周）：抽取共享 Core + iOS/macOS 合并。
- 第 3 阶段（1 周）：CI 与文档完善、发布前回归验证。

**C 节整改记录（2026-02-25）**：本节“内存/资源泄漏与生命周期风险”已按 C1～C4 完成代码修改：JNI 批量路径显式释放局部引用、iOS/macOS 回调使用 `__weak`、run_in_progress 由共享 Core 的 RAII 覆盖、线程退出/销毁顺序在 core 中注释明确并统一使用。

---

## 风险说明

- 本报告基于静态代码审查，未结合运行时 profiler 全量验证。
- 与资源泄漏相关结论中，已区分“确定问题”与“高风险隐患”；建议用工具做二次验证：
  - Android：Memory Profiler / JNI local refs 监控
  - Apple 平台：Instruments（Leaks/Zombies）
  - C/C++：ASAN/TSAN（若构建链允许）

