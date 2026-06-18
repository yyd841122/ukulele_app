// lib/features/tuner/presentation/pages/tuner_page.dart
//
// 来自 PRD_Architecture.md §3.7（Checker: UI_Performance_Guard）
//                    + §3.6（Auditor: 60fps 节流）
//
// 调音器主页面（横屏 720P 适配）。
//
// 核心约束：
//   - 必须使用 RepaintBoundary 包裹 CustomPaint（指针独立 Canvas Layer）；
//   - 横向布局：左侧调音仪表盘 + 右侧"开始/停止"按钮 + 状态栏；
//   - 720P 物理边界：可用宽度 1280px，可推导出仪表盘与按钮列的最大占比。

import 'package:flutter/material.dart';

import '../tuner_controller.dart';
import '../widgets/tuner_painter.dart';

class TunerPage extends StatefulWidget {
  final TunerController controller;

  const TunerPage({super.key, required this.controller});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    final c = widget.controller;
    if (c.isRunning) {
      await c.stop();
    } else {
      await c.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final state = c.state;
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            return Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildDialPanel(state),
                ),
                SizedBox(
                  width: constraints.maxWidth * 0.32,
                  child: _buildControlPanel(c, state),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildDialPanel(TunerState state) {
    return Center(
      child: AspectRatio(
        aspectRatio: 2.0, // 720P 半屏比例 720:360 = 2:1
        child: RepaintBoundary(
          child: CustomPaint(
            painter: TunerPainter(state: state),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }

  Widget _buildControlPanel(TunerController c, TunerState state) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusChip(c.isRunning, state),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            key: const Key('tuner_toggle_button'),
            onPressed: _toggle,
            icon: Icon(c.isRunning ? Icons.stop : Icons.play_arrow),
            label: Text(
              c.isRunning ? '停止' : '开始调音',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.isRunning
                  ? const Color(0xFFEF5350)
                  : const Color(0xFF66BB6A),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: c.reset,
            icon: const Icon(Icons.refresh),
            label: const Text('重置'),
          ),
          const SizedBox(height: 32),
          _infoLine('最近弦', state.currentStringName),
          _infoLine('频率', state.currentFrequencyHz <= 0
                  ? '— Hz'
                  : '${state.currentFrequencyHz.toStringAsFixed(2)} Hz'),
          _infoLine('Cents', state.centsOffset.toStringAsFixed(1)),
          _infoLine('状态',
              state.isFrozen ? '已冻结' : (state.isTuned ? '完美调音' : '调音中')),
        ],
      ),
    );
  }

  Widget _statusChip(bool running, TunerState state) {
    final color = state.isFrozen
        ? const Color(0xFF78909C)
        : (state.isTuned ? const Color(0xFF66BB6A) : const Color(0xFFFFCA28));
    final label = state.isFrozen
        ? 'FROZEN'
        : (state.isTuned ? 'TUNED' : (running ? 'LISTENING' : 'IDLE'));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
    );
  }

  Widget _infoLine(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            key,
            style: const TextStyle(color: Color(0xFFB0BEC5), fontSize: 16),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFECEFF1),
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
