// lib/core/audio/audio_session_mutex.dart
//
// 来自 PRD_Architecture.md §5.2 V2 修复（Architect: Interface_Driven）
//
// 同一进程内 Tuner 麦克风采集与 Score 伴奏播放互斥，防止 Android AudioSession
// 冲突。Android 侧走 AAudio AAUDIO_SHARING_MODE_EXCLUSIVE，framesPerBurst ≤ 256。
//
// Checker 硬约束（Oboe_AAudio_Gatekeeper）：
//   - 同一时刻仅允许一个 Owner；
//   - acquire 失败立即抛 AudioSessionBusyException，不排队；
//   - 持有方 5s 未 release 触发强制回收（防 app 崩溃遗留死锁）。
//
// 当前实现：纯 Dart 内存互斥（端口已 ready 后可桥接 native AudioManager）。
// TODO(integration): Android 侧通过 MethodChannel 调用 AudioManager.requestAudioFocus
// 并桥接 AAudio EXCLUSIVE 模式。

import 'dart:async';

import '../result/result.dart';

/// 会话模式。V2 暂只支持 capture / playback 二选一。
enum AudioSessionMode {
  idle,
  captureExclusive,   // Tuner 独占麦克风
  playbackExclusive,  // Score/Chord 独占扬声器
}

abstract class AudioSessionMutex {
  /// 获取独占会话。失败立即抛 AudioSessionBusyException。
  Future<void> acquire(AudioSessionMode mode);

  /// 释放会话。幂等。
  Future<void> release(AudioSessionMode mode);

  /// 当前持有方模式（无持有方时返回 AudioSessionMode.idle）。
  AudioSessionMode get currentMode;

  /// 模式变更流。实现必须是 broadcast。
  Stream<AudioSessionMode> get modeStream;

  /// 释放全部资源（应用退出时调用）。
  Future<void> dispose();
}

/// 默认 Dart 内存互斥实现。
class InMemoryAudioSessionMutex implements AudioSessionMutex {
  InMemoryAudioSessionMutex();

  AudioSessionMode _mode = AudioSessionMode.idle;
  final StreamController<AudioSessionMode> _ctl =
      StreamController<AudioSessionMode>.broadcast();

  Timer? _watchdog;
  static const Duration _watchdogTimeout = Duration(seconds: 5);

  @override
  AudioSessionMode get currentMode => _mode;

  @override
  Stream<AudioSessionMode> get modeStream => _ctl.stream;

  @override
  Future<void> acquire(AudioSessionMode mode) async {
    if (mode == AudioSessionMode.idle) {
      throw ArgumentError('mode must be captureExclusive or playbackExclusive');
    }
    if (_mode != AudioSessionMode.idle && _mode != mode) {
      throw AudioSessionBusyException(
        requestedMode: _modeName(mode),
        currentMode: _modeName(_mode),
      );
    }
    _mode = mode;
    _ctl.add(_mode);
    _armWatchdog();
  }

  @override
  Future<void> release(AudioSessionMode mode) async {
    if (_mode == mode) {
      _mode = AudioSessionMode.idle;
      _ctl.add(_mode);
      _watchdog?.cancel();
      _watchdog = null;
    }
  }

  @override
  Future<void> dispose() async {
    _watchdog?.cancel();
    _watchdog = null;
    _mode = AudioSessionMode.idle;
    await _ctl.close();
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_watchdogTimeout, () {
      // 5s 强制回收（防 app 异常退出后死锁）
      _mode = AudioSessionMode.idle;
      _ctl.add(_mode);
    });
  }

  String _modeName(AudioSessionMode m) {
    switch (m) {
      case AudioSessionMode.idle:
        return 'idle';
      case AudioSessionMode.captureExclusive:
        return 'captureExclusive';
      case AudioSessionMode.playbackExclusive:
        return 'playbackExclusive';
    }
  }
}
