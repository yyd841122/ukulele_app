// lib/core/di/service_locator.dart
//
// 来自 PRD_Architecture.md §6.1（Architect: Interface_Driven — 拒绝硬编码）
//
// 依赖注入容器。所有抽象接口在这里完成"接口 → 实现"的绑定，
// 业务层禁止任何位置出现具体实现类的硬编码。
//
// 提供三套注册入口：
//   - registerDependencies()  ：生产环境（Android AAudio）
//   - registerTestDependencies()：单元测试 / Widget 测试
//   - resetServiceLocator()   ：测试隔离清理
//
// 注意：以下仅完成"插槽预留"——AndroidAAudioCapture / AndroidAAudioPlayback
// 将在 Phase 2 中通过 MethodChannel 桥接 AAudio/Oboe 后实装。当前以 Noop 实现兜底，
// 保证主程序能跑通 build / analyze。

import 'package:get_it/get_it.dart';

import '../audio/audio_capture_port.dart';
import '../audio/audio_playback_port.dart';
import '../audio/audio_session_mutex.dart';

/// 全局 GetIt 实例。业务层通过 `sl<T>()` 取依赖，禁止使用具体实现类型。
final GetIt sl = GetIt.instance;

/// 是否已注册（防重复注册）。
bool _registered = false;

/// 生产环境注册。Phase 2 时将 NoopAudioCapture / NoopAudioPlayback
/// 替换为 AndroidAAudioCapture / AndroidAAudioPlayback 真实实现。
void registerDependencies() {
  if (_registered) return;
  // ── 核心音频会话互斥锁（生产）─────────────────────────────
  sl.registerLazySingleton<AudioSessionMutex>(InMemoryAudioSessionMutex.new);

  // ── 麦克风采集（Phase 2 替换为 AndroidAAudioCapture）────────
  sl.registerLazySingleton<AudioCapturePort>(NoopAudioCapture.new);

  // ── 音频播放（Phase 2 替换为 AndroidAAudioPlayback）─────────
  sl.registerLazySingleton<AudioPlaybackPort>(NoopAudioPlayback.new);

  _registered = true;
}

/// 测试环境注册：所有依赖替换为可注入的 Fake，单元测试可重新注册。
void registerTestDependencies({
  AudioSessionMutex? sessionMutex,
  AudioCapturePort? capture,
  AudioPlaybackPort? playback,
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
  _registered = true;
}

/// 测试隔离清理。每个测试 setUp / tearDown 必须调用。
Future<void> resetServiceLocator() async {
  if (sl.isRegistered<AudioSessionMutex>()) {
    await sl<AudioSessionMutex>().dispose();
  }
  if (sl.isRegistered<AudioCapturePort>()) {
    final c = sl<AudioCapturePort>();
    if (c is NoopAudioCapture) await c.dispose();
  }
  if (sl.isRegistered<AudioPlaybackPort>()) {
    final p = sl<AudioPlaybackPort>();
    if (p is NoopAudioPlayback) await p.close();
  }
  await sl.reset();
  _registered = false;
}
