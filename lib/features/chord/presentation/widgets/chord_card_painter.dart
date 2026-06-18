// lib/features/chord/presentation/widgets/chord_card_painter.dart
//
// 来自 PRD_Architecture.md §4.3 / §4.5 / §4.7 (Architect: Interface_Driven + Checker: UI_Performance_Guard)
//
// 720P 纵向极简 Canvas 和弦卡片 CustomPainter。
//
// 硬指标（Auditor: Metric_Hardening 一票否决）：
//   - 设计基准 200×240px（高 < 324px，恒满足 720P 45% 物理红线）。
//   - 禁止任何写死 > 10 的绝对像素。所有几何参数必须乘以统一 scale 因子。
//   - scale = min(size.width / designWidth, size.height / designHeight)。
//     即使宿主容器把高度压到 324px 甚至更低，依然等比例自适应，绝不越界 / 重叠。
//
// 绘制要素：
//   - 4 弦 × 5 品格网格（含起始品 = rootFret）✅ 物理拓扑对齐 §4.5
//   - 按弦实心圆（fret > 0）
//   - 空弦圆圈（fret == 0）
//   - 闷音叉（fret == -1）
//   - 高亮拨弦态（highlightedString ∈ [-1, 3]）
//   - 和弦名（卡片顶部）
//
// shouldRepaint 严格对比 chord + highlightedString，杜绝兄弟卡片被污染。

import 'package:flutter/material.dart';

import '../../domain/chord_model.dart';

/// 和弦指法图 CustomPainter。
///
/// 设计基准：宽 200px × 高 240px（已符合 PRD 324px 上限）。
class ChordCardPainter extends CustomPainter {
  /// 设计基准宽。
  static const double designWidth = 200.0;

  /// 设计基准高（240 < 324，符合 720P × 45% 物理红线）。
  static const double designHeight = 240.0;

  /// 可见品格数（含起始品）。
  static const int fretCount = 5;

  /// 和弦数据。
  final ChordModel chord;

  /// 高亮拨弦态：-1 = 无；0~3 = 第几根弦高亮。
  final int highlightedString;

  const ChordCardPainter({
    required this.chord,
    this.highlightedString = -1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1) 统一缩放因子：所有几何参数必须经过此 scale 转换。
    final scale = _scaleOf(size);
    final s = scale; // 局部缩写，便于阅读

    // ── 设计基准下的几何常量（绝不允许漏乘 s）────────────────
    const double dbTitleBaselineY = 24.0;   // 标题基线 Y（设计基准）
    const double dbTitleFontSize = 18.0;    // 标题字号（设计基准）
    const double dbGridLeft = 36.0;         // 网格左边界
    const double dbGridRight = 184.0;       // 网格右边界
    const double dbGridTop = 44.0;          // 网格上边界（标题之下）
    const double dbGridBottom = 220.0;      // 网格下边界
    const double dbFingerRadius = 8.0;      // 按弦圆点半径
    const double dbDotStroke = 2.0;         // 圆点描边粗细
    const double dbGridStroke = 1.5;        // 网格线粗细
    const double dbNutHeight = 4.0;         // 起始品横杠厚度
    const double dbSymbolRadius = 6.0;      // O / X 标记半径
    const double dbSymbolStroke = 2.0;      // O / X 描边
    const double dbSymbolOffsetY = 30.0;    // O / X 相对 dbGridTop 的偏移
    const double dbHighlightStroke = 2.5;   // 高亮拨弦描边粗细

    // ── 颜色 ───────────────────────────────────────────────
    const Color lineColor = Color(0xFF3C3C3C);
    const Color fingerFill = Color(0xFF1F1F1F);
    const Color fingerStroke = Color(0xFF1F1F1F);
    const Color openRingColor = Color(0xFF1F1F1F);
    const Color mutedColor = Color(0xFF1F1F1F);
    const Color textColor = Color(0xFF1F1F1F);
    const Color highlightColor = Color(0xFFE53935); // 高亮拨弦

    // ── 标题 ──────────────────────────────────────────────
    final TextPainter titlePainter = TextPainter(
      text: TextSpan(
        text: chord.name,
        style: TextStyle(
          color: textColor,
          fontSize: dbTitleFontSize * s,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titlePainter.paint(
      canvas,
      Offset(
        (size.width - titlePainter.width) / 2,
        (dbTitleBaselineY - dbTitleFontSize) * s,
      ),
    );

    // 网格几何（按 scale 缩放）
    final double gridLeft = dbGridLeft * s;
    final double gridRight = dbGridRight * s;
    final double gridTop = dbGridTop * s;
    final double gridBottom = dbGridBottom * s;
    final double gridWidth = gridRight - gridLeft;
    final double gridHeight = gridBottom - gridTop;
    final double fretSpacing = gridHeight / (fretCount - 1);
    final double stringSpacing = gridWidth / (ChordModel.stringCount - 1);
    final double fingerRadius = dbFingerRadius * s;
    final double dotStroke = dbDotStroke * s;
    final double gridStroke = dbGridStroke * s;
    final double nutHeight = dbNutHeight * s;
    final double symbolRadius = dbSymbolRadius * s;
    final double symbolStroke = dbSymbolStroke * s;
    final double symbolOffsetY = dbSymbolOffsetY * s;
    final double highlightStroke = dbHighlightStroke * s;

    // ── 网格线 ────────────────────────────────────────────
    final Paint gridPaint = Paint()
      ..color = lineColor
      ..strokeWidth = gridStroke
      ..style = PaintingStyle.stroke;

    // 4 根弦（垂直线）
    for (int i = 0; i < ChordModel.stringCount; i++) {
      final double x = gridLeft + i * stringSpacing;
      canvas.drawLine(
        Offset(x, gridTop),
        Offset(x, gridBottom),
        gridPaint,
      );
    }

    // fretCount 根品格线（水平线）
    for (int j = 0; j < fretCount; j++) {
      final double y = gridTop + j * fretSpacing;
      canvas.drawLine(
        Offset(gridLeft, y),
        Offset(gridRight, y),
        gridPaint,
      );
    }

    // ── 起始品横杠（rootFret == 0 时画粗 Nut）──────────────
    if (chord.rootFret == 0) {
      final Paint nutPaint = Paint()
        ..color = lineColor
        ..strokeWidth = nutHeight;
      canvas.drawLine(
        Offset(gridLeft, gridTop),
        Offset(gridRight, gridTop),
        nutPaint,
      );
    }

    // ── 弦上的标记（O / X / 按弦圆）─────────────────────
    for (int i = 0; i < ChordModel.stringCount; i++) {
      final double x = gridLeft + i * stringSpacing;
      final int fret = chord.frets[i];
      final int finger = chord.fingers[i];

      if (fret == -1) {
        // 闷音叉 X
        _drawMutedX(canvas, x, gridTop - symbolOffsetY, symbolRadius,
            symbolStroke, mutedColor);
      } else if (fret == 0) {
        // 空弦圈 O
        _drawOpenO(canvas, x, gridTop - symbolOffsetY, symbolRadius,
            symbolStroke, openRingColor);
      } else {
        // 按弦实心圆（在对应的品格行中心）
        final double y = gridTop + (fret - 0.5) * fretSpacing;
        final bool isHighlighted = (highlightedString == i);
        final Paint fillPaint = Paint()
          ..color = fingerFill
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(x, y), fingerRadius, fillPaint);

        // 描边：高亮弦用红色，否则黑色
        final Paint strokePaint = Paint()
          ..color = isHighlighted ? highlightColor : fingerStroke
          ..strokeWidth = isHighlighted ? highlightStroke : dotStroke
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(Offset(x, y), fingerRadius, strokePaint);

        // 指法数字（如 1/2/3/4）
        if (finger > 0) {
          final TextPainter fingerPainter = TextPainter(
            text: TextSpan(
              text: finger.toString(),
              style: TextStyle(
                color: const Color(0xFFFFFFFF),
                fontSize: fingerRadius * 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          fingerPainter.paint(
            canvas,
            Offset(x - fingerPainter.width / 2, y - fingerPainter.height / 2),
          );
        }
      }

      // 高亮拨弦态（即便 fret == 0/-1 也可高亮，仅加描边光晕）
      if (highlightedString == i && (fret == 0 || fret == -1)) {
        final Paint glowPaint = Paint()
          ..color = highlightColor
          ..strokeWidth = highlightStroke
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(
          Offset(x, gridTop - symbolOffsetY),
          symbolRadius * 1.4,
          glowPaint,
        );
      }
    }
  }

  /// 计算统一缩放因子（取 min，保证等比不变形 + 不越界）。
  static double _scaleOf(Size size) {
    final double scaleX = size.width / designWidth;
    final double scaleY = size.height / designHeight;
    final double s = scaleX < scaleY ? scaleX : scaleY;
    // 防御性下限：即使宿主给 0 尺寸也不能除零
    return s <= 0 ? 1.0 : s;
  }

  /// 绘制空弦圈 O。
  void _drawOpenO(
    Canvas canvas,
    double cx,
    double cy,
    double radius,
    double stroke,
    Color color,
  ) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(cx, cy), radius, p);
  }

  /// 绘制闷音叉 X。
  void _drawMutedX(
    Canvas canvas,
    double cx,
    double cy,
    double radius,
    double stroke,
    Color color,
  ) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(cx - radius, cy - radius),
      Offset(cx + radius, cy + radius),
      p,
    );
    canvas.drawLine(
      Offset(cx + radius, cy - radius),
      Offset(cx - radius, cy + radius),
      p,
    );
  }

  @override
  bool shouldRepaint(ChordCardPainter oldDelegate) {
    return oldDelegate.chord != chord ||
        oldDelegate.highlightedString != highlightedString;
  }
}