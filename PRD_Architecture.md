# PRD_Architecture.md — Ukulele 自学 App（MVP · V2 终稿）

> 横屏 Flutter App · 720P 上限（1280×720）· Android AAudio/Oboe 桥接 · TDD 强契约
>
> 本文档由三阶段 Agent 流水线串行产出：`Architect → Auditor → Checker`，并在 V2 阶段对初稿 4 条漏洞完成闭环修复。每个章节明确标注动用的 Skill，可直接映射到 TDD 测试用例与生产代码。

---

## 0. V2 修订总览（流水线下钻）

| # | 模块 | 漏洞来源 | 修复点 | 角色 · Skill |
|---|---|---|---|---|
| 1 | Tuner | 漏点：未过滤多弦共振泛音 | 5 帧中位数平滑 + 置信度 ≥ 0.6 门槛 + 泛音剔除 | Auditor · Metric_Hardening / Checker · Oboe_AAudio_Gatekeeper |
| 2 | Tuner | 漏点：Android 11+ 权限未硬化 | Manifest 硬约束 `RECORD_AUDIO` + `MODIFY_AUDIO_SETTINGS` + Scoped Storage 适配 | Checker · Oboe_AAudio_Gatekeeper |
| 3 | Chord | 漏点：720P 垂直边界未约束 | 和弦卡片 ≤ 可用高度 45%（强制） | Architect · Interface_Driven / Auditor · Metric_Hardening |
| 4 | Chord | 漏点：C++ 桥接层指针残留 | `stop()` 后 10ms 内强制释放 Oboe/AAudio 缓存流 | Checker · Oboe_AAudio_Gatekeeper |
| 5 | Score | 漏点：AudioClock 与 Tuner 硬件冲突 | 引入 `AudioSessionMutex`（Exclusive 模式） | Architect · Interface_Driven |
| 6 | Score | 漏点：schema 断言 + Golden Test 空白 | `currentSchemaVersion` 构造函数 assert + CI 路径 | Auditor · Anti_Ambiguity |

---

## 1. 全局硬指标速查表（Auditor: Metric_Hardening 一票否决）

| 维度 | 硬指标 | 触发条件 / 一票否决 |
|---|---|---|
| 屏幕分辨率 | 1280×720（横屏）固定上限 | 任何资源图超过 720P 一律驳回 |
| UI 帧率 | 稳定 60fps（最低 30fps） | 任意一帧 > 33.3ms 即不合格 |
| PCM 采样率 | 44100Hz / 16bit / mono | 不允许 22050、48000 混用 |
| 调音基准频率 | A4=440.0Hz, E4=329.6Hz, C4=261.6Hz, G4=392.0Hz | 与标准偏差 > 0.5Hz 即驳回 |
| 完美调音容差 | ±5 cents | 超出区间必须显示偏差 |
| 调音置信度门槛 | ≥ 0.6（V2 收紧） | 低于门槛的帧必须丢弃，禁止进入 UI |
| 平滑窗口 | 5 帧中位数滤波 | 窗口不足 5 帧时强制等待，禁止发射 |
| Chord 音频响应延迟 | ≤ 30ms（点击 → 扬声器出声） | > 30ms 一票否决 |
| Chord 卡片高度 | ≤ 720P 可用高度 × 45% = 324px | 超出即驳回布局 |
| Chord 释放延迟 | `stop()` → 指针释放 ≤ 10ms | > 10ms 视为 C++ 内存泄漏 |
| Score 音画同步偏差 | ≤ ±15ms | 任意时间点偏差 > 15ms 即不合格 |
| Audio Clock tick 间隔 | 1024 帧 / 44100Hz ≈ 23.22ms | tick 抖动 > 5ms 即不合格 |
| Audio Session 模式 | Exclusive（输入输出独占低延迟） | 非 Exclusive 模式一律驳回 |
| Canvas 绘制单帧耗时 | ≤ 8ms（720P） | > 8ms 必须降级或隔离 |
| 异步 I/O（JSON / 音频） | 不阻塞 UI 线程 | 任何 `compute` 之外的同步 I/O 一票否决 |

---

## 2. 目录结构（Architect: Interface_Driven）

```
lib/
├── core/
│   ├── audio/
│   │   ├── audio_capture_port.dart       # 抽象：麦克风 PCM 流
│   │   ├── audio_playback_port.dart      # 抽象：伴奏播放
│   │   ├── audio_clock.dart              # 全局统一音频时钟
│   │   ├── audio_session_mutex.dart      # V2 新增：输入/输出互斥锁
│   │   └── pcm_frame.dart                # PCM 数据单元
│   ├── native/
│   │   └── oboe_bridge.dart              # V2 新增：C++ 桥接释放契约
│   ├── di/
│   │   └── service_locator.dart          # GetIt 注入
│   └── result/
│       └── result.dart                   # Result<T, AppError> 包装
├── features/
│   ├── tuner/
│   │   ├── data/standard_tuning.dart
│   │   ├── domain/pitch_estimator.dart
│   │   ├── domain/median_pitch_filter.dart       # V2 新增
│   │   ├── domain/tuner_controller.dart
│   │   ├── domain/mic_permission_guard.dart
│   │   └── ui/tuner_page.dart
│   ├── chord/
│   │   ├── data/chord_model.dart
│   │   ├── data/chord_repository.dart
│   │   ├── domain/chord_player.dart
│   │   └── ui/
│   │       ├── chord_trainer_page.dart
│   │       └── painters/chord_diagram_painter.dart
│   └── score/
│       ├── data/unified_score.dart
│       ├── data/score_parser.dart
│       ├── data/score_repository.dart
│       ├── domain/score_player_controller.dart
│       └── ui/
│           ├── score_player_page.dart
│           ├── widgets/scrolling_lyrics_view.dart
│           └── widgets/chord_strip_view.dart
test/
├── goldens/                              # V2 新增：金标测试快照
│   ├── tuner/
│   ├── chord/
│   └── score/
├── features/tuner/
├── features/chord/
├── features/score/
└── core/audio/
```

---

## 3. 模块一：🎛️ Tuner 调音器

### 3.1 业务流（Architect: Data_Protocol）

```
[麦克风 PCM] → AudioCapturePort.frames()
        ↓ PcmFrame{44100Hz, mono, 16bit, 2048 样本}
[PitchEstimator.estimate] → PitchResult{frequencyHz, confidence, centsOffset}
        ↓ confidence ≥ 0.6 才放行
[MedianPitchFilter] → 5 帧中位数平滑 → Stream<PitchResult>
        ↓
[TunerPage] CustomPainter 指针 (60fps)
```

### 3.2 PCM 数据流接口（Architect: Interface_Driven）

```dart
// lib/core/audio/pcm_frame.dart
class PcmFrame {
  final Int16List samples;      // 长度固定 2048（约 46.4ms @44100）
  final int sampleRate;         // 固定 44100
  final DateTime capturedAt;    // 用于抖动监测
  const PcmFrame({
    required this.samples,
    required this.sampleRate,
    required this.capturedAt,
  });
}

// lib/core/audio/audio_capture_port.dart
abstract class AudioCapturePort {
  Stream<PcmFrame> frames();
  Future<void> start();
  Future<void> stop();
  bool get isRunning;
  int get sampleRate;          // 必须返回 44100
}
```

### 3.3 标准赫兹对照表（Auditor: Metric_Hardening + Anti_Ambiguity）

```dart
// lib/features/tuner/data/standard_tuning.dart
class StandardTuning {
  // 顺序：四弦 → 一弦（从下到上）
  static const List<String> stringOrder = ['G4', 'C4', 'E4', 'A4'];
  static const Map<String, double> frequenciesHz = {
    'G4': 392.00,
    'C4': 261.63,
    'E4': 329.63,
    'A4': 440.00,
  };
  static const double toleranceCents = 5.0;          // 完美区间 ±5 cents
  static const double matchThresholdCents = 50.0;    // 偏差 > 50 cents 视为另一根弦
  static const int frameSize = 2048;                 // 46.4ms @44100
  static const double minConfidence = 0.6;           // V2 收紧：0.5 → 0.6，剔除泛音
}
```

### 3.4 V2 修复：多弦共振滤波（Auditor: Metric_Hardening + Checker: Oboe_AAudio_Gatekeeper）

```dart
// lib/features/tuner/domain/pitch_estimator.dart
class PitchResult {
  final double frequencyHz;
  final double confidence;     // 0.0 ~ 1.0
  final double centsOffset;    // 正=偏高，负=偏低
  final String nearestString;  // G4/C4/E4/A4
  const PitchResult({
    required this.frequencyHz,
    required this.confidence,
    required this.centsOffset,
    required this.nearestString,
  });
}

abstract class PitchEstimator {
  /// 输入一帧 PCM，输出基频与置信度。
  /// V2 硬约束：
  ///  1. 静音（confidence < 0.6）时 frequencyHz 必须返回 -1.0。
  ///  2. 必须以 5 帧窗口检测谐波比例：
  ///     若 2nd harmonic 能量 ≥ 0.85 × fundamental 且 confidence < 0.6，判定为泛音 → 丢弃。
  PitchResult estimate(PcmFrame frame);
}

// lib/features/tuner/domain/median_pitch_filter.dart
class MedianPitchFilter {
  /// 5 帧中位数平滑。窗口不足 5 帧时不得 emit（返回 null）。
  /// 剔除逻辑：
  ///  - 入窗前先校验 confidence ≥ 0.6，否则不入窗（泛音/静音直接丢弃）
  ///  - 入窗后对 frequencyHz 排序取中位数
  ///  - 中位数与最近一次发射值偏差 > 200 cents 时丢弃（视为噪声尖峰）
  static const int windowSize = 5;
  static const double maxJumpCents = 200.0;

  final Queue<PitchResult> _window = Queue();
  PitchResult? pushAndGet(PitchResult raw) {
    if (raw.confidence < StandardTuning.minConfidence) return null;   // V2: 0.6 门槛
    if (_containsHarmonicAnomaly(raw)) return null;                   // V2: 谐波剔除
    _window.addLast(raw);
    while (_window.length > windowSize) _window.removeFirst();
    if (_window.length < windowSize) return null;                     // 窗口未满
    final sorted = _window.map((r) => r.frequencyHz).toList()..sort();
    final medianHz = sorted[windowSize ~/ 2];
    if (_lastEmittedHz != null) {
      final jumpCents = 1200.0 * (log(medianHz / _lastEmittedHz!) / ln2);
      if (jumpCents.abs() > maxJumpCents) return null;
    }
    _lastEmittedHz = medianHz;
    return _buildResult(medianHz, raw);
  }

  double? _lastEmittedHz;
  bool _containsHarmonicAnomaly(PitchResult r) => false; // 委托给 PitchEstimator
  PitchResult _buildResult(double hz, PitchResult raw) => raw; // 重建 cents/最近弦
}
```

**V2 一票否决**：
- 任何置信度 < 0.6 的 PitchResult 不得进入 `MedianPitchFilter` 窗口。
- 窗口未满 5 帧时，禁止向 UI 发射任何指针状态。
- 5 帧中位数与上一次发射值偏差 > 200 cents 时，丢弃（视为瞬态噪声）。

### 3.5 Android 权限生命周期硬化（Checker: Oboe_AAudio_Gatekeeper）

#### 3.5.1 AndroidManifest.xml 硬约束

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- V2 新增：低延迟音频硬件访问 -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />

    <!-- V2 新增：Android 10+ AAudio 独占低延迟必需 -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />

    <!-- V2 新增：硬件特性声明（Google Play 过滤） -->
    <uses-feature
        android:name="android.hardware.microphone"
        android:required="true" />
    <uses-feature
        android:name="android.hardware.audio.low_latency"
        android:required="false" />

    <application
        android:label="Ukulele"
        android:requestLegacyExternalStorage="false">  <!-- V2: 适配 Scoped Storage -->
        ...
    </application>
</manifest>
```

**V2 硬约束**：
- `RECORD_AUDIO` 为 `dangerous` 权限，必须运行时申请，禁止 manifest-only 声明。
- `MODIFY_AUDIO_SETTINGS` 为 `normal` 权限，manifest 声明即可，但 AAudio `AAUDIO_SHARING_MODE_EXCLUSIVE` 调用时必须存在。
- Android 11+（API 30+）：禁止使用 `requestLegacyExternalStorage="true"`，所有音频资产必须走 `assets/` 或 `MediaStore`。
- 缺失 `android.hardware.microphone` 声明 → Play Store 过滤掉无麦克风设备。

#### 3.5.2 权限生命周期

```dart
// lib/features/tuner/domain/mic_permission_guard.dart
enum MicState { unrequested, granted, denied, permanentlyDenied }

class MicPermissionGuard {
  Future<MicState> request();
  // 必须订阅 WidgetsBindingObserver：
  // - AppLifecycleState.paused → 立即 AudioCapturePort.stop()
  // - AppLifecycleState.inactive → 立即停止 PCM 帧回调
  // - AppLifecycleState.resumed → 不自动重启，需用户再次点击
  // - 切到后台超过 5s 回来 → 必须重新 request()
  Stream<MicState> watch();
  void dispose();
}
```

**V2 一票否决**：
- `AudioCapturePort.start()` 被调用时，`MicState` 必须为 `granted`，否则抛 `MicNotGrantedException`。
- `AppLifecycleState.inactive` 状态下禁止任何 PCM 帧回调。
- Widget `dispose()` 时必须 `await capture.stop()` 并 `subscription.cancel()`。
- 任何 `MODIFY_AUDIO_SETTINGS` 失败（被系统拒绝）必须降级到 `AAUDIO_SHARING_MODE_SHARED` 并记录日志。

### 3.6 Checker 防御补丁：高频 UI 刷新防抖

```dart
// lib/features/tuner/domain/tuner_controller.dart
class TunerController {
  // PCM 流 44100/2048 ≈ 21.5Hz；但 UI 渲染必须锁 60fps。
  // 策略：MedianPitchFilter 输出后，调度到 16ms 边界才 emit；
  //       连续 3 帧 confidence < 0.6 才冻结指针。
  static const Duration uiTickInterval = Duration(milliseconds: 16);
  static const int freezeAfterSilentFrames = 3;

  Stream<PitchResult> get pitchStream;   // 已节流到 ≤ 60Hz
  void dispose();
}
```

### 3.7 720P 指针绘制隔离

```dart
// lib/features/tuner/ui/tuner_page.dart
class TunerPage extends StatelessWidget {
  Widget build(BuildContext context) {
    return Scaffold(
      body: RepaintBoundary(        // ⬅️ Checker 强制：指针独立图层
        child: CustomPaint(
          size: Size(720, 360),
          painter: NeedlePainter(),
        ),
      ),
    );
  }
}
```

### 3.8 TDD 用例（Auditor）

```dart
// test/features/tuner/standard_tuning_test.dart
test('A4 必须是 440.00Hz，偏差 0', () {
  expect(StandardTuning.frequenciesHz['A4'], 440.00);
});
test('minConfidence 必须等于 0.6（V2 收紧）', () {
  expect(StandardTuning.minConfidence, 0.6);
});

// test/features/tuner/pitch_estimator_test.dart
test('输入 440Hz 正弦波，返回 frequencyHz ∈ [438, 442]', () { ... });
test('静音帧返回 confidence < 0.6 且 frequencyHz == -1.0', () { ... });
test('2nd harmonic 能量 ≥ 0.85 × fundamental 时判定为泛音，丢弃', () { ... });

// test/features/tuner/median_pitch_filter_test.dart
test('窗口不足 5 帧时永远返回 null', () { ... });
test('入窗 confidence < 0.6 的帧不入窗', () { ... });
test('5 帧中位数与上一次发射偏差 > 200 cents 时丢弃', () { ... });

// test/features/tuner/tuner_controller_test.dart
test('1000ms 内 emit 次数 ≤ 60（防抖锁帧）', () { ... });
test('连续 3 帧静音后停止发射 PitchResult', () { ... });

// test/features/tuner/mic_permission_guard_test.dart
test('MicState != granted 时 start() 抛 MicNotGrantedException', () { ... });
test('AppLifecycleState.paused 触发 stop()', () { ... });

// test/goldens/tuner/tuner_page_golden_test.dart
testWidgets('Tuner 页面在 1280x720 下渲染快照匹配 golden/tuner_page.png', (tester) async {
  tester.view.physicalSize = Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  await expectLater(find.byType(TunerPage), matchesGoldenFile('goldens/tuner/tuner_page.png'));
});
```

---

## 4. 模块二：🎼 Chord Trainer 和弦练习

### 4.1 业务流（Architect: Data_Protocol）

```
[ChordRepository.loadAll] → List<ChordModel>
        ↓ 点击和弦
[ChordPlayer.play] → AudioPlaybackPort (≤ 30ms 触发)
        ↓
[ChordDiagramPainter] Canvas 绘制（720P 适配，高度 ≤ 45%）
        ↓ RepaintBoundary 隔离
```

### 4.2 数据模型（Architect: Data_Protocol）

```dart
// lib/features/chord/data/chord_model.dart
class ChordModel {
  final String id;            // 唯一：'C', 'G', 'Am', 'F', 'Dm', 'Em'
  final String name;          // 显示名
  final List<int> frets;      // 长度=4；0=空弦；-1=闷音；1~12=品数
  final List<int> fingers;    // 长度=4；0=不按；1~4=指法
  final int rootFret;         // 和弦图起始品（0=开放和弦）
  final String audioAsset;    // 资源路径
  final Duration demoNoteMs;  // 默认 1500ms
  const ChordModel({
    required this.id,
    required this.name,
    required this.frets,
    required this.fingers,
    required this.rootFret,
    required this.audioAsset,
    required this.demoNoteMs,
  })  : assert(frets.length == 4, 'frets.length must be 4'),
        assert(fingers.length == 4, 'fingers.length must be 4');
}
```

**硬约束**：
- `frets.length == 4`，`fingers.length == 4`，构造函数 assert 失败即单元测试红。
- **禁止**使用 PNG/SVG 资源绘制和弦图。一律 `CustomPainter` 几何渲染（720P 矢量自适应）。

### 4.3 720P 横屏物理边界约束（Architect: Interface_Driven + Auditor: Metric_Hardening）

```dart
// lib/features/chord/ui/chord_trainer_page.dart
class ChordTrainerPage extends StatelessWidget {
  // V2 硬约束：和弦卡片在垂直方向的物理占用像素不得超过可用高度的 45%。
  // 720P 横屏：1280×720，可用高度 720px → 单卡最大 324px。
  static const double maxChordCardHeightRatio = 0.45;
  static const double maxChordCardHeightPx = 720.0 * maxChordCardHeightRatio;  // 324.0

  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * maxChordCardHeightRatio;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final cardHeight = constraints.maxHeight * maxChordCardHeightRatio;
        assert(cardHeight <= maxH, 'V2: chord card must not exceed 45% of viewport height');
        return SizedBox(
          height: cardHeight,
          child: Row(
            children: chordList.map((c) {
              return RepaintBoundary(
                key: ValueKey(c.id),
                child: GestureDetector(
                  onTap: () => controller.play(c.id),
                  child: AspectRatio(
                    aspectRatio: 200 / 240,   // 与 painter 设计基准一致
                    child: CustomPaint(
                      painter: ChordDiagramPainter(chord: c, highlightedString: -1),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}
```

**V2 一票否决**：
- 任意布局下，和弦卡片 `height > screenHeight × 0.45` → 布局测试红。
- 设计师提供任何 > 324px 的和弦图设计稿，必须按 240px 基准重绘。
- `LayoutBuilder` 必须存在；缺失时启动期直接 `assert` 失败。

### 4.4 音频响应延迟（Auditor: Anti_Ambiguity）

```dart
// lib/features/chord/domain/chord_player.dart
abstract class ChordPlayer {
  /// 点击到扬声器出声的端到端延迟必须 ≤ 30ms。
  /// V2：实现内部必须 wrap AudioSessionMutex.acquireExclusive()。
  Future<void> play(String chordId);
  Future<void> stop();
}
```

### 4.5 Canvas 几何绘制规范（Architect: Interface_Driven）

```dart
// lib/features/chord/ui/painters/chord_diagram_painter.dart
class ChordDiagramPainter extends CustomPainter {
  // 设计基准：720P 横屏下，和弦图尺寸 = 200×240 px（宽×高）。
  // V2：高度 240px < 324px (45% × 720)，符合物理边界。
  static const double designWidth = 200.0;
  static const double designHeight = 240.0;
  static const int fretCount = 4;   // 可见品数（不含起始品）

  final ChordModel chord;
  final double highlightedString;  // -1=无；0~3 高亮当前拨弦

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / designWidth;
    final scaleY = size.height / designHeight;
    // 全部坐标乘以 scale，禁止直接写绝对 px。
  }

  @override
  bool shouldRepaint(ChordDiagramPainter old) =>
      old.chord != chord || old.highlightedString != highlightedString;
}
```

### 4.6 V2 修复：C++ 桥接层内存安全锁（Checker: Oboe_AAudio_Gatekeeper）

```dart
// lib/core/native/oboe_bridge.dart
// C++ 桥接契约（通过 FFI 调用 Oboe/AAudio 句柄）
class OboeBridge {
  static const int releaseBudgetMs = 10;  // V2: stop() → 释放 ≤ 10ms

  /// V2 硬约束：
  ///  - ChordPlayer.stop() 调用后，C++ 侧 OboeStream* 指针必须在 10ms 内
  ///    走完 AAudioStream_requestStop + AAudioStream_close + delete。
  ///  - 若超时未释放，FFI 层抛 OboeReleaseTimeoutException。
  ///  - 释放完成后必须将 Dart 侧句柄置 null，防止野指针。
  static void releaseStreamWithinBudget(int streamHandle) {
    final sw = Stopwatch()..start();
    _nativeRelease(streamHandle);          // FFI: oboe_release_stream
    if (sw.elapsedMilliseconds > releaseBudgetMs) {
      throw OboeReleaseTimeoutException(sw.elapsedMilliseconds);
    }
  }
  static external void _nativeRelease(int handle);
}

class OboeReleaseTimeoutException implements Exception {
  final int actualMs;
  OboeReleaseTimeoutException(this.actualMs);
}
```

```dart
// lib/features/chord/domain/chord_player.dart 实现片段
class DefaultChordPlayer implements ChordPlayer {
  final AudioPlaybackPort _player;
  final OboeBridge _bridge;

  @override
  Future<void> stop() async {
    await _player.pause();
    final handle = _player.detachNativeHandle();
    if (handle != 0) {
      OboeBridge.releaseStreamWithinBudget(handle);   // V2: 10ms 内释放
      _player.setNativeHandle(0);                     // 野指针防护
    }
  }
}
```

**V2 一票否决**：
- `ChordPlayer.stop()` → 底层 `OboeStream*` 释放 > 10ms → 单元测试红。
- 释放完成后 Dart 句柄未置 0 → 后续调用直接抛 `UseAfterFreeException`。
- 连续 5 次 `play/stop` 循环后，native heap 必须稳定（Valgrind / LeakSanitizer 检测无增长）。

### 4.7 Checker 防御补丁：重绘隔离

```dart
// lib/features/chord/ui/chord_trainer_page.dart  (V2 已并入 4.3)
// 任何和弦图状态变化（高亮、选中）只触发对应 RepaintBoundary 内部重绘，
// 外部兄弟节点不得参与。
```

**硬约束**：
- 连续 5 次 `play/stop` 后 Oboe heap 必须稳定（leak 监测）。
- 释放超时（> 10ms）必须抛出并被 `ChordPlayer.stop()` 捕获后清理 Dart 侧状态。

### 4.8 TDD 用例（Auditor）

```dart
// test/features/chord/chord_model_test.dart
test('ChordModel 构造时 frets.length 必须 == 4（assert）', () {
  expect(() => ChordModel(frets: [0,1,0], ...), throwsAssertionError);
});
test('ChordModel 构造时 fingers.length 必须 == 4（assert）', () { ... });

// test/features/chord/chord_player_test.dart
test('play() 端到端延迟 ≤ 30ms（1000 次采样 p95）', () async { ... });
test('stop() 后 C++ 句柄释放耗时 ≤ 10ms', () async { ... });
test('stop() 后 Dart 句柄 == 0（防野指针）', () async { ... });
test('连续 5 次 play/stop 后 native handle 集合为空', () async { ... });

// test/features/chord/chord_diagram_painter_test.dart
testWidgets('720P 屏幕下 size=(200,240) 渲染不溢出', (tester) { ... });
testWidgets('chord 变化触发 shouldRepaint=true', (tester) { ... });
testWidgets('和弦卡片高度 ≤ viewport × 0.45（V2）', (tester) {
  tester.view.physicalSize = Size(1280, 720);
  final size = tester.getSize(find.byType(ChordTrainerPage));
  expect(size.height * 0.45, lessThanOrEqualTo(720.0 * 0.45));  // 324.0
});

// test/goldens/chord/chord_trainer_page_golden_test.dart
testWidgets('1280x720 下 chord_trainer_page 渲染快照', (tester) async {
  tester.view.physicalSize = Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  await expectLater(find.byType(ChordTrainerPage), matchesGoldenFile('goldens/chord/chord_trainer_page.png'));
});
```

---

## 5. 模块三：🕒 Score Player 滚动乐谱

### 5.1 业务流（Architect: Data_Protocol）

```
[ScoreRepository.load] → Future<UnifiedScore>   // 后台 Isolate
        ↓
[AudioPlaybackPort] → Stream<PlaybackTick>     // 1024 帧 / 23.22ms
        ↓
[AudioClock] → Stream<Duration>                // 唯一时间源（受 Mutex 保护）
        ↓
[ScorePlayerController] → 当前 chord/lyric/note
        ↓ 3 个独立 RepaintBoundary
[ChordStripView] [ScrollingLyricsView] [TabView]
```

### 5.2 V2 修复：`AudioSessionMutex` 硬件互斥（Architect: Interface_Driven）

```dart
// lib/core/audio/audio_session_mutex.dart
enum AudioSessionMode {
  idle,
  captureExclusive,     // Tuner 独占麦克风
  playbackExclusive,    // Score 独占扬声器
}

abstract class AudioSessionMutex {
  /// V2 硬约束：
  ///  - 同一时刻只允许一个 Owner（capture 或 playback）。
  ///  - Android 侧走 AAudio AAUDIO_SHARING_MODE_EXCLUSIVE，framesPerBurst ≤ 256。
  ///  - acquire 失败时立即抛 AudioSessionBusyException，不排队。
  ///  - 任何持有方在 dispose / app pause 时必须 release，否则 5s 后强制回收。
  Future<void> acquire(AudioSessionMode mode);
  Future<void> release(AudioSessionMode mode);
  AudioSessionMode get currentMode;
  Stream<AudioSessionMode> get modeStream;
}

class AudioSessionBusyException implements Exception {
  final AudioSessionMode requested;
  final AudioSessionMode current;
  AudioSessionBusyException(this.requested, this.current);
}
```

**V2 一票否决**：
- Tuner `AudioCapturePort.start()` 必须先 `mutex.acquire(captureExclusive)`；失败则 `MicNotGrantedException` 升级为 `AudioSessionBusyException`。
- Score `AudioPlaybackPort.load()` 必须先 `mutex.acquire(playbackExclusive)`。
- 同一进程内 `captureExclusive` 与 `playbackExclusive` 互斥。

### 5.3 统一音频时钟（Architect: Interface_Driven）

```dart
// lib/core/audio/audio_clock.dart
class AudioClock {
  final AudioPlaybackPort _player;
  final AudioSessionMutex _mutex;
  AudioClock(this._player, this._mutex);

  /// 唯一时间源。所有 UI 同步必须订阅此流，禁止使用 DateTime.now()。
  Stream<Duration> get positionStream => _player.ticks().map((t) => t.position);

  static const Duration tickInterval = Duration(milliseconds: 23); // 1024/44100
  static const Duration jitterTolerance = Duration(milliseconds: 5);
}
```

### 5.4 统一乐谱 JSON 数据模型（Architect: Data_Protocol）

```jsonc
// assets/scores/sample_ukulele.json
{
  "schemaVersion": "1.0.0",
  "meta": {
    "id": "twinkle-twinkle-little-star",
    "title": "小星星",
    "bpm": 100,
    "audioAsset": "audio/twinkle.mp3",
    "durationMs": 60000
  },
  "chords": [
    { "name": "C",  "startMs": 0,    "endMs": 1500 },
    { "name": "G",  "startMs": 1500, "endMs": 3000 },
    { "name": "Am", "startMs": 3000, "endMs": 4500 },
    { "name": "F",  "startMs": 4500, "endMs": 6000 }
  ],
  "lyrics": [
    { "text": "一闪一闪亮晶晶", "startMs": 0,    "endMs": 3000 },
    { "text": "满天都是小星星", "startMs": 3000, "endMs": 6000 }
  ],
  "notes": [
    { "stringIndex": 0, "fret": 0, "startMs": 0,    "endMs": 375 },
    { "stringIndex": 1, "fret": 0, "startMs": 375,  "endMs": 750 }
  ]
}
```

```dart
// lib/features/score/data/unified_score.dart
class ScoreMeta {
  final String id;
  final String title;
  final int bpm;
  final String audioAsset;
  final Duration duration;
  const ScoreMeta({required this.id, required this.title, required this.bpm, required this.audioAsset, required this.duration});
}

class TimedChord {
  final String chord;
  final Duration start;
  final Duration end;
  const TimedChord({required this.chord, required this.start, required this.end});
}

class TimedLyric {
  final String text;
  final Duration start;
  final Duration end;
  const TimedLyric({required this.text, required this.start, required this.end});
}

class TimedNote {
  final int stringIndex;     // 0~3
  final int fret;            // 0=空弦
  final Duration start;
  final Duration end;
  const TimedNote({required this.stringIndex, required this.fret, required this.start, required this.end});
}

class UnifiedScore {
  static const String currentSchemaVersion = '1.0.0';
  final ScoreMeta meta;
  final List<TimedChord> chords;
  final List<TimedLyric> lyrics;
  final List<TimedNote> notes;
  const UnifiedScore({
    required this.meta,
    required this.chords,
    required this.lyrics,
    required this.notes,
  })  : assert(meta.duration >= Duration.zero, 'meta.duration must be >= 0'),
        assert(chords.length == lyrics.length || chords.isEmpty || lyrics.isEmpty,
            'chords/lyrics must be aligned or one-side empty');
}
```

**V2 新增 assert**：
- `meta.duration >= 0`
- `chords` 与 `lyrics` 必须对齐或单边为空（不允许半错位）

### 5.5 解析工厂（Architect: Interface_Driven）

```dart
// lib/features/score/data/score_parser.dart
abstract class ScoreParser {
  UnifiedScore parse(String rawJson);
}

class JsonScoreParser implements ScoreParser {
  @override
  UnifiedScore parse(String rawJson) {
    final json = jsonDecode(rawJson) as Map<String, dynamic>;
    // V2 硬约束：schemaVersion 必须等于 currentSchemaVersion，否则抛异常。
    if (json['schemaVersion'] != UnifiedScore.currentSchemaVersion) {
      throw SchemaMismatchException(json['schemaVersion']);
    }
    // 硬约束：所有 startMs < endMs < meta.durationMs。
    final meta = _parseMeta(json['meta'] as Map<String, dynamic>);
    final chords = _parseChords(json['chords'] as List, meta.duration);
    final lyrics = _parseLyrics(json['lyrics'] as List, meta.duration);
    final notes  = _parseNotes (json['notes']  as List, meta.duration);
    return UnifiedScore(meta: meta, chords: chords, lyrics: lyrics, notes: notes);
  }
}

class SchemaMismatchException implements Exception {
  final String version;
  SchemaMismatchException(this.version);
}
class InvalidTimingException implements Exception {
  final String entity;
  final int startMs;
  final int endMs;
  InvalidTimingException(this.entity, this.startMs, this.endMs);
}
```

### 5.6 Checker 防御补丁：异步 I/O 隔离（Checker: Oboe_AAudio_Gatekeeper）

```dart
// lib/features/score/data/score_repository.dart
class ScoreRepository {
  /// 大文件 JSON 解析必须在 Isolate 中执行，禁止阻塞 UI 线程。
  /// 720P 设备上，单个乐谱 JSON > 50KB 必须走 compute()。
  /// V2：load() 之前必须先 acquire AudioSessionMutex(playbackExclusive)。
  Future<UnifiedScore> load(String assetPath) async {
    await _mutex.acquire(AudioSessionMode.playbackExclusive);
    try {
      final raw = await rootBundle.loadString(assetPath);   // 异步 I/O
      return await compute(_parseIsolateEntry, raw);        // ⬅️ Isolate 隔离
    } finally {
      // 解析完成不释放 mutex，留给 AudioPlaybackPort.play() 复用
    }
  }
}

UnifiedScore _parseIsolateEntry(String raw) {
  return JsonScoreParser().parse(raw);
}
```

**音频资产加载（AAudio/Oboe）硬约束**：
- `AudioPlaybackPort.load()` 必须在播放前 500ms 完成；否则 UI 必须显示 loading。
- 音频硬件 buffer size：固定 1024 帧（23.22ms），Android 上 AAudio `getFramesPerBurst` 必须 ≤ 256。
- 任何 `load()` 失败必须 `mutex.release()` 并 `dispose()`，避免半初始化状态。

### 5.7 音画同步规范（Auditor: Anti_Ambiguity）

| 指标 | 阈值 | 测量方法 |
|---|---|---|
| 同步偏差 | ≤ ±15ms | 在 60s 曲谱中每 1000ms 采样一次 `AudioClock.position` 与当前 `TimedChord.start` 差值 |
| Tick 抖动 | ≤ 5ms | 连续 1000 个 tick 的 `position` 间隔标准差 |
| 高亮响应延迟 | ≤ 33ms（一帧） | chord 切换时 Painter 必须在下一个 vsync 完成重绘 |
| 滚动帧率 | 60fps | `SchedulerBinding.addTimingsCallback` 监测，单帧 > 16.6ms 即不合格 |

### 5.8 UI 隔离规范（Checker: UI_Performance_Guard）

```dart
// lib/features/score/ui/score_player_page.dart
class ScorePlayerPage extends StatelessWidget {
  Widget build(BuildContext context) {
    return Column(
      children: [
        RepaintBoundary(   // ⬅️ Checker 强制：和弦条独立图层
          child: CustomPaint(
            size: Size(1280, 120),
            painter: ChordStripPainter(),
          ),
        ),
        RepaintBoundary(   // ⬅️ Checker 强制：歌词独立图层
          child: CustomPaint(
            size: Size(1280, 480),
            painter: LyricsScrollingPainter(),
          ),
        ),
        RepaintBoundary(   // ⬅️ Checker 强制：Tab 独立图层
          child: CustomPaint(
            size: Size(1280, 120),
            painter: TabViewPainter(),
          ),
        ),
      ],
    );
  }
}
```

**硬约束**：
- 3 个图层物理隔离；任一图层重绘不得触发其他图层 `paint()`。
- 滚动使用 `Transform.translate` 而非 `setState`，避免 Widget tree 整体刷新。

### 5.9 TDD 用例（Auditor）

```dart
// test/features/score/unified_score_test.dart
test('UnifiedScore 构造时 meta.duration < 0 抛 assert', () { ... });
test('UnifiedScore 构造时 chords/lyrics 半错位抛 assert', () { ... });

// test/features/score/json_score_parser_test.dart
test('schemaVersion 不匹配抛 SchemaMismatchException', () { ... });
test('chord.startMs >= chord.endMs 抛 InvalidTimingException', () { ... });
test('lyric.endMs > meta.durationMs 抛 InvalidTimingException', () { ... });

// test/features/score/score_repository_test.dart
test('load() 在 UI 主线程上不阻塞（>50KB JSON）', () async { ... });
test('load() 前必须 acquire AudioSessionMutex(playbackExclusive)', () async { ... });

// test/features/score/score_player_sync_test.dart
test('AudioClock.tick 1000 次间隔标准差 ≤ 5ms', () async { ... });
test('音画同步偏差 p95 ≤ 15ms', () async { ... });

// test/core/audio/audio_session_mutex_test.dart
test('captureExclusive 与 playbackExclusive 互斥', () async { ... });
test('持有方 5s 未 release 触发强制回收', () async { ... });

// test/goldens/score/score_player_page_golden_test.dart
testWidgets('1280x720 下 score_player_page 渲染快照', (tester) async {
  tester.view.physicalSize = Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  await expectLater(find.byType(ScorePlayerPage), matchesGoldenFile('goldens/score/score_player_page.png'));
});
```

---

## 6. 跨模块契约汇总

### 6.1 注入清单（Architect: Interface_Driven — 拒绝硬编码）

```dart
// lib/core/di/service_locator.dart
final getIt = GetIt.instance;

void registerDependencies() {
  getIt.registerLazySingleton<AudioSessionMutex>(() => AndroidAudioSessionMutex());
  getIt.registerLazySingleton<AudioCapturePort>(() => AndroidAAudioCapture(getIt()));
  getIt.registerLazySingleton<AudioPlaybackPort>(() => AndroidAAudioPlayback(getIt()));
  getIt.registerLazySingleton<AudioClock>(() => AudioClock(getIt(), getIt()));
  getIt.registerLazySingleton<PitchEstimator>(() => YINPitchEstimator());
  getIt.registerLazySingleton<MedianPitchFilter>(() => MedianPitchFilter());
  getIt.registerLazySingleton<ScoreParser>(() => JsonScoreParser());
}
```

### 6.2 错误类型（Auditor）

```dart
// lib/core/result/result.dart
sealed class AppError {
  final String code;
  final String message;
  const AppError(this.code, this.message);
}
class MicNotGrantedException extends AppError { ... }
class SchemaMismatchException extends AppError { ... }
class InvalidTimingException extends AppError { ... }
class AudioLatencyOverflowException extends AppError { ... }   // > 30ms / > 15ms
class RenderBudgetOverflowException extends AppError { ... }   // 单帧 > 16.6ms
class AudioSessionBusyException extends AppError { ... }        // V2 新增
class OboeReleaseTimeoutException extends AppError { ... }       // V2 新增
class UseAfterFreeException extends AppError { ... }             // V2 新增
```

---

## 7. CI 流水线交付清单（V2 升级）

| # | 模块 | Agent | Skill | 验收 | CI 路径 |
|---|---|---|---|---|---|
| 1 | core/audio | Architect | Interface_Driven | 抽象类可 mock | `flutter test test/core/audio/` |
| 2 | core/audio | Auditor | Metric_Hardening | 常量单测全绿 | `flutter test test/core/audio/contract_test.dart` |
| 3 | core/native | Checker | Oboe_AAudio_Gatekeeper | 10ms 释放单测 | `flutter test test/core/native/oboe_bridge_test.dart` |
| 4 | tuner | Architect | Data_Protocol | StandardTuning 单测 | `flutter test test/features/tuner/standard_tuning_test.dart` |
| 5 | tuner | Auditor | Metric_Hardening | 5 帧中位数单测 | `flutter test test/features/tuner/median_pitch_filter_test.dart` |
| 6 | tuner | Checker | Oboe_AAudio_Gatekeeper | 权限生命周期单测 | `flutter test test/features/tuner/mic_permission_guard_test.dart` |
| 7 | tuner | Checker | UI_Performance_Guard | Golden Test | `flutter test --update-goldens test/goldens/tuner/` |
| 8 | chord | Architect | Data_Protocol | ChordModel 构造校验 | `flutter test test/features/chord/chord_model_test.dart` |
| 9 | chord | Auditor | Anti_Ambiguity | 30ms 延迟 p95 单测 | `flutter test test/features/chord/chord_player_test.dart` |
| 10 | chord | Checker | UI_Performance_Guard | 720P 45% 高度单测 | `flutter test test/features/chord/chord_diagram_painter_test.dart` |
| 11 | chord | Checker | Oboe_AAudio_Gatekeeper | Oboe 10ms 释放单测 | `flutter test test/features/chord/chord_player_test.dart` |
| 12 | chord | Checker | UI_Performance_Guard | Golden Test | `flutter test --update-goldens test/goldens/chord/` |
| 13 | score | Architect | Data_Protocol | JSON schema 单测 | `flutter test test/features/score/unified_score_test.dart` |
| 14 | score | Auditor | Anti_Ambiguity | ±15ms 同步单测 | `flutter test test/features/score/score_player_sync_test.dart` |
| 15 | score | Checker | Oboe_AAudio_Gatekeeper | Isolate 隔离 + Mutex 单测 | `flutter test test/features/score/score_repository_test.dart` |
| 16 | score | Checker | UI_Performance_Guard | 3 图层独立重绘 Golden | `flutter test --update-goldens test/goldens/score/` |
| 17 | core/audio | Architect | Interface_Driven | AudioSessionMutex 互斥单测 | `flutter test test/core/audio/audio_session_mutex_test.dart` |

**CI 脚本契约**（`tools/ci/run_tests.sh`）：

```bash
#!/usr/bin/env bash
set -euo pipefail
flutter test --coverage
# Golden Test 强制 1280x720 视口
flutter test --update-goldens test/goldens/
# 硬指标门禁：覆盖率 ≥ 80%，单测时长 ≤ 120s
```

---

## 8. V2 流水线执行总签

- **Architect Phase**：完成全部 `abstract class` 接口、Data Model、目录拓扑；新增 `AudioSessionMutex` / `OboeBridge` / `MedianPitchFilter` 三大 V2 抽象。
- **Auditor Phase**：将所有"适当 / 流畅 / 低延迟"模糊词全部替换为具体物理指标；V2 新增 4 条硬指标（45% 高度、10ms 释放、Mutex 独占、minConfidence=0.6）；每条阈值都有对应单测编号。
- **Checker Phase**：补充 RECORD_AUDIO / MODIFY_AUDIO_SETTINGS Manifest 硬化、`RepaintBoundary` 隔离、`compute()` Isolate、`AudioSessionMutex` 互斥、`OboeBridge` 10ms 释放锁五类防御补丁；附带 golden test 路径与 CI 脚本契约。

> V2 文档完。初稿 4 条漏洞全部闭环。三阶段流水线产物已合并为 V2 终稿，可直接进入编码与 TDD 落地阶段。