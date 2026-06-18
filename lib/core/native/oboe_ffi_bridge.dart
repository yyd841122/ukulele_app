// lib/core/native/oboe_ffi_bridge.dart
//
// 来自 PRD_Architecture.md §4.6 + §5.3（Architect: FFI 强类型契约）
//
// Dart FFI 强类型绑定层：直接对 C++ 动态库 `liboboe_bridge.so` 暴露的
// 原生函数进行 `Pointer<Void>` / `IntPtr` 强类型映射。
//
// 与 lib/core/native/oboe_bridge.dart（高层契约 / 10ms 释放锁）的区别：
//   - oboe_bridge.dart       ：Dart 侧的句柄管理与超时守门（业务层调用）
//   - oboe_ffi_bridge.dart   ：与 C++ 函数指针 1:1 对应的 FFI 绑定（系统层）
//
// Checker（一票否决）：
//   1) 所有从 native 返回的 Pointer<Void> 必须通过 `Pointer.free()` / `calloc.free()`
//      在 try/finally 中释放，**严禁依赖 Dart GC 触达 C++ 堆内存**。
//   2) 仅在 Android 平台真机/模拟器存在 `liboboe_bridge.so` 时才走真 FFI 路径；
//      其它平台（Windows / Linux host / iOS）走 Stub 实现（直接抛 FfiUnavailable）。
//   3) FFI 查找失败必须捕获 ArgumentError 并升级为 FfiUnavailableException。
//   4) 任何 *Frames / *Buffer 类函数返回的 Pointer 必须由调用方负责释放，
//      不允许跨 isolate 共享 native pointer（避免 GC race）。
//
// 设计原则：
//   - 真 FFI 路径仅在 Android 平台且 `DynamicLibrary.open('liboboe_bridge.so')`
//     成功时才生效；其余情况退化到 Stub。
//   - 所有 C 函数都通过 `lookup<NativeFunction<...>>().asFunction<...>()` 包装。
//   - 字段顺序必须与 .h 头文件一致（X64_64 ABI），否则段错误。

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../result/result.dart';

// ──────────────────────────────────────────────────────────────
// FFI 异常 / 错误码在 result.dart 中定义（sealed class 必须在同一库）
// ──────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────────────────────
// 强类型函数签名（与 oboe_bridge.h 1:1 对齐）
// ──────────────────────────────────────────────────────────────

/// 初始化 capture 流：返回 native handle（intptr_t）。
/// 失败返回 0。
typedef NativeInitCaptureC = Int32 Function(
  Int32 sampleRate,
  Int32 channels,
  Int32 framesPerCallback,
);
typedef NativeInitCaptureDart = int Function(
  int sampleRate,
  int channels,
  int framesPerCallback,
);

/// 读取一帧 PCM 数据到 dstBuffer；返回写入的样本数（0 = 暂无可读）。
/// 调用方负责为 dstBuffer 分配至少 `framesPerCallback * 2` 字节（Int16）。
typedef NativeReadFramesC = Int32 Function(
  IntPtr handle,
  Pointer<Int16> dstBuffer,
  Int32 maxFrames,
);
typedef NativeReadFramesDart = int Function(
  int handle,
  Pointer<Int16> dstBuffer,
  int maxFrames,
);

/// 初始化 playback 流并写入 PCM 数据；返回 native handle。
typedef NativeInitPlaybackC = IntPtr Function(
  Pointer<Int16> pcmBuffer,
  Int32 frameCount,
  Int32 sampleRate,
  Int32 channels,
);
typedef NativeInitPlaybackDart = int Function(
  Pointer<Int16> pcmBuffer,
  int frameCount,
  int sampleRate,
  int channels,
);

/// 写入 / 追加 PCM 到 playback 流；返回已写入样本数。
typedef NativeWritePlaybackC = Int32 Function(
  IntPtr handle,
  Pointer<Int16> pcmBuffer,
  Int32 frameCount,
);
typedef NativeWritePlaybackDart = int Function(
  int handle,
  Pointer<Int16> pcmBuffer,
  int frameCount,
);

/// 同步释放 native 流。返回 0 = 成功；非 0 = error code。
typedef NativeReleaseStreamC = Int32 Function(IntPtr handle);
typedef NativeReleaseStreamDart = int Function(int handle);

/// 查询 native 端当前帧序号（用于 AudioClock 高频 tick 发射）。
typedef NativeGetFrameIndexC = Int64 Function(IntPtr handle);
typedef NativeGetFrameIndexDart = int Function(int handle);

/// 查询是否正在播放。
typedef NativeIsPlayingC = Int32 Function(IntPtr handle);
typedef NativeIsPlayingDart = int Function(int handle);

/// 查询 native 端采样率。
typedef NativeGetSampleRateC = Int32 Function(IntPtr handle);
typedef NativeGetSampleRateDart = int Function(int handle);

// ──────────────────────────────────────────────────────────────
// FFI Bridge 单例
// ──────────────────────────────────────────────────────────────

/// Oboe/AAudio C++ FFI 桥接层。
///
/// 仅在 Android 平台且 liboboe_bridge.so 加载成功时启用真 FFI 路径；
/// 其它平台/失败情况退化到 Stub（所有 native 调用抛 FfiUnavailableException）。
///
/// 所有公开方法都返回 `Result<T, AppError>`，业务层严禁 try/catch FFI 异常。
class OboeFfiBridge {
  OboeFfiBridge._();

  /// 真 FFI 句柄（非 null 表示已成功加载 liboboe_bridge.so）。
  static DynamicLibrary? _lib;

  /// 是否已尝试过初始化（防重复）。
  static bool _initialized = false;

  /// 初始化失败原因（供诊断）。
  static String? _initFailure;

  // ── C 函数指针（懒加载） ───────────────────────────────────
  static NativeInitCaptureDart? _initCapture;
  static NativeReadFramesDart? _readFrames;
  static NativeInitPlaybackDart? _initPlayback;
  // ignore: unused_field
  static NativeWritePlaybackDart? _writePlayback; // 预留给 streaming write 场景
  static NativeReleaseStreamDart? _releaseStream;
  static NativeGetFrameIndexDart? _getFrameIndex;
  static NativeIsPlayingDart? _isPlaying;
  static NativeGetSampleRateDart? _getSampleRate;

  /// 当前是否走真 FFI 路径。
  static bool get isAvailable {
    _ensureInit();
    return _lib != null;
  }

  /// 最近一次初始化失败原因；null 表示成功。
  static String? get initFailure => _initFailure;

  /// 静态初始化（仅执行一次）。
  ///
  /// V2 软策略：在真机上首次调用 isAvailable 时自动 load；
  /// 这里只是提前尝试一次，便于日志埋点。
  static void _ensureInit() {
    if (_initialized) return;
    _initialized = true;
    if (!_isAndroid) {
      _initFailure = 'Platform ${Platform.operatingSystem} not Android';
      return;
    }
    try {
      _lib = DynamicLibrary.open('liboboe_bridge.so');
      _initCapture = _lib!
          .lookup<NativeFunction<NativeInitCaptureC>>('oboe_init_capture')
          .asFunction<NativeInitCaptureDart>();
      _readFrames = _lib!
          .lookup<NativeFunction<NativeReadFramesC>>('oboe_read_frames')
          .asFunction<NativeReadFramesDart>();
      _initPlayback = _lib!
          .lookup<NativeFunction<NativeInitPlaybackC>>('oboe_init_playback')
          .asFunction<NativeInitPlaybackDart>();
      _writePlayback = _lib!
          .lookup<NativeFunction<NativeWritePlaybackC>>('oboe_write_playback')
          .asFunction<NativeWritePlaybackDart>();
      _releaseStream = _lib!
          .lookup<NativeFunction<NativeReleaseStreamC>>('oboe_release_stream')
          .asFunction<NativeReleaseStreamDart>();
      _getFrameIndex = _lib!
          .lookup<NativeFunction<NativeGetFrameIndexC>>('oboe_get_frame_index')
          .asFunction<NativeGetFrameIndexDart>();
      _isPlaying = _lib!
          .lookup<NativeFunction<NativeIsPlayingC>>('oboe_is_playing')
          .asFunction<NativeIsPlayingDart>();
      _getSampleRate = _lib!
          .lookup<NativeFunction<NativeGetSampleRateC>>('oboe_get_sample_rate')
          .asFunction<NativeGetSampleRateDart>();
    } on ArgumentError catch (e) {
      _lib = null;
      _initFailure = 'lookup failed: ${e.message}';
    } catch (e) {
      _lib = null;
      _initFailure = e.toString();
    }
  }

  static bool get _isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      // Platform 在 Web 上不可用；视为非 Android
      return false;
    }
  }

  // ───────────────────────────────────────────────────────────
  // 高层 API（全部返回 Result<T, AppError>）
  // ───────────────────────────────────────────────────────────

  /// 初始化 native capture 流。返回 0 = 失败。
  static Result<int, AppError> initCapture({
    required int sampleRate,
    required int channels,
    required int framesPerCallback,
  }) {
    _ensureInit();
    final fn = _initCapture;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('initCapture: liboboe_bridge.so not loaded'),
      );
    }
    try {
      final h = fn(sampleRate, channels, framesPerCallback);
      if (h == 0) {
        return const Result.failure(
          FfiCallFailedException(errorCode: 0, nativeFunction: 'oboe_init_capture'),
        );
      }
      return Result.success(h);
    } catch (e) {
      return const Result.failure(
        FfiCallFailedException(errorCode: -1, nativeFunction: 'oboe_init_capture'),
      );
    }
  }

  /// 从 native capture 流读取一帧 Int16 PCM 数据。
  ///
  /// 警告：返回的 n 仅为占位（native pointer 已在内部 free）。
  /// 生产代码请使用 [readFramesCopy]；本方法仅用于诊断 hook。
  @Deprecated('Use readFramesCopy; this method exists only for signature parity')
  static Result<int, AppError> readFrames({
    required int handle,
    required int maxFrames,
  }) {
    _ensureInit();
    final fn = _readFrames;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('readFrames: liboboe_bridge.so not loaded'),
      );
    }
    final ptr = calloc<Int16>(maxFrames);
    try {
      final n = fn(handle, ptr, maxFrames);
      if (n < 0) {
        // ignore: prefer_const_constructors
        return Result.failure(
          FfiCallFailedException(errorCode: n, nativeFunction: 'oboe_read_frames'),
        );
      }
      return Result.success(n);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 复制型 PCM 读取：分配 Int16List → 写入 → 立即 free native ptr。
  ///
  /// 这是 AndroidAAudioCapture 默认使用的入口，避免 native 指针跨异步边界。
  static Result<Int16List, AppError> readFramesCopy({
    required int handle,
    required int maxFrames,
  }) {
    _ensureInit();
    final fn = _readFrames;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('readFramesCopy: liboboe_bridge.so not loaded'),
      );
    }
    final ptr = calloc<Int16>(maxFrames);
    try {
      final n = fn(handle, ptr, maxFrames);
      if (n < 0) {
        // ignore: prefer_const_constructors
        return Result.failure(
          FfiCallFailedException(errorCode: n, nativeFunction: 'oboe_read_frames'),
        );
      }
      // copy-out：把 n 个样本复制到 Dart 侧 Int16List，free native ptr。
      final list = Int16List(n);
      for (var i = 0; i < n; i++) {
        list[i] = ptr[i];
      }
      return Result.success(list);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 初始化 native playback 流。
  ///
  /// [pcmBytes]：完整 PCM 数据（Int16 LE）。
  /// 返回 native handle（0 = 失败）。
  static Result<int, AppError> initPlayback({
    required Int16List pcmBytes,
    required int sampleRate,
    required int channels,
  }) {
    _ensureInit();
    final fn = _initPlayback;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('initPlayback: liboboe_bridge.so not loaded'),
      );
    }
    final ptr = calloc<Int16>(pcmBytes.length);
    try {
      // 复制到 native 侧
      for (var i = 0; i < pcmBytes.length; i++) {
        ptr[i] = pcmBytes[i];
      }
      final h = fn(ptr, pcmBytes.length, sampleRate, channels);
      if (h == 0) {
        return const Result.failure(
          FfiCallFailedException(errorCode: 0, nativeFunction: 'oboe_init_playback'),
        );
      }
      return Result.success(h);
    } finally {
      calloc.free(ptr);
    }
  }

  /// 同步释放 native 流。0 = 成功。
  ///
  /// 注意：与 OboeBridge.releaseStreamWithinBudget 不同，这里仅触发 native 释放，
  /// 10ms 预算守门由调用方（OboeBridge）承担。
  static Result<int, AppError> releaseStream(int handle) {
    _ensureInit();
    final fn = _releaseStream;
    if (fn == null) {
      // 不可用时返回 success(0) 视作"已经释放"——业务层已经退化，
      // 不需要再次报错。
      return const Result.success(0);
    }
    try {
      final rc = fn(handle);
      return Result.success(rc);
    } catch (e) {
      return const Result.failure(
        FfiCallFailedException(errorCode: -1, nativeFunction: 'oboe_release_stream'),
      );
    }
  }

  /// 查询当前 native 帧序号。
  static Result<int, AppError> getFrameIndex(int handle) {
    _ensureInit();
    final fn = _getFrameIndex;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('getFrameIndex: liboboe_bridge.so not loaded'),
      );
    }
    try {
      return Result.success(fn(handle));
    } catch (e) {
      return const Result.failure(
        FfiCallFailedException(errorCode: -1, nativeFunction: 'oboe_get_frame_index'),
      );
    }
  }

  /// 查询 native 是否正在播放。
  static Result<bool, AppError> isPlaying(int handle) {
    _ensureInit();
    final fn = _isPlaying;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('isPlaying: liboboe_bridge.so not loaded'),
      );
    }
    try {
      return Result.success(fn(handle) != 0);
    } catch (e) {
      return const Result.failure(
        FfiCallFailedException(errorCode: -1, nativeFunction: 'oboe_is_playing'),
      );
    }
  }

  /// 查询 native 端采样率。
  static Result<int, AppError> getSampleRate(int handle) {
    _ensureInit();
    final fn = _getSampleRate;
    if (fn == null) {
      return const Result.failure(
        FfiUnavailableException('getSampleRate: liboboe_bridge.so not loaded'),
      );
    }
    try {
      return Result.success(fn(handle));
    } catch (e) {
      return const Result.failure(
        FfiCallFailedException(errorCode: -1, nativeFunction: 'oboe_get_sample_rate'),
      );
    }
  }

  /// 测试 / 诊断：强制重置 FFI 绑定（仅用于单测隔离）。
  @visibleForTesting
  static void debugReset() {
    _lib = null;
    _initialized = false;
    _initFailure = null;
    _initCapture = null;
    _readFrames = null;
    _initPlayback = null;
    _writePlayback = null;
    _releaseStream = null;
    _getFrameIndex = null;
    _isPlaying = null;
    _getSampleRate = null;
  }

  /// 测试 / 诊断：注入伪 native 函数（用于在 host 平台测试）。
  ///
  /// 在 host / CI 上没有 .so，但我们可以注入 fake 函数模拟 native 行为。
  @visibleForTesting
  static void debugInstallStubs({
    NativeInitCaptureDart? initCapture,
    NativeReadFramesDart? readFrames,
    NativeInitPlaybackDart? initPlayback,
    NativeWritePlaybackDart? writePlayback,
    NativeReleaseStreamDart? releaseStream,
    NativeGetFrameIndexDart? getFrameIndex,
    NativeIsPlayingDart? isPlaying,
    NativeGetSampleRateDart? getSampleRate,
  }) {
    _initialized = true;
    _lib = DynamicLibrary.process(); // 占位，使 isAvailable=true
    _initCapture = initCapture;
    _readFrames = readFrames;
    _initPlayback = initPlayback;
    _writePlayback = writePlayback;
    _releaseStream = releaseStream;
    _getFrameIndex = getFrameIndex;
    _isPlaying = isPlaying;
    _getSampleRate = getSampleRate;
  }
}