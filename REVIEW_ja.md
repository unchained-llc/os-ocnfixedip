# OCN Fixed IP プラグイン全体調査

調査日: 2026-10-28。対象: ローカル `main` の `3ce3e5b` を基準とするソース一式。

## 修正後の状況（2026-10-28、2026.10.28）

| 初回の指摘 | 対応 |
|---|---|
| restart・無効化のスキップ | 時刻による重複抑制を廃止し、configure/restart/stopを共通ロックで直列化 |
| WANエイリアスの残存 | デバイス・アドレス・所有状態を記録し、所有するアドレスを停止時とWAN変更時に削除 |
| Applyの誤った成功応答 | バックエンドの結果・失敗工程・警告をAPIと画面へ反映 |
| JSON・HTML未エスケープ | JSONシリアライザーとHTML出力時のエスケープを追加 |
| 更新処理の認証・待ち時間 | HTTPS証明書検証、転送全体10秒の制限、認証情報の引用と一時ファイルの後始末を追加 |
| WAN IPv6候補の選択 | 不適切な候補を除外し、複数の `/56` がある場合は曖昧なまま選択しない |
| 状態取得の負荷・失敗表示 | 5秒の共有キャッシュ、要求の重複防止、失敗項目と通信エラーの表示を追加 |
| 配布・検証基盤 | 導入前の必須ツール検査、LICENSE同梱、27件の回帰テスト、画面テスト、CIを追加 |

設定途中の失敗時には、直前のトンネル・経路・管理エイリアス・MSS用sysctlの復元を試みる。記録のない再起動後でも、契約のBR・IPv4/peer・IPv6計算式と一致する復元済みトンネルを認識する。それ以外の設定済み `gif0` は上書き・停止しない。BRのICMP応答失敗だけでIPv4インターネット疎通を失敗扱いにしないよう修正した。

日本語対応はドキュメントに限定する。UIの翻訳辞書、独自の表示言語切り替え、DOMの翻訳処理は含めない。パッケージには不要なPythonキャッシュ等を含めない。

確認済みの範囲は、macOSとFreeBSD上の隔離した回帰テスト27件、英語の画面ロジック、PHP・シェル・XML・JavaScriptの構文検査、FreeBSD 15 / amd64のpkg生成、ダッシュボード復旧とpkg内容の照合。回帰テストのネットワーク・設定変更・PHP呼び出しはモックに置き換えており、実際のルーター設定を変更しない。

実回線のプレフィックス更新、WAN切断・復旧、LAN NAT/MSS、停止・アンインストールを含む一連の実機統合試験は未完了。復元処理はベストエフォートであり、OPNsenseのインターフェース割り当ては保持する。配布pkgはFreeBSD 15 / amd64向けで、他環境では対象機上でローカルビルドする。

### 再起動検証で確認した障害と修正

FreeBSD 15で `net.inet.tcp.mss_ifmtu` が存在しないため、事前検証が失敗し、再起動後にWANエイリアスとMTUを設定できなかった。元の実装はsysctl失敗を無視して続行していたが、保存・復元機能の追加時に誤って必須化していた。

v2026.10.28ではOIDを任意とし、不在時にもconfigure/stop/rollbackを継続する。また、再起動で `/var/run` の所有記録が失われても、契約設定と一致する既存GIFを認識して設定を再開する。OID不在・状態記録なし・OPNsense復元済みGIFという起動条件と、OIDが消えた後の停止を回帰テストに追加した。

修正pkgをFreeBSD 15上でビルド・導入し、再起動後に残っていた状態からの復旧を確認した。トンネルMTU 1460、IPv4 Ping 3/3、IPv4 HTTPS 200、ヘルス `healthy` を確認。修正適用後の追加の実機再起動は実施していない。この修正を含む版をv2026.10.28として公開する。

## 初回調査について

以下はコミット `3ce3e5b` の実装に対する修正前の調査記録。ソースへのリンクも同コミットに固定している。現在の動作は上記の修正状況、README、実装リファレンスを参照。

調査範囲はシェル、PHPコントローラー、MVCモデル・フォーム・ACL・メニュー、Volt画面、ウィジェット、configd設定、OPNsenseフック、パッケージビルドと既存ドキュメント。

## 優先して修正する項目

### 1. 明示的なrestartと無効化Applyが重複抑制で無視される

優先度: 高。ローカルの隔離環境で再現確認済み。

根拠: [configure.sh の11～33行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh#L11)。3秒以内のタイムスタンプ確認が、restart引数とenabledの判定より先にあり、`exit 0` で終了する。

直前のApply後すぐに無効化してApplyしても、トンネルが残る場合がある。直後のrestartも実行されない。最初のconfigureが途中失敗してもタイムスタンプは残るため、再試行が成功扱いでスキップされる。

明示的なstop/無効化とrestartは重複抑制から除外し、configure同士の排他には別のロックを用いる。3秒を超えた処理の重複も、現在のタイムスタンプでは防げない。連続Apply、失敗直後の再試行、実行中のstopをVMで検証する。

### 2. 停止時にWANエイリアスを残したまま追跡情報を消す

優先度: 高。ソースから確認。

根拠: [teardown.sh の25～26行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/teardown.sh#L25)、[configure.sh の25行と54～80行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh#L25)。停止処理は記録ファイルを削除するが、WAN上のIPv6を削除しない。

restartは先にteardownするため、プレフィックス変更後のrestartで古いアドレスを特定できなくなる。WAN変更時も、旧エイリアスを現在選択しているWANから探すので、元のデバイスに残り得る。

管理対象を「デバイス名とIPv6アドレス」の組として記録し、停止時にはその組に一致するエイリアスだけを削除してから記録を消す。既存の管理外アドレスを誤って削除しないよう、所有権の扱いも必要。通常更新、restart、WAN変更、uninstallを検証する。

### 3. Apply APIがバックエンドの失敗を成功として返す

優先度: 高。ソースから確認。

根拠: [ServiceController.php の34～43行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/ServiceController.php#L34)。POSTかどうかは確認するが、`configdRun()` の結果を破棄して `result: ok` を返す。

WAN IPv6取得やトンネル作成の失敗があっても、Applyの応答で区別できない。また、configure内でもMTU設定、経路変更、Prefix Updateの一部の失敗は終了コードへ反映されない。

configdから構造化した結果を返し、必須工程の失敗と更新APIの警告をUIに表示する。成功・失敗の定義を先に決め、ログだけに頼らず失敗箇所を確認できるようにする。

### 4. 診断結果のJSON生成とHTML表示が未エスケープ

優先度: 高。JSON破損とマークアップの伝搬をローカルで再現確認済み。ブラウザーでのスクリプト実行は未検証。

根拠: [diagnostics.sh の406～407行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/diagnostics.sh#L406)、[diagnostics.volt の91～95行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/mvc/app/views/OPNsense/OCNFixedIP/diagnostics.volt#L91)、[同232～234行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/mvc/app/views/OPNsense/OCNFixedIP/diagnostics.volt#L232)。任意テキストのhostnameが更新先URLへ入り、そのURLを `%s` でJSON文字列へ挿入し、画面ではHTML文字列として表示する。

hostnameにダブルクォートが入ると診断JSONを解析できなくなった。また、`<b>marker</b>` のような文字列はJSONを通って表示関数へそのまま到達する。設定変更権限を持つ利用者などが入力を与える条件があり、無認証で悪用可能とは確認していない。更新先が不正な応答トークンを返す経路も同じJSON生成を通る。

JSONはシリアライザーで生成し、DOMには原則 `.text()` で挿入する。hostnameはOCNの仕様に沿った検証とURLエンコードも行う。JSONのエスケープだけではHTMLへの埋め込み問題は解消しない。

### 5. 更新APIの応答待ち時間と認証処理

優先度: 高（タイムアウト・証明書検証）、中（一時ファイル・入力文字の扱い）。ソースとcurl公式資料で確認。

根拠: [configure.sh の202～209行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh#L202)、[diagnostics.sh の370～375行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/diagnostics.sh#L370)。更新リクエストは `--connect-timeout 2` のみで `--max-time` がなく、接続後に応答が止まると長時間待機し得る。`-k` はHTTPS証明書検証を無効にする。[curl公式マニュアル](https://curl.se/docs/manpage.html#--connect-timeout)も、接続段階の制限と[転送全体の制限](https://curl.se/docs/manpage.html#--max-time)を区別している。

更新処理には全体の制限時間を設け、HTTPSは通常の証明書検証を有効にする。HTTPを契約で指定されている構成について、HTTPSへ単純置換して動作するとは今回確認していない。提供元の対応を確認して扱う。

`mktemp` / `chmod` の失敗判定と終了時のtrapも追加したい。認証情報のnetrcへの書き込みは空白・引用符・改行を考慮していないため、対応するcurlバージョンに合わせて正しくエスケープするか、許容文字を明確にする。更新先URLのログはhostnameトークンをマスクする。

## 続いて改善する項目

### 6. WAN IPv6の候補選択が不十分

優先度: 中。ULAが先にあるケースはローカルで再現確認済み。

根拠: [lib.sh の38～41行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/lib.sh#L38)。`fe80:` と `::1` で始まる文字列を除外し、先頭候補を採用する。グローバル到達性、一時アドレス、tentative/deprecated、PDとの関係は確認しない。

モックの `ifconfig` でULA `fd00::1`、次に `2001:db8::1` を返すとULAが選ばれた。`/^::1/` は `::1234` なども除外する一方、リンクローカル範囲全体をIPアドレスとして判定していない。

IPアドレスとして候補を検証し、実際のWAN/PD情報から安定した利用可能なアドレスを選ぶ。HGW下の `/60` と直接接続の `/56` を両方検証する。単に「最初のグローバルアドレス」に変更しても、PDと別 `/56` のWAN構成は解決しない。

### 7. 状態取得の負荷と障害時の表示

優先度: 中。ソースから確認。実機の実行時間・CPU負荷は未測定。

根拠: [status.sh](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/status.sh)、[general.volt の48～95行](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/src/opnsense/mvc/app/views/OPNsense/OCNFixedIP/general.volt#L48)。状態取得ごとにDNSと複数Pingを直列実行し、設定画面は5秒ごとに要求する。応答待ち中の再要求を防ぐフラグはない。ウィジェットからも同じ検査を呼ぶ。

軽い状態取得と能動的な疎通検査を分離し、後者を短時間キャッシュするか更新完了後に次の要求を予約する。特定の外部ICMP宛先への失敗は「回線断」と分けて表示する。

設定画面は `health_failures` を表示しないので、MTUや更新APIだけが失敗している場合に理由が分かりにくい。診断画面はAJAX失敗時の表示処理がなく、Checkingのまま残る可能性がある。失敗項目一覧とAPIエラー表示を加える。

### 8. パッケージと検証基盤

優先度: 中。ソースから確認。

[build-pkg.sh](https://github.com/unchained-llc/os-ocnfixedip/blob/3ce3e5b/os-ocnfixedip/tools/build-pkg.sh) は依存パッケージや対応OPNsenseバージョンをmanifestに記載しない。必須ツールが不足する環境では、インストール後に初めて失敗が分かる。対応するFreeBSD/OPNsenseでパッケージ名を確認して依存を宣言するか、事前検査を加える。管理者向けREADMEの `26.1+` は、全バージョンを継続検証した保証ではない。

BSD 2-Clause表記はあるが、独立したLICENSEファイルがなく、一部ソースのライセンスヘッダーも条件・免責の記載範囲が異なる。権利者と既存コードの由来を確認したうえで配布物のライセンス表記をそろえる。

自動テストは未整備。まず構文チェックと、今回再現した重複抑制・IPv6選択・JSON出力の回帰テストを追加し、次にVMで起動・更新・停止・アンインストールを検証する。パッケージ作成に成功することと、実機の通信が成功することは分けて扱う。

## ドキュメントへの反映

- 日本語READMEを英語版相当へ拡充。設定項目、NAT/MSS、計算例、ヘルス判定、診断16項目、ログ、障害対応、性能報告、ビルド、制約、認証情報の扱いを記載した。
- 導入コマンドはワイルドカードを使わず、`pkg add -f /root/os-ocnfixedip/dist/os-ocnfixedip-2026.10.28.pkg` のように1つのバージョンを明示する。
- 両言語のREADMEと実装リファレンスを、修正後のロック・停止処理・失敗応答・更新処理に合わせた。
- `ocnfixedip.md` の「旧DSLiteファイルをインストーラーが削除する」という現行フックに存在しない説明を修正した。
- リリース `v2026.10.28` の導入URLと、配布pkgの対象アーキテクチャを明記した。

## 初回調査時の検証方法と限界

ローカルの一時ディレクトリへ対象スクリプトをコピーし、設定・ネットワークコマンドをモックに置き換え、状態ファイルの保存先も隔離して確認した。実際のWAN・経路・OCN APIは操作していない。

確認できたものは、ダブルクォートを含むhostnameによる診断JSON破損、HTMLマークアップの無加工伝搬、直近タイムスタンプによるrestart/無効化のスキップ、ULAを優先するIPv6選択、およびREADMEのIPv6計算例。加えてシェル・XML・JavaScriptの構文とMarkdownのローカルリンクを検査した。

初回調査時はmacOS環境にPHP CLIとFreeBSDの `pkg` がなく、PHP構文検査と実パッケージビルドは未実施だった。修正後にFreeBSD環境で実施した検証は冒頭を参照。OPNsense VM、ブラウザー上の表示・スクリプト実行、実回線のプレフィックス更新、LAN NAT/MSS、性能の実測は別途必要。
