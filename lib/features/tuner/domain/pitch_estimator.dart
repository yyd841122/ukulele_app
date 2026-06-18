// lib/features/tuner/domain/pitch_estimator.dart
//
// 来自 PRD_Architecture.md §3.2 / §3.4 (Architect: Interface_Driven + Auditor: Metric_Hardening)
//
// YIN 音高识别算法（纯 Dart 实现）。
//
// 算法流程（论文：de Cheveigné & Kawahara, 2002）：
//   1. 自相关差分函数 d(tau) = sum_{j=0..W-1} (x[j] - x[j+tau])^2
//   2. 累积平均差分函数 D(tau) = d(tau) / ((1/tau) * sum_{j=1..tau} d(j))
//   3. 绝对阈值检索：寻找 D(tau) 首次降到 threshold (0.10) 以下的 tau
//   4. 抛物线插值提升精度
//   5. 计算 confidence = 1 - D(tau_min)
//
// V2 硬指标（一票否决）：
//   - 采样率 44100Hz，帧长 2048 样本（来自 PcmFrame 硬约束）
//   - 绝对阈值 = 0.10
//   - 音高检索范围 100Hz ~ 1200Hz（尤克里里物理频域）
//   - 范围外 / 静音 / 谐波异常 → confidence = 0.0, frequencyHz = -1.0
//   - 2nd harmonic 能量 ≥ 0.85 × fundamental 且 confidence < 0.6 → 泛音剔除
//
// PitchResult 定义在 median_pitch_filter.dart 中复用（本文件不重复定义）。

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/audio/pcm_frame.dart';
import '../data/standard_tuning.dart';
import 'median_pitch_filter.dart' show PitchResult;

abstract class PitchEstimator {
  /// 输入一帧 PCM，输出基频与置信度。
  /// V2 硬约束：
  ///   1. 静音 / 范围外 / 谐波异常 → frequencyHz = -1.0, confidence = 0.0
  ///   2. 谐波剔除：2nd harmonic 能量 ≥ 0.85 × fundamental 且 confidence < 0.6
  PitchResult estimate(PcmFrame frame);
}

/// YIN 算法实现（纯 Dart，无原生依赖）。
class YINPitchEstimator implements PitchEstimator {
  /// 绝对阈值（V2 硬指标：0.10）。
  static const double absoluteThreshold = 0.10;

  /// 最小音高赫兹（任务硬约束：100.0Hz = 低于 G3 弦，不属于尤克里里频域）。
  static const double minFrequencyHz = 100.0;

  /// 最大音高赫兹（任务硬约束：1200.0Hz = 高于 A6，剔除高频泛音噪声）。
  static const double maxFrequencyHz = 1200.0;

  /// 静音 RMS 门槛（低于此值视为静音帧）。
  /// V2 阈值与 confidence 0.6 挂钩：典型 -40dBFS 对应 RMS ≈ 200（Int16 满量程 32767）。
  static const double silenceRmsThreshold = 200.0;

  /// 谐波判定：2nd harmonic 与 fundamental 能量比上限（≥ 0.85 且 conf < 0.6 → 泛音）。
  static const double harmonicRatioLimit = 0.85;

  final int _sampleRate;
  final int _frameSize;

  YINPitchEstimator({
    int sampleRate = 44100,
    int frameSize = 2048,
  })  : _sampleRate = sampleRate,
        _frameSize = frameSize;

  @override
  PitchResult estimate(PcmFrame frame) {
    // ── 0. 防御：样本长度不匹配 → 静音返回 ────────────────
    if (frame.samples.length < _frameSize) {
      return _silent();
    }
    if (frame.sampleRate != _sampleRate) {
      return _silent();
    }

    // ── 0.1 RMS 静音检测 ───────────────────────────────────
    final rms = _computeRms(frame.samples);
    if (rms < silenceRmsThreshold) {
      return _silent();
    }

    // ── 1. 自相关差分函数 d(tau) ──────────────────────────
    final yinBuffer = _difference(frame.samples);

    // ── 2. 累积平均差分函数 D(tau) ───────────────────────
    _cumulativeMeanNormalizedDifference(yinBuffer);

    // ── 3. 绝对阈值检索 ──────────────────────────────────
    final tauEstimate = _absoluteThreshold(yinBuffer);
    if (tauEstimate == -1) {
      return _silent();
    }

    // ── 4. 抛物线插值提升精度 ─────────────────────────────
    final tauRefined = _parabolicInterpolation(yinBuffer, tauEstimate);
    if (tauRefined <= 0) {
      return _silent();
    }

    final frequencyHz = _sampleRate / tauRefined;

    // ── 5. 范围守卫（V2 硬指标：100~1200Hz）─────────────
    if (frequencyHz < minFrequencyHz || frequencyHz > maxFrequencyHz) {
      return _silent();
    }

    // ── 6. confidence = 1 - D(tau) ───────────────────────
    final tauIndex = tauRefined.round().clamp(0, yinBuffer.length - 1);
    final dAtTau = yinBuffer[tauIndex];
    final rawConfidence = (1.0 - dAtTau).clamp(0.0, 1.0);

    // 谐波异常检测
    if (rawConfidence < StandardTuning.minConfidence) {
      if (_isHarmonicAnomaly(frame.samples, frequencyHz)) {
        return _silent();
      }
    }

    // ── 7. 重建 cents / nearestString ────────────────────
    final nearest = StandardTuning.nearestString(frequencyHz) ?? '?';
    final cents = nearest == '?'
        ? 0.0
        : StandardTuning.centsOffset(frequencyHz, nearest);

    return PitchResult(
      frequencyHz: frequencyHz,
      confidence: rawConfidence,
      centsOffset: cents,
      nearestString: nearest,
    );
  }

  // ─────────── YIN 子算法（纯函数）────────────────────────

  /// 步骤 1：自相关差分函数 d(tau)。
  /// d(tau) = Σ_{j=0..W-1} (x[j] - x[j+tau])^2
  Float64List _difference(Int16List samples) {
    final halfSize = _frameSize ~/ 2;
    final out = Float64List(halfSize);
    for (var tau = 1; tau < halfSize; tau++) {
      double sum = 0.0;
      for (var j = 0; j < halfSize; j++) {
        final delta = (samples[j] - samples[j + tau]).toDouble();
        sum += delta * delta;
      }
      out[tau] = sum;
    }
    return out;
  }

  /// 步骤 2：累积平均差分函数 D(tau) = d(tau) / ((1/tau) * Σ_{j=1..tau} d(j))。
  /// in-place 修改 yinBuffer。
  void _cumulativeMeanNormalizedDifference(Float64List yin) {
    yin[0] = 1.0; // 惯例
    double runningSum = 0.0;
    for (var tau = 1; tau < yin.length; tau++) {
      runningSum += yin[tau];
      if (runningSum == 0.0) {
        // 防止除零：平坦噪声帧的 d(tau) 均为 0。
        yin[tau] = 1.0;
      } else {
        yin[tau] = yin[tau] * tau / runningSum;
      }
    }
  }

  /// 步骤 3：绝对阈值检索。返回首个 D(tau) < threshold 的 tau；找不到返回 -1。
  int _absoluteThreshold(Float64List yin) {
    // tau=0 处 D=1 必跳过；tau=1 起开始扫。
    for (var tau = 2; tau < yin.length; tau++) {
      if (yin[tau] < absoluteThreshold) {
        // 找到后继续找到局部最低点（防半周期误检）
        while (tau + 1 < yin.length && yin[tau + 1] < yin[tau]) {
          tau++;
        }
        return tau;
      }
    }
    return -1;
  }

  /// 步骤 4：抛物线插值。
  /// 在 tau 附近用三点 (yin[tau-1], yin[tau], yin[tau+1]) 拟合抛物线求极小点。
  double _parabolicInterpolation(Float64List yin, int tau) {
    if (tau <= 0 || tau >= yin.length - 1) {
      return tau.toDouble();
    }
    final s0 = yin[tau - 1];
    final s1 = yin[tau];
    final s2 = yin[tau + 1];
    final denom = (2.0 * s1) - s2 - s0;
    if (denom.abs() < 1e-12) {
      return tau.toDouble();
    }
    final adjustment = (s2 - s0) / (2.0 * denom);
    return tau + adjustment;
  }

  /// RMS（均方根）幅值。Int16 → double 转换。
  double _computeRms(Int16List samples) {
    double sumSq = 0.0;
    final n = math.min(samples.length, _frameSize);
    for (var i = 0; i < n; i++) {
      final v = samples[i].toDouble();
      sumSq += v * v;
    }
    return math.sqrt(sumSq / n);
  }

  /// 谐波异常检测：在 fundamental 与 2*fundamental 两个频段上分别计算
  /// 归一化累积平均差分 D(tau)，用归一化比值判定泛音。
  ///
  /// 实现：直接对原信号重跑一次 YIN 差分 + 累积平均，但只针对 [tauHarmonic, tauFundamental]
  /// 局部区段计算 D 值，避免重算整个 D(tau) 数组（O(W²) → O(W·range)）。
  bool _isHarmonicAnomaly(Int16List samples, double fundamentalHz) {
    if (fundamentalHz <= 0) return false;
    final tauFund = (_sampleRate / fundamentalHz).round();
    final tauHarm = (tauFund / 2.0).round();
    final halfSize = _frameSize ~/ 2;
    if (tauHarm < 2 || tauHarm >= halfSize - 1) return false;
    if (tauFund < 2 || tauFund >= halfSize - 1) return false;

    final dHarm = _differenceAtTau(samples, tauHarm);
    final dFund = _differenceAtTau(samples, tauFund);
    if (dFund <= 0) return false;

    // 归一化：除以 tau 的累积和近似 → 简单线性归一（无需重算完整 running sum）
    // 归一化差分 ≈ d(tau) * tau / runningSum[tau]
    // 用 [1..tau] 区间内的 running sum 估计。
    final runHarm = _localRunningSum(samples, tauHarm);
    final runFund = _localRunningSum(samples, tauFund);
    if (runHarm <= 0 || runFund <= 0) return false;
    final dNormHarm = (dHarm * tauHarm) / runHarm;
    final dNormFund = (dFund * tauFund) / runFund;
    if (dNormFund <= 0) return false;
    return dNormHarm / dNormFund >= harmonicRatioLimit;
  }

  double _differenceAtTau(Int16List samples, int tau) {
    final halfSize = _frameSize ~/ 2;
    double sum = 0.0;
    for (var j = 0; j < halfSize; j++) {
      final delta = (samples[j] - samples[j + tau]).toDouble();
      sum += delta * delta;
    }
    return sum;
  }

  /// 局部累积和：Σ_{j=1..tau} d(j)。用于谐波检测中归一化。
  double _localRunningSum(Int16List samples, int tau) {
    double sum = 0.0;
    for (var k = 1; k <= tau; k++) {
      sum += _differenceAtTau(samples, k);
    }
    return sum;
  }

  PitchResult _silent() {
    return const PitchResult(
      frequencyHz: -1.0,
      confidence: 0.0,
      centsOffset: 0.0,
      nearestString: '?',
    );
  }
}
