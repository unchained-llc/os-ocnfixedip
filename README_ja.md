# OPNsense 用 OCN 固定IP（IPoE）プラグイン

[English](./README.md) | [日本語](./README_ja.md)

**OCN 固定IP（IPoE）**専用の OPNsense プラグインです。IPv4 over IPv6（IPIP）トンネルを `gif0` に構成し、固定IPv4の経路とプレフィックス更新を管理します。

> [!IMPORTANT]
> 本プラグインはコミュニティによる実装であり、NTTドコモビジネスや OPNsense の公式製品ではありません。
> Apply によりシステムのIPv4デフォルトルートが切り替わります。設定のバックアップを取得し、コンソールなど別の管理経路を確保して作業してください。

## スクリーンショット

### 設定（Settings）

![OCN 固定IPの設定画面](./Settings.png)

### 診断（Diagnostics）

![OCN 固定IPの診断画面](./Diagnostics.png)

## 目次

- [概要](#概要)
- [通信の仕組み](#通信の仕組み)
- [対応サービス](#対応サービス)
- [要件](#要件)
- [導入前の準備](#導入前の準備)
- [インストール](#インストール)
- [初期設定](#初期設定)
- [導入後に必要な設定](#導入後に必要な設定)
- [設定項目](#設定項目)
- [実行時の動作](#実行時の動作)
- [LAN側のIPv6プレフィックス追従](#lan側のipv6プレフィックス追従)
- [ログの確認](#ログの確認)
- [動作確認](#動作確認)
- [トラブルシューティング](#トラブルシューティング)
- [性能の参考値](#性能の参考値)
- [OPNsense上でのパッケージビルド](#opnsense上でのパッケージビルド)
- [アップグレードと再インストール](#アップグレードと再インストール)
- [アンインストール](#アンインストール)
- [既知の制約](#既知の制約)
- [セキュリティ上の注意](#セキュリティ上の注意)
- [開発者向け情報](#開発者向け情報)
- [ライセンス](#ライセンス)

## 概要

主な機能は次のとおりです。

- `gif0` に OCN 固定IP用のIPv4-in-IPv6トンネルを構成します。
- トンネル対向のIPv4アドレスは `192.0.0.1` 固定です。
- WANのIPv6アドレスを `/56` に正規化し、固定IPv4ブロックの開始アドレスからローカルトンネルIPv6を自動計算します。
- 起動・Apply・WANのIPv6更新時に OCN の Prefix Update API を呼び出します。
- `rc.newwanipv6` による再設定に対応し、アドレス取得を短時間リトライしてDHCPv6更新時のタイミング差を吸収します。
- プレフィックスやWANの変更時には、デバイスと所有状態を記録した古いWAN `/128` エイリアスを置き換えます。
- 認証には一時的な `netrc` ファイルを使い、ユーザーIDとパスワードを `curl` の引数に直接渡しません。
- 設定画面、ダッシュボードウィジェット、Diagnostics で状態を確認できます。

## 通信の仕組み

```text
LAN / VLAN の端末
       |
       | IPv4 + Outbound NAT
       v
OPNsense gif0（固定IPv4 → 192.0.0.1）
       |
       | IPv4-in-IPv6（IPIP）
       v
OCN の BR IPv6 エンドポイント
       |
       v
IPv4 インターネット
```

WANでは引き続きネイティブIPv6を使用します。本プラグインはWANのIPv6からトンネルのローカルエンドポイントを計算し、IPv4通信を `gif0` へ送ります。IPv6通信のアドレス変換は行いません。

プラグインが設定するのはトンネルと直近のIPv4デフォルトルートです。OPNsense のゲートウェイ設定、ファイアウォール、Outbound NAT、MSS正規化は管理者が別途設定します。

## 対応サービス

対応対象は **OCN 固定IP（IPoE）** です。汎用の DS-Lite / MAP-E プラグインではありません。

サービス情報は [NTTドコモビジネスの公式ページ](https://www.ntt.com/business/services/network/internet-connect/ocn-business/ftth.html)を参照してください。

## 要件

1. OPNsense 26.1 以降を対象とします。バージョンごとの動作は実機で確認してください。
2. WANでIPoEのネイティブIPv6が利用できること。
3. OCN 固定IPの契約情報がそろっていること。
4. OPNsense 上で `python3`、`curl` 7.84以降、`xmllint` と標準の FreeBSD ネットワークコマンドが利用できること。DNS診断には `drill`、`host`、`getent` のいずれかも使用します。
5. OPNsense のWeb UIおよび管理者シェルへアクセスできること。

典型的なWAN設定は、IPv4が DHCP または None（環境による）、IPv6が DHCPv6 です。

### フレッツ 光クロスのプレフィックス委譲

本リポジトリで想定している構成は次のとおりです。実際の委譲サイズは回線・HGW・契約の設定を確認してください。

| 構成 | 想定するPDサイズ | 補足 |
|---|---|---|
| 光クロス（10G） | `/56` | 元となる委譲プレフィックス |
| 光クロス（10G）でHGW配下に設置 | `/60` | 下流ルーターが `/60` を受ける構成 |

本プラグインのトンネルIPv6計算は、いずれも `/56` のベースへ正規化します。WANアドレスと委譲プレフィックスが別の `/56` に属する構成には、そのまま適用できません。

## 導入前の準備

OCN の開通案内や契約者向け画面から、次の情報を確認してください。例示のアドレスやトークンを実環境にそのまま使用しないでください。

| 項目 | 例 | 入力時の注意 |
|---|---|---|
| BR / AFTR IPv6 Endpoint | `2001:380:a120::a` | 契約で指定された対向IPv6アドレス |
| Fixed IPv4 Range Start | `203.0.113.96` | 割り当てブロックの先頭アドレス |
| Prefix Update URL | `http://ipoe-static.ocn.ad.jp/nic/update` | OCN指定の更新URL |
| Prefix Update Hostname | `ieabc123def456` | `hostname` クエリパラメーターに渡すトークン |
| Auth User ID | 契約ごとの値 | Prefix Update の認証ユーザーID |
| Auth Password | 契約ごとの値 | Prefix Update の認証パスワード |

現在のIPv4デフォルトルートを記録し、OPNsense の設定をエクスポートしてください。また、既存の `gif0` を他のサービスで使用していないことを確認します。所有記録と一致しない設定済み `gif0` がある場合は、上書きせず設定を失敗として返します。インストール時に事前作成された空の `gif0` は使用できます。

## インストール

### GitHub Releases から導入

以下はリポジトリに記載されている `v2026.07.22` の例です。最新版を示すものではありません。導入するバージョンとファイル名は [Releases](https://github.com/unchained-llc/os-ocnfixedip/releases) で確認してください。

```sh
pkg add -f https://github.com/unchained-llc/os-ocnfixedip/releases/download/v2026.07.22/os-ocnfixedip-2026.07.22.1155.pkg
```

### ローカルでビルドしたパッケージを導入

ローカルでビルドしたパッケージを導入します。

```sh
pkg add -f /root/os-ocnfixedip/dist/os-ocnfixedip-*.pkg
```

インストールフックは `configd` の再起動、OPNsense UIキャッシュの削除、存在しない場合の `gif0` 作成を行います。メニューとACLを読み込み直すため、Web UIを一度ログアウトして再ログインしてください。

`configctl ocnfixedip ...` が `Action not allowed or missing` を返す場合は、次を実行します。

```sh
service configd restart
```

## 初期設定

1. **Interfaces > OCN Fixed IP (IPoE) > Settings** を開きます。
2. ネイティブIPv6またはDHCPv6-PDを受けるWANインターフェースを選択します。
3. OCN指定のBR IPv6と固定IPv4ブロックの開始アドレスを入力します。
4. Prefix Update のURL、hostnameトークン、ユーザーID、パスワードを入力します。
5. MTUは、回線条件やOCNの指定がなければ既定の `1460` を使用します。
6. **Enable** を有効にして **Apply** を押します。
7. 数秒待ち、状態欄を確認します。**HEALTHY** にならない場合は Diagnostics とログで失敗項目を確認してください。

Apply APIは成功・失敗、失敗した工程、更新APIの警告を返し、画面に表示します。適用後は実際の状態も確認してください。トンネルが作成されても、次のゲートウェイ・NAT・MSS設定が完了するまではLAN側のIPv4通信は完成しません。

## 導入後に必要な設定

設定する順序は、プラグインのApply、インターフェース割り当ての確認、ゲートウェイ、Outbound NAT、MSS正規化です。

### トンネルインターフェースの割り当て

**Interfaces > Assignments** で、`gif0` が割り当てられていることを確認します。プラグインは既存の割り当てを再利用し、なければ空いている `optN` に説明名 `TUNNEL` で自動割り当てを試みます。

自動割り当てされなかった場合は手動で `gif0` を割り当て、もう一度Applyしてください。以降の `TUNNEL` は、実際に割り当てたインターフェース名に読み替えます。

### IPv4ゲートウェイ

**System > Gateways > Configuration** で作成または選択します。

| 項目 | 設定値 |
|---|---|
| Interface | `TUNNEL` |
| Address family | IPv4 |
| Gateway address | `192.0.0.1` |
| Upstream gateway | 有効 |
| Disable Gateway Monitoring | **有効（必須）** |

ゲートウェイグループやポリシールーティングを意図的に構成する場合を除き、IPv4デフォルトゲートウェイが競合しないようにしてください。

### Outbound NAT

**Firewall > NAT > Outbound** で、対象のLAN/VLANごとにルールを設定します。明示的に制御する場合は Hybrid または Manual モードを使用します。

| 項目 | 設定値 |
|---|---|
| Interface | `TUNNEL` |
| TCP/IP version | IPv4 |
| Source | 対象のLAN/VLANネットワーク |
| Translation / target | Interface address |

変換後のアドレスが、割り当てられた固定IPv4ブロックの開始アドレスになることを確認します。LAN側のファイアウォールルールでも、必要なIPv4通信を許可してください。

### MSS正規化（Normalization）

**Firewall > Settings > Normalization** に以下のルールを追加します。Direction を `Any` にして、外部からの接続を含めて適用します。

| 項目 | 設定値 |
|---|---|
| Interface | `TUNNEL` |
| Direction | `Any` |
| Protocol | `TCP` |
| Source / Destination | `any` |
| Max MSS | `1420` |
| Description | 例: `OCN IPoE MSS` |

`1420` はトンネルMTUが `1460` の場合の推奨値です。MTUを変更する場合は、MSSと経路MTUも合わせて見直してください。

## 設定項目

画面の英語表記と対応する説明です。

| 項目 | 説明 |
|---|---|
| **Enable** | プラグインを有効にします。無効にしてApplyするとトンネルを停止します。 |
| **WAN Interface** | トンネルIPv6の計算元となるWANインターフェースです。 |
| **BR / AFTR IPv6 Endpoint** | OCN指定のBR IPv6アドレスです。 |
| **Fixed IPv4 Range Start** | 固定IPv4ブロックの先頭です。`203.0.113.96/255.255.255.240` なら `203.0.113.96` を入力します。マスクは入力しません。 |
| **MTU**（Advanced） | 既定値 `1460`。モデルの入力範囲は `1280`～`9000` ですが、回線がその値に対応することを意味しません。 |
| **Prefix Update URL** | OCN指定の更新URLです。例: `http://ipoe-static.ocn.ad.jp/nic/update`。 |
| **Prefix Update Hostname** | `hostname` に渡すOCNのトークンです。URL内に既に `hostname=` があれば、こちらの値は追加されません。 |
| **Auth User ID** | Prefix Update の認証ユーザーIDです。必須です。 |
| **Auth Password** | Prefix Update の認証パスワードです。`/conf/config.xml` に保存されるため、バックアップも保護してください。 |

MTUの参考資料: [NTTドコモビジネス FAQ](https://support.ntt.com/ocn-business/faq/detail/pid2300001n9t/)。

Local Tunnel IPv6 と Tunnel Peer IPv4 の入力欄はありません。前者は自動計算、後者は `192.0.0.1` 固定です。NAT関連設定と Prefix Update Interval も、このプラグインの設定項目にはありません。

## 実行時の動作

### ローカルトンネルIPv6の自動計算

計算式は次のとおりです。`OR` はビット単位の論理和です。

```text
local_tunnel_v6 = WAN IPv6 の /56 ネットワークアドレス OR (固定IPv4の整数値 << 24)
```

例:

| 項目 | 値 |
|---|---|
| WANのIPv6アドレス | `2001:db8:1234:56f1::254` |
| 計算に使用する `/56` | `2001:db8:1234:5600::/56` |
| 固定IPv4開始アドレス | `203.0.113.96` |
| 計算結果 | `2001:db8:1234:5600:cb:71:6000:0` |

HGW配下で元の `/56` から `/60` を受ける場合でも、計算は `/56` にそろえます。ただし、委譲情報そのものを取得する実装ではなく、選択したWANデバイスのアドレスから求めています。

WANのIPv6取得は最大6回、1秒間隔で試みます。グローバルIPv6から、ULA・リンクローカル・一時・tentative・deprecated・重複・切断状態のアドレスと、記録済みのトンネル用エイリアスを除外します。候補が複数の `/56` にまたがる場合は、誤ったプレフィックスを選ばず失敗として返します。

### WANエイリアスとプレフィックス更新

計算したIPv6をWANへ `/128` エイリアスとして追加し、デバイス名・アドレス・所有フラグを `/var/run/ocnfixedip_local_tunnel_v6` に記録します。プレフィックスやWANの変更時は、記録した元のデバイスから管理対象アドレスを削除します。既に存在していた管理外の一致アドレスは削除しません。

旧バージョンの1列の記録は、設定済みWANと `/128` の存在を確認して扱います。旧実装で既に追跡情報が失われたアドレスは、自動的に所有権を判定できないため、必要に応じて手動で整理してください。

Prefix Update APIは、サービス起動・再起動・Apply、および `rc.newwanipv6` 経由の `newwanip(..., inet6)` イベントで呼び出します。IPv4側のイベントと別インターフェースの更新は対象外です。アドレスファミリーが省略された場合も処理対象です。

設定変更・再起動・停止は共通のカーネルロックで直列化し、別の処理の終了を最大30秒待ちます。3秒以内の操作をスキップする旧方式は廃止しました。restartは事前検証を済ませてから停止処理へ進みます。

更新リクエストはIPv6を使用し、接続開始を2秒、転送全体を10秒に制限します。更新失敗はトンネル設定の成功とは区別して、画面に警告を表示します。ネットワーク設定が途中で失敗した場合は、直前のトンネル・管理エイリアス・デフォルトルート・MSS用sysctlの復元を試みます。復元自体が失敗する可能性はあるため、失敗した工程とログも確認してください。

### 経路とMTU

IPv4デフォルトルートを `192.0.0.1` に変更します。変更に失敗した場合は削除・追加を試みます。経路操作の失敗は警告として記録されます。

また、システム全体の `net.inet.tcp.mss_ifmtu` の元の値を保存して `1` にし、停止時に保存値へ戻します。再起動を挟んでも元の値を保持します。

### 無効化・停止・再起動

停止処理は `gif0` を破棄し、現在のIPv4デフォルトルートが `gif0` を使っている場合に限り、そのルートを削除します。以前のゲートウェイは保存・復元しません。その後の経路は OPNsense 側のゲートウェイ管理状態に依存します。

停止時はプラグインが所有するWAN `/128` エイリアスを削除してから記録を消します。削除に失敗した場合は、次回に再試行できるよう記録を残し、失敗を返します。

### HEALTHY の判定

設定画面とウィジェットは `status.sh` の結果を使用します。`HEALTHY` には次の確認がすべて必要です。

| チェック | 内容 |
|---|---|
| `tunnel_state` | `gif0` が `RUNNING` |
| `default_route` | IPv4デフォルトルートが `192.0.0.1`、インターフェースが `gif0` |
| `dns` | `one.one.one.one` のAレコードを解決できる |
| `mtu` | 設定値と実際のMTUが一致 |
| `wan_alias` | ローカルトンネルIPv6のWANエイリアスが存在 |
| `prefix_update` | 記録済みの更新結果が成功終了かつ `good` / `nochg` |
| `ce_to_br` | CE（ローカルIPv6）からBRへのIPv6 Pingが成功 |
| `internet` | トンネルIPv4を送信元とした `1.1.1.1` へのPingが成功 |
| `ipv6_internet` | CEを送信元とした `2606:4700:4700::1111` へのPingが成功 |
| `mtu_probe` | トンネルMTU相当のIPv4 DF Pingが成功 |
| `mtu_fragmentation` | MTUを超えるIPv4パケットのDFなしPingが成功 |

失敗項目はJSONの `tunnel.health_failures` に列挙されます。外部の特定宛先やICMP応答に依存するため、`degraded` だけで回線全体の断線とは断定できません。設定画面は応答後5秒で次の状態取得を行い、要求を重ねません。検査結果は画面・ウィジェット間で最大5秒共有し、Apply・停止・診断更新時にはキャッシュを破棄します。

Diagnostics では、AAAA解決、IPv6のMTU・大きなパケットの確認、IPv4/IPv6のHTTPS接続を加えた16項目を調べます。ページを開くと自動実行し、**OCNへの実際の更新リクエストと更新結果の記録も行います**。

## LAN側のIPv6プレフィックス追従

英語版で案内している OPNsense 26.1 以降の構成例は `Identity association` です。プラグインがLAN側を設定するわけではありません。

1. WANを DHCPv6 にし、回線の要件に従ってPDを有効にします。
2. LAN/VLANで `Identity association` を選択します。
3. インターフェースごとに異なる Prefix ID（例: `1`、`3`、`4`）を設定します。
4. `Optional interface ID` でホスト部を固定します。

例えば委譲が `2001:db8:1234:5670::/60` のとき、Prefix IDを `1`、Optional interface IDを `254` にした構成例は `2001:db8:1234:5671::254/64` です。プレフィックス更新に追従しつつ、各インターフェースのホスト部をそろえるための設定です。使用中のOPNsenseの画面と実際の割り当て結果を確認してください。

## ログの確認

主に次のログを確認します。

```text
Auto-calculated local tunnel IPv6: ...
Sending prefix update (URL and hostname omitted)
Prefix update result: nochg または good
OCN Fixed IP (IPoE) tunnel configuration complete
```

シェルで継続監視する例:

```sh
tail -F /var/log/system/latest.log | grep -E 'rc.newwanipv6|ocnfixedip'
```

| 応答 | 意味・確認事項 |
|---|---|
| `nochg` | 変更不要。通常の成功応答です。 |
| `good` | 更新を受け付けた成功応答です。 |
| `nohost` | hostnameトークンと認証アカウントの組み合わせを確認します。 |
| その他・空応答 | URL、認証情報、IPv6疎通と応答本文を確認します。 |

更新ログにはURL、hostnameトークン、認証情報、応答本文を出さず、結果コードを記録します。アドレスなど他の運用情報は公開前に確認してください。

## 動作確認

### Web UI

1. **Interfaces > OCN Fixed IP (IPoE) > Settings** の状態欄を確認します。
2. `HEALTHY`、または失敗項目の内容を確認します。
3. Local IPv6、BR IPv6、Tunnel IPv4、MTUが想定どおりか確認します。
4. **Diagnostics** を開き、次の16項目を確認します。

| 順序 | 診断項目 |
|---|---|
| 1 | トンネルのUP/RUNNING状態 |
| 2 | IPv4デフォルトルート |
| 3 | WANのローカルIPv6エイリアス |
| 4 | 設定MTUと実際のMTUの一致 |
| 5 | IPv6 CE → BR Ping |
| 6 | Prefix Update API（実リクエスト） |
| 7 | IPv4インターネットPing（`1.1.1.1`） |
| 8 | IPv6インターネットPing（`2606:4700:4700::1111`） |
| 9 | IPv4 MTU確認（DF Ping） |
| 10 | IPv6 MTU確認（画面表記: DF Ping） |
| 11 | IPv4大容量パケットのフラグメント確認 |
| 12 | IPv6大容量パケットの送信元フラグメント確認 |
| 13 | DNS Aレコード解決 |
| 14 | IPv4 curl（`one.one.one.one`） |
| 15 | DNS AAAAレコード解決 |
| 16 | IPv6 curl（`one.one.one.one`） |

### シェル

OPNsense上で実行します。

```sh
ifconfig gif0
route -n get default
configctl ocnfixedip status
configctl ocnfixedip diagnostics
```

期待する結果は次のとおりです。

- `gif0` が存在し、`UP` と `RUNNING` が表示される。
- `tunnel inet6` に計算したローカルIPv6とOCN指定のBR IPv6が表示される。
- トンネルの固定IPv4に対して、対向アドレスが `192.0.0.1` になる。
- IPv4デフォルトルートが `192.0.0.1`、インターフェースが `gif0` になる。
- status JSON の `tunnel.health` が `healthy` になる。`degraded` なら `tunnel.health_failures` を調べる。
- BR、IPv4、IPv6の疎通確認が成功する。

### LAN端末からの確認

トンネル経由で通信するLAN端末から、信頼できるグローバルIP確認サービスなどで送信元IPv4を調べ、割り当てられたOCN固定IPv4ブロック内のアドレスになっていることを確認します。

ルーター自身のPing成功だけでは、LANのOutbound NATやファイアウォール設定まで確認したことにはなりません。

## トラブルシューティング

### Not started / Not Running、または gif0 がない

Enableと必須項目が保存されているか確認し、次を実行します。

```sh
configctl ocnfixedip restart
```

`/var/log/system/latest.log` のエラーと、選択したWANが実デバイスに対応しているかを確認します。他の設定処理が実行中の場合は、その終了を最大30秒待ちます。ロック待ちが失敗した場合は、実行中の処理とログを確認してください。

### ローカルトンネルIPv6を計算できない

WANに適切なIPv6があるか `ifconfig` で確認します。DHCPv6/PDの取得が完了していることと、`python3` の存在も確認してください。更新直後なら数秒待ってから再起動します。複数のグローバル `/56` がある場合は自動選択できません。WANのアドレス構成を確認してください。

### gif0 は上がるがIPv4インターネットへ出られない

デフォルトルート、TUNNELゲートウェイの Upstream と Disable Gateway Monitoring、各LAN/VLANのOutbound NAT、LAN側の許可ルールを順に確認します。Normalization が `TUNNEL / Any / TCP / Max MSS 1420`（MTU 1460の場合）になっているかも確認してください。

Diagnostics の経路、エイリアス、BR、IPv4/IPv6、DNS、curl、MTU、Prefix Update のうち、どこで失敗しているかを切り分けます。

### BRへのPingが失敗する

契約書のBR IPv6、WANのネイティブIPv6経路、WANに追加されたローカルトンネルIPv6を確認します。上流のIPv6ファイアウォールとルーティングも確認してください。ICMP応答が得られない場合は、他の疎通結果と合わせて判断します。

### Prefix Update が nohost を返す

hostnameトークンをOCNの案内どおりに入力し、認証アカウントとの対応を確認します。更新URLに古い `hostname=` が含まれていないかも確認してください。URLに含まれている値が優先されます。

### Prefix Update が good / nochg 以外を返す

URL、ユーザーID、パスワード、hostnameトークンと、IPv6経由で更新先に接続できることを確認します。ログの `Prefix update result` と診断の結果コードを調べてください。

Diagnostics の Prefix update API check でも即時確認できます。実際に更新を行うため、試験時にも `good` / `nochg` が返るのが通常です。HTTPSの場合は証明書検証も確認してください。診断APIは更新を伴うためPOSTと通常のOPNsenseのCSRF保護を使用します。

### WANプレフィックス変更後に復旧しない

通常は `rc.newwanipv6` 経由で再設定されます。遅延が続く場合は次を実行し、新しい計算結果と更新応答をログで確認します。

```sh
configctl ocnfixedip restart
```

旧バージョンで既に追跡情報を失ったエイリアスがある場合は、WAN上に旧プレフィックスのアドレスが残っていないか確認してください。手動削除する場合は、他の機能が使用するアドレスと区別します。

## 性能の参考値

英語版に掲載されている、単一の仮想化環境でのユーザー報告です。今回の調査で再測定した値ではありません。

| 項目 | 報告された環境 |
|---|---|
| 仮想化基盤 | Proxmox `9.2.4` |
| VM | `16 vCPU / 8GB RAM` |
| ホストCPU | Ryzen 7 3700X |
| NIC | Mellanox ConnectX-4 Lx 25GbE（スイッチへの接続は10GbE） |
| 測定 | speedtest.net / iperf3 / Ping |

| 測定項目 | 結果 |
|---|---|
| speedtest.net ダウンロード | 8002 Mbps |
| speedtest.net アップロード | 6998 Mbps |
| iperf3 8ストリーム ダウンロード | 8.80 Gbps |
| iperf3 8ストリーム アップロード | 8.13 Gbps |
| `1.1.1.1` Ping（16回） | 平均4.00 ms、最小3.667 / 最大4.470 ms |

性能保証ではありません。CPU、NICオフロード、仮想化設定、ファイアウォールルール、トラフィックや回線条件で結果は変わります。

## OPNsense上でのパッケージビルド

リポジトリを `/root/os-ocnfixedip` に配置した場合:

```sh
cd /root/os-ocnfixedip/os-ocnfixedip
make pkg
```

生成先はプラグインディレクトリ配下の `dist/`、この例では `/root/os-ocnfixedip/os-ocnfixedip/dist/` です。`pkg` コマンドを使用するため、OPNsense / FreeBSD 上で実行します。

ビルド情報を指定する例:

```sh
make pkg PKG_VERSION=2026.07.22.1 \
         PKG_MAINTAINER=you@example.com \
         PKG_ORIGIN=net/os-ocnfixedip
```

`PKG_WWW` も指定できます。バージョンを省略した場合はビルド日時から生成されます。

ローカルパッケージをインストールします。

```sh
pkg add -f /root/os-ocnfixedip/dist/os-ocnfixedip-*.pkg
```

ビルド用の一時ディレクトリと生成パッケージを削除する場合:

```sh
make clean
```

## アップグレードと再インストール

導入するバージョンのパッケージを、既存のものへ上書きインストールします。以下は既存リリースのコマンド例です。アップグレード時は新しいリリースのURLへ置き換えてください。

```sh
pkg add -f https://github.com/unchained-llc/os-ocnfixedip/releases/download/v2026.07.22/os-ocnfixedip-2026.07.22.1155.pkg
```

ローカルパッケージなら、ビルド節の `pkg add -f` と同じ方法を使用します。先に `pkg delete` すると停止処理が実行されるため、再インストールでも上書き導入を推奨します。ただし、上書き時の無停止動作を保証するものではありません。

必要に応じて次を実行します。

```sh
service configd restart
```

`/conf/config.xml` の `//OPNsense/ocnfixedip` に保存した設定は保持されます。更新後は状態、Diagnostics、LAN端末の通信を確認してください。

## アンインストール

```sh
pkg delete -y os-ocnfixedip
```

削除前フックは `configctl ocnfixedip stop` を実行し、削除後フックは `configd` の再起動とUIキャッシュの更新を行います。

`/conf/config.xml` のプラグイン設定、インターフェース割り当て、ゲートウェイ、Outbound NAT、ファイアウォール、Normalization は自動削除しません。プラグイン所有のWAN `/128` エイリアスは削除し、保存済みsysctlを復元します。失敗はログで確認してください。旧バージョンで孤立したエイリアスは手動確認が必要です。不要になった設定を確認し、別のIPv4経路を用意したうえで整理してください。

## 既知の制約

- OCN 固定IP（IPoE）専用です。
- トンネルは `gif0` の1本のみ、対向IPv4は `192.0.0.1` 固定です。既存の `gif0` と共存できません。
- IPv6計算はWANアドレスの `/56` を前提にします。WANとは別の `/56` に属する委譲プレフィックスは自動解析しません。
- Apply はシステム全体のIPv4デフォルトルートを直接変更します。
- Gateway / NAT / Firewall / MSS正規化は自動作成しません。
- 失敗時の復元はベストエフォートです。OPNsenseへ書き込んだインターフェース割り当ては残り、ネットワーク状態の復元自体が失敗する場合もあります。
- Prefix Updateの失敗は、トンネル設定の失敗とは区別して警告とヘルス状態へ反映します。
- ヘルス判定は特定の外部宛先への疎通に依存します。
- 設定・診断・ウィジェットはOPNsenseの表示言語に従って日本語を表示します。アドレスや内部の診断キーは共通表記です。
- 配布はGitHub Releasesまたはローカルビルドの `.pkg` で、公式OPNsenseプラグインリポジトリには未登録です。
- 自動回帰テストと構文検査を含みます。実回線・OPNsense VMの統合試験は別途必要です。

## セキュリティ上の注意

認証情報は `/conf/config.xml` とそのバックアップに含まれます。Web UIのパスワード表示が伏字でも、保存先が外部のシークレット管理になるわけではありません。

実行時は権限 `0600` の一時 `netrc` に引用符・空白・バックスラッシュを考慮して認証情報を書きます。通常終了・タイムアウト・処理可能な終了シグナルでは削除します。SIGKILLなど強制終了時の削除は保証できません。制御文字を含む認証情報は拒否します。

Prefix UpdateはHTTPSの証明書を検証します。契約互換性のためHTTPも受け付けますが、HTTPでは認証を含む通信がTLSで暗号化されません。指定された更新先がHTTPSに対応するとは限らないため、契約で指定された方式を確認してください。URLはHTTP(S)に制限し、埋め込み認証情報とフラグメントを拒否します。hostnameはトークンとして検証し、URLエンコードします。

更新ログにURL・hostname・認証情報は出力しません。診断結果にはインターフェースアドレスや経路が含まれます。公開時は伏せてください。診断ページを開くと実際の更新リクエストが送信されることにも注意してください。

## 開発者向け情報

主な構成:

```text
os-ocnfixedip/
  Makefile                           make pkg の入口
  tools/build-pkg.sh                 ステージング・manifest・pkg生成
  src/etc/inc/plugins.inc.d/         OPNsenseのライフサイクルフック
  src/opnsense/service/conf/         configdアクション
  src/opnsense/scripts/              トンネル設定・停止・状態・診断
  src/opnsense/mvc/                  モデル・API・フォーム・画面・ACL・メニュー
  src/opnsense/www/js/widgets/       ダッシュボードウィジェット
```

主な実装ファイルは `ocnfixedip.inc`、`configure.sh`、`lib.sh`、共通のPythonヘルパー `runtime.py`、フォームの `general.xml` です。詳細は英語の[実装リファレンス](./ocnfixedip.md)を参照してください。

自動チェックはプラグインディレクトリで実行します。

```sh
cd os-ocnfixedip
make check
```

Python 3、Node.js 20.11以降、`xmllint` が必要です。PHP CLIがある場合はPHP構文検査も実行し、CIではPHP検査を必須にします。パッケージは導入前フックで必須ランタイムコマンドを確認し、[ライセンス本文](./LICENSE)も同梱します。

個別のシェル構文確認:

```sh
for file in os-ocnfixedip/tools/build-pkg.sh \
            os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/*.sh; do
    sh -n "$file" || exit 1
done
```

XMLとPHPも構文検証し、OPNsenseの検証用VMで初回導入、Apply、restart、IPv6プレフィックス更新、無効化、アンインストールを確認してください。ルーティングや認証、停止処理の変更では、静的な検査だけで動作確認済みとは扱わないでください。

## ライセンス

BSD 2-Clause
