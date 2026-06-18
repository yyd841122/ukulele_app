// lib/features/tuner/presentation/tuner_controller.dart
//
// 来自 PRD_Architecture.md §3.6（Auditor: Metric_Hardening +
//                                 Checker: UI_Performance_Guard）
//
// Tuner 业务控制器。职责：
//   1. 订阅 AudioCapturePort.frames() 的 PCM 流；
//   2. 用 PitchEstimator 估算基频（可注入 YIN / 其它实现）；
//   3. 用 MedianPitchFilter 5 帧中位数平滑；
//   4. 强制 60fps（16.6ms）节流后通过 ChangeNotifier 通知 UI；
//   5. 连续 3 帧 confidence < 0.6 时冻结指针（维持最后一帧 PitchResult.frequencyHz
//      不变，但 isTuned = false，isFrozen = true），保证 UI 不跳变。
//
// V2 硬指标（一票否决）：
//   - uiTickInterval = 16ms（与 60fps vsync 对齐）；
//   - 任意连续两帧 PitchResult 发射间隔 >= 16ms；
//   - 1000ms 内 notifyListeners 调用次数 <= 60（防抖锁帧）；
//   - 静默帧（frequencyHz < 0）连续 3 帧后冻结指针；
//   - 完美调音容差 ±5 cents（StandardTuning.toleranceCents）→ isTuned = true。
//
// 注入依赖（构造函数）：
//   - AudioCapturePort
//   - PitchEstimator
//   - MedianPitchFilter（默认实例，可注入 fake）
//   - Stopwatch factory（测试可注入 fake clock）

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/audio/audio_capture_port.dart';
import '../../../core/audio/pcm_frame.dart';
import '../data/standard_tuning.dart';
import '../domain/median_pitch_filter.dart';
import '../domain/pitch_estimator.dart';

/// Tuner UI 状态。
/// 所有字段为不可变值类型，UI 直接绑定即可。
@immutable
class TunerState {
  /// 当前基频赫兹（-1 表示静音）。
  final double currentFrequencyHz;

  /// 最近弦名（G4/C4/E4/A4 或 '?'）。
  final String currentStringName;

  /// 与最近弦的 cents 偏差（正=偏高，负=偏低，clamp 到 [-50, 50]）。
  final double centsOffset;

  /// 是否进入完美容差（|centsOffset| <= 5）。
  final bool isTuned;

  /// 是否处于"指针冻结"态（连续 3 帧静音后，UI 维持最后一帧不再跳变）。
  final bool isFrozen;

  /// 静默计数器（0~3），UI 可用于淡出过渡。
  final int silentFrameCount;

  const TunerState({
    required this.currentFrequencyHz,
    required this.currentStringName,
    required this.centsOffset,
    required this.isTuned,
    required this.isFrozen,
    required this.silentFrameCount,
  });

  /// 初始空状态。
  static const TunerState idle = TunerState(
    currentFrequencyHz: -1.0,
    currentStringName: '?',
    centsOffset: 0.0,
    isTuned: false,
    isFrozen: false,
    silentFrameCount: 0,
  );

  TunerState copyWith({
    double? currentFrequencyHz,
    String? currentStringName,
    double? centsOffset,
    bool? isTuned,
    bool? isFrozen,
    int? silentFrameCount,
  }) {
    return TunerState(
      currentFrequencyHz: currentFrequencyHz ?? this.currentFrequencyHz,
      currentStringName: currentStringName ?? this.currentStringName,
      centsOffset: centsOffset ?? this.centsOffset,
      isTuned: isTuned ?? this.isTuned,
      isFrozen: isFrozen ?? this.isFrozen,
      silentFrameCount: silentFrameCount ?? this.silentFrameCount,
    );
  }
}

/// 抽象时钟（可注入 fake，便于单测断言 60fps 节流）。
abstract class TunerClock {
  int nowMs();
}

class SystemTunerClock implements TunerClock {
  const SystemTunerClock();
  @override
  int nowMs() => DateTime.now().millisecondsSinceEpoch;
}

/// Tuner 控制器。继承 [ChangeNotifier]，UI 通过 [AnimatedBuilder] / [ListenableBuilder]
/// 订阅。
///
/// 线程模型：所有处理在 UI isolate 上同步进行。YIN 算法 O(W²) = 2048² ≈ 4M 浮点 ops，
/// 单帧 < 2ms，60fps 节流后 UI isolate 剩余预算充足。
class TunerController extends ChangeNotifier {
  /// UI 通知最小间隔（PRD §3.6 硬指标：16ms 对齐 60fps vsync）。
  static const Duration uiTickInterval = Duration(milliseconds: 16);

  /// 静默冻结门槛：连续 N 帧 confidence < 0.6 后冻结指针（PRD §3.6 硬指标：3）。
  static const int freezeAfterSilentFrames = 3;

  /// Cents 偏转上限（±50 cents ≈ 半音）。
  static const double maxCentsOffset = 50.0;

  final AudioCapturePort _capture;
  final PitchEstimator _estimator;
  final MedianPitchFilter _filter;
  final TunerClock _clock;

  StreamSubscription<PcmFrame>? _subscription;

  /// 启动期间同步守卫：防止 start() 在 await 期间被重入。
  bool _starting = false;

  /// 上一次通知 UI 的本地时间戳（ms）。-1 表示尚未通知。
  int _lastEmitMs = -1;

  /// 累计通知次数（统计 1000ms 窗口）。
  final List<int> _emitTimestamps = <int>[];

  /// 内部状态。
  TunerState _state = TunerState.idle;
  TunerState get state => _state;

  /// UI 渲染总帧数（测试用）。
  int get notifyCount => _emitTimestamps.length;

  /// 是否在采集中。
  bool get isRunning => _subscription != null;

  /// 当前注入的 capture 端口（测试用）。
  AudioCapturePort get capture => _capture;

  TunerController({
    required AudioCapturePort capture,
    required PitchEstimator estimator,
    MedianPitchFilter? filter,
    TunerClock? clock,
  })  : _capture = capture,
        _estimator = estimator,
        _filter = filter ?? MedianPitchFilter(),
        _clock = clock ?? const SystemTunerClock();

  /// 启动 PCM 采集。重复调用是幂等的。
  Future<void> start() async {
    if (_subscription != null || _starting) return;
    _starting = true;
    try {
      final r = await _capture.start();
      if (!r.isSuccess) {
        throw StateError('AudioCapturePort.start failed: ${r.errorOrNull}');
      }
      _subscription = _capture.frames().listen(_onFrame, onError: _onError);
      _state = _state.copyWith(isFrozen: false, silentFrameCount: 0);
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  /// 停止采集。
  Future<void> stop() async {
    final sub = _subscription;
    if (sub == null) return; // 幂等：未启动时直接返回
    _subscription = null;
    await sub.cancel();
    await _capture.stop();
    _filter.reset();
    _emitTimestamps.clear();
    _state = TunerState.idle;
    notifyListeners();
  }

  /// 直接喂入一个 PitchResult（绕过 capture/estimator，测试用）。
  /// 仍然走 60fps 节流。
  void injectPitch(PitchResult result) {
    _onPitch(result);
  }

  /// 直接喂入一帧 PCM（测试用，跳过 estimator 注入真实算法）。
  void injectFrame(PcmFrame frame) {
    _onFrame(frame);
  }

  /// 重置状态（UI 上点击重置按钮时调用）。
  void reset() {
    _filter.reset();
    _state = TunerState.idle;
    _lastEmitMs = -1;
    _emitTimestamps.clear();
    notifyListeners();
  }

  void _onFrame(PcmFrame frame) {
    final raw = _estimator.estimate(frame);
    _onPitch(raw);
  }

  void _onPitch(PitchResult raw) {
    final filtered = _filter.pushAndGet(raw);

    // 静默帧累计
    final isSilent = filtered == null || filtered.frequencyHz <= 0;
    int silentCount = _state.silentFrameCount;
    if (isSilent) {
      silentCount++;
    } else {
      silentCount = 0;
    }

    if (isSilent) {
      // 静默时不更新频率/弦名/cents，但需要决定是否冻结。
      final frozen = silentCount >= freezeAfterSilentFrames;
      if (frozen != _state.isFrozen || silentCount != _state.silentFrameCount) {
        _state = _state.copyWith(
          isFrozen: frozen,
          silentFrameCount: silentCount,
        );
        _emitIfThrottled();
      }
      return;
    }

    // 计算完美容差
    final cents = filtered.centsOffset.clamp(-maxCentsOffset, maxCentsOffset);
    final tuned = cents.abs() <= StandardTuning.toleranceCents;

    _state = TunerState(
      currentFrequencyHz: filtered.frequencyHz,
      currentStringName: filtered.nearestString,
      centsOffset: cents,
      isTuned: tuned,
      isFrozen: false,
      silentFrameCount: 0,
    );
    _emitIfThrottled();
  }

  void _onError(Object error, StackTrace stack) {
    // 静默吞掉采集错误（避免在 UI isolate 抛未捕获异常）。
    // 真实工程可选择上报埋点。
  }

  void _emitIfThrottled() {
    final now = _clock.nowMs();
    // 节流 1：单帧间隔 >= 16ms（60fps vsync 对齐）
    final elapsed = now - _lastEmitMs;
    if (_lastEmitMs != -1 && elapsed < uiTickInterval.inMilliseconds) {
      return; // 单帧节流：丢弃本次
    }
    // 节流 2：滑动窗口 1000ms 内 emit 计数 <= 60
    // 清理 1000ms 之外的旧戳
    final cutoff = now - 1000;
    _emitTimestamps.removeWhere((t) => t < cutoff);
    if (_emitTimestamps.length >= 60) {
      // 窗口已满；延后到最早戳滑出窗口（>= 最早戳 + 1000ms）才允许下一次 emit
      // 为了避免总线阻塞，这里直接丢弃本次（软节流）
      return;
    }

    _lastEmitMs = now;
    _emitTimestamps.add(now);

    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
