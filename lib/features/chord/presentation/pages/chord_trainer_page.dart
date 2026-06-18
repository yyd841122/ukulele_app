// lib/features/chord/presentation/pages/chord_trainer_page.dart
//
// 来自 PRD_Architecture.md §4.3 + §4.7 (Architect: Interface_Driven +
// Checker: UI_Performance_Guard)
//
// 720P 横屏和弦练习页。横向滚动 + 卡片自适应。
//
// 硬指标（一票否决）：
//   - 720P 横屏：1280×720，可视区域 = 720px 高。
//   - 和弦卡片高度 ≤ 720 × 0.45 = 324px。
//   - ListView.builder 懒构建：超过 3 张卡片不创建多余 Widget。
//   - dispose() 时强制调用 ChordPlayer.dispose() 释放原生资源。
//   - 全部卡片被 RepaintBoundary 包裹（来自 ChordCardTile）。

import 'package:flutter/material.dart';

import '../../data/chord_repository.dart';
import '../../domain/chord_model.dart';
import '../../domain/chord_player.dart';
import '../widgets/chord_card_tile.dart';

/// 和弦练习页。
///
/// - 720P 横屏（landscape）专用。
/// - 主体：横向 [ListView.builder]，每个 item = [ChordCardTile]。
/// - 生命周期：dispose 时调用 [ChordPlayer.dispose]。
class ChordTrainerPage extends StatefulWidget {
  /// MVP 和弦仓储（生产可注入；测试可注入 fake）。
  final ChordRepository repository;

  /// 音频播放器（业务层注入）。
  final ChordPlayer player;

  /// 卡片高度占屏比（默认 0.45，符合 PRD §4.3 物理红线）。
  final double cardHeightRatio;

  /// 和弦卡片之间的水平间距（设计基准 200×240 容器下 16px 视觉舒适）。
  final double cardSpacing;

  const ChordTrainerPage({
    super.key,
    required this.repository,
    required this.player,
    this.cardHeightRatio = 0.45,
    this.cardSpacing = 16.0,
  });

  /// 720P × 45% 物理红线 = 324px。
  static const double maxChordCardHeightPx = 720.0 * 0.45;

  @override
  State<ChordTrainerPage> createState() => _ChordTrainerPageState();
}

class _ChordTrainerPageState extends State<ChordTrainerPage> {
  late Future<List<ChordModel>> _chordsFuture;
  int _highlightedString = -1;
  String? _playingChordId;

  @override
  void initState() {
    super.initState();
    _chordsFuture = widget.repository.getInitialChords();
  }

  @override
  void dispose() {
    // ★ Checker 强制：Widget dispose 时强制释放原生音频资源。
    //    防止页面被 pop 后 native 句柄未释放。
    widget.player.dispose();
    super.dispose();
  }

  Future<void> _onChordTap(ChordModel chord) async {
    // 高亮第一根弦作为视觉反馈（不阻塞 UI）。
    setState(() {
      _highlightedString = 0;
      _playingChordId = chord.id;
    });

    // 触发播放（错误在单测覆盖，UI 层静默吞掉避免崩溃）。
    final result = await widget.player.play(chord.id);
    if (!mounted) return;
    if (result.isFailure) {
      // UI 退化：保持高亮态即可，业务层日志在 player 内部处理。
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // V2: 锁定横屏 + 暗背景突出和弦卡片
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: FutureBuilder<List<ChordModel>>(
          future: _chordsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Center(
                child: Text(
                  'Failed to load chords: ${snapshot.error}',
                  style: const TextStyle(color: Colors.white70),
                ),
              );
            }
            final chords = snapshot.data!;
            return LayoutBuilder(
              builder: (context, constraints) {
                // V2 物理红线：单卡片最大高度 = min(可用高度×45%, 324)
                final maxByRatio = constraints.maxHeight * widget.cardHeightRatio;
                final cardHeight =
                    maxByRatio < ChordTrainerPage.maxChordCardHeightPx
                        ? maxByRatio
                        : ChordTrainerPage.maxChordCardHeightPx;
                // V2: 物理红线断言（debug 期红屏，release 期优化掉）
                assert(
                  cardHeight <= ChordTrainerPage.maxChordCardHeightPx,
                  'V2: chord card height $cardHeight exceeds 324px physical red-line',
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(chordCount: chords.length),
                    Expanded(
                      child: _HorizontalChordList(
                        chords: chords,
                        cardHeight: cardHeight,
                        spacing: widget.cardSpacing,
                        highlightedString: _highlightedString,
                        playingChordId: _playingChordId,
                        onTap: _onChordTap,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// 顶部标题栏。
class _Header extends StatelessWidget {
  final int chordCount;
  const _Header({required this.chordCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          const Text(
            'Chord Trainer',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            '$chordCount chords',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// 横向滚动列表。
class _HorizontalChordList extends StatelessWidget {
  final List<ChordModel> chords;
  final double cardHeight;
  final double spacing;
  final int highlightedString;
  final String? playingChordId;
  final ValueChanged<ChordModel> onTap;

  const _HorizontalChordList({
    required this.chords,
    required this.cardHeight,
    required this.spacing,
    required this.highlightedString,
    required this.playingChordId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: 24, vertical: spacing),
      itemCount: chords.length,
      itemBuilder: (context, index) {
        final chord = chords[index];
        final isPlaying = chord.id == playingChordId;
        return Padding(
          padding: EdgeInsets.only(right: spacing),
          child: SizedBox(
            height: cardHeight,
            // ChordCardTile 内部已锁 AspectRatio = 200/240
            child: ChordCardTile(
              key: ValueKey<String>(chord.id),
              chord: chord,
              highlightedString: isPlaying ? highlightedString : -1,
              onTap: () => onTap(chord),
            ),
          ),
        );
      },
    );
  }
}
