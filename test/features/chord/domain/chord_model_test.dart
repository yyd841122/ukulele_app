// test/features/chord/domain/chord_model_test.dart
//
// 来自 PRD_Architecture.md §4.2 / §4.3 / §4.5 / §4.7 / §4.8 (Auditor + Checker)
//
// ChordModel 与 ChordCardPainter / ChordCardTile 的 TDD 强契约：
//   1) 合法实例化（C / G 等标准和弦）
//   2) 非法数据 → AssertionError（长度 / 范围）
//   3) 720P 极限 200×324 容器下渲染 0 抛错、0 溢出
//   4) RepaintBoundary 隔离、shouldRepaint 行为正确

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ukulele_app/features/chord/domain/chord_model.dart';
import 'package:ukulele_app/features/chord/presentation/widgets/chord_card_painter.dart';
import 'package:ukulele_app/features/chord/presentation/widgets/chord_card_tile.dart';

const Duration _kDemoNote = Duration(milliseconds: 1500);

ChordModel _chord({
  String id = 'C',
  String name = 'C',
  List<int>? frets,
  List<int>? fingers,
  int rootFret = 0,
  String audioAsset = 'audio/c.wav',
}) {
  return ChordModel(
    id: id,
    name: name,
    frets: frets ?? const [0, 0, 0, 3],
    fingers: fingers ?? const [0, 0, 0, 3],
    rootFret: rootFret,
    audioAsset: audioAsset,
    demoNoteMs: _kDemoNote,
  );
}

void main() {
  group('ChordModel — Architect: Data_Protocol', () {
    test('C 和弦 [0,0,0,3] 正常实例化', () {
      final c = _chord(frets: const [0, 0, 0, 3], fingers: const [0, 0, 0, 3]);
      expect(c.id, 'C');
      expect(c.frets, [0, 0, 0, 3]);
      expect(c.fingers, [0, 0, 0, 3]);
    });

    test('G 和弦 [0,2,3,2] 正常实例化', () {
      final g = _chord(
        id: 'G',
        name: 'G',
        frets: const [0, 2, 3, 2],
        fingers: const [0, 1, 2, 3],
      );
      expect(g.id, 'G');
      expect(g.frets, [0, 2, 3, 2]);
      expect(g.hasOpen, isTrue);
    });

    test('Am 和弦 [2,0,0,0] 包含空弦', () {
      final am = _chord(
        id: 'Am',
        name: 'Am',
        frets: const [2, 0, 0, 0],
        fingers: const [2, 0, 0, 0],
      );
      expect(am.hasOpen, isTrue);
      expect(am.hasMuted, isFalse);
    });

    test('含 -1 闷音时 hasMuted=true', () {
      final m = _chord(
        frets: const [-1, 0, 0, 3],
        fingers: const [0, 0, 0, 3],
      );
      expect(m.hasMuted, isTrue);
    });

    test('== 与 hashCode 一致（数据相等性）', () {
      final a = _chord();
      final b = _chord();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('ChordModel — Auditor: Metric_Hardening / Fail-fast assert', () {
    test('frets.length != 4 抛 AssertionError', () {
      expect(
        () => _chord(frets: const [0, 0, 0]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('frets.length == 5 抛 AssertionError', () {
      expect(
        () => _chord(frets: const [0, 0, 0, 3, 3]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('fingers.length != 4 抛 AssertionError', () {
      expect(
        () => _chord(fingers: const [0, 0]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('fret = 15 越界（> 12）抛 AssertionError', () {
      expect(
        () => _chord(frets: const [0, 0, 0, 15]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('fret = -2 越界（< -1）抛 AssertionError', () {
      expect(
        () => _chord(frets: const [-2, 0, 0, 3]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('finger = 5 越界（> 4）抛 AssertionError', () {
      expect(
        () => _chord(fingers: const [0, 0, 0, 5]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rootFret = 13 越界抛 AssertionError', () {
      expect(
        () => _chord(rootFret: 13),
        throwsA(isA<AssertionError>()),
      );
    });

    test('边界值 fret = 12 / fret = -1 通过', () {
      expect(
        () => _chord(frets: const [12, -1, 0, 3]),
        returnsNormally,
      );
    });
  });

  group('ChordCardPainter — shouldRepaint 语义', () {
    test('chord 不变 + highlight 不变 → 不重绘', () {
      final p1 = ChordCardPainter(chord: _chord(), highlightedString: -1);
      final p2 = ChordCardPainter(chord: _chord(), highlightedString: -1);
      expect(p2.shouldRepaint(p1), isFalse);
    });

    test('chord 变化 → 必须重绘', () {
      final p1 = ChordCardPainter(chord: _chord(id: 'C'), highlightedString: -1);
      final p2 = ChordCardPainter(
        chord: _chord(id: 'G', frets: const [0, 2, 3, 2]),
        highlightedString: -1,
      );
      expect(p2.shouldRepaint(p1), isTrue);
    });

    test('highlightedString 变化 → 必须重绘', () {
      final p1 = ChordCardPainter(chord: _chord(), highlightedString: -1);
      final p2 = ChordCardPainter(chord: _chord(), highlightedString: 0);
      expect(p2.shouldRepaint(p1), isTrue);
    });
  });

  group('ChordCardPainter — Checker: 720P 极限渲染', () {
    Widget wrap(Size size, ChordModel chord, {int highlight = -1}) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: ChordCardTile(
                chord: chord,
                highlightedString: highlight,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('设计基准 200×240 渲染 0 抛错', (tester) async {
      await tester.pumpWidget(wrap(
        const Size(200, 240),
        _chord(),
      ));
      await tester.pump();
      expect(find.byType(ChordCardTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('极限压缩 200×324（720P × 45% 物理红线）0 抛错 0 溢出',
        (tester) async {
      await tester.pumpWidget(wrap(
        const Size(200, 324),
        _chord(),
      ));
      await tester.pump();
      expect(find.byType(ChordCardTile), findsOneWidget);
      // 渲染过程不能抛错
      expect(tester.takeException(), isNull);
    });

    testWidgets('极窄 60×100 容器 0 抛错（极限压扁）', (tester) async {
      await tester.pumpWidget(wrap(
        const Size(60, 100),
        _chord(frets: const [0, 2, 3, 2], fingers: const [0, 1, 2, 3]),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('G 和弦 720P 极限渲染 0 抛错', (tester) async {
      await tester.pumpWidget(wrap(
        const Size(200, 324),
        _chord(id: 'G', frets: const [0, 2, 3, 2], fingers: const [0, 1, 2, 3]),
        highlight: 1,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('闷音和弦 [X,0,0,3] 720P 渲染 0 抛错', (tester) async {
      await tester.pumpWidget(wrap(
        const Size(200, 324),
        _chord(frets: const [-1, 0, 0, 3], fingers: const [0, 0, 0, 3]),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('rootFret = 5（非开放和弦）720P 渲染 0 抛错', (tester) async {
      await tester.pumpWidget(wrap(
        const Size(200, 324),
        _chord(
          frets: const [5, 7, 7, 6],
          fingers: const [1, 3, 4, 2],
          rootFret: 5,
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('ChordCardTile — Checker: UI_Performance_Guard', () {
    testWidgets('RepaintBoundary 包裹 CustomPaint', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChordCardTile(chord: _chord()),
          ),
        ),
      );
      // 必须存在 RepaintBoundary
      expect(
        find.descendant(
          of: find.byType(ChordCardTile),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('高亮拨弦态变更不抛错', (tester) async {
      Widget app = MaterialApp(
        home: Scaffold(
          body: ChordCardTile(chord: _chord(), highlightedString: -1),
        ),
      );
      await tester.pumpWidget(app);
      await tester.pump();

      // 切换到第 3 根弦高亮
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChordCardTile(chord: _chord(), highlightedString: 3),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('多个 ChordCardTile 并列存在（兄弟节点隔离）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChordCardTile(chord: _chord(id: 'C')),
                  ChordCardTile(
                    chord: _chord(
                      id: 'G',
                      frets: const [0, 2, 3, 2],
                      fingers: const [0, 1, 2, 3],
                    ),
                  ),
                  ChordCardTile(
                    chord: _chord(id: 'Am', frets: const [2, 0, 0, 0]),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ChordCardTile), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });
  });

  group('ChordCardPainter — 几何常量硬指标', () {
    test('设计基准宽 = 200 / 高 = 240（< 324 物理红线）', () {
      expect(ChordCardPainter.designWidth, 200.0);
      expect(ChordCardPainter.designHeight, 240.0);
      // 240 < 324 — 满足 PRD §4.3 一票否决
      expect(ChordCardPainter.designHeight, lessThan(324.0));
    });

    test('可见品格数 = 5', () {
      expect(ChordCardPainter.fretCount, 5);
    });
  });
}