// test/features/tuner/median_pitch_filter_test.dart
//
// 来自 PRD_Architecture.md §3.4 + §3.8 (Auditor: Metric_Hardening)
//
// 单元测试锁死 V2 硬指标：
//   - 5 帧中位数窗口
//   - confidence < 0.6 直接丢弃
//   - 有效帧 < 3 时返回 null
//   - 中位数跳变 > 200 cents 时丢弃（瞬态噪声）
//   - 尤克里里共振场景：混入 G4/C4/E4/A4 泛音噪点 (conf<0.6) 必须被剔除
//
// 覆盖：
//   1) 入窗 confidence 门槛
//   2) 窗口未满（<3）时不发射
//   3) 满 3 帧开始发射
//   4) 5 帧中位数正确性
//   5) 200 cents 跳变丢弃
//   6) 共振泛音场景（混入低 conf 噪点后仍能稳定输出真基频）
//   7) reset() 后状态清空
//   8) frequencyHz <= 0 的非法帧不入窗

import 'package:flutter_test/flutter_test.dart';
import 'package:ukulele_app/features/tuner/data/standard_tuning.dart';
import 'package:ukulele_app/features/tuner/domain/median_pitch_filter.dart';

PitchResult _r(double hz, double conf, {String? nearest}) {
  final ns = nearest ?? StandardTuning.nearestString(hz) ?? '?';
  final cents = ns == '?' ? 0.0 : StandardTuning.centsOffset(hz, ns);
  return PitchResult(
    frequencyHz: hz,
    confidence: conf,
    centsOffset: cents,
    nearestString: ns,
  );
}

void main() {
  group('MedianPitchFilter · 硬指标门禁', () {
    test('A4 标准赫兹 440.00Hz（Auditor 卡死）', () {
      expect(StandardTuning.frequenciesHz['A4'], 440.00);
    });

    test('minConfidence 必须 == 0.6（V2 收紧）', () {
      expect(StandardTuning.minConfidence, 0.6);
    });

    test('windowSize 必须 == 5', () {
      expect(MedianPitchFilter.windowSize, 5);
    });

    test('maxJumpCents 必须 == 200.0', () {
      expect(MedianPitchFilter.maxJumpCents, 200.0);
    });

    test('minValidFramesToEmit 必须 == 3（任务硬约束）', () {
      expect(MedianPitchFilter.minValidFramesToEmit, 3);
    });
  });

  group('MedianPitchFilter · confidence 门槛', () {
    test('confidence < 0.6 的帧直接丢弃，不入窗', () {
      final f = MedianPitchFilter();
      // 连续 5 帧全部 < 0.6
      for (var i = 0; i < 5; i++) {
        final out = f.pushAndGet(_r(440.0, 0.3));
        expect(out, isNull, reason: 'frame $i conf=0.3 must be dropped');
      }
      expect(f.validFrameCount, 0);
    });

    test('confidence == 0.6 边界值：算有效（>= 门槛）', () {
      final f = MedianPitchFilter();
      f.pushAndGet(_r(440.0, 0.6));
      f.pushAndGet(_r(440.0, 0.6));
      f.pushAndGet(_r(440.0, 0.6));
      // 3 帧后窗口已满足 minValidFramesToEmit
      final out = f.pushAndGet(_r(440.0, 0.6));
      // 此时窗口长度 4，>= 3，输出中位数
      expect(out, isNotNull);
      expect(out!.frequencyHz, closeTo(440.0, 0.01));
    });

    test('frequencyHz <= 0 的非法帧不入窗', () {
      final f = MedianPitchFilter();
      expect(f.pushAndGet(_r(0.0, 0.9)), isNull);
      expect(f.pushAndGet(_r(-1.0, 0.9)), isNull);
      expect(f.validFrameCount, 0);
    });
  });

  group('MedianPitchFilter · 窗口未满时不发射', () {
    test('窗口内有效帧 < 3 时永远返回 null', () {
      final f = MedianPitchFilter();
      expect(f.pushAndGet(_r(440.0, 0.9)), isNull); // 1
      expect(f.pushAndGet(_r(440.0, 0.9)), isNull); // 2
    });

    test('窗口达到 3 帧时立即发射中位数', () {
      final f = MedianPitchFilter();
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      final out = f.pushAndGet(_r(440.0, 0.9));
      expect(out, isNotNull);
      expect(out!.frequencyHz, closeTo(440.0, 0.01));
    });
  });

  group('MedianPitchFilter · 5 帧中位数正确性', () {
    test('5 帧输入 [438, 439, 440, 441, 442] → 中位数 440.0', () {
      final f = MedianPitchFilter();
      f.pushAndGet(_r(438.0, 0.9));
      f.pushAndGet(_r(439.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(441.0, 0.9));
      final out = f.pushAndGet(_r(442.0, 0.9));
      expect(out, isNotNull);
      expect(out!.frequencyHz, closeTo(440.0, 0.01));
    });

    test('5 帧输入 [440, 440, 440, 440, 880] → 中位数 440.0（剔除八度漂移）', () {
      final f = MedianPitchFilter();
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      final out = f.pushAndGet(_r(880.0, 0.9)); // 八度噪声
      expect(out!.frequencyHz, closeTo(440.0, 0.01));
    });

    test('FIFO 窗口：第 6 帧进入时第 1 帧自动出窗', () {
      final f = MedianPitchFilter();
      // 5 帧 [438, 439, 440, 441, 442]
      f.pushAndGet(_r(438.0, 0.9));
      f.pushAndGet(_r(439.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(441.0, 0.9));
      f.pushAndGet(_r(442.0, 0.9));
      // 第 6 帧 460.0 进入 → 窗口 [439, 440, 441, 442, 460]
      final out = f.pushAndGet(_r(460.0, 0.9));
      // 中位数 441.0
      expect(out!.frequencyHz, closeTo(441.0, 0.01));
    });
  });

  group('MedianPitchFilter · 200 cents 跳变丢弃', () {
    test('中位数相对上次发射跳变 > 200 cents → 丢弃', () {
      final f = MedianPitchFilter();
      // 稳定在 440Hz 5 帧
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      final first = f.pushAndGet(_r(440.0, 0.9)); // 第 4 帧发射
      f.pushAndGet(_r(440.0, 0.9)); // 第 5 帧发射
      expect(first, isNotNull);

      // 突然跳到 ~660Hz（A5，约 700 cents 跳变）
      f.pushAndGet(_r(660.0, 0.9));
      f.pushAndGet(_r(660.0, 0.9));
      f.pushAndGet(_r(660.0, 0.9));
      f.pushAndGet(_r(660.0, 0.9));
      final spike = f.pushAndGet(_r(660.0, 0.9));
      // 跳变过大，被丢弃
      expect(spike, isNull, reason: '>200 cents jump must be dropped as transient noise');
    });
  });

  group('MedianPitchFilter · 尤克里里共振泛音场景（任务核心场景）', () {
    test(
        '扫弦 A4 真实基频 + 混入 G4/C4/E4 八度/五度泛音噪点 (conf<0.6) → 输出稳定在 440.0Hz',
        () {
      final f = MedianPitchFilter();
      // 模拟尤克里里扫弦 A4：真实基频 ~440Hz，
      // 同时 G4/C4/E4 弦的 2nd/3rd harmonic 也会被麦克风拾取。
      // 谐波能量较弱 → 置信度 < 0.6 → 必须被剔除。
      final rawSequence = <PitchResult>[
        _r(440.0, 0.92), // 真基频
        _r(784.0, 0.30), // G4 二次谐波（噪声）
        _r(440.0, 0.88), // 真基频
        _r(880.0, 0.25), // A4 八度（泛音）
        _r(440.0, 0.95), // 真基频
        _r(523.26, 0.35), // C5 泛音（噪声）
        _r(440.0, 0.90), // 真基频
        _r(659.26, 0.40), // E5 泛音（噪声）
        _r(440.0, 0.93), // 真基频
      ];

      final emitted = <double>[];
      for (final r in rawSequence) {
        final out = f.pushAndGet(r);
        if (out != null) emitted.add(out.frequencyHz);
      }

      // 至少要发射 1 次
      expect(emitted, isNotEmpty);
      // 所有发射值都必须接近 440.0（不允许被泛音带偏）
      for (final hz in emitted) {
        expect(hz, closeTo(440.0, 1.0),
            reason: 'median must stay on A4 fundamental; got $hz');
      }
    });

    test('从 E4 换到 A4 真实过渡：499 cents 跳变超出 maxJumpCents → 被丢弃', () {
      final f = MedianPitchFilter();
      // 前 5 帧：E4
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));
      final e4 = f.pushAndGet(_r(329.63, 0.9));
      expect(e4!.frequencyHz, closeTo(329.63, 0.01));

      // 切到 A4：cents 跳变约 499 > 200 cents → 触发噪声尖峰丢弃
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      final a4 = f.pushAndGet(_r(440.0, 0.9));
      expect(a4, isNull,
          reason: 'E4→A4 is ~499 cents jump (>200), must be discarded as transient');
    });

    test('缓慢滑动换弦（每帧 50 cents 增量）：通过跳变检查', () {
      final f = MedianPitchFilter();
      // 起始 329.63Hz（E4）
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));
      f.pushAndGet(_r(329.63, 0.9));

      // 每次 +10Hz（~50 cents 跳变）连续 5 次
      final outputs = <double>[];
      var hz = 329.63;
      for (var i = 0; i < 5; i++) {
        hz += 10.0;
        final out = f.pushAndGet(_r(hz, 0.9));
        if (out != null) outputs.add(out.frequencyHz);
      }
      // 滑动场景每次跳变 < 200 cents，应至少有发射
      expect(outputs, isNotEmpty);
      // 5 次增量后窗口 = [339.63, 349.63, 359.63, 369.63, 379.63]
      // 中位数 = 359.63
      expect(outputs.last, closeTo(359.63, 1.0));
    });
  });

  group('MedianPitchFilter · reset() 生命周期', () {
    test('reset() 后窗口清空、_lastEmittedHz 清空', () {
      final f = MedianPitchFilter();
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      f.pushAndGet(_r(440.0, 0.9));
      expect(f.validFrameCount, 5);
      expect(f.lastEmittedHz, isNotNull);

      f.reset();
      expect(f.validFrameCount, 0);
      expect(f.lastEmittedHz, isNull);

      // reset 后重新走窗口未满分支
      expect(f.pushAndGet(_r(440.0, 0.9)), isNull);
    });
  });
}
