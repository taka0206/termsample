RHEL 9.8 の perf ディレクトリを Windows 11 に取得する

■ 最初に行うこと
1. ZIP を右クリックし「すべて展開」で、例えば C:\Tools\PerfGet に展開します。
   GetPerf.ttl、PerfLocal.ps1、collect-perf.sh を同じフォルダーに置いてください。
   起動するのは GetPerf.ttl だけです。RHEL へのスクリプトの事前配置は不要です。
2. GetPerf.ttl をメモ帳で開き、先頭を環境に合わせます。次の値は例です。

   SSH_HOST      = 'rhel98.example.jp'
   SSH_PORT      = 22
   REMOTE_PARENT = '/var/log/batch'
   LOCAL_BASE    = 'C:\Work\Perf'
   AUTH_MODE     = 'ask'

   取得元が /var/log/batch/perf のとき、REMOTE_PARENT は /var/log/batch です。
   「perf」の名前はプログラムが付けます。親パスは / から始まる絶対パスで、
   空白や日本語も指定できます。値に ' を含む場合、TTL の文字列を " で囲みます。
   SSH_HOST と REMOTE_PARENT を空欄にすると実行時に入力できます。
   LOCAL_BASE が空欄の場合は %USERPROFILE%\PerfDownloads に保存します。
   SSH_HOST はホスト名、FQDN または IPv4、LOCAL_BASE はドライブの絶対パスです。
   AUTH_MODE は ask（毎回入力）、saved（Windows に暗号化保存）、
   inline（コードに事前設定）から選べます。既定値は ask です。
3. Tera Term 5.5.2 以降の ttpmacro.exe に GetPerf.ttl をドラッグ＆ドロップします。
   .ttl が関連付け済みならダブルクリックでも起動します。
   インストール先が次の場所なら、Windows PowerShell からも起動できます。

   & 'C:\Program Files\teraterm5\ttpmacro.exe' 'C:\Tools\PerfGet\GetPerf.ttl'

4. SSH 認証画面で spfai001 のパスワードを入力します。
   初めてのホストでは管理者から受け取ったホスト鍵の指紋と照合します。
   続いて「RHEL root」のダイアログに su 用の root パスワードを入力します。
   サーバーがパスワード入力なしの su を許可している場合はこのダイアログを省きます。
   認証後は取得、検証、展開、一時領域の削除まで自動で進みます。

■ 保存結果
上の設定で /var/log/batch/perf/day01/node01/perf.data を取得した場合

   C:\Work\Perf\rhel98.example.jp_YYYYMMDD_HHMMSS_識別子\perf\day01\node01\perf.data

同じ実行フォルダーの中に次ができます。
   perf\           展開済みのディレクトリ。隠しファイル、ゼロバイトのファイル、空の階層を含みます。
   perf.tar.gz     SHA-256 を RHEL 側と照合した取得書庫です。
   transfer.log    取得元、サイズ、SHA-256、展開したファイル・ディレクトリ件数、失敗理由を記録します。

再実行のたびに新しい保存フォルダーを作ります。実行中は perf.tar.gz.part、
展開中は _extracting を使います。完了した perf フォルダーは最後に公開します。

■ パスワードをコードに事前設定する場合（inline）
GetPerf.ttl 先頭の設定を次のように変更します。

   AUTH_MODE     = 'inline'
   SSH_PASSWORD  = 'ここに spfai001 の SSH パスワードを記載'
   ROOT_PASSWORD = 'ここに su 用の root パスワードを記載'

SSH と su には設定した値を使い、パスワード入力画面を省きます。
両方の設定が必須です。空欄、制御文字、長さの上限超過は SSH 接続前にエラーにします。
UTF-8 で各 240 バイト以内にしてください。SSH 用の二重引用符は自動でエスケープし、
その後の長さも 240 バイト以内である必要があります。空白や日本語も使用できます。
値に ' を含む場合は TTL の文字列を " で囲み、両方の引用符を含む場合は
文字列と #39（'）または #34（"）を連結して指定してください。
この方式では GetPerf.ttl にパスワードが平文で残るため、設定済みファイルの共有や
Git への登録を避けてください。初回のホスト鍵確認と SHOW_RESULT の動作は他のモードと同じです。
毎回入力に戻すには AUTH_MODE = 'ask'、暗号化保存に切り替えるには 'saved' にします。
SSH_PASSWORD と ROOT_PASSWORD は inline のときだけ参照し、saved の保存内容は更新しません。

■ Windows に暗号化して保存する場合（saved）
接続先と REMOTE_PARENT を固定し、GetPerf.ttl 先頭の AUTH_MODE = 'saved' に変更します。
初回の PowerShell 画面に SSH 用、root 用の順で入力してください。入力中は文字が隠れます。
2 回目からは同じ Windows PC・同じ Windows ユーザーで保存認証を利用します。
対象は SSH パスワード認証と標準の su のパスワードプロンプトです。
初回の SSH ホスト鍵確認は必要です。ホスト鍵変更時は表示された指紋を管理者に確認してください。
完了通知の OK 操作も省く場合は SHOW_RESULT = 0 にします。

保存先は %LOCALAPPDATA%\TeraTermPerf\spfai001_ホスト名_ポート.clixml です。
SecureString を Windows DPAPI で暗号化しています。同じ Windows アカウントからは復号可能です。
資格情報の保存が許可された端末で利用してください。接続時は専用マクロのプロセス環境で
一時的に受け渡し、SSH パスワードをプロセスのコマンドラインに含めないようにしています。
入力を間違えた場合やパスワード変更後は、該当する .clixml だけを削除して再実行してください。
保存モードは、制御文字を含まず、UTF-8 で 240 バイト以内のパスワードに対応します
（SSH 用では二重引用符をエスケープした後の長さで判定します）。

■ 実行環境
Windows 11
   Tera Term 5.5.2 以降（TTSSH と ttpmacro.exe を含む）、Windows PowerShell 5.1、標準の tar.exe。
   5.5.2 の getver は「5.5」を返し、メジャー・マイナー番号を比較するため、
   マクロの起動判定には getver ttver '5.5' を使用しています。
   使用中の sendbinary、scprecv、exec 等は公式 v5.5.2 ソースで確認済みです。
   認証方式の分岐と入力検証は Tera Term 5.5.2 の実行ファイルで単体確認しています。
   SSH と su を含む RHEL 実機での通し試験は未実施です。
   通常の Windows ユーザーで実行できます。保存先には書庫と展開データの両方の空きが必要です。
   ヘルパーには実行プロセス単位で -ExecutionPolicy Bypass を指定します。
   組織の GPO、AppLocker、WDAC 等でスクリプト実行が制限されている場合はその設定が適用されます。

RHEL 9.8
   spfai001 で SSH 対話ログインでき、同ユーザーによる su で root への切り替えが許可されていること。
   初期ログインシェルは bash または sh 互換、SSH サーバーは PTY と SCP の別チャネルを許可すること。
   コマンドは bash、su、tar、gzip、sha256sum、stat、mktemp、sed、stty、scp を使用します。
   /usr/bin/python3（標準ライブラリのみ）を Windows に展開できるかの判定に使用します。
   /var/tmp に圧縮書庫 1 個分の空きが必要です。SCP は Tera Term の scprecv から起動します。
   RHEL 側で command -v scp を実行して確認できます（提供元は openssh-clients）。
   SFTP 専用で旧 SCP のリモートコマンドを禁止するサーバーでは scprecv は利用できません。

■ 何を転送するか
spfai001 で専用の SSH セッションを開始し、su --login で root の UID 0 を確認します。
root が親ディレクトリへ移動し、GNU tar で perf を丸ごと読み取ります。アーカイブの
出力先は spfai001 が先に開くため、SCP でも同じ spfai001 が読めます。サーバーの
一時ディレクトリは /var/tmp/ttperf.識別子（0700）、書庫は 0600 です。
元のディレクトリの所有者や権限を操作するコマンドはありません。
Tera Term の非同期 SCP を開始した後、書き手がファイルを閉じるのを待ち、受信サイズと
SHA-256 を照合します。展開後はファイル・ディレクトリ件数を照合します。
正常時は取得完了後に一時領域を削除します。切断時はサーバー側の trap でも回収します。

Windows の通常のフォルダーへ展開できるのは、名前と型を表現できるツリーです。
内部のシンボリックリンクはリンクとして書庫に保存し、外部のリンク先を読みません。
リンク、FIFO 等の特殊ファイル、大文字小文字だけが違う名前、Windows の予約名などを
検出したときは、書庫全体を Windows に保存し、自動展開を見送ります（終了コード 2）。
通常ファイルのハードリンクは各名前で内容を収録します。perf 自身は実ディレクトリを指定してください。
/usr/bin/python3 がない場合も、ハッシュ照合済みの書庫を保存し、理由を記録します。
UNIX ソケット等を tar が読み飛ばした場合や、読み取り中の変更を tar が検出した場合は、
取得失敗とします。一時点の記録が必要な場合は計測ツールの出力が確定してから実行してください。

■ 失敗した場合
・PACK_1 などで UID 0 に到達しない場合は、手動で spfai001 にログインして
  LC_ALL=C su --login root を確認してください。標準の Password: プロンプトに対応します。
・PACK_42 は親ディレクトリに移動できない場合、PACK_43 はその直下の perf がない、
  ディレクトリ以外、または perf 自身がシンボリックリンクである場合です。
・PACK_0 は tar が警告を出して一部の項目を読み飛ばした場合を含みます。
  PACK_1 や PACK_2 では、計測中の書き換えや /var/tmp の空き容量も確認してください。
・NO_SCP は RHEL 側の scp コマンドが見つからない場合です。
・受信タイムアウトでは SSH サーバーの scp、通信、Windows の空き容量を確認してください。
  大きな書庫では TTL の TIME_LIMIT を延長できます（既定 7200 秒、最大 82800 秒）。
・展開に失敗した場合は transfer.log を確認してください。検証済みの perf.tar.gz は残ります。
  長いパスで失敗した場合は LOCAL_BASE を例えば C:\Perf に短くして再実行してください。
・サーバー停止等で一時ディレクトリが残った場合は、エラーに表示された正確なパスを
  spfai001 で確認してください。他の実行の ttperf ディレクトリと区別してください。

マクロの終了コード
   0   SHA-256 と件数を照合し、perf を展開済み
   2   SHA-256 を照合し、書庫のみ保存（理由は transfer.log）
   1   取得、検証、展開、または一時領域の削除確認に失敗

■ 開発時の認証テスト
リポジトリの tests\test_authentication.py を Python 3.10 以降で実行できます。
通常の取得操作に Python は不要です。リポジトリのフォルダーで次を実行します。

   python tests\test_authentication.py --ttpmacro 'C:\Program Files\teraterm5\ttpmacro.exe' -v

ask、saved、inline の選択、引用符や日本語、空欄、制御文字、バイト数上限を検証します。
SSH 接続と端末への入出力は行わないため、実サーバーでの接続・転送試験は別途必要です。
配布用 ZIP は実行用の 4 ファイルだけを含み、テストコードはリポジトリで管理します。

公式仕様
Tera Term の scprecv    https://teratermproject.github.io/manual/5/ja/macro/command/scprecv.html
Tera Term の SSH 認証   https://teratermproject.github.io/manual/5/ja/commandline/ttssh.html
Windows の tar          https://learn.microsoft.com/en-us/windows/tar/
Windows の資格情報保存  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml?view=powershell-5.1

Tera Term 5.5.2 のバージョン判定の実装
https://github.com/TeraTermProject/teraterm/blob/v5.5.2/teraterm/ttpmacro/ttl.cpp
