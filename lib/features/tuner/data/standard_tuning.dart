// lib/features/tuner/data/standard_tuning.dart
//
// 来自 PRD_Architecture.md §3.3 (Auditor: Metric_Hardening + Anti_Ambiguity)
//
// 标准尤克里里调音赫兹对照表 + 硬指标常量。
// 单元测试须逐条断言：偏差 > 0.5Hz 或 minConfidence != 0.6 即红。
//
// 严禁在业务代码中出现 "适当 / 流畅 / 自适应" 等模糊词。
// 所有数值必须为本表中的硬常量。

import 'dart:math' as math;

/// 尤克里里四弦标准赫兹数（顺序：四弦 → 一弦，从下到上）。
///
/// 硬指标（Auditor 一票否决）：
///   - A4 = 440.00Hz
///   - E4 = 329.63Hz
///   - C4 = 261.63Hz
///   - G4 = 392.00Hz
///   - 与标准偏差 > 0.5Hz 一律驳回
class StandardTuning {
  StandardTuning._();

  /// 弦顺序：四弦 → 一弦（从下到上）。
  static const List<String> stringOrder = <String>['G4', 'C4', 'E4', 'A4'];

  /// 标准赫兹对照表。
  static const Map<String, double> frequenciesHz = <String, double>{
    'G4': 392.00,
    'C4': 261.63,
    'E4': 329.63,
    'A4': 440.00,
  };

  /// 完美调音容差（±5 cents）。
  static const double toleranceCents = 5.0;

  /// 偏差大于此值视为另一根弦（50 cents ≈ 半音）。
  static const double matchThresholdCents = 50.0;

  /// PCM 帧大小（每帧 2048 样本 ≈ 46.4ms @ 44100Hz）。
  static const int frameSize = 2048;

  /// 置信度门槛（V2 收紧：0.5 → 0.6，用于剔除泛音/静音）。
  static const double minConfidence = 0.6;

  /// 采样率（硬指标：44100Hz）。
  static const int sampleRate = 44100;

  /// 找到距离给定频率最近的弦名。
  /// 偏差 > matchThresholdCents 时返回 null（视为两弦之间的过渡态）。
  static String? nearestString(double hz) {
    if (hz <= 0) return null;
    String? best;
    double bestCents = double.infinity;
    for (final entry in frequenciesHz.entries) {
      final cents = 1200.0 * _log2(hz / entry.value);
      if (cents.abs() < bestCents) {
        bestCents = cents.abs();
        best = entry.key;
      }
    }
    return bestCents <= matchThresholdCents ? best : null;
  }

  /// 计算给定频率与标准赫兹的 cents 偏差。
  static double centsOffset(double hz, String stringName) {
    final ref = frequenciesHz[stringName];
    if (ref == null) {
      throw ArgumentError('Unknown string: $stringName');
    }
    return 1200.0 * _log2(hz / ref);
  }

  static double _log2(double x) => math.log(x) / math.ln2;
}
