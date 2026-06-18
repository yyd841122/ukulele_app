// lib/core/di/service_locator.dart
//
// 来自 PRD_Architecture.md §6.1（Architect: Interface_Driven — 拒绝硬编码）
//
// 依赖注入容器。所有抽象接口在这里完成"接口 → 实现"的绑定，
// 业务层禁止任何位置出现具体实现类的硬编码。
//
// 提供三套注册入口：
//   - registerDependencies()        ：生产环境（Android FFI / AAudio）
//   - registerTestDependencies()    ：单元测试 / Widget 测试（注入 Fake）
//   - resetServiceLocator()         ：测试隔离清理
//
// Phase 4 升级点：
//   - AudioCapturePort      ：AndroidAAudioCapture（生产）替代 NoopAudioCapture
//   - AudioPlaybackPort     ：AndroidAAudioPlayback（生产）替代 NoopAudioPlayback
//   - AudioClock            ：新增（注入 playback + mutex）
//   - OboeFfiBridge         ：静态类，自动在 Android 平台加载 .so
//   - AndroidAudioBridge    ：可选注入（当 FFI 不可用时走 MethodChannel 兜底）
//
// 注意：registerTestDependencies() 仍走 Noop/Fake 实现，保证单测与 CI 不依赖 .so。

import 'package:get_it/get_it.dart';

import '../../features/chord/data/chord_repository.dart';
import '../../features/chord/domain/chord_player.dart';
import '../audio/android_aaudio_ports.dart';
import '../audio/audio_capture_port.dart';
import '../audio/audio_clock.dart';
import '../audio/audio_playback_port.dart';
import '../audio/audio_session_mutex.dart';
import '../native/android_audio_bridge.dart';

/// 全局 GetIt 实例。业务层通过 `sl<T>()` 取依赖，禁止使用具体实现类型。
final GetIt sl = GetIt.instance;

/// 是否已注册（防重复注册）。
bool _registered = false;

/// 是否已注册生产 Android FFI 端口。
bool _productionAudioRegistered = false;

/// 生产环境注册：Android FFI / AAudio 端口 + AudioClock。
void registerDependencies({
  AndroidAudioBridge? audioBridge,
}) {
  if (_registered) return;

  // ── 核心音频会话互斥锁（生产）─────────────────────────────
  sl.registerLazySingleton<AudioSessionMutex>(InMemoryAudioSessionMutex.new);

  // ── AndroidAudioBridge（可选；用于 MethodChannel 兜底）─────
  if (audioBridge != null) {
    sl.registerLazySingleton<AndroidAudioBridge>(() => audioBridge);
  }

  // ── 麦克风采集（生产：AndroidAAudioCapture）───────────────
  sl.registerLazySingleton<AudioCapturePort>(
    () => AndroidAAudioCapture(
      mutex: sl<AudioSessionMutex>(),
      bridge: sl.isRegistered<AndroidAudioBridge>()
          ? sl<AndroidAudioBridge>()
          : null,
    ),
  );

  // ── 音频播放（生产：AndroidAAudioPlayback）─────────────────
  sl.registerLazySingleton<AudioPlaybackPort>(
    () => AndroidAAudioPlayback(mutex: sl<AudioSessionMutex>()),
  );

  // ── 全局统一音频时钟（PRD §5.3）───────────────────────────
  sl.registerLazySingleton<AudioClock>(
    () => AudioClock(sl<AudioPlaybackPort>()),
  );

  // ── Chord 模块数据源 + 播放器 ─────────────────────────────
  sl.registerLazySingleton<ChordRepository>(ChordRepository.new);
  sl.registerLazySingleton<ChordPlayer>(
    () => DefaultChordPlayer(
      assetPlayer: sl<AudioPlaybackPort>(),
      mutex: sl<AudioSessionMutex>(),
      repository: sl<ChordRepository>(),
    ),
  );

  // 确保 OboeBridge 默认释放委托已就绪（占位实现）。
  // 注：debugResetReleaseDelegate 标记 @visibleForTesting，
  //    在 service_locator 中通过 @visibleForTesting 反射调用，
  //    或在 dev 入口（main.dart）由测试 runner 调用。
  //    此处改为注释；测试 setUp 由测试代码自行 reset。
  // OboeBridge.debugResetReleaseDelegate();

  _registered = true;
  _productionAudioRegistered = true;
}

/// 测试环境注册：所有依赖替换为可注入的 Fake，单元测试可重新注册。
///
/// 调用方可通过可选参数注入 fake/mock 端口；不传则用 Noop 实现兜底。
void registerTestDependencies({
  AudioSessionMutex? sessionMutex,
  AudioCapturePort? capture,
  AudioPlaybackPort? playback,
  AudioClock? clock,
}) {
  resetServiceLocator();
  sl.registerLazySingleton<AudioSessionMutex>(
    () => sessionMutex ?? InMemoryAudioSessionMutex(),
  );
  sl.registerLazySingleton<AudioCapturePort>(
    () => capture ?? NoopAudioCapture(),
  );
  sl.registerLazySingleton<AudioPlaybackPort>(
    () => playback ?? NoopAudioPlayback(),
  );
  sl.registerLazySingleton<AudioClock>(
    () => clock ?? AudioClock(sl<AudioPlaybackPort>()),
  );
  sl.registerLazySingleton<ChordRepository>(ChordRepository.new);
  sl.registerLazySingleton<ChordPlayer>(
    () => DefaultChordPlayer(
      assetPlayer: sl<AudioPlaybackPort>(),
      mutex: sl<AudioSessionMutex>(),
      repository: sl<ChordRepository>(),
    ),
  );
  _registered = true;
  _productionAudioRegistered = false;
}

/// 测试隔离清理。每个测试 setUp / tearDown 必须调用。
Future<void> resetServiceLocator() async {
  if (sl.isRegistered<AudioSessionMutex>()) {
    await sl<AudioSessionMutex>().dispose();
  }
  if (sl.isRegistered<AudioCapturePort>()) {
    final c = sl<AudioCapturePort>();
    if (c is NoopAudioCapture) await c.dispose();
    if (c is AndroidAAudioCapture) await c.dispose();
  }
  if (sl.isRegistered<AudioPlaybackPort>()) {
    final p = sl<AudioPlaybackPort>();
    if (p is NoopAudioPlayback) await p.close();
    if (p is AndroidAAudioPlayback) await p.dispose();
  }
  if (sl.isRegistered<AudioClock>()) {
    await sl<AudioClock>().dispose();
  }
  if (sl.isRegistered<ChordPlayer>()) {
    await sl<ChordPlayer>().dispose();
  }
  await sl.reset();
  _registered = false;
  _productionAudioRegistered = false;
}

/// 当前是否已注册生产 Android FFI 实现（供启动期检查）。
bool get isProductionAudioRegistered => _productionAudioRegistered;