import 'package:flutter/material.dart';

/// 小さな選択チップ。色で意味を持たせず、選択だけを見せる。
class MiniChip extends StatelessWidget {
  const MiniChip({super.key, required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
          border: Border.all(
            color: selected ? scheme.primary.withValues(alpha: 0.45) : scheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 上だけの細い線。カードを使わず、線と余白だけで区切る。
class HairLine extends StatelessWidget {
  const HairLine({super.key});

  @override
  Widget build(BuildContext context) => Container(
        height: 0.5,
        color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
      );
}

/// 詳細の中の1行。「だれが」「いつまで」「くりかえし」を畳んで置く。
class AttrRow extends StatelessWidget {
  const AttrRow({super.key, required this.label, required this.value, required this.onTap});

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 76,
              child: Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}
