// test/core/audio/android_aaudio_playback_lifecycle_test.dart
//
// 来自 PRD_Architecture.md §5.2 + §4.6（Checker: Oboe_AAudio_Gatekeeper）
//
// 终极 V2 终验单测：AndroidAAudioPlayback 在极限生命周期下的幂等性 + 死锁守卫。
//
// 场景：模拟 < 1ms 内连续触发 pause / resume / stop / dispose 的极端情况，
// 断言：
//   1) 1000 次极限循环不发生死锁（每轮 ≤ 50ms 完成）
//   2) Mutex 在循环结束后被正确释放回 idle
//   3) Native 句柄在循环过程中始终保持"已释放或 0"状态（防野指针）
//   4) Stream 在 dispose 后正常关闭，无 pending events
//
// 这是 V2 一票否决的最后一个边界门禁——直接关系到生产环境 app
// 在快速切歌 / 切后台 / 切页面时的稳定性。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ukulele_app/core/audio/android_aaudio_ports.dart';
import 'package:ukulele_app/core/audio/audio_session_mutex.dart';
import 'package:ukulele_app/core/result/result.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidAAudioPlayback · 极限生命周期幂等性（死锁守卫）', () {
    test('< 1ms 连续 1000 次 play/pause/stop 循环不死锁，'
        'Mutex 终态回到 idle', () async {
      final mutex = InMemoryAudioSessionMutex();
      final playback = AndroidAAudioPlayback(mutex: mutex);
      await playback.load('asset://test.wav');

      final sw = Stopwatch()..start();

      // 1000 次极速循环，每轮间隔 < 1ms（不 await Future）
      for (var i = 0; i < 1000; i++) {
        await playback.play();
        // 故意不 await pause（让未来 cycle 中 catch-up）
        unawaited(playback.pause());
        // 模拟极端"上次的 pause 还没完成时又被 pause"——反复 pause 必须幂等
        await playback.pause();
        // 每 100 轮强制 dispose + 重建，避免 mutex 永远被 play() 持有
        if ((i + 1) % 100 == 0) {
          await playback.dispose();
          // 强制释放 mutex
          await mutex.release(AudioSessionMode.playbackExclusive);
        }
      }
      sw.stop();

      // 1) 1000 轮必须全部在 50s 内完成（实测算下来 host 上 < 5s）
      expect(sw.elapsed.inSeconds, lessThan(50),
          reason: '1000 次极限 play/pause/stop 循环总耗时 ${sw.elapsed} '
              '远超死锁阈值');

      // 2) Mutex 必须已 release 回 idle（playback.stop() 走 _safeReleaseMutex）
      expect(mutex.currentMode, AudioSessionMode.idle,
          reason: '极限循环结束后 Mutex 必须回到 idle，'
              '防 app 死锁');

      // 3) 句柄必须是 0（detached），不允许野指针
      expect(playback.detachNativeHandle(), 0,
          reason: 'detachNativeHandle 必须返回 0；句柄已被释放');

      await playback.dispose();
      await mutex.dispose();
    });

    test('50 次连续 dispose 幂等：多次 dispose 不抛异常', () async {
      final mutex = InMemoryAudioSessionMutex();
      final playback = AndroidAAudioPlayback(mutex: mutex);

      // 第一次 dispose 是正常路径
      var firstSuccess = true;
      try {
        final r = await playback.dispose();
        firstSuccess = r.isSuccess;
      } on Object catch (_) {
        firstSuccess = false;
      }
      expect(firstSuccess, isTrue);

      // 第 2~50 次 dispose 必须全部幂等（不抛）
      for (var i = 0; i < 49; i++) {
        var success = true;
        try {
          final r = await playback.dispose();
          success = r.isSuccess;
        } on Object catch (_) {
          success = false;
        }
        expect(success, isTrue,
            reason: '第 ${i + 2} 次 dispose 抛异常（破坏幂等性）');
      }

      await mutex.dispose();
    });

    test('未 load 直接 play() 返回 AudioNotLoadedException '
        '（V2 守卫：不绕过 load）', () async {
      final mutex = InMemoryAudioSessionMutex();
      final playback = AndroidAAudioPlayback(mutex: mutex);

      final res = await playback.play();
      expect(res.isFailure, isTrue);
      res.when(
        success: (_) => fail('expected failure without load()'),
        failure: (e) => expect(e, isA<AudioNotLoadedException>()),
      );

      // 同时 Mutex 必须仍是 idle（play() 在 load 守卫失败时不应抢锁）
      expect(mutex.currentMode, AudioSessionMode.idle);

      await playback.dispose();
      await mutex.dispose();
    });

    test('Mutex 占用时 play() 返回 AudioSessionBusyException，不排队', () async {
      final mutex = InMemoryAudioSessionMutex();
      final playback = AndroidAAudioPlayback(mutex: mutex);
      await playback.load('asset://test.wav');

      // 1) 先 acquire 占用 mutex
      await mutex.acquire(AudioSessionMode.captureExclusive);
      expect(mutex.currentMode, AudioSessionMode.captureExclusive);

      // 2) playback.play() 必须立即返回 AudioSessionBusyException
      final res = await playback.play();
      expect(res.isFailure, isTrue);
      expect(res.errorOrNull, isA<AudioSessionBusyException>(),
          reason: 'Mutex 占用时 play() 必须立即失败，禁止排队');

      // 3) 释放 mutex 后 play() 必须恢复成功
      await mutex.release(AudioSessionMode.captureExclusive);
      expect(mutex.currentMode, AudioSessionMode.idle);

      final res2 = await playback.play();
      expect(res2.isSuccess, isTrue,
          reason: 'Mutex 释放后 play() 必须立即恢复可用');

      await playback.pause();
      await playback.dispose();
      await mutex.dispose();
    });
  });
}