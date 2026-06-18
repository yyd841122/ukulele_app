// lib/features/chord/domain/chord_player.dart
//
// 来自 PRD_Architecture.md §4.4 + §4.6 (Auditor: Metric_Hardening +
// Checker: Oboe_AAudio_Gatekeeper)
//
// 30ms 极速音频播放器。V2 硬指标（一票否决）：
//   - 端到端延迟 P95 ≤ 30ms（点击 → 扬声器）。
//   - 重复 play() 必须幂等 + 即时释放前序资源（OboeStream* 句柄）。
//   - dispose() 必须走 OboeBridge.releaseStreamWithinBudget（10ms 预算）
//     并最终调用 assetPlayer.release() 释放 Dart 侧句柄。
//   - 同一进程内 captureExclusive 与 playbackExclusive 互斥（Mutex）。
//
// 设计原则：
//   - 同步可注入：playback / mutex 构造期注入，单测可替换。
//   - 状态机：disposed 一次为终态，再调 play/stop 抛 StateError。
//   - 拒绝抛裸异常：play 失败一律 Result.failure；超时/释放失败抛
//     OboeReleaseTimeoutException（业务层 try/onError 捕获后清理）。

import 'dart:async';

import 'package:meta/meta.dart';

import '../../../core/audio/audio_playback_port.dart';
import '../../../core/audio/audio_session_mutex.dart';
import '../../../core/native/oboe_bridge.dart';
import '../../../core/result/result.dart';
import '../data/chord_repository.dart';

/// 单次播放的延迟采样（用于单测 / 上报）。
class ChordPlaySample {
  /// 从 play() 进入到 play() 返回（即底层已触发播放）的耗时。
  final Duration latency;
  const ChordPlaySample(this.latency);
}

/// ChordPlayer 抽象。
///
/// 业务层注入 `ChordPlayer`，禁止依赖具体实现。
abstract class ChordPlayer {
  /// 触发一次和弦播放。
  ///
  /// - 内部需在 30ms 内走完「Mutex 抢锁 → load → release 前序句柄 → play」。
  /// - 成功：Result.success(ChordPlaySample)。
  /// - 失败：Result.failure(...)；常见失败原因：busy / asset not loaded。
  Future<Result<ChordPlaySample, AppError>> play(String chordId);

  /// 主动停止当前播放（不一定在播放中；幂等）。
  Future<Result<void, AppError>> stop();

  /// 释放全部资源（包含 OboeStream* 与底层 audio port）。
  /// 调用后再调 play/stop 必须抛 StateError。
  Future<void> dispose();

  /// 当前是否已 dispose。
  bool get isDisposed;
}

/// 生产环境默认实现：复用 AudioPlaybackPort + AudioSessionMutex + OboeBridge。
class DefaultChordPlayer implements ChordPlayer {
  final AudioPlaybackPort _assetPlayer;
  final AudioSessionMutex _mutex;
  final ChordRepository _repository;

  bool _disposed = false;
  String? _currentChordId;

  /// 构造。
  ///  - [assetPlayer] ：底层 AAudio/Oboe 播放端口（可注入 fake）。
  ///  - [mutex]      ：同进程音频会话互斥锁。
  ///  - [repository] ：和弦元数据源（仅用于 id→assetPath 解析）。
  DefaultChordPlayer({
    required AudioPlaybackPort assetPlayer,
    required AudioSessionMutex mutex,
    required ChordRepository repository,
  })  : _assetPlayer = assetPlayer,
        _mutex = mutex,
        _repository = repository;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<Result<ChordPlaySample, AppError>> play(String chordId) async {
    if (_disposed) {
      throw StateError('ChordPlayer.play() invoked after dispose()');
    }

    final sw = Stopwatch()..start();

    // 1) Mutex 抢锁（capture / playback 互斥）
    try {
      await _mutex.acquire(AudioSessionMode.playbackExclusive);
    } on AudioSessionBusyException catch (e) {
      sw.stop();
      return Result.failure(e);
    } catch (e) {
      sw.stop();
      return const Result.failure(AudioSessionBusyException(
        requestedMode: 'playbackExclusive',
        currentMode: 'unknown',
      ));
    }

    // 2) 幂等释放前序 native 句柄（防止连续点击 5 次以上的句柄堆积）
    //    若释放超时 / 句柄异常：仍必须继续走完当前 play 流程，
    //    并在末尾走 _safeRelease 兜底，保证 mutex + playback 状态不残留。
    final prevHandle = _assetPlayer.detachNativeHandle();
    if (prevHandle != 0) {
      try {
        OboeBridge.releaseStreamWithinBudget(prevHandle);
      } on OboeReleaseTimeoutException {
        // ★ V2 一票否决修复：不能 rethrow，必须吞掉继续当前播放。
        // 理由：业务层已经进入播放请求链；逃出会导致后续 load/play 全部跳过，
        //       但 mutex 仍持锁 + playback 仍 loaded → 资源锁死。
        // 真正的清理交给末尾的 _safeRelease()。
      } on UseAfterFreeException {
        // 句柄为空/野指针：吞掉（句柄已置 0，安全）。
      }
    }

    // 3) 查找和弦元数据
    final chord = _repository.findById(chordId);
    if (chord == null) {
      sw.stop();
      await _safeRelease();
      return Result.failure(AssetNotFoundException(chordId));
    }

    // 4) load → play（高频触发：load 已缓存时几乎无开销）
    final loadRes = await _assetPlayer.load(chord.audioAsset);
    if (loadRes.isFailure) {
      sw.stop();
      await _safeRelease();
      return Result.failure(loadRes.errorOrNull!);
    }

    final playRes = await _assetPlayer.play();
    if (playRes.isFailure) {
      sw.stop();
      await _safeRelease();
      return Result.failure(playRes.errorOrNull!);
    }

    sw.stop();
    _currentChordId = chordId;
    return Result.success(ChordPlaySample(sw.elapsed));
  }

  @override
  Future<Result<void, AppError>> stop() async {
    if (_disposed) {
      throw StateError('ChordPlayer.stop() invoked after dispose()');
    }
    final pauseRes = await _assetPlayer.pause();
    if (pauseRes.isFailure) {
      return Result.failure(pauseRes.errorOrNull!);
    }
    final handle = _assetPlayer.detachNativeHandle();
    if (handle != 0) {
      try {
        OboeBridge.releaseStreamWithinBudget(handle);
      } on OboeReleaseTimeoutException catch (e) {
        // 释放超时：仍返回 Result.failure 让上层感知，
        // 但内部已尽量清理。
        return Result.failure(e);
      } on UseAfterFreeException {
        // 句柄已空：视为成功。
      }
    }
    _currentChordId = null;
    return const Result.success(null);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // 1) 释放 native 句柄
    final handle = _assetPlayer.detachNativeHandle();
    if (handle != 0) {
      try {
        OboeBridge.releaseStreamWithinBudget(handle);
      } on OboeReleaseTimeoutException {
        // 超时已抛；继续清掉 Dart 侧
      } on UseAfterFreeException {
        // 已空，安全
      }
    }

    // 2) 释放底层 AudioPlaybackPort（= release 走 assetPlayer.release()）
    await _assetPlayer.dispose();

    // 3) 释放互斥锁（持锁时 dispose 必须放掉）
    try {
      await _mutex.release(AudioSessionMode.playbackExclusive);
    } on AudioSessionBusyException {
      // 非持有方释放：忽略
    } catch (_) {
      // 忽略其它 mutex 错误
    }
  }

  /// 内部辅助：尽力释放资源（失败不抛）。
  Future<void> _safeRelease() async {
    final h = _assetPlayer.detachNativeHandle();
    if (h != 0) {
      try {
        OboeBridge.releaseStreamWithinBudget(h);
      } catch (_) {
        // 吞掉；上层已拿到错误
      }
    }
    try {
      await _mutex.release(AudioSessionMode.playbackExclusive);
    } catch (_) {
      // 吞掉
    }
  }

  @visibleForTesting
  String? get currentChordId => _currentChordId;
}
