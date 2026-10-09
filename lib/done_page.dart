import 'package:flutter/material.dart';

import 'detail_page.dart';
import 'format.dart';
import 'model.dart';
import 'store.dart';

/// おわったものの一覧。履歴は端末内の現在の世帯の記録だけで検索する。
/// 並びは新しい順。押すと詳細に飛ぶ。
class DonePage extends StatefulWidget {
  const DonePage({super.key, required this.store, this.linkFor});

  final IssueStore store;
  final Future<String?> Function(Issue)? linkFor;

  @override
  State<DonePage> createState() => _DonePageState();
}

class _DonePageState extends State<DonePage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final done = widget.store.doneHistory;
        final query = _search.text.trim().toLowerCase();
        // A linear scan of the locally projected history is adequate for
        // years of household tasks and requires no network connection.
        final matches = query.isEmpty
            ? done
            : done.where(
                (issue) => issue.title.toLowerCase().contains(query),
              ).toList();
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
          body: Column(
            children: [
              if (done.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    key: const ValueKey('done-title-search'),
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'おわったものを検索',
                      hintText: 'タイトルで探す',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: query.isNotEmpty
                          ? IconButton(
                              tooltip: '検索をクリア',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                            )
                          : null,
                    ),
                  ),
                ),
              Expanded(
                child: done.isEmpty
                    ? Center(
                        child: Text(
                          'まだおわったものはない',
                          style: TextStyle(
                            fontSize: 13.5,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : matches.isEmpty
                    ? const Center(child: Text('一致する用事はありません'))
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: matches.length,
                        separatorBuilder: (context, _) => const Padding(
                          padding: EdgeInsets.only(left: 20),
                          child: Divider(height: 1, thickness: 0.5),
                        ),
                        itemBuilder: (context, index) {
                          final issue = matches[index];
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
                                  : '${timeLabel(at, widget.store.now)}におわった',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => DetailPage(
                                  store: widget.store,
                                  issueId: issue.id,
                                  linkFor: widget.linkFor,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
