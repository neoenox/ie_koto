import 'package:flutter/material.dart';

import 'detail_page.dart';
import 'format.dart';
import 'model.dart';
import 'store.dart';

/// おわったものの一覧。後から探す用（ホームの「今日・あとで」とは別）。
/// 並びは新しい順。押すと詳細に飛ぶ。
class DonePage extends StatelessWidget {
  const DonePage({super.key, required this.store, this.linkFor});

  final IssueStore store;
  final Future<String?> Function(Issue)? linkFor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final done = store.doneHistory;
        return Scaffold(
          appBar: AppBar(
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: 'もどる',
            ),
            title: const Text(
              'おわったもの',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          body: done.isEmpty
              ? Center(
                  child: Text(
                    'まだおわったものはない',
                    style: TextStyle(
                      fontSize: 13.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: done.length,
                  separatorBuilder: (context, _) => const Padding(
                    padding: EdgeInsets.only(left: 20),
                    child: Divider(height: 1, thickness: 0.5),
                  ),
                  itemBuilder: (context, index) {
                    final issue = done[index];
                    final at = issue.completedAt;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      title: Text(
                        issue.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        at == null
                            ? 'おわった'
                            : '${timeLabel(at, store.now)}におわった',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DetailPage(
                            store: store,
                            issueId: issue.id,
                            linkFor: linkFor,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
