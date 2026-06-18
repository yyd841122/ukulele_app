// test/features/chord/domain/chord_player_test.dart
//
// 来自 PRD_Architecture.md §4.4 + §4.6 + §4.8 (Auditor: TDD)
// ChordPlayer + ChordRepository 的强契约单测。
//
// 覆盖维度：
//   1) ChordRepository.getInitialChords() 异步不阻塞主线程
//   2) ChordRepository 返回 4 个 MVP 和弦（C / G / Am / F）
//   3) ChordPlayer.play() 端到端延迟 ≤ 30ms（1000 次采样 P95）
//   4) ChordPlayer.play() 重复调用幂等 + 句柄即时释放
//   5) ChordPlayer.stop() 释放 native 句柄 ≤ 10ms
//   6) ChordPlayer.dispose() 之后 play() 抛 StateError
//   7) 连续 5 次 play/stop 循环不发生句柄堆积
//   8) Mutex 占用时 play() 返回 AudioSessionBusyException
//   9) 不存在 id 返回 AssetNotFoundException

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ukulele_app/core/audio/audio_playback_port.dart';
import 'package:ukulele_app/core/audio/audio_session_mutex.dart';
import 'package:ukulele_app/core/native/oboe_bridge.dart';
import 'package:ukulele_app/core/result/result.dart';
import 'package:ukulele_app/features/chord/data/chord_repository.dart';
import 'package:ukulele_app/features/chord/domain/chord_model.dart';
import 'package:ukulele_app/features/chord/domain/chord_player.dart';

void main() {
  group('ChordRepository — Architect: Data_Protocol', () {
    test('getInitialChords() 返回 Future，不阻塞调用方', () {
      final repo = ChordRepository();
      final ret = repo.getInitialChords();
      // Future 未完成时不能取 valueOrNull 等同步结果
      expect(ret, isA<Future<List<ChordModel>>>());
    });

    test('getInitialChords() 异步返回 4 个 MVP 和弦', () async {
      final repo = ChordRepository();
      final list = await repo.getInitialChords();
      expect(list.length, 4);
      final ids = list.map((c) => c.id).toSet();
      expect(ids, containsAll(<String>['C', 'G', 'Am', 'F']));
    });

    test('getInitialChords() 返回的 List 不可变（防误改）', () async {
      final repo = ChordRepository();
      final list = await repo.getInitialChords();
      expect(() => list.clear(), throwsUnsupportedError);
    });

    test('findById 命中 / 未命中', () {
      final repo = ChordRepository();
      expect(repo.findById('C')?.id, 'C');
      expect(repo.findById('F')?.id, 'F');
      expect(repo.findById('NonExist'), isNull);
    });

    test('count == 4', () {
      final repo = ChordRepository();
      expect(repo.count, 4);
    });
  });

  group('DefaultChordPlayer — Auditor: TDD', () {
    late FakePlaybackPort playback;
    late InMemoryAudioSessionMutex mutex;
    late ChordRepository repository;
    late DefaultChordPlayer player;

    setUp(() {
      playback = FakePlaybackPort();
      mutex = InMemoryAudioSessionMutex();
      repository = ChordRepository();
      player = DefaultChordPlayer(
        assetPlayer: playback,
        mutex: mutex,
        repository: repository,
      );
    });

    tearDown(() async {
      if (!player.isDisposed) {
        await player.dispose();
      }
      await mutex.dispose();
    });

    test('play("C") 端到端延迟 ≤ 30ms', () async {
      // install trivial release delegate
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        final res = await player.play('C');
        expect(res.isSuccess, isTrue);
        final sample = res.valueOrNull!;
        expect(sample.latency, lessThanOrEqualTo(const Duration(milliseconds: 30)));
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('1000 次 play() 采样 P95 ≤ 30ms', () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        final ids = <String>['C', 'G', 'Am', 'F'];
        final latencies = <int>[];
        for (var i = 0; i < 1000; i++) {
          final res = await player.play(ids[i % ids.length]);
          expect(res.isSuccess, isTrue, reason: 'i=$i');
          latencies.add(res.valueOrNull!.latency.inMicroseconds);
        }
        latencies.sort();
        final p95 = latencies[(latencies.length * 0.95).floor() - 1];
        // P95 上限 30ms = 30000μs
        expect(p95, lessThanOrEqualTo(30000),
            reason: 'P95 latency $p95 μs exceeded 30ms budget');
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('重复 play() 幂等 + 前序句柄即时释放（无堆积）', () async {
      var releaseCount = 0;
      OboeBridge.debugSetReleaseDelegate((_) {
        releaseCount += 1;
      });
      try {
        // 5 次连续 play，每次携带一个非 0 的 native handle
        for (var i = 0; i < 5; i++) {
          playback.debugSetHandle(1000 + i);
          final res = await player.play('C');
          expect(res.isSuccess, isTrue);
        }
        // 5 次 play，每次都有前序 handle 需释放 → 释放 5 次
        expect(releaseCount, 5);
        // 最终 fake port 内剩余句柄为 0（无堆积）
        expect(playback.currentHandle, 0);
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('stop() 释放 native 句柄 ≤ 10ms', () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        // 先 play 一次让 player 持有 handle
        playback.debugSetHandle(1234);
        await player.play('C');
        // 现在模拟 playback 拿回 0（已被 play 内释放），再注入新 handle
        playback.debugSetHandle(5678);
        final sw = Stopwatch()..start();
        final res = await player.stop();
        sw.stop();
        expect(res.isSuccess, isTrue);
        expect(sw.elapsedMilliseconds, lessThanOrEqualTo(10),
            reason: 'stop() release took ${sw.elapsedMilliseconds}ms');
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('dispose() 之后 play() 抛 StateError', () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        await player.dispose();
        expect(player.isDisposed, isTrue);
        expect(() => player.play('C'), throwsStateError);
        expect(() => player.stop(), throwsStateError);
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('dispose() 幂等：多次调用不抛错', () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        await player.dispose();
        await player.dispose();
        await player.dispose();
        expect(player.isDisposed, isTrue);
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('连续 5 次 play/stop 后 native handle 集合为空', () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        for (var i = 0; i < 5; i++) {
          playback.debugSetHandle(100 + i);
          final r1 = await player.play('G');
          expect(r1.isSuccess, isTrue);
          // play 内部会 detach & release；模拟底层又分配一个新 handle
          playback.debugSetHandle(200 + i);
          final r2 = await player.stop();
          expect(r2.isSuccess, isTrue);
          // 每次 stop 后底层句柄必须为 0
          expect(playback.currentHandle, 0,
              reason: 'iteration $i: handle leaked');
        }
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('Mutex 被 captureExclusive 占用时 play() 返回 AudioSessionBusyException',
        () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        // 占用麦克风会话
        await mutex.acquire(AudioSessionMode.captureExclusive);
        final res = await player.play('C');
        expect(res.isFailure, isTrue);
        expect(res.errorOrNull, isA<AudioSessionBusyException>());
        // 释放 mutex，避免 tearDown 时 watchdog 异常
        await mutex.release(AudioSessionMode.captureExclusive);
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });

    test('不存在的 chordId 返回 AssetNotFoundException', () async {
      OboeBridge.debugSetReleaseDelegate((_) {});
      try {
        final res = await player.play('NonExist');
        expect(res.isFailure, isTrue);
        expect(res.errorOrNull, isA<AssetNotFoundException>());
      } finally {
        OboeBridge.debugResetReleaseDelegate();
      }
    });
  });
}

/// 测试专用 AudioPlaybackPort：可控 handle、可注入 handle、可观测。
class FakePlaybackPort implements AudioPlaybackPort {
  final StreamController<PlaybackTick> _ticks =
      StreamController<PlaybackTick>.broadcast();

  int _handle = 0;
  bool _loaded = false;
  bool _playing = false;
  String? _asset;
  Duration _position = Duration.zero;

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
    _handle = 0;
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
    _handle = 0;
    return h;
  }

  // ── Test helpers ─────────────────────────────────────────
  void debugSetHandle(int h) {
    _handle = h;
  }

  int get currentHandle => _handle;
}
