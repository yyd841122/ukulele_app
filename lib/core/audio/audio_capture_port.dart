// lib/core/audio/audio_capture_port.dart
//
// 来自 PRD_Architecture.md §3.2 (Architect: Interface_Driven)
//
// 抽象麦克风 PCM 采集接口。实现方：AndroidAAudioCapture（生产）/ FakeAudioCapture（测试）。
// 调用方：Tuner 模块。
//
// Checker 硬约束（Oboe_AAudio_Gatekeeper）：
//   - start() 被调用前调用方必须已获得 RECORD_AUDIO 权限；
//     实现方可以选择在此处再次 assert MicState == granted。
//   - start() 失败必须返回 Result.failure，不抛裸异常。
//   - stop() 必须幂等，多次调用不得抛异常。
//   - frames() 返回的 Stream 必须是 broadcast。

import 'dart:async';

import 'pcm_frame.dart';
import '../result/result.dart';

abstract class AudioCapturePort {
  /// PCM 帧流。实现必须是 broadcast（多订阅者安全）。
  Stream<PcmFrame> frames();

  /// 启动麦克风采集。必须先获 RECORD_AUDIO 权限。
  Future<Result<void, AppError>> start();

  /// 停止采集。幂等。
  Future<Result<void, AppError>> stop();

  /// 当前是否在采集中。
  bool get isRunning;

  /// 采样率，必须返回 44100。
  int get sampleRate;
}

/// 供测试桩使用的轻量实现（不连接任何硬件）。
/// 仅在 registerTestDependencies() 中注册。
class NoopAudioCapture implements AudioCapturePort {
  final StreamController<PcmFrame> _ctl = StreamController<PcmFrame>.broadcast();
  bool _running = false;

  @override
  Stream<PcmFrame> frames() => _ctl.stream;

  @override
  Future<Result<void, AppError>> start() async {
    _running = true;
    return const Result.success(null);
  }

  @override
  Future<Result<void, AppError>> stop() async {
    _running = false;
    return const Result.success(null);
  }

  @override
  bool get isRunning => _running;

  @override
  int get sampleRate => 44100;

  /// 测试辅助：主动推一帧。
  void debugPush(PcmFrame frame) => _ctl.add(frame);

  Future<void> dispose() async => _ctl.close();
}
