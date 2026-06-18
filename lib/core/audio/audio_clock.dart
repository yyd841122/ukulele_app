// lib/core/audio/audio_clock.dart
//
// 来自 PRD_Architecture.md §5.3 + §5.7（Architect: Interface_Driven + Auditor: Metric_Hardening）
//
// 全局唯一音频时钟。所有 UI 同步（chord 切换 / 歌词滚动 / Tab 高亮）
// 必须订阅本时钟的 positionStream，禁止使用 DateTime.now() 作为时间源。
//
// V2 硬指标（一票否决）：
//   - tick 间隔：1024 帧 / 44100Hz ≈ 23.22ms
//   - 1000 个连续 tick 的物理时间抖动标准差 ≤ 5ms
//   - 长时间运行位置累计误差 ≤ ±15ms（PRD §4.6 音画同步）
//   - positionStream 必须是 broadcast（多 UI 订阅者）
//
// 实现策略：
//   - 单一时间源：AudioPlaybackPort.ticks()（生产）或注入的 FakeClock
//   - 物理时间标定：每次发射 tick 时记录 wall clock，与 expectedTime 做差
//   - 抖动监测：内置标准差统计，> 5ms 时发出 JitterOverflowException
//
// 角色分工：
//   - Architect：强类型契约，注入播放端口
//   - Auditor：positionStream 高频转化 + 抖动断言
//   - Checker：句柄释放 / 反压控制 / Isolate 隔离

import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../result/result.dart';
import 'audio_playback_port.dart';

/// 全局统一音频时钟。
///
/// 唯一时间源：`AudioPlaybackPort.ticks()`。
/// 每个 tick 携带 frameIndex → 转算为 Duration position。
///
/// 抖动监测：当 `_enableJitterMonitor` 为 true 时，最近 N 个 tick 的物理
/// 时间间隔会被记录；N >= 阈值时计算标准差，超出预算则触发 _jitterOverflowCtrl
/// （测试用抛异常，生产用日志 + 降级）。
class AudioClock {
  /// 1024 帧 / 44100Hz。
  static const int kFramesPerTick = 1024;

  /// 44100Hz。
  static const int kSampleRate = 44100;

  /// 单 tick 物理时长（≈ 23.22ms）。
  static const Duration kTickInterval =
      Duration(microseconds: 23226544); // 1024 * 1e6 / 44100

  /// 抖动容差（PRD §5.7 一票否决：≤ 5ms）。
  static const Duration kJitterTolerance = Duration(milliseconds: 5);

  /// 抖动监测窗口。
  static const int kJitterWindow = 1000;

  /// 位置累计误差容差（PRD §4.6 音画同步：≤ ±15ms）。
  static const Duration kPositionDriftTolerance = Duration(milliseconds: 15);

  final AudioPlaybackPort _player;
  final StreamController<Duration> _positionCtl =
      StreamController<Duration>.broadcast();
  final StreamController<JitterOverflowException> _jitterCtl =
      StreamController<JitterOverflowException>.broadcast();

  StreamSubscription<PlaybackTick>? _sub;

  /// 最近 N 个 tick 的 wall-clock 间隔（μs）。仅 monitor 模式下累积。
  final List<int> _intervalMicros = <int>[];

  /// 上一次 tick 的 wall-clock 时刻（μs）。
  int? _lastTickMicros;

  /// 上一次 tick 的 expected position（预留给累计误差统计）。
  // ignore: unused_field
  Duration? _lastEmittedPosition;

  /// 物理时间与逻辑时间的累计误差（μs）。正 = 落后。
  int _accumulatedDriftMicros = 0;

  /// 是否启用抖动监测。生产可关闭以节省 CPU。
  final bool _enableJitterMonitor;

  /// 抖动超限时是否抛异常（测试用 true，生产用 false）。
  final bool _failFastOnJitter;

  AudioClock(
    AudioPlaybackPort player, {
    bool enableJitterMonitor = true,
    bool failFastOnJitter = false,
  })  : _player = player,
        _enableJitterMonitor = enableJitterMonitor,
        _failFastOnJitter = failFastOnJitter;

  /// 当前播放位置流（广播）。所有 UI 订阅此流作为唯一时间源。
  Stream<Duration> get positionStream => _positionCtl.stream;

  /// 抖动超限事件流（广播）。仅 monitor 启用时发射。
  Stream<JitterOverflowException> get jitterOverflowStream => _jitterCtl.stream;

  /// 启动时钟监听（绑定到 player.ticks）。
  void start() {
    if (_sub != null) return;
    _sub = _player.ticks().listen(_onTick);
  }

  /// 停止监听。
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _lastTickMicros = null;
    _lastEmittedPosition = null;
    _intervalMicros.clear();
    _accumulatedDriftMicros = 0;
  }

  /// 释放资源。
  Future<void> dispose() async {
    await stop();
    await _positionCtl.close();
    await _jitterCtl.close();
  }

  // ── 内部 ─────────────────────────────────────────────────

  void _onTick(PlaybackTick tick) {
    if (!tick.isPlaying) return;

    final nowMicros = DateTime.now().microsecondsSinceEpoch;

    // 1) 抖动监测
    if (_enableJitterMonitor && _lastTickMicros != null) {
      final intervalUs = nowMicros - _lastTickMicros!;
      _intervalMicros.add(intervalUs);
      if (_intervalMicros.length > kJitterWindow) {
        _intervalMicros.removeAt(0);
      }
      // 累计误差
      final expectedUs = kTickInterval.inMicroseconds;
      _accumulatedDriftMicros += (intervalUs - expectedUs);
    }
    _lastTickMicros = nowMicros;

    // 2) 期望位置（基于 frameIndex 推算，与物理时间无关）
    _positionCtl.add(tick.position);
    _lastEmittedPosition = tick.position;

    // 3) 窗口满后做一次标准差检查
    if (_enableJitterMonitor && _intervalMicros.length == kJitterWindow) {
      _evaluateJitter();
    }
  }

  void _evaluateJitter() {
    if (_intervalMicros.isEmpty) return;
    final mean = _intervalMicros.reduce((a, b) => a + b) / _intervalMicros.length;
    final variance = _intervalMicros
            .map((x) => (x - mean) * (x - mean))
            .reduce((a, b) => a + b) /
        _intervalMicros.length;
    final stdDevMicros = math.sqrt(variance);
    final stdDevMs = stdDevMicros / 1000.0;

    if (stdDevMs > kJitterTolerance.inMilliseconds) {
      final ex = JitterOverflowException(
        stdDevMs: stdDevMs,
        sampleCount: _intervalMicros.length,
      );
      if (_failFastOnJitter) {
        // 测试场景：直接抛，由 AudioClockTest 捕获
        throw ex;
      }
      // 生产场景：emit 到 jitterOverflowStream 供上层告警
      if (!_jitterCtl.isClosed) _jitterCtl.add(ex);
    }
  }

  // ── 测试 / 诊断入口 ───────────────────────────────────────

  /// 当前累计物理时间误差（μs）。
  @visibleForTesting
  int get accumulatedDriftMicros => _accumulatedDriftMicros;

  /// 当前窗口样本数。
  @visibleForTesting
  int get jitterSampleCount => _intervalMicros.length;

  /// 当前窗口标准差（ms）。
  @visibleForTesting
  double get currentJitterStdDevMs {
    if (_intervalMicros.isEmpty) return 0.0;
    final mean =
        _intervalMicros.reduce((a, b) => a + b) / _intervalMicros.length;
    final variance = _intervalMicros
            .map((x) => (x - mean) * (x - mean))
            .reduce((a, b) => a + b) /
        _intervalMicros.length;
    return math.sqrt(variance) / 1000.0;
  }

  /// 直接注入一个 tick（绕过 _player.ticks）。仅供测试。
  @visibleForTesting
  void debugInjectTick(PlaybackTick tick) => _onTick(tick);
}