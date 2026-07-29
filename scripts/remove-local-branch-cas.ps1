[CmdletBinding()]
param(
    [string]$Repository,
    [string]$TaskSlug,
    [string]$ExpectedHeadOid
)

Microsoft.PowerShell.Core\Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LocalCleanupGitCommand = @(
    Microsoft.PowerShell.Core\Get-Command git `
        -CommandType Application `
        -ErrorAction Stop
)[0]
if (
    $script:LocalCleanupGitCommand.CommandType -ne
        [System.Management.Automation.CommandTypes]::Application -or
    [string]::IsNullOrWhiteSpace($script:LocalCleanupGitCommand.Path) -or
    -not [System.IO.Path]::IsPathRooted($script:LocalCleanupGitCommand.Path) -or
    -not [System.IO.File]::Exists($script:LocalCleanupGitCommand.Path) -or
    @('git', 'git.exe') -inotcontains
        [System.IO.Path]::GetFileName($script:LocalCleanupGitCommand.Path)
) {
    throw 'Git must resolve to an existing fully-qualified application path.'
}
$script:LocalCleanupUtf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:LocalCleanupLockFileName = 'codex-isolated-worktree-cleanup.lock'
$script:LocalCleanupConfigWriterLockFileName = 'config.lock'
$script:LocalCleanupNullConfigPath = if (
    [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
) {
    'NUL'
} else {
    '/dev/null'
}

function New-LocalCleanupRuntimeIntegrityGuard {
    # function定義直後のScriptBlock identityをclosureへ閉じ込める。aliasだけでなく、
    # dot-source後やtest hook内のFunction:/Filter差替えも次のcritical call前に拒否する。
    $protectedFunctionNames = @(
        'Set-LocalCleanupProcessEnvironmentValue',
        'Get-LocalCleanupGitEnvironmentSnapshot',
        'Clear-LocalCleanupGitEnvironment',
        'Invoke-LocalCleanupGit',
        'Test-LocalCleanupTaskSlug',
        'Get-LocalCleanupLockPath',
        'New-LocalCleanupLock',
        'Get-LocalCleanupLockNonce',
        'Test-LocalCleanupLockOwnership',
        'Assert-LocalCleanupLockOwnership',
        'Close-LocalCleanupLock',
        'Get-LocalBranchConfigState',
        'Get-LocalCleanupTemporaryConfigState',
        'Test-LocalBranchCheckedOut',
        'Get-LocalCleanupWorktreeRecords',
        'Test-LocalCleanupPathEqual',
        'New-LocalCleanupConfigWriterLock',
        'Get-LocalCleanupConfigWriterLockPathNonce',
        'Test-LocalCleanupConfigWriterLockOwnership',
        'Assert-LocalCleanupConfigWriterLockOwnership',
        'Close-LocalCleanupConfigWriterLock',
        'New-LocalCleanupGuardDescriptor',
        'Test-LocalCleanupGuardPathState',
        'Test-LocalCleanupGuardInvariant',
        'Open-LocalCleanupGuardWorktree',
        'Close-LocalCleanupGuardWorktree',
        'Get-LocalBranchOid',
        'Invoke-LocalBranchCleanupCore',
        'Remove-IsolatedWorktreeLocalBranch',
        'New-LocalCleanupRuntimeIntegrityGuard'
    )
    $expectedFunctionScripts =
        [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::Ordinal
        )
    foreach ($protectedFunctionName in $protectedFunctionNames) {
        $resolvedFunction = Microsoft.PowerShell.Core\Get-Command `
            -Name $protectedFunctionName `
            -CommandType Function `
            -ErrorAction Stop
        if (
            $resolvedFunction.CommandType -ne
                [System.Management.Automation.CommandTypes]::Function -or
            $null -eq $resolvedFunction.ScriptBlock
        ) {
            throw "Runtime function '$protectedFunctionName' is not an exact function."
        }
        $expectedFunctionScripts.Add(
            $protectedFunctionName,
            $resolvedFunction.ScriptBlock
        )
    }

    $integrityGuardBody = {
        foreach ($protectedFunctionName in $protectedFunctionNames) {
            if ($null -ne (
                Microsoft.PowerShell.Utility\Get-Alias `
                    -Name $protectedFunctionName `
                    -ErrorAction SilentlyContinue
            )) {
                throw (
                    "Ambient alias '$protectedFunctionName' can redirect the " +
                    'local cleanup helper; remove the alias before retrying.'
                )
            }

            $currentFunction = $null
            try {
                $currentFunction = Microsoft.PowerShell.Core\Get-Command `
                    -Name $protectedFunctionName `
                    -CommandType Function `
                    -ErrorAction Stop
            }
            catch {
                throw "Runtime function '$protectedFunctionName' is unavailable."
            }
            if (
                $currentFunction.CommandType -ne
                    [System.Management.Automation.CommandTypes]::Function -or
                $null -eq $currentFunction.ScriptBlock -or
                -not [object]::ReferenceEquals(
                    $expectedFunctionScripts[$protectedFunctionName],
                    $currentFunction.ScriptBlock
                )
            ) {
                throw "Runtime function '$protectedFunctionName' changed after review."
            }
        }
    }
    return $integrityGuardBody.GetNewClosure()
}

function Set-LocalCleanupProcessEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    # .NETのprocess setterはhostによってnullを空文字keyとして残すため、
    # nullはEnv providerのLiteralPathで完全に除去する。
    if ($null -eq $Value) {
        Microsoft.PowerShell.Management\Remove-Item `
            -LiteralPath "Env:$Name" `
            -ErrorAction SilentlyContinue
        return
    }
    [Environment]::SetEnvironmentVariable(
        $Name,
        [string]$Value,
        [EnvironmentVariableTarget]::Process
    )
}

function Get-LocalCleanupGitEnvironmentSnapshot {
    # Linux/macOSでは環境変数名がcase-sensitiveなため、GIT_Xとgit_xを
    # 別entryとして保持する。PowerShell既定hashtableのcase foldingを使わない。
    $snapshot = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    ).GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name.StartsWith(
            'GIT_',
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            $snapshot[$name] = [string]$entry.Value
        }
    }
    return $snapshot
}

function Clear-LocalCleanupGitEnvironment {
    $names = @(
        [Environment]::GetEnvironmentVariables(
            [EnvironmentVariableTarget]::Process
        ).Keys |
            Microsoft.PowerShell.Core\ForEach-Object { [string]$_ } |
            Microsoft.PowerShell.Core\Where-Object {
                $_.StartsWith(
                    'GIT_',
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    foreach ($name in $names) {
        Set-LocalCleanupProcessEnvironmentValue -Name $name -Value $null
    }
}

function Invoke-LocalCleanupGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [int[]]$AllowedExitCodes = @(0)
    )

    # PowerShell 5.1はnative stderrをerror recordへ変換するため、終了codeを
    # authoritativeに扱い、呼出し中だけErrorActionPreferenceを緩める。
    $previousErrorActionPreference = $ErrorActionPreference
    $previousGitEnvironment = Get-LocalCleanupGitEnvironmentSnapshot
    $output = @()
    $exitCode = -1
    $ErrorActionPreference = 'Continue'
    try {
        # -Cより強いambient GIT_DIR等を全除去し、引数Repositoryの境界を固定する。
        # 安全controlだけをhelper値で再設定し、値そのものはlogへ出さない。
        Clear-LocalCleanupGitEnvironment
        Set-LocalCleanupProcessEnvironmentValue `
            -Name 'GIT_CONFIG_GLOBAL' `
            -Value $script:LocalCleanupNullConfigPath
        Set-LocalCleanupProcessEnvironmentValue `
            -Name 'GIT_CONFIG_NOSYSTEM' `
            -Value '1'
        Set-LocalCleanupProcessEnvironmentValue `
            -Name 'GIT_TERMINAL_PROMPT' `
            -Value '0'
        $output = @(
            & $script:LocalCleanupGitCommand.Path `
                -c 'core.hooksPath=' `
                -c 'commit.gpgSign=false' `
                -C $RepositoryPath `
                @Arguments 2>&1
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        # 成否を問わずhelperが追加した値を除去し、存在と値をexactに復元する。
        Clear-LocalCleanupGitEnvironment
        foreach ($name in $previousGitEnvironment.Keys) {
            Set-LocalCleanupProcessEnvironmentValue `
                -Name $name `
                -Value $previousGitEnvironment[$name]
        }
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        $summary = (
            $output | Microsoft.PowerShell.Core\ForEach-Object { "$_" }
        ) -join [Environment]::NewLine
        throw "git command failed with exit $exitCode ($($Arguments -join ' ')). $summary"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ((
            $output | Microsoft.PowerShell.Core\ForEach-Object { "$_" }
        ) -join "`n").Trim()
    }
}

function Test-LocalCleanupTaskSlug {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    # branch名を組み立てる前に、config queryへ安全に埋め込めるASCII slugへ限定する。
    return $null -ne $Value -and $Value -cmatch '\A[a-z0-9-]+\z'
}

function Get-LocalCleanupLockPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    # linked worktree固有のgit dirではなくcommon git dirを使い、同repo内の
    # 全worktree/sessionが同じlock namespaceを共有する。
    $commonDirResult = Invoke-LocalCleanupGit `
        -RepositoryPath $RepositoryPath `
        -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    $commonDirLines = @(
        $commonDirResult.Output -split "`n" |
            Microsoft.PowerShell.Core\Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )
    if ($commonDirLines.Count -ne 1) {
        throw 'Git common directory resolution must return exactly one non-empty record.'
    }

    $commonDir = [System.IO.Path]::GetFullPath($commonDirLines[0])
    if (-not [System.IO.Directory]::Exists($commonDir)) {
        throw 'The resolved Git common directory does not exist.'
    }

    return [System.IO.Path]::Combine($commonDir, $script:LocalCleanupLockFileName)
}

function New-LocalCleanupLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # CreateNewは1回だけ試すnonblocking acquisition。既存lockがactiveかstaleかを
    # 推測して消さず、取得不能ならbranchを保持したままcallerを停止させる。
    $nonce = [guid]::NewGuid().ToString('N')
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch {
        return $null
    }

    try {
        $nonceBytes = $script:LocalCleanupUtf8NoBom.GetBytes($nonce)
        $stream.Write($nonceBytes, 0, $nonceBytes.Length)
        $stream.Flush()
        return [pscustomobject]@{
            Path = $Path
            Nonce = $nonce
            Stream = $stream
        }
    }
    catch {
        $stream.Dispose()
        # nonceの永続化に失敗した時点ではpathの所有を証明できない。自動削除せず、
        # stale/uncertain lockとして残すことで別ownerのlockを巻き込まない。
        throw
    }
}

function Get-LocalCleanupLockNonce {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock
    )

    # 所有handle自身からbounded lengthのnonceを読み、path差替えの影響を避ける。
    $stream = $Lock.Stream
    if ($null -eq $stream -or -not $stream.CanRead -or -not $stream.CanSeek) {
        return $null
    }
    if ($stream.Length -ne 32) {
        return $null
    }

    $previousPosition = $stream.Position
    try {
        $stream.Position = 0
        $bytes = [byte[]]::new(32)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                return $null
            }
            $offset += $read
        }
        return $script:LocalCleanupUtf8NoBom.GetString($bytes)
    }
    finally {
        $stream.Position = $previousPosition
    }
}

function Test-LocalCleanupLockOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock
    )

    $observedNonce = Get-LocalCleanupLockNonce -Lock $Lock
    return $null -ne $observedNonce -and $observedNonce -ceq $Lock.Nonce
}

function Assert-LocalCleanupLockOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock
    )

    # owner nonceが一致しない状態では、ref/configへの破壊操作へ進まない。
    if (-not (Test-LocalCleanupLockOwnership -Lock $Lock)) {
        throw 'Cleanup lock ownership is uncertain; preserving the local branch.'
    }
}

function Close-LocalCleanupLock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock
    )

    # finally releaseでもnonceを照合し、別ownerのpathを削除しない。
    $ownedBeforeClose = $false
    try {
        $ownedBeforeClose = Test-LocalCleanupLockOwnership -Lock $Lock
    }
    catch {
        $ownedBeforeClose = $false
    }

    try {
        $Lock.Stream.Dispose()
    }
    catch {
        return $false
    }

    if (-not $ownedBeforeClose) {
        return $false
    }

    try {
        $pathNonce = [System.IO.File]::ReadAllText(
            $Lock.Path,
            $script:LocalCleanupUtf8NoBom
        )
        if ($pathNonce -cne $Lock.Nonce) {
            return $false
        }
        [System.IO.File]::Delete($Lock.Path)
        return -not [System.IO.File]::Exists($Lock.Path)
    }
    catch {
        return $false
    }
}

function Get-LocalBranchConfigState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$TaskSlug
    )

    # TaskSlugは先にASCII kebabへ限定済みなのでPOSIX EREのmetacharを含まない。
    $pattern = "^branch\.fix/$TaskSlug\."
    $result = Invoke-LocalCleanupGit `
        -RepositoryPath $RepositoryPath `
        -Arguments @('config', '--local', '--get-regexp', $pattern) `
        -AllowedExitCodes @(0, 1)
    return [pscustomobject]@{
        Present = $result.ExitCode -eq 0
        Output = $result.Output
    }
}

function Get-LocalCleanupTemporaryConfigState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$Nonce
    )

    # owner nonce由来のsectionだけを照合する。caller入力やbranch名は混ぜない。
    if ($Nonce -cnotmatch '\A[0-9a-f]{32}\z') {
        throw 'Temporary branch config nonce must be exactly 32 lowercase hex characters.'
    }
    $pattern = "^branch\.codex-cleanup-$Nonce\."
    $result = Invoke-LocalCleanupGit `
        -RepositoryPath $RepositoryPath `
        -Arguments @('config', '--local', '--get-regexp', $pattern) `
        -AllowedExitCodes @(0, 1)
    return [pscustomobject]@{
        Present = $result.ExitCode -eq 0
        Output = $result.Output
    }
}

function Test-LocalBranchCheckedOut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$BranchRef
    )

    $branchRecords = @(
        Get-LocalCleanupWorktreeRecords -RepositoryPath $RepositoryPath |
            Microsoft.PowerShell.Core\Where-Object {
                $_.BranchRef -ceq $BranchRef
            }
    )
    return $branchRecords.Count -gt 0
}

function Get-LocalCleanupWorktreeRecords {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    # porcelainをrecord単位へ分解し、controlled guard pathとbranch refを同じ
    # record内で照合できる形にする。空行だけをrecord boundaryとして扱う。
    $worktreeResult = Invoke-LocalCleanupGit `
        -RepositoryPath $RepositoryPath `
        -Arguments @('worktree', 'list', '--porcelain')
    $records = @()
    $currentPath = $null
    $currentBranchRef = $null
    foreach ($rawLine in @($worktreeResult.Output -split "`n")) {
        $line = $rawLine.TrimEnd("`r")
        if ([string]::IsNullOrEmpty($line)) {
            if ($null -ne $currentPath) {
                $records += [pscustomobject]@{
                    Path = $currentPath
                    BranchRef = $currentBranchRef
                }
            }
            $currentPath = $null
            $currentBranchRef = $null
            continue
        }
        if ($line -clike 'worktree *') {
            $currentPath = [System.IO.Path]::GetFullPath($line.Substring(9))
            continue
        }
        if ($line -clike 'branch refs/heads/*') {
            $currentBranchRef = $line.Substring(7)
        }
    }
    if ($null -ne $currentPath) {
        $records += [pscustomobject]@{
            Path = $currentPath
            BranchRef = $currentBranchRef
        }
    }
    return @($records)
}

function Test-LocalCleanupPathEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    $comparison = if (
        [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    ) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ),
        [System.IO.Path]::GetFullPath($Right).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ),
        $comparison
    )
}

function New-LocalCleanupConfigWriterLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommonDirectory
    )

    # Git自身がlocal config更新に使うcommon-dir/config.lockだけを対象にする。
    # common dirやleafが差し替わった場合は、既存pathへ触れる前に拒否する。
    $commonDirectory = [System.IO.Path]::GetFullPath($ExpectedCommonDirectory)
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $expectedPath = [System.IO.Path]::Combine(
        $commonDirectory,
        $script:LocalCleanupConfigWriterLockFileName
    )
    if (
        -not [System.IO.Directory]::Exists($commonDirectory) -or
        -not (Test-LocalCleanupPathEqual -Left $resolvedPath -Right $expectedPath) -or
        -not (Test-LocalCleanupPathEqual `
            -Left ([System.IO.Path]::GetDirectoryName($resolvedPath)) `
            -Right $commonDirectory
        ) -or
        [System.IO.Path]::GetFileName($resolvedPath) -cne
            $script:LocalCleanupConfigWriterLockFileName
    ) {
        throw 'Git config writer lock path escaped the exact common directory.'
    }
    $commonAttributes = [System.IO.File]::GetAttributes($commonDirectory)
    if (
        ($commonAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw 'Git common directory must not be a reparse point.'
    }

    # CreateNewは待機も既存lock削除も行わない単発取得である。FileShare.Readは
    # ownerが保持中のpath contentを照合できる一方、通常writerの作成・更新を拒否する。
    $nonce = [guid]::NewGuid().ToString('N')
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $resolvedPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::Read
        )
    }
    catch {
        return $null
    }

    try {
        $nonceBytes = $script:LocalCleanupUtf8NoBom.GetBytes($nonce)
        $stream.Write($nonceBytes, 0, $nonceBytes.Length)
        $stream.Flush()
        return [pscustomobject]@{
            Path = $resolvedPath
            CommonDirectory = $commonDirectory
            Nonce = $nonce
            Stream = $stream
        }
    }
    catch {
        $stream.Dispose()
        # nonce永続化に失敗したpathは所有を証明できないため、自動削除しない。
        throw
    }
}

function Get-LocalCleanupConfigWriterLockPathNonce {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # owner streamはReadWrite accessを保持するため、path側readerも既存handleの
    # accessを許すshare modeで開く。32 bytes以外は読み込まずownership不一致とする。
    $pathStream = $null
    try {
        $pathStream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        if ($pathStream.Length -ne 32) {
            return $null
        }
        $bytes = [byte[]]::new(32)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $pathStream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                return $null
            }
            $offset += $read
        }
        return $script:LocalCleanupUtf8NoBom.GetString($bytes)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $pathStream) {
            $pathStream.Dispose()
        }
    }
}

function Test-LocalCleanupConfigWriterLockOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommonDirectory
    )

    try {
        # descriptor、root、leaf、regular-file属性、handle/path双方のnonceを照合する。
        # POSIXでpathがrename/recreateされた場合もpath側nonce差分でCAS前に拒否する。
        $commonDirectory = [System.IO.Path]::GetFullPath($ExpectedCommonDirectory)
        $resolvedExpectedPath = [System.IO.Path]::GetFullPath($ExpectedPath)
        $derivedExpectedPath = [System.IO.Path]::Combine(
            $commonDirectory,
            $script:LocalCleanupConfigWriterLockFileName
        )
        if (
            -not (Test-LocalCleanupPathEqual `
                -Left $resolvedExpectedPath `
                -Right $derivedExpectedPath
            ) -or
            -not (Test-LocalCleanupPathEqual `
                -Left $Lock.CommonDirectory `
                -Right $commonDirectory
            ) -or
            -not (Test-LocalCleanupPathEqual `
                -Left $Lock.Path `
                -Right $resolvedExpectedPath
            ) -or
            [System.IO.Path]::GetFileName($resolvedExpectedPath) -cne
                $script:LocalCleanupConfigWriterLockFileName -or
            -not [System.IO.Directory]::Exists($commonDirectory) -or
            -not [System.IO.File]::Exists($resolvedExpectedPath)
        ) {
            return $false
        }
        $commonAttributes = [System.IO.File]::GetAttributes($commonDirectory)
        $pathAttributes = [System.IO.File]::GetAttributes($resolvedExpectedPath)
        if (
            ($commonAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($pathAttributes -band [System.IO.FileAttributes]::Directory) -ne 0 -or
            ($pathAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            return $false
        }
        if (
            $Lock.Nonce -cnotmatch '\A[0-9a-f]{32}\z' -or
            (Get-LocalCleanupLockNonce -Lock $Lock) -cne $Lock.Nonce
        ) {
            return $false
        }
        $pathInfo = [System.IO.FileInfo]::new($resolvedExpectedPath)
        if ($pathInfo.Length -ne 32) {
            return $false
        }
        $pathNonce = Get-LocalCleanupConfigWriterLockPathNonce `
            -Path $resolvedExpectedPath
        return $pathNonce -ceq $Lock.Nonce
    }
    catch {
        return $false
    }
}

function Assert-LocalCleanupConfigWriterLockOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommonDirectory
    )

    if (-not (Test-LocalCleanupConfigWriterLockOwnership `
        -Lock $Lock `
        -ExpectedPath $ExpectedPath `
        -ExpectedCommonDirectory $ExpectedCommonDirectory
    )) {
        throw 'Git config writer lock ownership is uncertain; preserving the local branch.'
    }
}

function Close-LocalCleanupConfigWriterLock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedCommonDirectory
    )

    # owner handleを閉じる前後に同じexpected root/path/nonceを照合し、
    # descriptor driftやpath replacement時は推測削除せずuncertain lockを残す。
    $ownedBeforeClose = Test-LocalCleanupConfigWriterLockOwnership `
        -Lock $Lock `
        -ExpectedPath $ExpectedPath `
        -ExpectedCommonDirectory $ExpectedCommonDirectory
    try {
        $Lock.Stream.Dispose()
    }
    catch {
        return $false
    }
    if (-not $ownedBeforeClose) {
        return $false
    }

    try {
        $commonDirectory = [System.IO.Path]::GetFullPath($ExpectedCommonDirectory)
        $resolvedExpectedPath = [System.IO.Path]::GetFullPath($ExpectedPath)
        $derivedExpectedPath = [System.IO.Path]::Combine(
            $commonDirectory,
            $script:LocalCleanupConfigWriterLockFileName
        )
        if (
            -not (Test-LocalCleanupPathEqual `
                -Left $resolvedExpectedPath `
                -Right $derivedExpectedPath
            ) -or
            -not (Test-LocalCleanupPathEqual `
                -Left $Lock.Path `
                -Right $resolvedExpectedPath
            ) -or
            -not (Test-LocalCleanupPathEqual `
                -Left $Lock.CommonDirectory `
                -Right $commonDirectory
            ) -or
            -not [System.IO.File]::Exists($resolvedExpectedPath)
        ) {
            return $false
        }
        $commonAttributes = [System.IO.File]::GetAttributes($commonDirectory)
        $pathAttributes = [System.IO.File]::GetAttributes($resolvedExpectedPath)
        if (
            ($commonAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($pathAttributes -band [System.IO.FileAttributes]::Directory) -ne 0 -or
            ($pathAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            return $false
        }
        $pathNonce = Get-LocalCleanupConfigWriterLockPathNonce `
            -Path $resolvedExpectedPath
        if ($pathNonce -cne $Lock.Nonce) {
            return $false
        }
        [System.IO.File]::Delete($resolvedExpectedPath)
        return (
            -not [System.IO.File]::Exists($resolvedExpectedPath) -and
            -not [System.IO.Directory]::Exists($resolvedExpectedPath)
        )
    }
    catch {
        return $false
    }
}

function New-LocalCleanupGuardDescriptor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchRef,

        [Parameter(Mandatory = $true)]
        [string]$TaskSlug,

        [Parameter(Mandatory = $true)]
        [string]$Nonce,

        [Parameter(Mandatory = $true)]
        [string]$CommonDirectory
    )

    if ($Nonce -cnotmatch '\A[0-9a-f]{32}\z') {
        throw 'Guard worktree nonce must be exactly 32 lowercase hex characters.'
    }
    $temporaryParent = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    )
    $leafName = "codex-isolated-worktree-cleanup-guard-$Nonce"
    $guardPath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($temporaryParent, $leafName)
    )
    if (-not (Test-LocalCleanupPathEqual `
        -Left ([System.IO.Path]::GetDirectoryName($guardPath)) `
        -Right $temporaryParent
    )) {
        throw 'Guard worktree path escaped its exact temporary parent.'
    }

    return [pscustomobject]@{
        Path = $guardPath
        BranchRef = $BranchRef
        ShortBranch = "fix/$TaskSlug"
        CommonDirectory = [System.IO.Path]::GetFullPath($CommonDirectory)
        Attempted = $false
        Acquired = $false
    }
}

function Test-LocalCleanupGuardPathState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Guard
    )

    if (-not [System.IO.Directory]::Exists($Guard.Path)) {
        return $false
    }
    $rootAttributes = [System.IO.File]::GetAttributes($Guard.Path)
    if (
        ($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        return $false
    }

    # normal `git worktree add --no-checkout` が作るregular .git fileだけを
    # owner guard rootとして認める。追加entryやjunction/symlink差替えには触れない。
    $entries = @(
        [System.IO.Directory]::EnumerateFileSystemEntries($Guard.Path) |
            Microsoft.PowerShell.Utility\Select-Object -First 2
    )
    if ($entries.Count -ne 1) {
        return $false
    }
    $gitMarkerPath = [System.IO.Path]::Combine($Guard.Path, '.git')
    if (
        -not [System.IO.File]::Exists($gitMarkerPath) -or
        -not (Test-LocalCleanupPathEqual -Left $entries[0] -Right $gitMarkerPath)
    ) {
        return $false
    }
    $markerAttributes = [System.IO.File]::GetAttributes($gitMarkerPath)
    if (
        ($markerAttributes -band [System.IO.FileAttributes]::Directory) -ne 0 -or
        ($markerAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        return $false
    }

    # markerはexpected common-dir/worktrees/<exact-guard-leaf>だけを指せる。
    # boundedなregular file以外は読み込まず、別repo metadataへのredirectを拒否する。
    $markerInfo = [System.IO.FileInfo]::new($gitMarkerPath)
    if ($markerInfo.Length -le 0 -or $markerInfo.Length -gt 4096) {
        return $false
    }
    $markerText = [System.IO.File]::ReadAllText(
        $gitMarkerPath,
        $script:LocalCleanupUtf8NoBom
    )
    $markerMatch = [regex]::Match(
        $markerText,
        '\Agitdir: (?<path>[^\r\n]+)\r?\n?\z'
    )
    if (-not $markerMatch.Success) {
        return $false
    }
    $adminPath = [System.IO.Path]::GetFullPath(
        $markerMatch.Groups['path'].Value
    )
    $expectedAdminParent = [System.IO.Path]::Combine(
        $Guard.CommonDirectory,
        'worktrees'
    )
    if (
        -not (Test-LocalCleanupPathEqual `
            -Left ([System.IO.Path]::GetDirectoryName($adminPath)) `
            -Right $expectedAdminParent
        ) -or
        -not (Test-LocalCleanupPathEqual `
            -Left ([System.IO.Path]::GetFileName($adminPath)) `
            -Right ([System.IO.Path]::GetFileName($Guard.Path))
        ) -or
        -not [System.IO.Directory]::Exists($adminPath)
    ) {
        return $false
    }
    $adminAttributes = [System.IO.File]::GetAttributes($adminPath)
    return (
        ($adminAttributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
    )
}

function Test-LocalCleanupGuardInvariant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [object]$Guard
    )

    $records = @(Get-LocalCleanupWorktreeRecords -RepositoryPath $RepositoryPath)
    $pathRecords = @(
        $records |
            Microsoft.PowerShell.Core\Where-Object {
                Test-LocalCleanupPathEqual -Left $_.Path -Right $Guard.Path
            }
    )
    $branchRecords = @(
        $records |
            Microsoft.PowerShell.Core\Where-Object {
                $_.BranchRef -ceq $Guard.BranchRef
            }
    )
    return (
        $pathRecords.Count -eq 1 -and
        $branchRecords.Count -eq 1 -and
        $pathRecords[0].BranchRef -ceq $Guard.BranchRef -and
        (Test-LocalCleanupGuardPathState -Guard $Guard)
    )
}

function Open-LocalCleanupGuardWorktree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [object]$Guard
    )

    if (
        [System.IO.File]::Exists($Guard.Path) -or
        [System.IO.Directory]::Exists($Guard.Path)
    ) {
        throw 'Task-owned guard worktree path already exists; preserving the branch.'
    }

    # short branch名はGit自身のworktree occupancyを取得するためだけに使う。
    # 成功後は必ずfully-qualified refとのexact porcelain bindingを要求する。
    $Guard.Attempted = $true
    $addResult = Invoke-LocalCleanupGit `
        -RepositoryPath $RepositoryPath `
        -Arguments @(
            'worktree',
            'add',
            '--no-checkout',
            $Guard.Path,
            $Guard.ShortBranch
        ) `
        -AllowedExitCodes @(0, 1, 128)
    if ($addResult.ExitCode -ne 0) {
        throw 'Guard worktree could not acquire exclusive branch occupancy.'
    }
    $Guard.Acquired = $true
    if (-not (Test-LocalCleanupGuardInvariant `
        -RepositoryPath $RepositoryPath `
        -Guard $Guard
    )) {
        throw 'Guard worktree did not bind its exact path to the fully-qualified branch ref.'
    }
}

function Close-LocalCleanupGuardWorktree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [object]$Guard,

        [Parameter(Mandatory = $true)]
        [object]$Lock,

        [Parameter(Mandatory = $true)]
        [bool]$CasOutcomeKnown,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedOid
    )

    if (-not $Guard.Attempted) {
        return [pscustomobject]@{
            Released = $true
            Reason = 'guard acquisition was not attempted'
        }
    }

    try {
        # custom owner lockを失った場合はnative occupancyも保持し、外部回復へ渡す。
        Assert-LocalCleanupLockOwnership -Lock $Lock
        $records = @(Get-LocalCleanupWorktreeRecords -RepositoryPath $RepositoryPath)
        $pathRecords = @(
            $records |
                Microsoft.PowerShell.Core\Where-Object {
                    Test-LocalCleanupPathEqual -Left $_.Path -Right $Guard.Path
                }
        )
        if ($pathRecords.Count -eq 0) {
            $absent = (
                -not [System.IO.File]::Exists($Guard.Path) -and
                -not [System.IO.Directory]::Exists($Guard.Path)
            )
            return [pscustomobject]@{
                Released = $absent
                Reason = if ($absent) {
                    'guard add failed without creating path or metadata'
                } else {
                    'guard path exists without an attributable worktree record'
                }
            }
        }
        if (-not (Test-LocalCleanupGuardInvariant `
            -RepositoryPath $RepositoryPath `
            -Guard $Guard
        )) {
            return [pscustomobject]@{
                Released = $false
                Reason = 'guard path, branch, or sole-occupancy invariant changed'
            }
        }

        # まずnormal removeを試す。tracked fileを展開しないguardはrefが存在すると
        # dirty判定され得るため、CAS outcome既知かつexact owner stateのときだけ
        # Git自身のexact-path --forceをcleanup primitiveとして1回許す。
        $removeResult = Invoke-LocalCleanupGit `
            -RepositoryPath $RepositoryPath `
            -Arguments @('worktree', 'remove', $Guard.Path) `
            -AllowedExitCodes @(0, 1, 128)
        if ($removeResult.ExitCode -ne 0) {
            if (-not $CasOutcomeKnown) {
                # CAS前failureでも、refがexpected OIDのままかつowner guardがexactなら、
                # branchを触らないexact-path force removeだけをguard解放に許す。
                $releaseBranchOid = Get-LocalBranchOid `
                    -RepositoryPath $RepositoryPath `
                    -BranchRef $Guard.BranchRef
                if ($releaseBranchOid -cne $ExpectedOid) {
                    return [pscustomobject]@{
                        Released = $false
                        Reason = (
                            'normal guard removal failed before CAS and the branch ' +
                            'no longer equals the expected OID'
                        )
                    }
                }
            }
            if (-not (Test-LocalCleanupGuardInvariant `
                -RepositoryPath $RepositoryPath `
                -Guard $Guard
            )) {
                return [pscustomobject]@{
                    Released = $false
                    Reason = 'guard state changed after normal worktree removal was rejected'
                }
            }
            $forceResult = Invoke-LocalCleanupGit `
                -RepositoryPath $RepositoryPath `
                -Arguments @('worktree', 'remove', '--force', $Guard.Path) `
                -AllowedExitCodes @(0, 1, 128)
            if ($forceResult.ExitCode -ne 0) {
                return [pscustomobject]@{
                    Released = $false
                    Reason = "exact guard worktree force removal returned exit $($forceResult.ExitCode)"
                }
            }
        }
        $remainingRecords = @(
            Get-LocalCleanupWorktreeRecords -RepositoryPath $RepositoryPath |
                Microsoft.PowerShell.Core\Where-Object {
                    Test-LocalCleanupPathEqual -Left $_.Path -Right $Guard.Path
                }
        )
        $released = (
            $remainingRecords.Count -eq 0 -and
            -not [System.IO.File]::Exists($Guard.Path) -and
            -not [System.IO.Directory]::Exists($Guard.Path)
        )
        return [pscustomobject]@{
            Released = $released
            Reason = if ($released) {
                'exact worktree removal completed'
            } else {
                'guard path or metadata remained after normal worktree removal'
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Released = $false
            Reason = $_.Exception.Message
        }
    }
}

function Get-LocalBranchOid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$BranchRef
    )

    $result = Invoke-LocalCleanupGit `
        -RepositoryPath $RepositoryPath `
        -Arguments @('rev-parse', '--verify', $BranchRef) `
        -AllowedExitCodes @(0, 128)
    if ($result.ExitCode -ne 0) {
        return $null
    }
    return $result.Output
}

function Invoke-LocalBranchCleanupCore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$TaskSlug,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedOid,

        [scriptblock]$AfterWorktreeGateForTest,

        [scriptblock]$BeforeConfigRenameForTest,

        [scriptblock]$BeforeCasForTest,

        [scriptblock]$AfterConfigWriterLockForTest,

        [scriptblock]$AfterCasForTest
    )

    # LOCAL-CAS-PHASE: INPUT-VALIDATION
    # closure referenceをhook前にlocalへ固定し、同期hookがscript variableを差し替えても
    # alias/function integrityの再検査を迂回させない。
    $runtimeIntegrityGuard = $script:LocalCleanupRuntimeIntegrityGuard
    & $runtimeIntegrityGuard

    if (-not (Test-LocalCleanupTaskSlug -Value $TaskSlug)) {
        throw 'Task slug must contain only lowercase ASCII letters, digits, and hyphens.'
    }
    if ($ExpectedOid -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') {
        throw 'Expected head OID must be a lowercase 40- or 64-hex object ID.'
    }

    $resolvedRepository = [System.IO.Path]::GetFullPath($RepositoryPath)
    $branchRef = "refs/heads/fix/$TaskSlug"
    $originalConfigSection = "branch.fix/$TaskSlug"
    # LOCAL-CAS-PHASE: LOCK-ACQUIRE
    $lockPath = Get-LocalCleanupLockPath -RepositoryPath $resolvedRepository
    $lock = New-LocalCleanupLock -Path $lockPath
    if ($null -eq $lock) {
        throw 'Repository cleanup lock is unavailable; preserving the local branch.'
    }

    $gitCommonDirectory = [System.IO.Path]::GetDirectoryName($lockPath)
    $configWriterLockPath = [System.IO.Path]::Combine(
        $gitCommonDirectory,
        $script:LocalCleanupConfigWriterLockFileName
    )
    $temporaryConfigSection = "branch.codex-cleanup-$($lock.Nonce)"
    $guard = New-LocalCleanupGuardDescriptor `
        -BranchRef $branchRef `
        -TaskSlug $TaskSlug `
        -Nonce $lock.Nonce `
        -CommonDirectory ([System.IO.Path]::GetDirectoryName($lockPath))
    $configMoved = $false
    $expectedTemporaryConfigOutput = $null
    $casSucceeded = $false
    $casOutcomeKnown = $false
    $primaryFailure = $null
    $recoveryFailure = $null
    $configWriterLock = $null
    $configWriterLockAcquisitionUncertain = $false
    $configWriterLockReleased = $false
    $configWriterLockReleaseFailure = $null
    $preserveLock = $false
    try {
        # LOCAL-CAS-PHASE: PRECHECK
        # lock取得後のcritical section内だけを成功条件に使い、外側の観測は参照しない。
        Assert-LocalCleanupLockOwnership -Lock $lock
        $observedOid = Get-LocalBranchOid `
            -RepositoryPath $resolvedRepository `
            -BranchRef $branchRef
        if ($observedOid -cne $ExpectedOid) {
            throw 'Local branch no longer equals the expected PR head.'
        }
        # fixture hookはnative occupancy取得直前へ通常checkout actorを差し込む。
        # Git自身のworktree addが競合をatomicに拒否することを回帰検証する。
        if ($null -ne $AfterWorktreeGateForTest) {
            & $AfterWorktreeGateForTest $lock $guard
        }
        & $runtimeIntegrityGuard

        Assert-LocalCleanupLockOwnership -Lock $lock
        $observedOid = Get-LocalBranchOid `
            -RepositoryPath $resolvedRepository `
            -BranchRef $branchRef
        if ($observedOid -cne $ExpectedOid) {
            throw 'Local branch drifted before guard acquisition; preserving the new tip.'
        }
        # 既に存在する標準config.lockはactive/stale/reparseを推測せず、native
        # guard取得前に拒否する。absence観測後のraceは最終CreateNewでも再度拒否する。
        if (
            [System.IO.File]::Exists($configWriterLockPath) -or
            [System.IO.Directory]::Exists($configWriterLockPath)
        ) {
            throw 'Git config writer lock is unavailable; preserving the local branch.'
        }

        # LOCAL-CAS-PHASE: GUARD-ACQUIRE
        # short branch operandでGit native occupancyを保持する。直後にcontrolled pathと
        # fully-qualified refの1対1 bindingを検証し、detached/ambiguous結果を拒否する。
        Open-LocalCleanupGuardWorktree `
            -RepositoryPath $resolvedRepository `
            -Guard $guard

        # LOCAL-CAS-PHASE: CONFIG-ISOLATION
        # branch configをowner nonce付き一時sectionへrenameし、CAS後に同名branchを
        # 再作成したactorの新configと区別する。元sectionを後から直接削除しない。
        $originalConfig = Get-LocalBranchConfigState `
            -RepositoryPath $resolvedRepository `
            -TaskSlug $TaskSlug
        if ($originalConfig.Present) {
            $temporaryConfig = Get-LocalCleanupTemporaryConfigState `
                -RepositoryPath $resolvedRepository `
                -Nonce $lock.Nonce
            if ($temporaryConfig.Present) {
                throw 'Owner-scoped temporary branch config already exists.'
            }
            # fixture hookはread/checkとrenameの間へ通常config writerを差し込む。
            # rename後snapshotの差分でactor payloadをowner dataとして誤削除しない。
            if ($null -ne $BeforeConfigRenameForTest) {
                & $BeforeConfigRenameForTest
            }
            & $runtimeIntegrityGuard
            Invoke-LocalCleanupGit `
                -RepositoryPath $resolvedRepository `
                -Arguments @(
                    'config',
                    '--local',
                    '--rename-section',
                    $originalConfigSection,
                    $temporaryConfigSection
                ) | Microsoft.PowerShell.Core\Out-Null
            $configMoved = $true
            $expectedTemporaryConfigOutput = $originalConfig.Output.Replace(
                "$originalConfigSection.",
                "$temporaryConfigSection."
            )
            $isolatedTemporaryConfig = Get-LocalCleanupTemporaryConfigState `
                -RepositoryPath $resolvedRepository `
                -Nonce $lock.Nonce
            if (-not $isolatedTemporaryConfig.Present -or
                $isolatedTemporaryConfig.Output -cne
                    $expectedTemporaryConfigOutput) {
                throw (
                    'Branch config changed while owner isolation was acquired; ' +
                    'preserving the ref, temporary config, guard, and lock.'
                )
            }
            $originalConfigAfterIsolation = Get-LocalBranchConfigState `
                -RepositoryPath $resolvedRepository `
                -TaskSlug $TaskSlug
            if ($originalConfigAfterIsolation.Present) {
                throw (
                    'Original branch config was recreated during owner isolation; ' +
                    'preserving both config sections.'
                )
            }
        }

        # LOCAL-CAS-PHASE: FINAL-PRE-CAS
        # config rename後にもlock/ref/native guardを再確認し、CAS直前の状態だけを採用する。
        Assert-LocalCleanupLockOwnership -Lock $lock
        $observedOid = Get-LocalBranchOid `
            -RepositoryPath $resolvedRepository `
            -BranchRef $branchRef
        if ($observedOid -cne $ExpectedOid) {
            throw 'Local branch drifted after config isolation; preserving it.'
        }
        if (-not (Test-LocalCleanupGuardInvariant `
            -RepositoryPath $resolvedRepository `
            -Guard $guard
        )) {
            throw 'Guard worktree occupancy changed after config isolation.'
        }

        # fixture hookはCAS直前へref/config driftを差し込み、expected old OID拒否と
        # owner config sectionのfail-closed保持を回帰検証する。
        if ($null -ne $BeforeCasForTest) {
            & $BeforeCasForTest $lock $guard
        }
        & $runtimeIntegrityGuard

        # test hookを含む最後の外部処理後にもowner/native guardを再確認する。
        # nonceやoccupancyが変わった状態でCASへ進まない。
        Assert-LocalCleanupLockOwnership -Lock $lock
        if (-not (Test-LocalCleanupGuardInvariant `
            -RepositoryPath $resolvedRepository `
            -Guard $guard
        )) {
            throw 'Guard worktree occupancy changed immediately before CAS.'
        }
        # LOCAL-CAS-PHASE: CONFIG-WRITER-LOCK-ACQUIRE
        # BeforeCas actorが終わった後でGit標準config.lockを単発取得し、以降の
        # config absence確認からCAS/postcheckまで通常Git writerを排他する。
        try {
            $configWriterLock = New-LocalCleanupConfigWriterLock `
                -Path $configWriterLockPath `
                -ExpectedCommonDirectory $gitCommonDirectory
        }
        catch {
            # CreateNew後のnonce write/Flush失敗はpath所有を証明できない。
            # uncertain pathを推測削除せず、guard/custom lockも回復識別子として残す。
            $configWriterLockAcquisitionUncertain = $true
            throw
        }
        if ($null -eq $configWriterLock) {
            throw 'Git config writer lock is unavailable; preserving the local branch.'
        }
        if ($null -ne $AfterConfigWriterLockForTest) {
            & $AfterConfigWriterLockForTest $configWriterLock $guard
        }
        & $runtimeIntegrityGuard
        Assert-LocalCleanupConfigWriterLockOwnership `
            -Lock $configWriterLock `
            -ExpectedPath $configWriterLockPath `
            -ExpectedCommonDirectory $gitCommonDirectory
        Assert-LocalCleanupLockOwnership -Lock $lock
        if (-not (Test-LocalCleanupGuardInvariant `
            -RepositoryPath $resolvedRepository `
            -Guard $guard
        )) {
            throw 'Guard worktree occupancy changed after config writer lock acquisition.'
        }

        # configless開始でもBeforeCas actorが元sectionを作れる。writer lock保持中に
        # 必ず元sectionを再照合し、存在時はCAS前に拒否する。
        $preCasOriginalConfig = Get-LocalBranchConfigState `
            -RepositoryPath $resolvedRepository `
            -TaskSlug $TaskSlug
        if ($configMoved) {
            $preCasTemporaryConfig = Get-LocalCleanupTemporaryConfigState `
                -RepositoryPath $resolvedRepository `
                -Nonce $lock.Nonce
            if (-not $preCasTemporaryConfig.Present -or
                $preCasTemporaryConfig.Output -cne
                    $expectedTemporaryConfigOutput) {
                throw (
                    'Owner temporary config changed immediately before CAS; ' +
                    'preserving all attributable state.'
                )
            }
            if ($preCasOriginalConfig.Present) {
                throw (
                    'Original branch config was recreated immediately before CAS; ' +
                    'preserving both config sections.'
                )
            }
            # Git configにはsection全体のexpected-value deleteが無い。queryと
            # --remove-sectionを分けると、その間の同nonce writerを消し得るため、
            # configを隔離したbranchはCAS自体を拒否してexplicit recoveryへ渡す。
            throw (
                'Automatic local branch CAS was refused because owner config ' +
                'cannot be deleted with an atomic expected-value operation.'
            )
        }
        if ($preCasOriginalConfig.Present) {
            throw (
                'Original branch config appeared before configless CAS; ' +
                'the ref and actor config were preserved.'
            )
        }

        # LOCAL-CAS-PHASE: CAS-DELETE
        $casResult = Invoke-LocalCleanupGit `
            -RepositoryPath $resolvedRepository `
            -Arguments @('update-ref', '-d', $branchRef, $ExpectedOid) `
            -AllowedExitCodes @(0, 1, 128)
        $casOutcomeKnown = $true
        if ($casResult.ExitCode -ne 0) {
            throw 'Expected-OID local branch deletion was rejected; preserving the new tip.'
        }
        $casSucceeded = $true

        # fixture hookはconfigless CAS後の同名branch/config再作成を差し込み、
        # 新actorのstateを保持することを回帰検証する。
        if ($null -ne $AfterCasForTest) {
            & $AfterCasForTest $guard
        }
        & $runtimeIntegrityGuard

        # LOCAL-CAS-PHASE: POST-CAS-CHECK
        Assert-LocalCleanupConfigWriterLockOwnership `
            -Lock $configWriterLock `
            -ExpectedPath $configWriterLockPath `
            -ExpectedCommonDirectory $gitCommonDirectory
        Assert-LocalCleanupLockOwnership -Lock $lock
        if (-not (Test-LocalCleanupGuardInvariant `
            -RepositoryPath $resolvedRepository `
            -Guard $guard
        )) {
            throw 'Guard worktree occupancy changed after CAS.'
        }
        $postCasOid = Get-LocalBranchOid `
            -RepositoryPath $resolvedRepository `
            -BranchRef $branchRef
        if ($null -ne $postCasOid) {
            throw 'Local branch was recreated after CAS; preserving the recreated tip.'
        }
        $reflogResult = Invoke-LocalCleanupGit `
            -RepositoryPath $resolvedRepository `
            -Arguments @('reflog', 'exists', $branchRef) `
            -AllowedExitCodes @(0, 1)
        if ($reflogResult.ExitCode -ne 1) {
            throw 'Deleted local branch reflog still exists.'
        }
        $recreatedConfig = Get-LocalBranchConfigState `
            -RepositoryPath $resolvedRepository `
            -TaskSlug $TaskSlug
        if ($recreatedConfig.Present) {
            throw 'Local branch config was recreated after CAS; preserving it.'
        }

        # LOCAL-CAS-PHASE: OWNER-CONFIG-CLEANUP
        # config付きbranchはCAS前に必ず拒否するため、ここへconfigMoved=trueで
        # 到達してはならない。防御的にも自動removeは行わず、全stateを保持する。
        if ($configMoved) {
            throw (
                'Owner config unexpectedly reached post-CAS cleanup; ' +
                'automatic temporary-section deletion was refused.'
            )
        }

        # LOCAL-CAS-PHASE: FINAL-CHECK
        # lock解放前にcritical section内で最終状態を再確認する。
        Assert-LocalCleanupConfigWriterLockOwnership `
            -Lock $configWriterLock `
            -ExpectedPath $configWriterLockPath `
            -ExpectedCommonDirectory $gitCommonDirectory
        Assert-LocalCleanupLockOwnership -Lock $lock
        if (-not (Test-LocalCleanupGuardInvariant `
            -RepositoryPath $resolvedRepository `
            -Guard $guard
        )) {
            throw 'Guard worktree occupancy changed before cleanup completed.'
        }
        $finalBranchOid = Get-LocalBranchOid `
            -RepositoryPath $resolvedRepository `
            -BranchRef $branchRef
        if ($null -ne $finalBranchOid) {
            throw 'Local branch reappeared before cleanup completed.'
        }
        $finalBranchConfig = Get-LocalBranchConfigState `
            -RepositoryPath $resolvedRepository `
            -TaskSlug $TaskSlug
        if ($finalBranchConfig.Present) {
            throw 'Local branch config reappeared before cleanup completed.'
        }

        return [pscustomobject]@{
            BranchRef = $branchRef
            ExpectedHeadOid = $ExpectedOid
            ConfigRemoved = $false
        }
    }
    catch {
        $primaryFailure = $_

        # CAS前のrename-backは別actorが再作成した元sectionと競合し、payloadを
        # merge/上書きし得る。owner一時sectionは触らず、guard/lockと共に外部回復へ渡す。
        if (-not $casSucceeded -and $configMoved) {
            try {
                throw (
                    'Automatic owner config rename-back was refused after a ' +
                    'pre-CAS failure; the temporary config requires explicit recovery.'
                )
            }
            catch {
                # 意図的な回復拒否も一次failureへ隠さず、owner lockを回復識別子として残す。
                $recoveryFailure = $_
            }
        }

        # 防御的にconfigMoved=trueのpost-CAS failureへ入っても、Git configに
        # atomic expected-value section deleteが無いため自動cleanupを行わない。
        if ($casSucceeded -and $configMoved) {
            try {
                throw (
                    'Automatic owner temporary config deletion was refused; ' +
                    'Git config has no atomic expected-value section delete.'
                )
            }
            catch {
                # data-lossを避け、owner temp/guard/lockをexternal recoveryへ渡す。
                $recoveryFailure = $_
            }
        }

        if ($null -ne $recoveryFailure) {
            $preserveLock = $true
            throw (
                "Local cleanup failed and automatic owner recovery was refused or failed; " +
                "the cleanup lock and guard worktree were preserved at " +
                "'$($lock.Path)' and '$($guard.Path)'. " +
                "Primary failure: $($primaryFailure.Exception.Message) " +
                "Recovery failure: $($recoveryFailure.Exception.Message)"
            )
        }

        throw
    }
    finally {
        # LOCAL-CAS-PHASE: CONFIG-WRITER-LOCK-RELEASE
        # Git標準lockをowner確認付きで先に解放する。不確実ならguard/custom lockも
        # 保持し、別ownerのconfig.lockを推測削除しない。
        if ($configWriterLockAcquisitionUncertain) {
            try {
                throw (
                    'Git config writer lock acquisition became uncertain after ' +
                    'CreateNew; automatic path deletion was refused.'
                )
            }
            catch {
                $configWriterLockReleaseFailure = $_
                if ($null -eq $recoveryFailure) {
                    $recoveryFailure = $_
                }
            }
        }
        if ($null -ne $configWriterLock) {
            $configWriterLockReleased = Close-LocalCleanupConfigWriterLock `
                -Lock $configWriterLock `
                -ExpectedPath $configWriterLockPath `
                -ExpectedCommonDirectory $gitCommonDirectory
            if (-not $configWriterLockReleased) {
                try {
                    throw (
                        'Git config writer lock could not be released with exact ' +
                        'owner, path, root, and nonce proof.'
                    )
                }
                catch {
                    $configWriterLockReleaseFailure = $_
                    if ($null -eq $recoveryFailure) {
                        $recoveryFailure = $_
                    }
                }
            }
        }

        # LOCAL-CAS-PHASE: GUARD-RELEASE
        # owner config回復が失敗した場合はnative occupancyも回復識別子として残す。
        # それ以外はnormal removeだけを試し、失敗時にbranchを追加削除しない。
        $guardReleased = $false
        $guardReleaseReason = 'guard was intentionally preserved'
        if ($null -ne $recoveryFailure) {
            $preserveLock = $true
        } else {
            $guardReleaseResult = Close-LocalCleanupGuardWorktree `
                -RepositoryPath $resolvedRepository `
                -Guard $guard `
                -Lock $lock `
                -CasOutcomeKnown $casOutcomeKnown `
                -ExpectedOid $ExpectedOid
            $guardReleased = $guardReleaseResult.Released
            $guardReleaseReason = $guardReleaseResult.Reason
            if (-not $guardReleased) {
                $preserveLock = $true
            }
        }

        # LOCAL-CAS-PHASE: LOCK-RELEASE
        if ($preserveLock) {
            try {
                $lock.Stream.Dispose()
            }
            catch {
                Microsoft.PowerShell.Utility\Write-Warning `
                    'Recovery lock handle could not be closed; its path was preserved.'
            }
        } else {
            $released = Close-LocalCleanupLock -Lock $lock
            if (-not $released) {
                if ($null -eq $primaryFailure) {
                    throw 'Cleanup completed but the owner lock could not be released safely.'
                }
                Microsoft.PowerShell.Utility\Write-Warning `
                    'Cleanup lock release also failed; the uncertain lock was preserved.'
            }
        }
        if ($null -eq $recoveryFailure -and -not $guardReleased) {
            $primaryMessage = if ($null -eq $primaryFailure) {
                'none; the main cleanup path completed'
            } else {
                $primaryFailure.Exception.Message
            }
            throw (
                "Local cleanup guard recovery failed; the cleanup lock and " +
                "guard worktree were preserved at '$($lock.Path)' and " +
                "'$($guard.Path)'. No fallback branch deletion was attempted. " +
                "Primary failure: $primaryMessage " +
                "Guard recovery failure: $guardReleaseReason"
            )
        }
        if ($null -ne $configWriterLockReleaseFailure) {
            $primaryMessage = if ($null -eq $primaryFailure) {
                'none; the main cleanup path completed'
            } else {
                $primaryFailure.Exception.Message
            }
            throw (
                "Local cleanup config writer lock release failed; the uncertain " +
                "config lock, cleanup lock, and guard worktree were preserved at " +
                "'$configWriterLockPath', '$($lock.Path)', and '$($guard.Path)'. " +
                "Primary failure: $primaryMessage " +
                "Writer lock failure: $($configWriterLockReleaseFailure.Exception.Message)"
            )
        }
    }
}

function Remove-IsolatedWorktreeLocalBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$TaskSlug,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedOid
    )

    # public entrypointはtest hookを公開せず、実行直前のreviewed function identityを検査する。
    $runtimeIntegrityGuard = $script:LocalCleanupRuntimeIntegrityGuard
    & $runtimeIntegrityGuard
    return Invoke-LocalBranchCleanupCore `
        -RepositoryPath $RepositoryPath `
        -TaskSlug $TaskSlug `
        -ExpectedOid $ExpectedOid
}

$script:LocalCleanupRuntimeIntegrityGuard =
    & ${function:New-LocalCleanupRuntimeIntegrityGuard}
& $script:LocalCleanupRuntimeIntegrityGuard

if ($MyInvocation.InvocationName -ne '.') {
    $result = & ${function:Remove-IsolatedWorktreeLocalBranch} `
        -RepositoryPath $Repository `
        -TaskSlug $TaskSlug `
        -ExpectedOid $ExpectedHeadOid
    Microsoft.PowerShell.Utility\Write-Host `
        "Local branch cleanup passed for $($result.BranchRef)."
}
