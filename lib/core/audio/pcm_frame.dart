// lib/core/audio/pcm_frame.dart
//
// 来自 PRD_Architecture.md §3.2 (Architect: Interface_Driven)
//
// 一帧 PCM 数据单元。V2 硬约束：
//   - samples 长度固定 2048（约 46.4ms @44100Hz）
//   - sampleRate 固定 44100
//   - 构造函数 assert 任何偏差都将被单元测试捕获
//
// 该类为纯数据载体，禁止在该类中实现任何业务逻辑。

import 'dart:typed_data';

import 'package:meta/meta.dart';

@immutable
class PcmFrame {
  /// 固定 2048 个 Int16 样本（约 46.4ms @ 44100Hz）。
  final Int16List samples;

  /// 固定 44100 Hz。
  final int sampleRate;

  /// 帧被采集的本地时间戳，用于抖动监测（PCM 帧间隔应在 46ms 附近）。
  final DateTime capturedAt;

  const PcmFrame({
    required this.samples,
    required this.sampleRate,
    required this.capturedAt,
  })  : assert(samples.length == 2048, 'PcmFrame.samples.length must be 2048'),
        assert(sampleRate == 44100, 'PcmFrame.sampleRate must be 44100');

  /// 设计帧大小（PRD 硬指标）。
  static const int kFrameSize = 2048;

  /// 设计采样率（PRD 硬指标）。
  static const int kSampleRate = 44100;
}
