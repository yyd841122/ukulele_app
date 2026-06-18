// lib/core/audio/audio_playback_port.dart
//
// 来自 PRD_Architecture.md §4 + §5.3 (Architect: Interface_Driven)
//
// 抽象音频播放接口。实现方：AndroidAAudioPlayback（生产）/ FakeAudioPlayback（测试）。
// 调用方：Chord 模块、Score 模块。
//
// Checker 硬约束（Oboe_AAudio_Gatekeeper）：
//   - load() 必须在 play() 之前调用；load 失败必须 dispose 并 Result.failure。
//   - ticks() 必须以 1024 帧 / 44100Hz ≈ 23.22ms 的固定间隔发射。
//   - play() 端到端延迟 ≤ 30ms（V2 硬指标）。
//   - detachNativeHandle() 释放后必须由调用方调用 OboeBridge.releaseStreamWithinBudget，
//     并将 Dart 侧句柄置 0。
//   - 所有 Stream 必须为 broadcast。

import 'dart:async';

import '../result/result.dart';

/// 播放时钟 tick（每 1024 帧一个，≈ 23.22ms @ 44100Hz）。
class PlaybackTick {
  /// 自 0 开始的连续帧序号。
  final int frameIndex;

  /// 当前播放位置。
  final Duration position;

  /// 是否正在播放。
  final bool isPlaying;

  const PlaybackTick({
    required this.frameIndex,
    required this.position,
    required this.isPlaying,
  });
}

abstract class AudioPlaybackPort {
  /// 时钟 tick 流。实现必须是 broadcast。
  Stream<PlaybackTick> ticks();

  /// 加载资产。必须在 play() 之前调用。
  Future<Result<void, AppError>> load(String assetPath);

  /// 开始播放。端到端延迟 ≤ 30ms。
  Future<Result<void, AppError>> play();

  /// 暂停。
  Future<Result<void, AppError>> pause();

  /// 跳转到指定位置。
  Future<Result<void, AppError>> seek(Duration position);

  /// 释放全部资源。
  Future<Result<void, AppError>> dispose();

  /// 是否已加载资产。
  bool get isLoaded;

  /// 是否正在播放。
  bool get isPlaying;

  /// 当前播放位置。
  Duration get position;

  /// 关联的 Asset 路径（已加载时）。
  String? get loadedAsset;

  /// ★ V2 新增：脱离底层 Oboe/AAudio 流句柄，供 ChordPlayer.stop() 调用
  /// OboeBridge.releaseStreamWithinBudget(handle)。调用后本对象不再持有句柄，
  /// 必须由调用方负责将句柄置 0。
  ///
  /// 返回 0 表示无可释放句柄（例如 Mock 或未播放状态）。
  int detachNativeHandle();
}

/// 供测试桩使用的轻量实现。
class NoopAudioPlayback implements AudioPlaybackPort {
  final StreamController<PlaybackTick> _ticks = StreamController<PlaybackTick>.broadcast();
  bool _loaded = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  String? _asset;
  int _handle = 0;

  @override
  Stream<PlaybackTick> ticks() => _ticks.stream;

  @override
  Future<Result<void, AppError>> load(String assetPath) async {
    _asset = assetPath;
    _loaded = true;
    return const Result.success(null);
  }

  @override
  Future<Result<void, AppError>> play() async {
    if (!_loaded) return const Result.failure(AudioNotLoadedException());
    _playing = true;
    return const Result.success(null);
  }

  @override
  Future<Result<void, AppError>> pause() async {
    _playing = false;
    return const Result.success(null);
  }

  @override
  Future<Result<void, AppError>> seek(Duration position) async {
    _position = position;
    return const Result.success(null);
  }

  @override
  Future<Result<void, AppError>> dispose() async {
    _playing = false;
    _loaded = false;
    _asset = null;
    return const Result.success(null);
  }

  @override
  bool get isLoaded => _loaded;

  @override
  bool get isPlaying => _playing;

  @override
  Duration get position => _position;

  @override
  String? get loadedAsset => _asset;

  @override
  int detachNativeHandle() {
    final h = _handle;
    _handle = 0; // V2: 释放后立即清零，防野指针
    return h;
  }

  /// 测试辅助：注入句柄模拟 native 层。
  void debugSetHandle(int h) => _handle = h;

  /// 测试辅助：发射一个 tick。
  void debugTick(PlaybackTick t) => _ticks.add(t);

  Future<void> close() async => _ticks.close();
}
