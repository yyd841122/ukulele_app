// lib/features/chord/data/chord_repository.dart
//
// 来自 PRD_Architecture.md §4 (Architect: Data_Protocol) + §4.2 (Auditor: Metric_Hardening)
//
// 和弦数据仓储。MVP 阶段硬编码 C / G / Am / F 四个核心标准和弦。
// V2 升级路径：未来可在此处注入 rootBundle.loadString() → Isolate JSON 解析。
//
// Checker 硬约束（Oboe_AAudio_Gatekeeper）：
//   - getInitialChords() 必须返回 Future，永不返回同步 List。
//     业务层 await 即可获得数据，禁止任何位置出现
//     `final list = repo.getInitialChords();` 这种「漏 await」反模式。
//   - Repository 内部数据对所有调用方不可变 (unmodifiableListView)，
//     杜绝下游误改污染全局状态。
//   - byId 查找为 O(n)（MVP 4 个和弦，n=4，无需上索引）。

import 'dart:async';

import '../domain/chord_model.dart';

/// 和弦仓储。提供 MVP 四个标准和弦的不可变快照。
///
/// 设计要点：
///   - 异步签名：与未来 JSON/网络源保持接口一致。
///   - 不可变：所有返回的 List 为 unmodifiableListView。
///   - 单例友好：状态全为 static final，构造无副作用。
class ChordRepository {
  /// 创建仓储实例。MVP 阶段无外部依赖，构造无副作用。
  ChordRepository();

  /// 单个和弦的示例音频时长（PRD §4.2 默认 1500ms）。
  static const Duration _demoNote = Duration(milliseconds: 1500);

  /// MVP 内置四个标准和弦（与 PRD §4.2 表格对齐）。
  ///
  /// 列表本身使用 final（非 const），因 ChordModel 构造函数内的
  /// assert 调用了静态方法，无法在 const list 字面量中静态求值。
  static final List<ChordModel> _builtin = <ChordModel>[
    // C 大调：0 0 0 3 (无名指按 1 弦 3 品)
    ChordModel(
      id: 'C',
      name: 'C',
      frets: const <int>[0, 0, 0, 3],
      fingers: const <int>[0, 0, 0, 3],
      rootFret: 0,
      audioAsset: 'audio/chords/c.wav',
      demoNoteMs: _demoNote,
    ),
    // G 大调：0 2 3 2
    ChordModel(
      id: 'G',
      name: 'G',
      frets: const <int>[0, 2, 3, 2],
      fingers: const <int>[0, 1, 2, 3],
      rootFret: 0,
      audioAsset: 'audio/chords/g.wav',
      demoNoteMs: _demoNote,
    ),
    // Am 小调：2 0 0 0
    ChordModel(
      id: 'Am',
      name: 'Am',
      frets: const <int>[2, 0, 0, 0],
      fingers: const <int>[2, 0, 0, 0],
      rootFret: 0,
      audioAsset: 'audio/chords/am.wav',
      demoNoteMs: _demoNote,
    ),
    // F 大调：2 0 1 0 (Ukulele 经典 F 简化按法)
    ChordModel(
      id: 'F',
      name: 'F',
      frets: const <int>[2, 0, 1, 0],
      fingers: const <int>[2, 0, 1, 0],
      rootFret: 0,
      audioAsset: 'audio/chords/f.wav',
      demoNoteMs: _demoNote,
    ),
  ];

  /// 异步返回内置的 MVP 标准和弦列表。
  ///
  /// 必须是 `Future` 返回类型：
  ///   - 业务层 await 调用，编译期即可阻止「漏 await 同步反模式」。
  ///   - 未来切换到 JSON / 网络源时，调用方零修改。
  ///
  /// 实现内部使用 `scheduleMicrotask` 在下一 microtask 派发结果，
  /// 既保证异步语义，又不会引入真实 IO 延迟（单测稳定）。
  Future<List<ChordModel>> getInitialChords() {
    final completer = Completer<List<ChordModel>>();
    scheduleMicrotask(() {
      // 返回不可变快照，下游不可改。
      completer.complete(List<ChordModel>.unmodifiable(_builtin));
    });
    return completer.future;
  }

  /// 根据 id 同步查找和弦（O(n) 线性扫描）。
  ///
  /// 仅在已知 id 列表有限（如 MVP 4 个）时使用；
  /// 数据源扩展为百级时须改 Map 索引。
  ChordModel? findById(String id) {
    for (final c in _builtin) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 当前内置和弦数量。
  int get count => _builtin.length;
}