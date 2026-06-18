// lib/features/tuner/domain/median_pitch_filter.dart
//
// 来自 PRD_Architecture.md §3.4 (Auditor: Metric_Hardening + Checker: Oboe_AAudio_Gatekeeper)
//
// 5 帧中位数滤波器，用于剔除多弦共振产生的泛音噪点。
//
// V2 硬指标（一票否决）：
//   - 窗口大小固定为 5（FIFO 队列）。
//   - 入窗前校验 confidence >= StandardTuning.minConfidence (0.6)，
//     低于门槛的帧不入窗（视为泛音/静音噪点）。
//   - 窗口内有效元素 >= 3 时，对 frequencyHz 排序取中位数输出。
//   - 窗口内有效元素 < 3 时返回 null（强制等待，禁止发射）。
//   - 中位数与最近一次发射值偏差 > maxJumpCents (200 cents) 时丢弃
//     （视为瞬态噪声尖峰）。
//
// 注入依赖：StandardTuning.minConfidence（避免魔术数字）。
// 纯 Dart 实现，无 I/O，无 Stream 订阅；调用方逐帧 pushAndGet。

import 'dart:collection';
import 'dart:math' as math;

import '../data/standard_tuning.dart';

/// 单帧基频检测结果（来自 PitchEstimator 的输出）。
class PitchResult {
  /// 基频赫兹。
  final double frequencyHz;

  /// 置信度 [0.0, 1.0]。
  final double confidence;

  /// 与最近弦的 cents 偏差（正=偏高，负=偏低）。
  final double centsOffset;

  /// 距离最近的弦名（G4/C4/E4/A4），无法判定时为 '?'。
  final String nearestString;

  const PitchResult({
    required this.frequencyHz,
    required this.confidence,
    required this.centsOffset,
    required this.nearestString,
  });

  PitchResult copyWith({
    double? frequencyHz,
    double? confidence,
    double? centsOffset,
    String? nearestString,
  }) {
    return PitchResult(
      frequencyHz: frequencyHz ?? this.frequencyHz,
      confidence: confidence ?? this.confidence,
      centsOffset: centsOffset ?? this.centsOffset,
      nearestString: nearestString ?? this.nearestString,
    );
  }

  @override
  String toString() =>
      'PitchResult(hz: ${frequencyHz.toStringAsFixed(2)}, '
      'conf: ${confidence.toStringAsFixed(2)}, '
      'cents: ${centsOffset.toStringAsFixed(1)}, '
      'str: $nearestString)';
}

/// 5 帧中位数滤波器。
class MedianPitchFilter {
  /// 滑动窗口大小（V2 硬指标）。
  static const int windowSize = 5;

  /// 中位数与上一次发射值偏差上限（cents），超出视为噪声尖峰。
  static const double maxJumpCents = 200.0;

  /// 最小有效帧数，少于此值禁止发射（V2 硬指标：3）。
  static const int minValidFramesToEmit = 3;

  final double _minConfidence;
  final Queue<PitchResult> _window = Queue<PitchResult>();
  double? _lastEmittedHz;

  /// 构造时可注入自定义 confidence 门槛（测试时常用 0.6 即可）。
  MedianPitchFilter({double minConfidence = StandardTuning.minConfidence})
      : _minConfidence = minConfidence;

  /// 当前窗口内有效元素数量。
  int get validFrameCount => _window.length;

  /// 上一次发射的频率；尚未发射过返回 null。
  double? get lastEmittedHz => _lastEmittedHz;

  /// 清空窗口与历史状态（生命周期/重置时调用）。
  void reset() {
    _window.clear();
    _lastEmittedHz = null;
  }

  /// 推入一帧并返回中位数结果。
  ///
  /// 返回 null 的场景：
  ///   1) 当前帧 confidence < 0.6（不入窗）。
  ///   2) 窗口内有效帧 < 3（强制等待）。
  ///   3) 中位数相对上次发射值跳跃 > 200 cents（噪声尖峰丢弃）。
  PitchResult? pushAndGet(PitchResult raw) {
    if (raw.confidence < _minConfidence) {
      return null; // 泛音/静音噪点直接丢弃
    }
    if (raw.frequencyHz <= 0) {
      return null; // 非法频率
    }

    _window.addLast(raw);
    while (_window.length > windowSize) {
      _window.removeFirst();
    }

    if (_window.length < minValidFramesToEmit) {
      return null; // 窗口未满，禁止发射
    }

    final sorted = _window.map((r) => r.frequencyHz).toList()..sort();
    final medianHz = sorted[sorted.length ~/ 2];

    if (_lastEmittedHz != null) {
      final jumpCents = 1200.0 * (math.log(medianHz / _lastEmittedHz!) / math.ln2);
      if (jumpCents.abs() > maxJumpCents) {
        return null; // 噪声尖峰，丢弃本次中位数
      }
    }

    _lastEmittedHz = medianHz;

    // 基于中位数重建 centsOffset 与 nearestString（保持输入的 confidence）。
    final nearest = StandardTuning.nearestString(medianHz) ?? '?';
    final cents = nearest == '?'
        ? 0.0
        : StandardTuning.centsOffset(medianHz, nearest);

    return PitchResult(
      frequencyHz: medianHz,
      confidence: raw.confidence,
      centsOffset: cents,
      nearestString: nearest,
    );
  }
}
