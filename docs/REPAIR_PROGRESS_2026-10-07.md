# レビュー修正の進捗（2026-10-07）

リポジトリ: https://github.com/neoenox/ie_koto （非公開）。レビューの13件をIssue #1〜#13として登録してから修正を開始した。

修正ブランチ: `fix/review-data-integrity`。

## 最初の修正

- #3: 受信ページをストアへ取り込んで保存してからcursorを確定する。次ページが失敗しても、再起動後に取得済み記録が残る。
- #4: 世帯seqの番号確保とop挿入を一つのD1 batchに含める。遅れた送信のopが既に公開したcursorより前に挿入されなくなる。

両方とも回帰テストが修正前に失敗し、修正後に成功した。

検証: `flutter analyze` 問題なし、`flutter test --reporter expanded` 126件成功、`server` の `npm test` 18件成功、`git diff --check` 成功。

未対応: #1、#2、#5〜#13。Issueはすべて開いたまま。特に端末IDの既存データ移行、共有リンクの権限制限、世帯ごとの保存分離は追加の修正が必要。

今回の検証はローカル環境で行った。SharedPreferencesの終了直前の書き込み耐久性、Android実機、Cloudflare本番での確認は未実施。マージ・デプロイは行っていない。
