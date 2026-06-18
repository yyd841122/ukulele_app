// lib/core/native/android_audio_bridge.dart
//
// 来自 PRD_Architecture.md §3.5 (Checker: Oboe_AAudio_Gatekeeper)
//
// Dart ↔ Android 原生层 MethodChannel / EventChannel 桥接契约。
// 真实 MethodChannel 注册由 Android 侧 `MainActivity.kt` 配套实现。
//
// V2 硬指标（一票否决）：
//   - Channel name 固定 "com.yyd841122.ukulele_app/audio"
//   - startCapture() 前未获 RECORD_AUDIO 权限 → 返回 MicNotGrantedException
//   - 绑定 Android Activity 生命周期 onPause / onStop；
//     失去焦点时必须在 10ms 内通知底层释放 native 句柄（走 OboeBridge）
//   - 权限状态机：unrequested → requesting → granted / denied / permanentlyDenied
//
// 当前实现：契约骨架 + 内存侧状态机；真实 native bridge 集成在 Android NDK 阶段补齐。
// 测试策略：FakeAndroidAudioBridge 模拟 granted/denied/timeout 场景。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import '../audio/pcm_frame.dart';
import '../result/result.dart';
import 'oboe_bridge.dart';

/// Channel 名称（与 Android 侧 MainActivity.kt 保持一致）。
const String kAudioChannelName = 'com.yyd841122.ukulele_app/audio';

/// EventChannel 名称。
const String kAudioCaptureEventChannel =
    'com.yyd841122.ukulele_app/audio_frames';

/// MethodChannel 调用方法名常量。
class AudioMethod {
  AudioMethod._();
  static const String requestMicPermission = 'requestMicPermission';
  static const String startCapture = 'startCapture';
  static const String stopCapture = 'stopCapture';
  static const String releaseStream = 'releaseStream';
  static const String getNativeHandle = 'getNativeHandle';
}

/// 权限状态机。
enum MicState { unrequested, requesting, granted, denied, permanentlyDenied }

/// 桥接层异常。
class AudioBridgeException implements Exception {
  final String code;
  final String message;
  const AudioBridgeException(this.code, this.message);
  @override
  String toString() => 'AudioBridgeException($code: $message)';
}

/// Android 原生桥接契约。
abstract class AndroidAudioBridge {
  MicState get micState;
  Stream<MicState> get micStateStream;
  bool get isCapturing;
  Stream<PcmFrame> get frames;

  Future<MicState> requestPermission();
  Future<Result<void, AppError>> startCapture();
  Future<Result<void, AppError>> stopCapture();
  Future<void> onLifecyclePause();
  void onLifecycleResume();
  Future<void> dispose();
}

/// 字符串权限名 → MicState 转换 helper。
MicState parseMicStateName(String? raw) {
  switch (raw) {
    case 'granted':
      return MicState.granted;
    case 'denied':
      return MicState.denied;
    case 'permanentlyDenied':
      return MicState.permanentlyDenied;
    default:
      return MicState.denied;
  }
}

/// 默认实现：MethodChannel + EventChannel。
class MethodChannelAudioBridge implements AndroidAudioBridge {
  final MethodChannel _methodChannel;
  final StreamController<PcmFrame> _frameCtl =
      StreamController<PcmFrame>.broadcast();
  final StreamController<MicState> _stateCtl =
      StreamController<MicState>.broadcast();
  final NativeHandleOwner _handle = NativeHandleOwner();

  MicState _micState = MicState.unrequested;
  bool _isCapturing = false;
  StreamSubscription<dynamic>? _eventSub;

  MethodChannelAudioBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel = methodChannel ??
            const MethodChannel(kAudioChannelName) {
    final ec = eventChannel ?? const EventChannel(kAudioCaptureEventChannel);
    _eventSub = ec.receiveBroadcastStream().listen(
      _onNativeFrame,
      onError: (Object err) {
        // 原生侧错误：保持 stream 开放不中断采集
        // ignore: avoid_print
        assert(() {
          // ignore: avoid_print
          print('AudioBridge event error: $err');
          return true;
        }());
      },
    );
  }

  @override
  MicState get micState => _micState;

  @override
  Stream<MicState> get micStateStream => _stateCtl.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Stream<PcmFrame> get frames => _frameCtl.stream;

  @override
  Future<MicState> requestPermission() async {
    _setMicState(MicState.requesting);
    try {
      final raw = await _methodChannel.invokeMethod<String>(
        AudioMethod.requestMicPermission,
      );
      final next = parseMicStateName(raw);
      _setMicState(next);
      return next;
    } on PlatformException catch (e) {
      _setMicState(MicState.denied);
      throw AudioBridgeException(e.code, e.message ?? 'permission request failed');
    }
  }

  @override
  Future<Result<void, AppError>> startCapture() async {
    if (_micState != MicState.granted) {
      // V2 一票否决：未授权时一票否决 startCapture()
      return const Result.failure(MicNotGrantedException());
    }
    if (_isCapturing) {
      return const Result.success(null);
    }
    try {
      await _methodChannel.invokeMethod<void>(AudioMethod.startCapture);
      _isCapturing = true;
      return const Result.success(null);
    } on PlatformException catch (e) {
      return Result.failure(
        NativeBridgeException(e.code, e.message ?? 'startCapture failed'),
      );
    }
  }

  @override
  Future<Result<void, AppError>> stopCapture() async {
    if (!_isCapturing) {
      return const Result.success(null);
    }
    try {
      await _methodChannel.invokeMethod<void>(AudioMethod.stopCapture);
      _isCapturing = false;
      if (!_handle.isReleased) {
        _handle.releaseWithinBudget();
      }
      return const Result.success(null);
    } on PlatformException catch (e) {
      return Result.failure(
        NativeBridgeException(e.code, e.message ?? 'stopCapture failed'),
      );
    }
  }

  @override
  Future<void> onLifecyclePause() async {
    if (_isCapturing) {
      await stopCapture();
    }
    if (!_handle.isReleased) {
      _handle.releaseWithinBudget();
    }
  }

  @override
  void onLifecycleResume() {
    // 不自动重启采集；用户需再次点击。
  }

  @override
  Future<void> dispose() async {
    if (_isCapturing) {
      await stopCapture();
    }
    if (!_handle.isReleased) {
      _handle.releaseWithinBudget();
    }
    await _eventSub?.cancel();
    await _frameCtl.close();
    await _stateCtl.close();
  }

  // ── 内部 ───────────────────────────────────────────

  void _onNativeFrame(dynamic raw) {
    if (raw is Uint8List) {
      final samples = Int16List.view(
        raw.buffer,
        raw.offsetInBytes,
        raw.lengthInBytes ~/ 2,
      );
      _frameCtl.add(PcmFrame(
        samples: samples,
        sampleRate: 44100,
        capturedAt: DateTime.now(),
      ));
    } else if (raw is List<int>) {
      final samples = Int16List.fromList(raw.cast<int>());
      _frameCtl.add(PcmFrame(
        samples: samples,
        sampleRate: 44100,
        capturedAt: DateTime.now(),
      ));
    }
  }

  void _setMicState(MicState s) {
    _micState = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }
}

/// 内存侧 Fake Bridge（用于单元测试）。
class FakeAndroidAudioBridge implements AndroidAudioBridge {
  final StreamController<PcmFrame> _frameCtl =
      StreamController<PcmFrame>.broadcast();
  final StreamController<MicState> _stateCtl =
      StreamController<MicState>.broadcast();
  final NativeHandleOwner _handle = NativeHandleOwner();

  MicState _micState = MicState.unrequested;
  bool _isCapturing = false;

  final Map<String, Object> _methodResponses = <String, Object>{};
  final List<String> methodCalls = <String>[];

  @visibleForTesting
  void debugConfigure(String method, Object response) {
    _methodResponses[method] = response;
  }

  @visibleForTesting
  void debugPushFrame(PcmFrame frame) => _frameCtl.add(frame);

  @override
  MicState get micState => _micState;

  @override
  Stream<MicState> get micStateStream => _stateCtl.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Stream<PcmFrame> get frames => _frameCtl.stream;

  @override
  Future<MicState> requestPermission() async {
    methodCalls.add(AudioMethod.requestMicPermission);
    final resp = _methodResponses[AudioMethod.requestMicPermission];
    if (resp is MicState) {
      _micState = resp;
      _stateCtl.add(resp);
      return resp;
    }
    if (resp is String) {
      final s = parseMicStateName(resp);
      _micState = s;
      _stateCtl.add(s);
      return s;
    }
    _micState = MicState.granted;
    _stateCtl.add(_micState);
    return _micState;
  }

  @override
  Future<Result<void, AppError>> startCapture() async {
    methodCalls.add(AudioMethod.startCapture);
    if (_micState != MicState.granted) {
      return const Result.failure(MicNotGrantedException());
    }
    final resp = _methodResponses[AudioMethod.startCapture];
    if (resp is Exception) {
      return Result.failure(
        NativeBridgeException('fake', 'fake startCapture error: $resp'),
      );
    }
    _isCapturing = true;
    return const Result.success(null);
  }

  @override
  Future<Result<void, AppError>> stopCapture() async {
    methodCalls.add(AudioMethod.stopCapture);
    if (!_isCapturing) {
      return const Result.success(null);
    }
    _isCapturing = false;
    if (!_handle.isReleased) {
      _handle.releaseWithinBudget();
    }
    return const Result.success(null);
  }

  @override
  Future<void> onLifecyclePause() async {
    if (_isCapturing) {
      await stopCapture();
    }
    if (!_handle.isReleased) {
      _handle.releaseWithinBudget();
    }
  }

  @override
  void onLifecycleResume() {}

  @override
  Future<void> dispose() async {
    _frameCtl.close();
    _stateCtl.close();
  }
}
