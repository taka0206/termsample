#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Saved', 'Prepare', 'Receive')][string]$Action)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Start-SavedMacro {
    $server = $env:TT_PERF_HOST
    $port = $env:TT_PERF_PORT
    if ($server -notmatch '^[a-z0-9][a-z0-9.-]{0,126}$' -or $port -notmatch '^\d{1,5}$') {
        throw '接続先を確認してください。'
    }
    $store = Join-Path $env:LOCALAPPDATA 'TeraTermPerf'
    [void][IO.Directory]::CreateDirectory($store)
    $record = Join-Path $store ("spfai001_{0}_{1}.clixml" -f $server, $port)
    $isNew = -not [IO.File]::Exists($record)
    if ($isNew) {
        Write-Host ("初回登録  {0}:{1}  Windows ユーザー {2}" -f $server, $port, $env:USERNAME)
        $secrets = [pscustomobject]@{
            Login = (Read-Host 'spfai001 の SSH パスワード' -AsSecureString)
            Root  = (Read-Host 'su で使用する root のパスワード' -AsSecureString)
        }
    } else {
        $secrets = Import-Clixml -LiteralPath $record
    }
    $worker = New-Object Diagnostics.ProcessStartInfo
    $worker.FileName = $env:TT_PERF_EXE
    $worker.WorkingDirectory = $PSScriptRoot
    $worker.Arguments = '"{0}" saved-worker' -f (Join-Path $PSScriptRoot 'GetPerf.ttl')
    $worker.UseShellExecute = $false
    try {
        foreach ($field in @('Login', 'Root')) {
            $secret = $secrets.$field
            if ($secret -isnot [Security.SecureString] -or $secret.Length -eq 0) {
                throw '両方のパスワードを入力してください。'
            }
            $plain = [Net.NetworkCredential]::new('', $secret).Password
            if ($plain -match '[\x00-\x1f\x7f]') { throw '制御文字を含むパスワードは登録できません。' }
            if ($field -eq 'Login') { $plain = $plain.Replace('"', '""') }
            if ([Text.Encoding]::UTF8.GetByteCount($plain) -gt 240) { throw '保存認証のパスワードが長すぎます。' }
            $worker.EnvironmentVariables['TT_PERF_' + $field.ToUpperInvariant()] = $plain
            $plain = $null
        }
        if ($isNew) {
            $tmp = "$record.$([guid]::NewGuid().ToString('N')).tmp"
            try {
                $secrets | Export-Clixml -LiteralPath $tmp  # SecureStrings use Windows user DPAPI.
                [IO.File]::Move($tmp, $record)
            } finally {
                if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
            }
        }
        $process = [Diagnostics.Process]::Start($worker)
    } finally {
        $worker.EnvironmentVariables.Remove('TT_PERF_LOGIN')
        $worker.EnvironmentVariables.Remove('TT_PERF_ROOT')
    }
    try {
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Write-TransferLog([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($log, $line, [Text.Encoding]::UTF8)
}

function Confirm-Download([string]$Path, [long]$ExpectedBytes, [string]$ExpectedHash) {
    if ($ExpectedBytes -le 0 -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}$') {
        throw 'RHEL から返されたサイズまたは SHA-256 が不正です。'
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $limit = [int]$env:TT_PERF_LIMIT
    while ($timer.Elapsed.TotalSeconds -lt $limit) {
        $stream = $null
        if ([IO.File]::Exists($Path)) {
            try {
                # A writer still holding the file prevents this exclusive open.
                $stream = [IO.File]::Open($Path, 'Open', 'Read', 'None')
            } catch [IO.IOException] {
                # SCP is still writing, or the file has just been renamed.
            }
        }
        if ($null -ne $stream) {
            try {
                if ($stream.Length -gt $ExpectedBytes) { throw '受信サイズが RHEL 側のサイズを超えました。' }
                if ($stream.Length -eq $ExpectedBytes) {
                    $actual = (Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash
                    if ($actual -ne $ExpectedHash) { throw "SHA-256 不一致  expected=$ExpectedHash  actual=$actual" }
                    return
                }
            } finally {
                $stream.Dispose()
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw ("SCP の完了を {0} 秒以内に確認できませんでした。期待サイズ {1} バイト。" -f $limit, $ExpectedBytes)
}

if ($Action -eq 'Saved') {
    try { exit (Start-SavedMacro) } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 90
    }
}
$run = $env:TT_PERF_RUN
if ([string]::IsNullOrEmpty($run) -or $run -notmatch '^[A-Za-z]:\\') { exit 1 }
$log = Join-Path $run 'transfer.log'
if ($Action -eq 'Prepare') {
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($run))
        # Without -Force this fails if the run directory already exists.
        $null = New-Item -ItemType Directory -Path $run
        Write-TransferLog ("取得元 {0}:{1}  {2}/perf" -f $env:TT_PERF_HOST, $env:TT_PERF_PORT, $env:TT_PERF_PARENT.TrimEnd('/'))
        exit 0
    } catch { exit 1 }
}

$part = Join-Path $run 'perf.tar.gz.part'
$archive = Join-Path $run 'perf.tar.gz'
$tree = Join-Path $run '_extracting'
$published = Join-Path $run 'perf'
try {
    Write-TransferLog ("SCP 受信待ち  {0} バイト" -f $env:TT_PERF_BYTES)
    Confirm-Download $part ([long]$env:TT_PERF_BYTES) $env:TT_PERF_HASH
    [IO.File]::Move($part, $archive)
    Write-TransferLog ("SHA-256 一致  {0}  perf.tar.gz" -f $env:TT_PERF_HASH)
    if ($env:TT_PERF_MODE -ne 'OK') {
        $reasons = @{
            LINK_OR_SPECIAL = 'シンボリックリンクまたは特殊ファイルが含まれます。'
            NAME_COLLISION  = '大文字・小文字を区別しないと同名になる項目があります。'
            WINDOWS_NAME    = 'Windows で表現できない名前、または短いファイル名と競合しうる名前があります。'
            NO_PYTHON       = 'RHEL の /usr/bin/python3 がなく、Windows 用の名前と種類を検査できませんでした。'
        }
        Write-TransferLog ("書庫のみ保存  {0}  {1}" -f $env:TT_PERF_MODE, $reasons[$env:TT_PERF_MODE])
        exit 2
    }
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not [IO.File]::Exists($tarExe)) { throw 'Windows 標準の tar.exe を確認できません。検証済み書庫は保存済みです。' }
    $null = New-Item -ItemType Directory -Path $tree
    $tarMessages = & $tarExe --no-same-owner --no-same-permissions -xkf $archive -C $tree 2>&1
    $tarCode = $LASTEXITCODE
    foreach ($message in $tarMessages) { Write-TransferLog ([string]$message) }
    if ($tarCode -ne 0) { throw "tar.exe が終了コード $tarCode を返しました。" }
    $root = Join-Path $tree 'perf'
    if (-not [IO.Directory]::Exists($root)) { throw '展開結果に perf がありません。' }
    [long]$files = 0
    [long]$dirs = 1  # Includes perf itself, the same convention as the RHEL inventory.
    Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop | ForEach-Object {
        if ($_.PSIsContainer) { $dirs++ } else { $files++ }
    }
    if ($files -ne [long]$env:TT_PERF_FILES -or $dirs -ne [long]$env:TT_PERF_DIRS) {
        throw "展開件数不一致  RHEL=$env:TT_PERF_FILES/$env:TT_PERF_DIRS  Windows=$files/$dirs"
    }
    [IO.Directory]::Move($root, $published)
    [IO.Directory]::Delete($tree)
    Write-TransferLog ("完了  ファイル {0} 件、ディレクトリ {1} 件（perf 自身を含む）  {2}" -f $files, $dirs, $published)
    exit 0
} catch {
    try { Write-TransferLog ('ERROR  ' + $_.Exception.Message) } catch {}
    # A partial extraction is kept separate. A verified archive is retained.
    exit 1
}
