import 'package:flutter/material.dart';

import 'session.dart';

/// サーバーとのやり取り。相手の既読・受諾を示すものではない。
class SyncStatusLine extends StatelessWidget {
  const SyncStatusLine({super.key, required this.session, this.onRetry});
  final SyncSession session;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final storage = session.storage ?? session.store.storage;
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.store, storage]),
      builder: (context, _) {
        final saveError = storage?.lastSaveError != null;
        final failed = session.lastError != null;
        final saving = storage?.isSaving == true;
        final pending = session.hasPendingChanges;
        final String label;
        if (saveError) {
          label = '端末に保存できません・閉じずに再試行';
        } else if (saving) {
          label = '端末に保存中';
        } else if (session.isSyncing) {
          label = pending ? '送信・同期中' : '同期中';
        } else if (failed) {
          label = pending ? '同期できません・送信待ち' : '同期できません';
        } else if (pending) {
          label = storage == null ? '送信待ち' : '端末に保存済み・送信待ち';
        } else {
          label = session.lastSyncedAt == null ? '同期を確認中' : 'サーバーと同期済み';
        }
        return Padding(
          key: const ValueKey('sync-status'),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: saveError || failed || pending,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: (saveError || failed)
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (saveError || failed || pending)
                TextButton(
                  onPressed: session.isSyncing || saving
                      ? null
                      : () async {
                          await storage?.flush();
                          try {
                            if (onRetry != null) {
                              await onRetry!();
                            } else {
                              await session.syncNow();
                            }
                          } catch (_) {
                            // 状態表示に残す。端末の記録を消さない。
                          }
                        },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: Text(saveError || failed ? '再試行' : '今すぐ送る'),
                ),
            ],
          ),
        );
      },
    );
  }
}
