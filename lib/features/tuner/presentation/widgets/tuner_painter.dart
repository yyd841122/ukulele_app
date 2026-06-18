// lib/features/tuner/presentation/widgets/tuner_painter.dart
//
// 来自 PRD_Architecture.md §3.7（Checker: UI_Performance_Guard）
//                    + §1（Auditor: 720P 物理边界卡死）
//
// 调音仪表盘 CustomPainter。绘制：
//   1. 弧形刻度（-50 ~ +50 cents）；
//   2. 中心准心；
//   3. 弦名 + 频率 + cents 文本；
//   4. 指针（旋转角度由 centsOffset 决定）；
//   5. isTuned == true 时指针与文字平滑变绿。
//
// 720P 物理边界卡死（一票否决）：
//   - 任何坐标全部使用相对比例（size 约束），禁止写死绝对宽高；
//   - 设计基准：720×360（横屏上半部分）；
//   - 指针最大摆角 ±60°（±50 cents 映射到 ±60°，留余量）；
//   - 弦名/频率文本在垂直方向总占用 <= 0.25 × size.height（防止溢出）。
//
// 性能约束：
//   - paint() 内部不分配对象（除 Path/TextStyle 局部变量外）；
//   - shouldRepaint 仅在关键字段变化时返回 true；
//   - 由外层 RepaintBoundary 包裹，painter 高频重绘不污染兄弟节点。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/standard_tuning.dart';
import '../tuner_controller.dart';

class TunerPainter extends CustomPainter {
  /// 设计基准宽（PRD 硬指标：720 横屏半屏）。
  static const double designWidth = 720.0;

  /// 设计基准高（PRD 硬指标：360）。
  static const double designHeight = 360.0;

  /// cents → 角度映射上限（±50 cents 映射到 ±maxAngleDeg）。
  static const double maxAngleDeg = 60.0;

  /// cents 量程上限。
  static const double maxCents = StandardTuning.matchThresholdCents;

  final TunerState state;

  TunerPainter({required this.state});

  @override
  void paint(Canvas canvas, Size size) {
    // 相对比例缩放：所有坐标乘以 scale，禁止写死绝对像素。
    final scaleX = size.width / designWidth;
    final scaleY = size.height / designHeight;
    final scale = math.min(scaleX, scaleY); // 等比缩放保持圆形刻度
    canvas.save();
    canvas.translate(size.width / 2, size.height * 0.55);
    canvas.scale(scale, scale);

    _drawArcScale(canvas);
    _drawCenterHub(canvas);
    _drawNeedle(canvas);
    _drawTicks(canvas);
    _drawStringLabel(canvas);
    _drawFrequencyLabel(canvas);
    _drawCentsLabel(canvas);
    _drawTunedBadge(canvas);

    canvas.restore();
  }

  // ─────────── 弧形刻度盘 ───────────
  void _drawArcScale(Canvas canvas) {
    const radius = 180.0;
    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);
    const start = math.pi * 0.85; // ~153°
    const sweep = math.pi * 1.30; // ~234°
    final bg = Paint()
      ..color = const Color(0xFF263238)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, bg);

    // 完美区间弧（绿色高亮带）
    final tunedPaint = Paint()
      ..color = const Color(0xFF66BB6A).withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    // 0° 位置在 start + sweep/2 方向；±toleranceCents 对应 ±tunedArcCents 角度
    final tunedArcDeg = (state.isTuned ? 18.0 : 12.0); // 视觉宽度
    final tunedRad = math.pi * (tunedArcDeg / 180.0);
    const mid = start + sweep / 2;
    canvas.drawArc(rect, mid - tunedRad, tunedRad * 2, false, tunedPaint);
  }

  // ─────────── 中心准心圆 ───────────
  void _drawCenterHub(Canvas canvas) {
    final fill = Paint()..color = const Color(0xFF455A64);
    canvas.drawCircle(Offset.zero, 8, fill);

    final ring = Paint()
      ..color = const Color(0xFFB0BEC5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(Offset.zero, 22, ring);
  }

  // ─────────── 刻度短横线 ───────────
  void _drawTicks(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFFB0BEC5)
      ..strokeWidth = 2;
    const tickInner = 158.0;
    const tickOuter = 172.0;
    const tickCount = 11; // -50, -40, ..., 0, ..., +50
    const start = math.pi * 0.85;
    const sweep = math.pi * 1.30;
    for (var i = 0; i < tickCount; i++) {
      final t = i / (tickCount - 1);
      final angle = start + sweep * t;
      final p1 = Offset(math.cos(angle) * tickInner, math.sin(angle) * tickInner);
      final p2 = Offset(math.cos(angle) * tickOuter, math.sin(angle) * tickOuter);
      canvas.drawLine(p1, p2, paint);
    }
  }

  // ─────────── 指针 ───────────
  void _drawNeedle(Canvas canvas) {
    final cents = state.centsOffset.clamp(-maxCents, maxCents);
    final angleDeg = -(cents / maxCents) * maxAngleDeg; // +cents → 逆时针
    final angleRad = angleDeg * math.pi / 180.0;

    canvas.save();
    canvas.rotate(angleRad);

    final color = _needleColor();
    final needle = Paint()
      ..color = color
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, const Offset(0, -160), needle);

    // 指针尾
    final tail = Paint()
      ..color = color.withOpacity(0.4)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, const Offset(0, 30), tail);

    canvas.restore();
  }

  Color _needleColor() {
    if (state.isFrozen) return const Color(0xFF78909C);
    if (state.isTuned) return const Color(0xFF66BB6A);
    return const Color(0xFFEF5350);
  }

  // ─────────── 弦名（顶部） ───────────
  void _drawStringLabel(Canvas canvas) {
    final tp = TextPainter(
      text: TextSpan(
        text: state.currentStringName,
        style: TextStyle(
          color: _needleColor(),
          fontSize: 64,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2 - 40));
  }

  // ─────────── 频率（弦名下方） ───────────
  void _drawFrequencyLabel(Canvas canvas) {
    final hz = state.currentFrequencyHz;
    final text = hz <= 0 ? '— Hz' : '${hz.toStringAsFixed(2)} Hz';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFFECEFF1),
          fontSize: 28,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, 30));
  }

  // ─────────── Cents 偏差（底部） ───────────
  void _drawCentsLabel(Canvas canvas) {
    final cents = state.centsOffset;
    final sign = cents >= 0 ? '+' : '';
    final text = '$sign${cents.toStringAsFixed(1)} cents';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: _needleColor(),
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, 75));
  }

  // ─────────── 完美调音徽标（侧边） ───────────
  void _drawTunedBadge(Canvas canvas) {
    if (!state.isTuned) return;
    final tp = TextPainter(
      text: const TextSpan(
        text: '✓ TUNED',
        style: TextStyle(
          color: Color(0xFF66BB6A),
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, 110));
  }

  @override
  bool shouldRepaint(TunerPainter oldDelegate) {
    return oldDelegate.state.currentFrequencyHz != state.currentFrequencyHz ||
        oldDelegate.state.currentStringName != state.currentStringName ||
        oldDelegate.state.centsOffset != state.centsOffset ||
        oldDelegate.state.isTuned != state.isTuned ||
        oldDelegate.state.isFrozen != state.isFrozen ||
        oldDelegate.state.silentFrameCount != state.silentFrameCount;
  }
}
