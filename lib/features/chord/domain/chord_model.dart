// lib/features/chord/domain/chord_model.dart
//
// 来自 PRD_Architecture.md §4.2 (Architect: Data_Protocol) + §4.3 (Auditor: Metric_Hardening)
//
// Ukulele 和弦的不可变数据契约。
// - 长度严格 = 4（4 根弦）
// - 品格取值严格 ∈ [-1, 12]（-1=闷音，0=空弦，1~12=实按品）
// - 构造函数 assert 失败即单元测试红（Fail-fast，脏数据绝不流入渲染层）

import 'package:meta/meta.dart';

/// Ukulele 和弦数据模型。
///
/// 字段约定（PRD §4.2）：
///   - [id]：和弦唯一标识，如 'C' / 'G' / 'Am' / 'F' / 'Dm' / 'Em'
///   - [name]：显示名（与 id 通常相同）
///   - [frets]：四弦品格，长度必须 == 4；元素 ∈ [-1, 12]
///       * -1 = 闷音（X）
///       *  0 = 空弦（O）
///       *  1~12 = 实按品数
///   - [fingers]：四弦指法，长度必须 == 4；元素 ∈ [0, 4]
///       * 0 = 不按
///       * 1~4 = 食指/中指/无名指/小指
///   - [rootFret]：和弦图起始品（0 = 开放和弦）
///   - [audioAsset]：和弦音频资源路径
///   - [demoNoteMs]：示例音频时长
///
/// 硬指标（Auditor 一票否决）：
///   - frets.length == 4（否则构造时直接 AssertionError）
///   - fingers.length == 4（否则构造时直接 AssertionError）
///   - 所有 fret ∈ [-1, 12]（越界直接 AssertionError）
///   - 所有 finger ∈ [0, 4]（越界直接 AssertionError）
///   - rootFret ∈ [0, 12]（越界直接 AssertionError）
@immutable
class ChordModel {
  /// 唯一标识（'C' / 'G' / 'Am' ...）。
  final String id;

  /// 显示名。
  final String name;

  /// 四弦品格（长度固定 4；-1=闷音 / 0=空弦 / 1~12=实按）。
  final List<int> frets;

  /// 四弦指法（长度固定 4；0=不按 / 1~4=指法）。
  final List<int> fingers;

  /// 和弦图起始品（0=开放和弦）。
  final int rootFret;

  /// 音频资源路径。
  final String audioAsset;

  /// 示例音频时长。
  final Duration demoNoteMs;

  /// Ukulele 弦数（硬指标 = 4，任何模型必须遵循）。
  static const int stringCount = 4;

  /// 合法品格范围下界（含）：-1 表示闷音。
  static const int minFret = -1;

  /// 合法品格范围上界（含）：12 品是常见 ukulele 指板上限。
  static const int maxFret = 12;

  /// 合法指法范围下界（含）：0 表示不按。
  static const int minFinger = 0;

  /// 合法指法范围上界（含）：4 表示小指。
  static const int maxFinger = 4;

  /// 合法起始品范围下界（含）。
  static const int minRootFret = 0;

  /// 合法起始品范围上界（含）。
  static const int maxRootFret = 12;

  ChordModel({
    required this.id,
    required this.name,
    required this.frets,
    required this.fingers,
    required this.rootFret,
    required this.audioAsset,
    required this.demoNoteMs,
  })  : assert(
          frets.length == stringCount,
          'frets.length must be $stringCount (got ${frets.length})',
        ),
        assert(
          fingers.length == stringCount,
          'fingers.length must be $stringCount (got ${fingers.length})',
        ),
        assert(
          rootFret >= minRootFret && rootFret <= maxRootFret,
          'rootFret must be in [$minRootFret, $maxRootFret] (got $rootFret)',
        ),
        assert(
          _allFretsInRange(frets),
          'each fret must be in [minFret, maxFret]',
        ),
        assert(
          _allFingersInRange(fingers),
          'each finger must be in [minFinger, maxFinger]',
        );

  /// 私有 helper：所有 fret ∈ [minFret, maxFret]。
  static bool _allFretsInRange(List<int> f) {
    for (final v in f) {
      if (v < minFret || v > maxFret) return false;
    }
    return true;
  }

  /// 私有 helper：所有 finger ∈ [minFinger, maxFinger]。
  static bool _allFingersInRange(List<int> f) {
    for (final v in f) {
      if (v < minFinger || v > maxFinger) return false;
    }
    return true;
  }

  /// 是否有任意一弦是闷音（-1）。
  bool get hasMuted => frets.any((f) => f == -1);

  /// 是否有任意一弦是空弦（0）。
  bool get hasOpen => frets.any((f) => f == 0);

  /// 数据相等：用于 painter 的 shouldRepaint 与 Repository 去重。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChordModel &&
          other.id == id &&
          other.name == name &&
          _listEq(other.frets, frets) &&
          _listEq(other.fingers, fingers) &&
          other.rootFret == rootFret &&
          other.audioAsset == audioAsset &&
          other.demoNoteMs == demoNoteMs;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        Object.hashAll(frets),
        Object.hashAll(fingers),
        rootFret,
        audioAsset,
        demoNoteMs,
      );

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'ChordModel(id: $id, name: $name, frets: $frets, fingers: $fingers, '
      'rootFret: $rootFret, audioAsset: $audioAsset, demoNoteMs: $demoNoteMs)';
}