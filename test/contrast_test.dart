import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';

/// WCAG 2.1 の相対輝度とコントラスト比。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  testWidgets('#70 本文・説明文・エラー・強調のコントラストがAA(4.5:1)を満たす', (tester) async {
    await tester.pumpWidget(IeKotoApp(store: IssueStore()));
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(Scaffold).first);
    final theme = Theme.of(ctx);
    final scheme = theme.colorScheme;
    final scaffold = theme.scaffoldBackgroundColor;
    final surface = scheme.surface;

    // 選択チップの背景は primary を12%重ねたもの（[lib/widgets.dart] の MiniChip）。
    final selectedChipBg = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.12),
      surface,
    );

    final cases = <String, (Color fg, Color bg)>{
      '本文 onSurface / 背景': (scheme.onSurface, scaffold),
      '本文 onSurface / surface': (scheme.onSurface, surface),
      '説明文 onSurfaceVariant / 背景': (scheme.onSurfaceVariant, scaffold),
      '説明文 onSurfaceVariant / surface': (scheme.onSurfaceVariant, surface),
      'エラー error / 背景': (scheme.error, scaffold),
      '強調・リンク primary / 背景': (scheme.primary, scaffold),
      '強調・リンク primary / surface': (scheme.primary, surface),
      '通知 onErrorContainer / errorContainer': (
        scheme.onErrorContainer,
        scheme.errorContainer,
      ),
      '選択チップ primary / 選択背景': (scheme.primary, selectedChipBg),
    };

    final lines = <String>[];
    cases.forEach((name, pair) {
      final ratio = _contrast(pair.$1, pair.$2);
      lines.add('$name = ${ratio.toStringAsFixed(2)}:1');
    });
    // ignore: avoid_print
    print('[contrast]\n${lines.join('\n')}');

    cases.forEach((name, pair) {
      final ratio = _contrast(pair.$1, pair.$2);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: '$name が ${ratio.toStringAsFixed(2)}:1（AAは4.5:1以上）',
      );
    });
  });
}
