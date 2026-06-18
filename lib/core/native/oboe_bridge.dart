// lib/core/native/oboe_bridge.dart
//
// 来自 PRD_Architecture.md §4.6 (Checker: Oboe_AAudio_Gatekeeper)
//
// Dart ↔ C++ (Oboe/AAudio) 桥接抽象骨架。
// 本文件仅定义 Dart 侧契约；真正的 FFI 在 Phase 2 的 .so / .dll 集成阶段补齐。
//
// V2 硬指标（一票否决）：
//   - releaseStreamWithinBudget() 必须在 10ms 内触发底层清理。
//   - 超时立即抛 OboeReleaseTimeoutException(actualMs)。
//   - 释放后 Dart 侧句柄必须置 0 / nullptr（防 use-after-free）。
//   - 句柄为空时任何操作立刻抛 UseAfterFreeException。
//
// 设计原则：
//   - 句柄用 int 句柄（0 表示空），与 C++ 侧 intptr_t 对齐。
//   - 所有方法必须可被 fake 替换（提供 NativeReleaseDelegate 注入）。
//   - 严禁在 release 路径中调用 await（保持同步，避免事件循环额外延迟）。

import 'package:meta/meta.dart';

import '../result/result.dart';

/// 释放预算（V2 硬指标：10ms）。
const int kOboeReleaseBudgetMs = 10;

/// Native 释放回调签名。
/// 生产环境：调用 FFI `oboe_release_stream(handle)`。
/// 测试环境：注入 fake 实现，可模拟超时。
typedef NativeReleaseDelegate = void Function(int handle);

/// 默认 Native 释放实现（占位）。
/// Phase 2 集成 Oboe/AAudio 后，将 _defaultNativeRelease 替换为
/// `DynamicLibrary.open('liboboe_bridge.so').lookup<NativeFunction<Void Function(IntPtr)>>('oboe_release_stream').asFunction()`。
///
/// 占位实现下，handle 必须为 0；非 0 handle 表示调用方未正确注入 release 委托，
/// 直接抛 [UnsupportedError] 强制在测试期暴露问题。
void _defaultNativeRelease(int handle) {
  if (handle != 0) {
    throw UnsupportedError(
      'OboeBridge._defaultNativeRelease is a no-op placeholder. '
      'Production must inject a real FFI delegate via debugSetReleaseDelegate().',
    );
  }
}

/// C++ 桥接契约。
///
/// 调用方流程（参考 PRD §4.6 DefaultChordPlayer.stop）：
/// ```dart
/// final handle = player.detachNativeHandle();
/// if (handle != 0) {
///   OboeBridge.releaseStreamWithinBudget(handle);   // 同步，10ms 内
///   player.setNativeHandle(0);                      // 野指针防护
/// }
/// ```
class OboeBridge {
  OboeBridge._();

  static NativeReleaseDelegate _releaseImpl = _defaultNativeRelease;

  /// 注入 native 释放实现（仅测试使用）。生产代码严禁调用。
  @visibleForTesting
  static void debugSetReleaseDelegate(NativeReleaseDelegate impl) {
    _releaseImpl = impl;
  }

  /// 还原为默认占位实现。
  @visibleForTesting
  static void debugResetReleaseDelegate() {
    _releaseImpl = _defaultNativeRelease;
  }

  /// 同步释放 native 流。必须 10ms 内返回。
  ///
  /// [handle] 必须 != 0；为 0 时直接抛 UseAfterFreeException
  /// （调用方应在 detach 后立即置 0，从而走入这条 fast-fail 分支）。
  ///
  /// 抛出：
  ///   - UseAfterFreeException：handle == 0
  ///   - OboeReleaseTimeoutException：底层释放耗时 > 10ms
  static void releaseStreamWithinBudget(int handle) {
    if (handle == 0) {
      throw const UseAfterFreeException();
    }
    final sw = Stopwatch()..start();
    _releaseImpl(handle);
    sw.stop();
    if (sw.elapsedMilliseconds > kOboeReleaseBudgetMs) {
      throw OboeReleaseTimeoutException(sw.elapsedMilliseconds);
    }
  }

  /// 句柄守卫：句柄 == 0 时抛 UseAfterFreeException。
  /// 用于 NoopAudioPlayback 等持有方在调用前自检。
  static void guardHandle(int handle) {
    if (handle == 0) {
      throw const UseAfterFreeException();
    }
  }

  /// 释放并显式清零。
  /// 适用于调用方持有句柄的常见模式：
  ///   final h = player.detachNativeHandle();
  ///   OboeBridge.detachNativeHandleAndRelease(h, player.setNativeHandle);
  static void detachNativeHandleAndRelease(
    int handle,
    void Function(int) clearHandle,
  ) {
    if (handle == 0) {
      // 已为空句柄，按契约快速失败；clearHandle 仍应被调用以保持一致。
      clearHandle(0);
      throw const UseAfterFreeException();
    }
    releaseStreamWithinBudget(handle);
    clearHandle(0);
  }
}

/// 持有 native 句柄的可释放对象。
///
/// 让 NoopAudioPlayback / 未来 AndroidAAudioPlayback 共用释放路径，
/// 避免每个实现各自裸持有 int 句柄导致野指针。
class NativeHandleOwner {
  int _handle;

  NativeHandleOwner([int initialHandle = 0]) : _handle = initialHandle;

  /// 当前句柄（0 表示已释放）。
  int get handle => _handle;

  /// 是否处于已释放状态。
  bool get isReleased => _handle == 0;

  /// 设置句柄（仅在 detach 后用于置 0）。
  void setNativeHandle(int h) {
    _handle = h;
  }

  /// 脱离句柄并返回原值（调用方随后应通过 OboeBridge 释放）。
  int detachNativeHandle() {
    final h = _handle;
    _handle = 0;
    return h;
  }

  /// 释放当前持有的句柄（10ms 内同步完成）。
  void releaseWithinBudget() {
    if (_handle == 0) {
      throw const UseAfterFreeException();
    }
    OboeBridge.releaseStreamWithinBudget(_handle);
    _handle = 0;
  }
}
