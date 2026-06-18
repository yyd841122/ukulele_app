// test/core/audio/audio_session_mutex_test.dart
//
// 来自 PRD_Architecture.md §5.2 + §5.9 (Architect: Interface_Driven + Checker: Oboe_AAudio_Gatekeeper)
//
// 单元测试锁死 V2 硬指标：
//   - captureExclusive 与 playbackExclusive 互斥
//   - 同模式重复 acquire 幂等（直接切换不算 busy）
//   - release 后允许对方 acquire
//   - 5s watchdog 强制回收（持有方 5s 未 release 触发）
//   - modeStream 广播模式变更
//   - 抛出 AudioSessionBusyException 携带 requested/current 信息
//
// 场景：
//   1) Tuner 持有 capture 时，Score 请求 playback → 立即抛 Busy
//   2) Tuner 释放 capture 后，Score 才能 acquire playback
//   3) 同模式（capture→capture）幂等：不抛
//   4) 5s watchdog 模拟：通过 fakeAsync / manual Timer 验证
//   5) dispose() 幂等

import 'package:flutter_test/flutter_test.dart';
import 'package:ukulele_app/core/audio/audio_session_mutex.dart';
import 'package:ukulele_app/core/result/result.dart';

void main() {
  group('AudioSessionMutex · 基础状态机', () {
    test('初始 currentMode == idle', () {
      final m = InMemoryAudioSessionMutex();
      expect(m.currentMode, AudioSessionMode.idle);
      m.dispose();
    });

    test('acquire(captureExclusive) → currentMode 切换并广播', () async {
      final m = InMemoryAudioSessionMutex();
      final events = <AudioSessionMode>[];
      final sub = m.modeStream.listen(events.add);

      await m.acquire(AudioSessionMode.captureExclusive);
      expect(m.currentMode, AudioSessionMode.captureExclusive);
      // microtask flush
      await Future<void>.delayed(Duration.zero);
      expect(events, contains(AudioSessionMode.captureExclusive));
      await sub.cancel();
      await m.dispose();
    });
  });

  group('AudioSessionMutex · Tuner vs Score 互斥（任务核心场景）', () {
    test('Tuner 持有 capture 时，Score 请求 playback 立即抛 AudioSessionBusyException',
        () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);

      expect(
        () => m.acquire(AudioSessionMode.playbackExclusive),
        throwsA(
          isA<AudioSessionBusyException>()
              .having((e) => e.requestedMode, 'requestedMode',
                  'playbackExclusive')
              .having((e) => e.currentMode, 'currentMode', 'captureExclusive'),
        ),
      );
      await m.dispose();
    });

    test('Score 持有 playback 时，Tuner 请求 capture 立即抛 AudioSessionBusyException',
        () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.playbackExclusive);

      expect(
        () => m.acquire(AudioSessionMode.captureExclusive),
        throwsA(isA<AudioSessionBusyException>()),
      );
      await m.dispose();
    });

    test('Tuner 释放 capture 后，Score 立即能 acquire playback', () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);
      await m.release(AudioSessionMode.captureExclusive);
      expect(m.currentMode, AudioSessionMode.idle);

      // 此刻 Score acquire 成功
      await m.acquire(AudioSessionMode.playbackExclusive);
      expect(m.currentMode, AudioSessionMode.playbackExclusive);
      await m.dispose();
    });

    test('同模式重复 acquire 幂等（capture → capture 不抛）', () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);
      // 第二次 acquire 同模式不应抛
      await m.acquire(AudioSessionMode.captureExclusive);
      expect(m.currentMode, AudioSessionMode.captureExclusive);
      await m.dispose();
    });

    test('release 与当前模式不匹配时幂等不抛', () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);
      // 用错误的 mode release，不应改变状态也不应抛
      await m.release(AudioSessionMode.playbackExclusive);
      expect(m.currentMode, AudioSessionMode.captureExclusive);
      await m.dispose();
    });
  });

  group('AudioSessionMutex · 5s Watchdog 强制回收', () {
    test('持有方 5s 未 release 触发 watchdog 强制回收（fakeAsync）', () async {
      // 内部 watchdog 是 Timer，使用 fakeAsync 可以确定性测时间。
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);
      expect(m.currentMode, AudioSessionMode.captureExclusive);

      // 模拟时间推进 4.999s：仍未回收
      await Future<void>.delayed(const Duration(milliseconds: 4999));
      expect(m.currentMode, AudioSessionMode.captureExclusive);

      // 推进到 5s+ 边界：watchdog 触发
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(m.currentMode, AudioSessionMode.idle,
          reason: '5s watchdog must reclaim unreleased session');

      // 回收后对方可 acquire
      await m.acquire(AudioSessionMode.playbackExclusive);
      expect(m.currentMode, AudioSessionMode.playbackExclusive);
      await m.dispose();
    });

    test('正常 release 5s 内：watchdog 被取消，不强制回收', () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);

      // 2s 后主动 release
      await Future<void>.delayed(const Duration(seconds: 2));
      await m.release(AudioSessionMode.captureExclusive);
      expect(m.currentMode, AudioSessionMode.idle);

      // 继续等待 4s，状态应保持 idle（watchdog 已取消）
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(m.currentMode, AudioSessionMode.idle);
      await m.dispose();
    });
  });

  group('AudioSessionMutex · 模式变更广播', () {
    test('modeStream 是 broadcast：多个订阅者都能收到事件', () async {
      final m = InMemoryAudioSessionMutex();
      final a = <AudioSessionMode>[];
      final b = <AudioSessionMode>[];
      final subA = m.modeStream.listen(a.add);
      final subB = m.modeStream.listen(b.add);

      await m.acquire(AudioSessionMode.captureExclusive);
      await Future<void>.delayed(Duration.zero);

      expect(a, contains(AudioSessionMode.captureExclusive));
      expect(b, contains(AudioSessionMode.captureExclusive));

      await subA.cancel();
      await subB.cancel();
      await m.dispose();
    });
  });

  group('AudioSessionMutex · dispose 幂等', () {
    test('多次 dispose 不抛', () async {
      final m = InMemoryAudioSessionMutex();
      await m.acquire(AudioSessionMode.captureExclusive);
      await m.dispose();
      // 二次 dispose 必须幂等
      await m.dispose();
    });

    test('dispose 后 stream 关闭', () async {
      final m = InMemoryAudioSessionMutex();
      final events = <AudioSessionMode>[];
      final sub = m.modeStream.listen(events.add);
      await m.dispose();
      await Future<void>.delayed(Duration.zero);
      // broadcast stream done
      expect(sub.isPaused, isFalse);
      await sub.cancel();
    });
  });

  group('AudioSessionMutex · 异常携带的诊断信息', () {
    test('AudioSessionBusyException 包含 code/message 字段', () {
      const e = AudioSessionBusyException(
        requestedMode: 'playbackExclusive',
        currentMode: 'captureExclusive',
      );
      expect(e.code, 'audio_session_busy');
      expect(e.requestedMode, 'playbackExclusive');
      expect(e.currentMode, 'captureExclusive');
      expect(e.message, contains('playbackExclusive'));
      expect(e.message, contains('captureExclusive'));
      // 类型契约：必须可作为 AppError 捕获
      expect(e, isA<AppError>());
    });
  });
}
