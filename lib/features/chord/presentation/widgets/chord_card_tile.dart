// lib/features/chord/presentation/widgets/chord_card_tile.dart
//
// 来自 PRD_Architecture.md §4.7 (Checker: UI_Performance_Guard)
//
// 单个和弦卡片的封装 Widget。
//   - 强制使用 RepaintBoundary 隔离图层：单个卡片的高亮/选中状态变更
//     绝不能触发兄弟卡片 / 父级 Widget tree 的 paint() 调用。
//   - AspectRatio 锁 200:240 比例，与 painter 设计基准完全对齐，
//     任何宿主容器下都自动约束到 ≤ 720P × 45% = 324px 物理红线内。

import 'package:flutter/material.dart';

import '../../domain/chord_model.dart';
import 'chord_card_painter.dart';

/// 和弦卡片 Widget。
///
/// 设计基准 200×240（高 240 < 324，符合 PRD §4.3 物理红线）。
/// 包裹 [RepaintBoundary]，杜绝高亮态变更时污染兄弟图层。
class ChordCardTile extends StatelessWidget {
  /// 设计基准宽。
  static const double designWidth = ChordCardPainter.designWidth; // 200

  /// 设计基准高。
  static const double designHeight = ChordCardPainter.designHeight; // 240

  /// 和弦数据。
  final ChordModel chord;

  /// 高亮拨弦态：-1 = 无；0~3 = 第几根弦。
  final int highlightedString;

  /// 卡片点击回调（可选；用于触发 ChordPlayer.play）。
  final VoidCallback? onTap;

  /// 卡片背景色。
  final Color backgroundColor;

  /// 卡片圆角。
  final double borderRadius;

  const ChordCardTile({
    super.key,
    required this.chord,
    this.highlightedString = -1,
    this.onTap,
    this.backgroundColor = const Color(0xFFFAFAFA),
    this.borderRadius = 12.0,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AspectRatio(
        aspectRatio: designWidth / designHeight,
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(borderRadius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: CustomPaint(
              size: const Size(designWidth, designHeight),
              painter: ChordCardPainter(
                chord: chord,
                highlightedString: highlightedString,
              ),
            ),
          ),
        ),
      ),
    );
  }
}