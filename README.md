# 生徒会ポータル

スマートフォン利用を優先した、生徒会向けSPAです。認証・プロフィール・投稿・資料・投票・チャットはSupabaseを使用します。

## 構成

- `index.html`: アプリ本体。GitHub PagesのルートからHTTPSで配信します。
- `supabase/schema.sql`: テーブル、Auth登録トリガー、RLS、RPC、非公開Storage bucketの初期スキーマです。
- `supabase/migrations/`: 既存DBへ機能を追加するSQLです。段階的な機能はファイル名順に適用します。

## セットアップ

1. 新しいSupabaseプロジェクトを作成します。
2. 新規プロジェクトの場合、Supabase SQL Editorで `supabase/schema.sql` を一度実行した後、`supabase/migrations/` のSQLをファイル名順に実行します。これは空の新規プロジェクト向けです。既存DBには `schema.sql` を再実行せず、未適用のマイグレーションだけを実行してください。
3. Supabase Authで顧問用ユーザーを作成し、SQL Editorで次のSQLのメールアドレスを置き換えて実行します。

	```sql
	update public.profiles
	set role = 'superadmin', status = 'approved', grade = 'admin', class_name = '生徒会顧問'
	where id = (select id from auth.users where email = 'teacher@example.com');
	```

4. `index.html` 内の `SUPABASE_URL` と `SUPABASE_ANON_KEY` に、SupabaseのProject URLとanon／publishable keyを設定します。`service_role` keyはブラウザーに置かないでください。
5. Supabase Authの許可URLに `https://yumirima1.github.io/Seitokai-TODO/` を設定し、GitHub Pagesで公開します。
6. 顧問アカウントでログインし、マイページから生徒会役員・管理者のロールを割り当てます。新規登録者は初期状態で一般生徒・承認待ちです。

## 運用上の注意

- DB権限の最終防衛線はRLSです。画面上の表示制御だけでアクセスを許可していません。
- 無記名投票では投票者本人以外に投票者IDを返しません。集計結果は全員に表示されます。
- 匿名チャットは一般利用者向けビューで投稿者情報を伏せ、管理者向けには実名と組を返します。
- 表示中のタブは5秒ごとに再取得します。ブラウザーを閉じた状態へのWeb Push通知は未実装です。
- 旧版でブラウザーのLocalStorageに保存されたデータは自動移行・削除しません。旧版のパスワードが保存されている場合は、必要なデータを確認した後にブラウザーのサイトデータを消去してください。
- 管理者ロール・匿名発言・資料の監査ログを運用する際は、学校のプライバシー方針に合わせて保存期間と閲覧権限を定めてください。
- `20261107_phase1_tasks_notifications.sql` はプロジェクト・タスク・進捗コメント・通知・通知設定を追加します。タスク情報は役員以上に限定され、担当者も承認済み役員以上から選択されます。削除は論理削除です。
- 通知センターには投稿、チャット、投票、予定、資料、タスクの通知が表示されます。タスク・投票の期限通知は利用者がポータルを開いている間に定期確認されます。バックグラウンド通知やWeb PushにはSupabase Cron/Push基盤が別途必要です。
- 同じ `20261107_phase1_tasks_notifications.sql` には出欠確認、議事録、資料分類・検索・お気に入り・閲覧履歴・更新履歴、組織図、活動履歴、年度引き継ぎも追加しています。引き継ぎ時は完了済みタスクのプロジェクトと資料・議事録・活動記録を論理アーカイブし、未完了タスクは残します。旧情報の上書き・物理削除はしません。
- 新しいSupabaseプロジェクトには `schema.sql` を実行してから、このマイグレーションをファイル名順に実行してください。既存環境では未適用のマイグレーションだけを適用し、利用者の多い時間帯を避けて実行結果を確認してください。