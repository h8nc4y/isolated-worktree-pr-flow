[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gitCommand = Get-Command git -ErrorAction Stop
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$assertionCount = 0
$tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ("isolated-worktree-pr-flow-" + [guid]::NewGuid().ToString('N'))
$isolatedGlobalConfig = Join-Path $testRoot 'empty-global.gitconfig'
$isolatedHooksPath = Join-Path $testRoot 'empty-hooks'
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$pathComparison = if ($isWindowsPlatform) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDirectory 'remove-local-branch-cas.ps1')

function Set-ProcessEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    # PowerShell can coerce a null string argument to an empty environment
    # value, which Git still treats as an active (and invalid) path override.
    # Use the Env provider to remove null values completely.
    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
        return
    }

    [Environment]::SetEnvironmentVariable($Name, [string]$Value, 'Process')
}

function Get-GitProcessEnvironmentSnapshot {
    $snapshot = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
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

function Clear-GitProcessEnvironment {
    $names = @(
        [Environment]::GetEnvironmentVariables('Process').Keys |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -match '^GIT_' }
    )
    foreach ($name in $names) {
        Set-ProcessEnvironmentValue -Name $name -Value $null
    }
}

function Test-GitProcessEnvironmentSnapshotEqual {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$Left,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$Right
    )

    if ($Left.Count -ne $Right.Count) {
        return $false
    }
    foreach ($name in $Left.Keys) {
        if (-not $Right.ContainsKey($name) -or
            -not [string]::Equals(
                [string]$Left[$name],
                [string]$Right[$name],
                [System.StringComparison]::Ordinal
            )) {
            return $false
        }
    }
    return $true
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [int[]]$AllowedExitCodes = @(0)
    )

    # PowerShell 5.1 converts native stderr to error records. Keep this
    # invocation on Continue and treat the native exit code as authoritative.
    $previousErrorActionPreference = $ErrorActionPreference
    $previousGitEnvironment = Get-GitProcessEnvironmentSnapshot
    $output = @()
    $exitCode = -1
    $ErrorActionPreference = 'Continue'
    try {
        # Every synthetic Git call is isolated from machine/user config,
        # signing, hooks, and updateRefs so external policy cannot alter the
        # commit graph or turn a passing topology test into a false failure.
        Clear-GitProcessEnvironment
        Set-ProcessEnvironmentValue -Name 'GIT_CONFIG_GLOBAL' -Value $isolatedGlobalConfig
        Set-ProcessEnvironmentValue -Name 'GIT_CONFIG_NOSYSTEM' -Value '1'
        Set-ProcessEnvironmentValue -Name 'GIT_TERMINAL_PROMPT' -Value '0'
        $isolationArguments = @(
            '-c', "core.hooksPath=$isolatedHooksPath",
            '-c', 'commit.gpgSign=false',
            '-c', 'rebase.updateRefs=false'
        )
        $output = @(& $gitCommand.Source @isolationArguments -C $Repository @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Clear-GitProcessEnvironment
        foreach ($name in $previousGitEnvironment.Keys) {
            Set-ProcessEnvironmentValue -Name $name -Value $previousGitEnvironment[$name]
        }
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        $summary = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        throw "git command failed with exit $exitCode ($($Arguments -join ' ')). $summary"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    }
}

function Assert-ExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [int]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Result.ExitCode -ne $Expected) {
        throw "$Message (expected exit $Expected, actual $($Result.ExitCode))"
    }

    $script:assertionCount++
}

function Assert-Equal {
    param(
        [AllowEmptyString()]
        [string]$Actual,

        [AllowEmptyString()]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message (values differ)"
    }

    $script:assertionCount++
}

function Assert-NotEqual {
    param(
        [AllowEmptyString()]
        [string]$Actual,

        [AllowEmptyString()]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ceq $Expected) {
        throw "$Message (values unexpectedly match)"
    }

    $script:assertionCount++
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }

    $script:assertionCount++
}

function Assert-False {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Condition) {
        throw $Message
    }

    $script:assertionCount++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $caughtMessage = $null
    try {
        & $Action
    }
    catch {
        $caughtMessage = $_.Exception.Message
    }

    if ($null -eq $caughtMessage) {
        throw "$Message (no exception was thrown)"
    }
    if ($caughtMessage -notmatch $Pattern) {
        throw "$Message (unexpected exception: $caughtMessage)"
    }

    $script:assertionCount++
}

function Write-FixtureFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Initialize-FixtureRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    New-Item -ItemType Directory -Path $Path | Out-Null
    Invoke-Git -Repository $Path -Arguments @('init', '-b', 'main') | Out-Null
    Invoke-Git -Repository $Path -Arguments @('config', 'user.name', 'Cleanup Guard Test') | Out-Null
    $fixtureEmail = 'cleanup-guard' + '@' + 'example.invalid'
    Invoke-Git -Repository $Path -Arguments @('config', 'user.email', $fixtureEmail) | Out-Null
    Invoke-Git -Repository $Path -Arguments @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-Git -Repository $Path -Arguments @('config', 'core.hooksPath', $isolatedHooksPath) | Out-Null
    Invoke-Git -Repository $Path -Arguments @('config', 'commit.gpgSign', 'false') | Out-Null
    Invoke-Git -Repository $Path -Arguments @('config', 'rebase.updateRefs', 'false') | Out-Null

    Write-FixtureFile -Path (Join-Path $Path 'base.txt') -Content "base`n"
    Invoke-Git -Repository $Path -Arguments @('add', '--', 'base.txt') | Out-Null
    Invoke-Git -Repository $Path -Arguments @('commit', '-m', 'base') | Out-Null
}

function Add-Commit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-FixtureFile -Path (Join-Path $Repository $RelativePath) -Content $Content
    Invoke-Git -Repository $Repository -Arguments @('add', '--', $RelativePath) | Out-Null
    Invoke-Git -Repository $Repository -Arguments @('commit', '-m', $Message) | Out-Null
}

function Test-PathTextEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right,

        [Parameter(Mandatory = $true)]
        [System.StringComparison]$Comparison
    )

    return $Left.Equals($Right, $Comparison)
}

function Test-AttributesAllowRecursiveRemoval {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileAttributes]$Attributes
    )

    return ($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
}

function Test-FixtureRootBoundary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$TemporaryParent
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $separatorCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $resolvedTemporaryParent = [System.IO.Path]::GetFullPath($TemporaryParent)
    $resolvedTemporaryParent = $resolvedTemporaryParent.TrimEnd($separatorCharacters)
    $resolvedRootParent = [System.IO.Path]::GetDirectoryName($resolvedRoot)
    if ([string]::IsNullOrEmpty($resolvedRootParent)) {
        return $false
    }
    $resolvedRootParent = $resolvedRootParent.TrimEnd($separatorCharacters)
    $rootName = [System.IO.Path]::GetFileName($resolvedRoot)

    return (
        -not (Test-PathTextEqual -Left $resolvedRoot -Right $resolvedTemporaryParent -Comparison $pathComparison) -and
        (Test-PathTextEqual -Left $resolvedRootParent -Right $resolvedTemporaryParent -Comparison $pathComparison) -and
        $rootName -cmatch '^isolated-worktree-pr-flow-[0-9a-f]{32}$'
    )
}

function Remove-FixtureRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$TemporaryParent
    )

    # Recursive deletion is allowed only for this run's direct, GUID-named
    # child below the OS temp root. The temp root itself always fails shut.
    if (-not (Test-FixtureRootBoundary -Root $Root -TemporaryParent $TemporaryParent)) {
        throw 'Refusing to remove a cleanup-guard fixture outside the OS temporary directory.'
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    if (Test-Path -LiteralPath $resolvedRoot) {
        $rootItem = Get-Item -LiteralPath $resolvedRoot
        if (-not (Test-AttributesAllowRecursiveRemoval -Attributes $rootItem.Attributes)) {
            throw 'Refusing to recursively remove a cleanup-guard fixture through a reparse point.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

$primaryFailure = $null

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    New-Item -ItemType Directory -Path $isolatedHooksPath | Out-Null
    [System.IO.File]::WriteAllText($isolatedGlobalConfig, '', $utf8NoBom)

    # Exercise the destructive cleanup boundary without deleting invalid
    # candidates: only the direct GUID child generated for this run is valid.
    Assert-True -Condition (Test-FixtureRootBoundary -Root $testRoot -TemporaryParent $tempParent) `
        -Message 'The generated fixture root must satisfy the cleanup boundary'
    Assert-False -Condition (Test-FixtureRootBoundary -Root $tempParent -TemporaryParent $tempParent) `
        -Message 'The OS temporary root itself must never satisfy the cleanup boundary'
    Assert-False `
        -Condition (Test-FixtureRootBoundary -Root (Join-Path $tempParent 'isolated-worktree-pr-flow-not-a-guid') -TemporaryParent $tempParent) `
        -Message 'A non-GUID fixture name must never satisfy the cleanup boundary'
    Assert-False `
        -Condition (Test-FixtureRootBoundary -Root (Join-Path $testRoot 'nested') -TemporaryParent $tempParent) `
        -Message 'A nested path must never satisfy the direct-child cleanup boundary'
    Assert-False `
        -Condition (Test-PathTextEqual -Left '/tmp' -Right '/TMP' -Comparison ([System.StringComparison]::Ordinal)) `
        -Message 'POSIX path comparison must keep differently-cased siblings distinct'
    Assert-False `
        -Condition (Test-AttributesAllowRecursiveRemoval -Attributes ([System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint)) `
        -Message 'A reparse-point directory must never enter recursive removal'

    # production snapshot自身がOrdinal comparerを持つことを全OSで実測する。
    # case-sensitive hostだけで再現する環境変数名の衝突をWindowsでも回帰検出できる。
    $caseVariantSnapshot = Get-LocalCleanupGitEnvironmentSnapshot
    $caseVariantCountBefore = $caseVariantSnapshot.Count
    $caseVariantUpperName = (
        'GIT_CODEX_CASE_' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
    )
    $caseVariantLowerName = $caseVariantUpperName.ToLowerInvariant()
    $caseVariantSnapshot[$caseVariantUpperName] = 'upper'
    $caseVariantSnapshot[$caseVariantLowerName] = 'lower'
    Assert-Equal `
        -Actual $caseVariantSnapshot.Count `
        -Expected ($caseVariantCountBefore + 2) `
        -Message 'Snapshot comparer must preserve differently-cased GIT names'
    Assert-Equal `
        -Actual $caseVariantSnapshot[$caseVariantUpperName] `
        -Expected 'upper' `
        -Message 'Snapshot comparer must preserve the uppercase GIT value'
    Assert-Equal `
        -Actual $caseVariantSnapshot[$caseVariantLowerName] `
        -Expected 'lower' `
        -Message 'Snapshot comparer must preserve the lowercase git value'

    # Merge-commit mode preserves the source commits as main ancestors, which
    # is the positive path for guard 2a before a normal branch -d.
    $mergeRepository = Join-Path $testRoot 'merge'
    Initialize-FixtureRepository -Path $mergeRepository
    $mergeBaseOid = (Invoke-Git -Repository $mergeRepository `
        -Arguments @('rev-parse', 'refs/heads/main')).Output
    Invoke-Git -Repository $mergeRepository -Arguments @('switch', '-c', 'fix/merge') | Out-Null
    Add-Commit -Repository $mergeRepository -RelativePath 'feature.txt' -Content "merge`n" -Message 'feature'
    $mergeHeadRefOid = (Invoke-Git -Repository $mergeRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/merge')).Output
    Invoke-Git -Repository $mergeRepository -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -Repository $mergeRepository `
        -Arguments @('merge', '--no-ff', 'refs/heads/fix/merge', '-m', 'merge result') | Out-Null
    Invoke-Git -Repository $mergeRepository `
        -Arguments @('update-ref', 'refs/remotes/origin/main', 'refs/heads/main') | Out-Null

    $mergeBranchAncestor = Invoke-Git -Repository $mergeRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            'refs/heads/fix/merge',
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $mergeBranchAncestor -Expected 0 `
        -Message 'Guard 2a must accept a branch landed by merge commit'

    # 同名tagが短縮refを奪うと、進んだbranchではなくmerge済みtagを検証して
    # guard 2aがfalse-passする。fully-qualified branch refだけを安全条件に使う。
    Invoke-Git -Repository $mergeRepository -Arguments @('switch', 'fix/merge') | Out-Null
    Add-Commit -Repository $mergeRepository -RelativePath 'late.txt' `
        -Content "late`n" -Message 'late merge-mode commit'
    Invoke-Git -Repository $mergeRepository `
        -Arguments @('tag', 'fix/merge', $mergeHeadRefOid) | Out-Null
    $ambiguousMergeBranchAncestor = Invoke-Git -Repository $mergeRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            'fix/merge',
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $ambiguousMergeBranchAncestor -Expected 0 `
        -Message 'A same-name tag must demonstrate why shorthand guard 2a is ambiguous'
    $qualifiedMergeBranchAncestor = Invoke-Git -Repository $mergeRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            'refs/heads/fix/merge',
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $qualifiedMergeBranchAncestor -Expected 1 `
        -Message 'Fully qualified guard 2a must reject the advanced branch instead of accepting the same-name tag'

    # target側のorigin/mainもDWIM短縮refであり、同名tagがremote-tracking refより
    # 先に解決される。未反映remoteを隠すfalse-passをfully-qualified targetで拒否する。
    Invoke-Git -Repository $mergeRepository `
        -Arguments @('tag', 'origin/main', 'refs/heads/main') | Out-Null
    Invoke-Git -Repository $mergeRepository `
        -Arguments @('update-ref', 'refs/remotes/origin/main', $mergeBaseOid) | Out-Null
    $ambiguousRemoteTargetAncestor = Invoke-Git -Repository $mergeRepository `
        -Arguments @('merge-base', '--is-ancestor', $mergeHeadRefOid, 'origin/main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $ambiguousRemoteTargetAncestor -Expected 0 `
        -Message 'A same-name tag must demonstrate why shorthand remote-tracking targets are ambiguous'
    $qualifiedRemoteTargetAncestor = Invoke-Git -Repository $mergeRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            $mergeHeadRefOid,
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $qualifiedRemoteTargetAncestor -Expected 1 `
        -Message 'Fully qualified remote-tracking target must reject a result absent from the fetched default branch'

    # Squash does not make the source commits ancestors of main. Guard 2b's
    # two checks jointly prove the landed result and the unchanged local tip.
    $squashRepository = Join-Path $testRoot 'squash'
    Initialize-FixtureRepository -Path $squashRepository
    Invoke-Git -Repository $squashRepository -Arguments @('switch', '-c', 'fix/squash') | Out-Null
    Add-Commit -Repository $squashRepository -RelativePath 'feature-a.txt' -Content "a`n" -Message 'feature a'
    Add-Commit -Repository $squashRepository -RelativePath 'feature-b.txt' -Content "b`n" -Message 'feature b'
    $squashHeadRefOid = (Invoke-Git -Repository $squashRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/squash')).Output

    Invoke-Git -Repository $squashRepository -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -Repository $squashRepository `
        -Arguments @('merge', '--squash', 'refs/heads/fix/squash') | Out-Null
    Invoke-Git -Repository $squashRepository -Arguments @('commit', '-m', 'squash result') | Out-Null
    Invoke-Git -Repository $squashRepository `
        -Arguments @('update-ref', 'refs/remotes/origin/main', 'refs/heads/main') | Out-Null
    $squashMergeCommitOid = (Invoke-Git -Repository $squashRepository `
        -Arguments @('rev-parse', 'refs/heads/main')).Output

    $squashBranchAncestor = Invoke-Git -Repository $squashRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            'refs/heads/fix/squash',
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $squashBranchAncestor -Expected 1 `
        -Message 'Guard 2a must reject a correctly squashed branch'

    $squashResultAncestor = Invoke-Git -Repository $squashRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            $squashMergeCommitOid,
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $squashResultAncestor -Expected 0 `
        -Message 'Guard 2b must accept a landed squash result'

    $squashLocalTip = (Invoke-Git -Repository $squashRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/squash')).Output
    Assert-Equal -Actual $squashLocalTip -Expected $squashHeadRefOid `
        -Message 'Guard 2b must accept an unchanged local PR branch'

    # A claimed merge result outside the default branch must block deletion.
    $squashTreeOid = (Invoke-Git -Repository $squashRepository -Arguments @('rev-parse', 'main^{tree}')).Output
    $unrelatedCommitOid = (Invoke-Git -Repository $squashRepository `
        -Arguments @('commit-tree', $squashTreeOid, '-m', 'unrelated result')).Output
    $unrelatedResultAncestor = Invoke-Git -Repository $squashRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            $unrelatedCommitOid,
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $unrelatedResultAncestor -Expected 1 `
        -Message 'Guard 2b must reject a merge result outside the default branch'

    # The headRefOid comparison must catch a local commit added after merge.
    Invoke-Git -Repository $squashRepository -Arguments @('switch', 'fix/squash') | Out-Null
    Add-Commit -Repository $squashRepository -RelativePath 'late.txt' -Content "late`n" -Message 'late local commit'
    Invoke-Git -Repository $squashRepository `
        -Arguments @('tag', 'fix/squash', $squashHeadRefOid) | Out-Null
    $ambiguousSquashTip = Invoke-Git -Repository $squashRepository `
        -Arguments @('rev-parse', 'fix/squash')
    $ambiguousSquashOidLines = @(
        $ambiguousSquashTip.Output -split "`n" |
            Where-Object {
                $_ -cmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$'
            }
    )
    Assert-Equal -Actual ($ambiguousSquashOidLines -join "`n") -Expected $squashHeadRefOid `
        -Message 'Shorthand guard 2b rev-parse must demonstrate why a same-name tag is unsafe'
    $advancedLocalTip = (Invoke-Git -Repository $squashRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/squash')).Output
    Assert-NotEqual -Actual $advancedLocalTip -Expected $squashHeadRefOid `
        -Message 'Fully qualified guard 2b must inspect the advanced branch instead of the same-name tag'

    # Rebase merge rewrites commit IDs. Preserve the original PR branch while
    # rebasing a copy, then fast-forward main to synthesize GitHub's topology.
    $rebaseRepository = Join-Path $testRoot 'rebase'
    Initialize-FixtureRepository -Path $rebaseRepository
    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', '-c', 'fix/rebase') | Out-Null
    Add-Commit -Repository $rebaseRepository -RelativePath 'feature-a.txt' -Content "a`n" -Message 'feature a'
    Add-Commit -Repository $rebaseRepository -RelativePath 'feature-b.txt' -Content "b`n" -Message 'feature b'
    $rebaseHeadRefOid = (Invoke-Git -Repository $rebaseRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/rebase')).Output

    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', 'main') | Out-Null
    Add-Commit -Repository $rebaseRepository -RelativePath 'base-next.txt' -Content "next`n" -Message 'advance base'
    Invoke-Git -Repository $rebaseRepository `
        -Arguments @('branch', 'rebased-result', 'refs/heads/fix/rebase') | Out-Null
    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', 'rebased-result') | Out-Null
    Invoke-Git -Repository $rebaseRepository -Arguments @('rebase', 'main') | Out-Null
    $rebaseMergeCommitOid = (Invoke-Git -Repository $rebaseRepository -Arguments @('rev-parse', 'rebased-result')).Output
    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -Repository $rebaseRepository -Arguments @('merge', '--ff-only', 'rebased-result') | Out-Null
    Invoke-Git -Repository $rebaseRepository `
        -Arguments @('update-ref', 'refs/remotes/origin/main', 'refs/heads/main') | Out-Null

    # Fail at the rewritten-history premise itself so later topology checks
    # cannot be the only signal that the synthetic rebase actually rewrote it.
    Assert-NotEqual -Actual $rebaseMergeCommitOid -Expected $rebaseHeadRefOid `
        -Message 'The landed rebase commit must differ from the original PR head'

    $rebaseBranchAncestor = Invoke-Git -Repository $rebaseRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            'refs/heads/fix/rebase',
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $rebaseBranchAncestor -Expected 1 `
        -Message 'Guard 2a must reject a correctly rebased branch with rewritten commits'

    $rebaseResultAncestor = Invoke-Git -Repository $rebaseRepository `
        -Arguments @(
            'merge-base',
            '--is-ancestor',
            $rebaseMergeCommitOid,
            'refs/remotes/origin/main'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $rebaseResultAncestor -Expected 0 `
        -Message 'Guard 2b must accept the landed rebase result'

    $rebaseLocalTip = (Invoke-Git -Repository $rebaseRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/rebase')).Output
    Assert-Equal -Actual $rebaseLocalTip -Expected $rebaseHeadRefOid `
        -Message 'Guard 2b must accept the unchanged original PR head after rebase merge'

    # branch生成前にtask slugをASCII kebabへ限定し、config queryのERE注入を防ぐ。
    Assert-True -Condition (Test-LocalCleanupTaskSlug -Value 'local-delete') `
        -Message 'A lowercase ASCII kebab task slug must be accepted'
    foreach ($invalidTaskSlug in @(
        '',
        'Upper',
        'with/slash',
        'with+plus',
        'with(paren)',
        'with|pipe',
        "local-delete`n"
    )) {
        Assert-False -Condition (Test-LocalCleanupTaskSlug -Value $invalidTaskSlug) `
            -Message "An unsafe task slug must be rejected before branch construction: $invalidTaskSlug"
    }

    # PowerShellのalias-first解決でinternal helperが横取りされる前に、同名aliasを拒否する。
    try {
        Microsoft.PowerShell.Utility\Set-Alias `
            -Name 'Invoke-LocalCleanupGit' `
            -Value 'Write-Output' `
            -Scope Script
        Assert-Throws `
            -Action {
                Invoke-LocalBranchCleanupCore `
                    -RepositoryPath $testRoot `
                    -TaskSlug 'alias-collision' `
                    -ExpectedOid ('a' * 40) | Out-Null
            } `
            -Pattern 'Ambient alias ''Invoke-LocalCleanupGit'' can redirect' `
            -Message 'An ambient alias matching an internal helper must fail closed'
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item `
            -LiteralPath 'Alias:Invoke-LocalCleanupGit' `
            -ErrorAction SilentlyContinue
    }
    Assert-False -Condition (
        $null -ne (
            Microsoft.PowerShell.Utility\Get-Alias `
                -Name 'Invoke-LocalCleanupGit' `
                -ErrorAction SilentlyContinue
        )
    ) -Message 'The ambient alias fixture must remove only its disposable alias'

    # dot-source後または同期hook内のFunction:差替えも、captured ScriptBlockと不一致になる。
    $reviewedInvokeGitFunction = ${function:Invoke-LocalCleanupGit}
    try {
        Microsoft.PowerShell.Management\Set-Item `
            -LiteralPath 'Function:Invoke-LocalCleanupGit' `
            -Value { throw 'proxy replacement' }
        Assert-Throws `
            -Action {
                Invoke-LocalBranchCleanupCore `
                    -RepositoryPath $testRoot `
                    -TaskSlug 'function-replacement' `
                    -ExpectedOid ('a' * 40) | Out-Null
            } `
            -Pattern 'Runtime function ''Invoke-LocalCleanupGit'' changed after review' `
            -Message 'A replaced internal function must fail closed before repository access'
    }
    finally {
        Microsoft.PowerShell.Management\Set-Item `
            -LiteralPath 'Function:Invoke-LocalCleanupGit' `
            -Value $reviewedInvokeGitFunction
    }

    foreach ($invalidOidLength in @(41, 63)) {
        Assert-Throws `
            -Action {
                Invoke-LocalBranchCleanupCore `
                    -RepositoryPath $testRoot `
                    -TaskSlug 'invalid-oid-length' `
                    -ExpectedOid ('a' * $invalidOidLength) | Out-Null
            } `
            -Pattern 'Expected head OID must be a lowercase 40- or 64-hex object ID' `
            -Message "A $invalidOidLength-hex OID must be rejected before repository access"
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $testRoot `
                -TaskSlug 'invalid-oid-trailing-lf' `
                -ExpectedOid (('a' * 40) + "`n") | Out-Null
        } `
        -Pattern 'Expected head OID must be a lowercase 40- or 64-hex object ID' `
        -Message 'A 40-hex OID followed by LF must be rejected before repository access'

    # local branch削除はrepo common dirのowner-nonce lock内だけで実行し、同じ
    # headRefOidをexpected old OIDにする。fixture外のrepo/GitHubは使用しない。
    $localDeleteRepository = Join-Path $testRoot 'local-delete'
    Initialize-FixtureRepository -Path $localDeleteRepository
    Invoke-Git -Repository $localDeleteRepository -Arguments @('switch', '-c', 'fix/local-delete') | Out-Null
    Add-Commit -Repository $localDeleteRepository -RelativePath 'local.txt' `
        -Content "expected`n" -Message 'local delete expected head'
    $localExpectedHeadOid = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-delete')).Output
    Invoke-Git -Repository $localDeleteRepository -Arguments @('switch', 'main') | Out-Null
    $localReflogBeforeDelete = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('reflog', 'exists', 'refs/heads/fix/local-delete') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $localReflogBeforeDelete -Expected 0 `
        -Message 'The local branch fixture must start with a reflog'

    # 既にcheckout中のbranchはGit native guard acquisitionがatomicに拒否し、
    # finallyでowner lockを解放したうえでref/reflog/configを全て保持する。
    $localDeleteWorktree = Join-Path $testRoot 'local-delete-worktree'
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('worktree', 'add', $localDeleteWorktree, 'fix/local-delete') | Out-Null
    Assert-Throws `
        -Action {
            Remove-IsolatedWorktreeLocalBranch `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-delete' `
                -ExpectedOid $localExpectedHeadOid | Out-Null
        } `
        -Pattern 'Guard worktree could not acquire exclusive branch occupancy' `
        -Message 'Native guard acquisition must reject an exact branch checked out elsewhere'
    $checkedOutLocalTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-delete')).Output
    Assert-Equal -Actual $checkedOutLocalTip -Expected $localExpectedHeadOid `
        -Message 'Checked-out rejection must preserve the expected local tip'
    $checkedOutLocalConfig = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get', 'branch.fix/local-delete.remote') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $checkedOutLocalConfig -Expected 1 `
        -Message 'Checked-out rejection must not invent branch config'
    $localCleanupLockPath = Get-LocalCleanupLockPath -RepositoryPath $localDeleteRepository
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Checked-out rejection must release the owner cleanup lock in finally'
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('worktree', 'remove', $localDeleteWorktree) | Out-Null

    # configを持たないbranchがexpected HのままならCASに成功し、ref/reflogを削除する。
    $positiveLocalDelete = Remove-IsolatedWorktreeLocalBranch `
        -RepositoryPath $localDeleteRepository `
        -TaskSlug 'local-delete' `
        -ExpectedOid $localExpectedHeadOid
    Assert-Equal -Actual $positiveLocalDelete.BranchRef `
        -Expected 'refs/heads/fix/local-delete' `
        -Message 'Local cleanup must delete a branch that still equals the expected PR head'
    Assert-False -Condition $positiveLocalDelete.ConfigRemoved `
        -Message 'Config-free local cleanup must report that no config was removed'
    $localRefAfterDelete = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('show-ref', '--verify', '--quiet', 'refs/heads/fix/local-delete') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $localRefAfterDelete -Expected 1 `
        -Message 'The exact local branch ref must be absent after successful CAS deletion'
    $localReflogAfterDelete = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('reflog', 'exists', 'refs/heads/fix/local-delete') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $localReflogAfterDelete -Expected 1 `
        -Message 'Successful update-ref deletion must remove the local branch reflog'
    $localConfigAfterDelete = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get', 'branch.fix/local-delete.remote') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $localConfigAfterDelete -Expected 1 `
        -Message 'Successful configless cleanup must not invent branch config'
    $localConfigAfterCleanup = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get-regexp', '^branch\.fix/local-delete\.') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $localConfigAfterCleanup -Expected 1 `
        -Message 'No branch config may remain after successful local cleanup'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Positive local cleanup must release the owner lock'
    $localConfigWriterLockPath = Join-Path `
        ([System.IO.Path]::GetDirectoryName($localCleanupLockPath)) `
        'config.lock'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Positive local cleanup must release the exact Git config writer lock'

    # Git標準config.lockの保持中は通常のgit config writerが失敗する一方、
    # configless branchのexpected-OID CASはcritical section内で完了できる。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-config-writer-block', $localExpectedHeadOid) | Out-Null
    $configWriterBlockState = [pscustomobject]@{
        ExitCode = $null
        LockPath = $null
    }
    $configWriterBlockHook = {
        param($writerLock)

        $configWriterBlockState.LockPath = $writerLock.Path
        $blockedConfigWrite = Invoke-Git `
            -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                '--local',
                'branch.fix/local-config-writer-block.remote',
                'actor-origin'
            ) `
            -AllowedExitCodes @(0, 1, 128, 255)
        $configWriterBlockState.ExitCode = $blockedConfigWrite.ExitCode
        Assert-NotEqual -Actual $blockedConfigWrite.ExitCode -Expected 0 `
            -Message 'Git config writer lock must block an ordinary competing config update'
    }
    $configWriterBlockCleanup = Invoke-LocalBranchCleanupCore `
        -RepositoryPath $localDeleteRepository `
        -TaskSlug 'local-config-writer-block' `
        -ExpectedOid $localExpectedHeadOid `
        -AfterConfigWriterLockForTest $configWriterBlockHook
    Assert-Equal -Actual $configWriterBlockCleanup.BranchRef `
        -Expected 'refs/heads/fix/local-config-writer-block' `
        -Message 'Config writer exclusion must still permit the exact configless CAS'
    Assert-NotEqual -Actual $configWriterBlockState.ExitCode -Expected 0 `
        -Message 'Competing git config must remain blocked throughout the hook'
    Assert-True `
        -Condition (Test-LocalCleanupPathEqual `
            -Left $configWriterBlockState.LockPath `
            -Right $localConfigWriterLockPath
        ) `
        -Message 'Writer exclusion must use only common-dir/config.lock'
    $configWriterBlockRef = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'show-ref',
            '--verify',
            '--quiet',
            'refs/heads/fix/local-config-writer-block'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $configWriterBlockRef -Expected 1 `
        -Message 'Writer-block fixture must complete the expected-OID local CAS'
    $configWriterBlockConfig = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-config-writer-block.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $configWriterBlockConfig -Expected 1 `
        -Message 'Blocked competing writer must not leave branch config'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Successful writer exclusion must release common-dir/config.lock'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Successful writer exclusion must release the owner cleanup lock'

    # 先着した標準config.lockはactive/staleを推測せず、単発CreateNew失敗として
    # CAS前に拒否する。既存contentを変更せず、owner guard/custom lockだけを解放する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-config-lock-preexisting', $localExpectedHeadOid) | Out-Null
    $preexistingConfigLockContent = 'fixture-preexisting-config-lock'
    $preexistingConfigLockState = [pscustomobject]@{
        GuardPath = $null
    }
    $preexistingConfigLockHook = {
        param($cleanupLock, $cleanupGuard)

        $preexistingConfigLockState.GuardPath = $cleanupGuard.Path
    }
    Write-FixtureFile `
        -Path $localConfigWriterLockPath `
        -Content $preexistingConfigLockContent
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-config-lock-preexisting' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterWorktreeGateForTest $preexistingConfigLockHook | Out-Null
        } `
        -Pattern 'Git config writer lock is unavailable' `
        -Message 'A pre-existing common-dir/config.lock must fail closed before CAS'
    $preexistingConfigLockTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-config-lock-preexisting'
        )).Output
    Assert-Equal -Actual $preexistingConfigLockTip -Expected $localExpectedHeadOid `
        -Message 'Pre-existing config.lock refusal must preserve the exact branch ref'
    Assert-Equal `
        -Actual ([System.IO.File]::ReadAllText(
            $localConfigWriterLockPath,
            $utf8NoBom
        )) `
        -Expected $preexistingConfigLockContent `
        -Message 'Pre-existing config.lock refusal must preserve its exact content'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Pre-existing config.lock refusal must release the owner cleanup lock'
    Assert-False `
        -Condition (
            [System.IO.Directory]::Exists($preexistingConfigLockState.GuardPath) -or
            [System.IO.File]::Exists($preexistingConfigLockState.GuardPath)
        ) `
        -Message 'Pre-existing config.lock refusal must release the exact native guard'
    [System.IO.File]::Delete($localConfigWriterLockPath)

    # owner descriptorのpathがhookで差し替わった場合、CASとreleaseの双方を拒否し、
    # uncertain config.lock、native guard、custom lockを外部回復用に保持する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-config-lock-path-drift', $localExpectedHeadOid) | Out-Null
    $configLockPathDriftState = [pscustomobject]@{
        OriginalPath = $null
        Nonce = $null
        GuardPath = $null
    }
    $configLockPathDriftHook = {
        param($writerLock, $cleanupGuard)

        $configLockPathDriftState.OriginalPath = $writerLock.Path
        $configLockPathDriftState.Nonce = $writerLock.Nonce
        $configLockPathDriftState.GuardPath = $cleanupGuard.Path
        $writerLock.Path = Join-Path `
            $writerLock.CommonDirectory `
            'config.lock.replaced'
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-config-lock-path-drift' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterConfigWriterLockForTest $configLockPathDriftHook | Out-Null
        } `
        -Pattern 'config writer lock release failed.*uncertain config lock' `
        -Message 'Config lock descriptor replacement must reject CAS and automatic release'
    $configLockPathDriftTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-config-lock-path-drift'
        )).Output
    Assert-Equal -Actual $configLockPathDriftTip -Expected $localExpectedHeadOid `
        -Message 'Config lock path drift must preserve the exact branch ref'
    Assert-Equal `
        -Actual ([System.IO.File]::ReadAllText(
            $configLockPathDriftState.OriginalPath,
            $utf8NoBom
        )) `
        -Expected $configLockPathDriftState.Nonce `
        -Message 'Path drift must preserve the exact owner nonce file for recovery'
    Assert-True -Condition ([System.IO.Directory]::Exists($configLockPathDriftState.GuardPath)) `
        -Message 'Path drift must preserve native guard occupancy'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Path drift must preserve the owner cleanup lock'
    [System.IO.File]::Delete($configLockPathDriftState.OriginalPath)
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $configLockPathDriftState.GuardPath
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)

    # pre-existing config.lockがjunction/symlinkならregular owner fileとして扱わず、
    # targetへ触れずにCAS前拒否する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-config-lock-reparse', $localExpectedHeadOid) | Out-Null
    $configLockReparseTarget = Join-Path $testRoot 'config-lock-reparse-target'
    [System.IO.Directory]::CreateDirectory($configLockReparseTarget) | Out-Null
    if ($isWindowsPlatform) {
        New-Item `
            -ItemType Junction `
            -Path $localConfigWriterLockPath `
            -Target $configLockReparseTarget | Out-Null
    } else {
        New-Item `
            -ItemType SymbolicLink `
            -Path $localConfigWriterLockPath `
            -Target $configLockReparseTarget | Out-Null
    }
    $configLockReparseState = [pscustomobject]@{
        GuardPath = $null
    }
    $configLockReparseHook = {
        param($cleanupLock, $cleanupGuard)

        $configLockReparseState.GuardPath = $cleanupGuard.Path
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-config-lock-reparse' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterWorktreeGateForTest $configLockReparseHook | Out-Null
        } `
        -Pattern 'Git config writer lock is unavailable' `
        -Message 'A reparse-point config.lock must fail closed before CAS'
    $configLockReparseAttributes = [System.IO.File]::GetAttributes(
        $localConfigWriterLockPath
    )
    Assert-True `
        -Condition (
            ($configLockReparseAttributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0
        ) `
        -Message 'Reparse-point refusal must preserve the exact fixture link'
    $configLockReparseTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-config-lock-reparse'
        )).Output
    Assert-Equal -Actual $configLockReparseTip -Expected $localExpectedHeadOid `
        -Message 'Reparse-point config.lock refusal must preserve the exact branch ref'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Reparse-point config.lock refusal must release the owner cleanup lock'
    Assert-False `
        -Condition (
            [System.IO.Directory]::Exists($configLockReparseState.GuardPath) -or
            [System.IO.File]::Exists($configLockReparseState.GuardPath)
        ) `
        -Message 'Reparse-point config.lock refusal must release the exact native guard'
    if ($isWindowsPlatform) {
        [System.IO.Directory]::Delete($localConfigWriterLockPath)
    } else {
        [System.IO.File]::Delete($localConfigWriterLockPath)
    }
    Assert-True -Condition ([System.IO.Directory]::Exists($configLockReparseTarget)) `
        -Message 'Fixture link cleanup must not remove its target directory'

    # owner handleのnonce contentが変わった場合はCAS前owner checkとfinally releaseを
    # 共に拒否し、変異path/guard/custom lockを保持する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-config-lock-content-drift', $localExpectedHeadOid) | Out-Null
    $configLockContentDriftState = [pscustomobject]@{
        Path = $null
        Nonce = $null
        GuardPath = $null
    }
    $configLockContentDriftHook = {
        param($writerLock, $cleanupGuard)

        $configLockContentDriftState.Path = $writerLock.Path
        $configLockContentDriftState.GuardPath = $cleanupGuard.Path
        $configLockContentDriftState.Nonce = if (
            $writerLock.Nonce -ceq ('f' * 32)
        ) {
            'e' * 32
        } else {
            'f' * 32
        }
        $driftBytes = $utf8NoBom.GetBytes($configLockContentDriftState.Nonce)
        $writerLock.Stream.Position = 0
        $writerLock.Stream.SetLength(0)
        $writerLock.Stream.Write($driftBytes, 0, $driftBytes.Length)
        $writerLock.Stream.Flush()
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-config-lock-content-drift' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterConfigWriterLockForTest $configLockContentDriftHook | Out-Null
        } `
        -Pattern 'config writer lock release failed.*uncertain config lock' `
        -Message 'Config lock content drift must reject CAS and unsafe release'
    $configLockContentDriftTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-config-lock-content-drift'
        )).Output
    Assert-Equal -Actual $configLockContentDriftTip -Expected $localExpectedHeadOid `
        -Message 'Config lock content drift must preserve the exact branch ref'
    Assert-Equal `
        -Actual ([System.IO.File]::ReadAllText(
            $configLockContentDriftState.Path,
            $utf8NoBom
        )) `
        -Expected $configLockContentDriftState.Nonce `
        -Message 'Unsafe release must preserve the observed drifted lock content'
    Assert-True -Condition ([System.IO.Directory]::Exists($configLockContentDriftState.GuardPath)) `
        -Message 'Config lock content drift must preserve native guard occupancy'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Config lock content drift must preserve the owner cleanup lock'
    [System.IO.File]::Delete($configLockContentDriftState.Path)
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $configLockContentDriftState.GuardPath
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)

    # Git configにatomic expected-value section deleteが無いため、config付きbranchは
    # CAS前に拒否する。ref/config/guard/lockを保持し、explicit recoveryだけを許す。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'branch',
            'fix/local-config-retained',
            $localExpectedHeadOid
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-config-retained.remote',
            'origin'
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-config-retained.merge',
            'refs/heads/fix/local-config-retained'
        ) | Out-Null
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-config-retained' `
                -ExpectedOid $localExpectedHeadOid | Out-Null
        } `
        -Pattern (
            'Automatic local branch CAS was refused because owner config.*' +
            'Automatic owner config rename-back was refused'
        ) `
        -Message 'A branch with owner config must refuse non-atomic automatic cleanup'
    $retainedConfigTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-config-retained'
        )).Output
    Assert-Equal -Actual $retainedConfigTip -Expected $localExpectedHeadOid `
        -Message 'Config-bearing cleanup refusal must preserve the exact branch ref'
    $retainedOriginalConfig = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get-regexp',
            '^branch\.fix/local-config-retained\.'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $retainedOriginalConfig -Expected 1 `
        -Message 'Refused cleanup must leave owner config isolated, not guess-renamed'
    $retainedTemporaryConfig = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get-regexp',
            '^branch\.codex-cleanup-.*\.(remote|merge)$'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $retainedTemporaryConfig -Expected 0 `
        -Message 'Refused cleanup must preserve the exact owner temporary payload'
    $retainedConfigSectionMatch = [regex]::Match(
        $retainedTemporaryConfig.Output,
        (
            '(?m)^(?<section>branch\.codex-cleanup-[0-9a-f]{32})' +
            '\.remote\s+origin$'
        )
    )
    Assert-True -Condition $retainedConfigSectionMatch.Success `
        -Message 'Retained config must stay attributable to its owner nonce'
    $retainedConfigGuardPath = Join-Path `
        $tempParent `
        (
            'codex-isolated-worktree-cleanup-guard-' +
            $retainedConfigSectionMatch.Groups['section'].Value.Substring(
                'branch.codex-cleanup-'.Length
            )
        )
    Assert-True -Condition ([System.IO.Directory]::Exists($retainedConfigGuardPath)) `
        -Message 'Config-bearing cleanup refusal must preserve native occupancy'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Config-bearing cleanup refusal must preserve the owner lock'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Config-bearing refusal must release only its exact Git config writer lock'
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--rename-section',
            $retainedConfigSectionMatch.Groups['section'].Value,
            'branch.fix/local-config-retained'
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $retainedConfigGuardPath
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)
    $retainedConfigAfterRecovery = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-config-retained.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $retainedConfigAfterRecovery.Output -Expected 'origin' `
        -Message 'Explicit recovery must restore the exact retained config'
    Assert-False -Condition ([System.IO.Directory]::Exists($retainedConfigGuardPath)) `
        -Message 'Explicit recovery must remove only the retained owner guard'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Explicit recovery must release only the retained owner lock'

    # guard取得中はGit自身のbranch occupancyにより、通常worktree add/switchを
    # ともに拒否する。exact marker/common-dir invariantもCAS直前hookで実測する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-guard-occupancy', $localExpectedHeadOid) | Out-Null
    $guardCompetitorWorktree = Join-Path $testRoot 'local-guard-competitor'
    $guardOccupancyState = [pscustomobject]@{
        Path = $null
        AddExitCode = $null
        SwitchExitCode = $null
    }
    $guardOccupancyHook = {
        param(
            $cleanupLock,
            $cleanupGuard
        )

        $guardOccupancyState.Path = $cleanupGuard.Path
        Assert-True -Condition (
            Test-LocalCleanupGuardInvariant `
                -RepositoryPath $localDeleteRepository `
                -Guard $cleanupGuard
        ) -Message 'CAS hook must observe exact task-owned native guard state'
        $blockedAdd = Invoke-Git `
            -Repository $localDeleteRepository `
            -Arguments @(
                'worktree',
                'add',
                $guardCompetitorWorktree,
                'fix/local-guard-occupancy'
            ) `
            -AllowedExitCodes @(0, 128)
        $guardOccupancyState.AddExitCode = $blockedAdd.ExitCode
        Assert-ExitCode -Result $blockedAdd -Expected 128 `
            -Message 'Native guard must block an ordinary competing worktree add'
        $blockedSwitch = Invoke-Git `
            -Repository $localDeleteRepository `
            -Arguments @('switch', 'fix/local-guard-occupancy') `
            -AllowedExitCodes @(0, 128)
        $guardOccupancyState.SwitchExitCode = $blockedSwitch.ExitCode
        Assert-ExitCode -Result $blockedSwitch -Expected 128 `
            -Message 'Native guard must block an ordinary competing branch switch'
    }
    $guardOccupancyCleanup = Invoke-LocalBranchCleanupCore `
        -RepositoryPath $localDeleteRepository `
        -TaskSlug 'local-guard-occupancy' `
        -ExpectedOid $localExpectedHeadOid `
        -BeforeCasForTest $guardOccupancyHook
    Assert-Equal -Actual $guardOccupancyCleanup.BranchRef `
        -Expected 'refs/heads/fix/local-guard-occupancy' `
        -Message 'Guarded cleanup must complete after both ordinary checkout attempts are blocked'
    Assert-Equal -Actual $guardOccupancyState.AddExitCode -Expected 128 `
        -Message 'Competing add result must remain observable after cleanup'
    Assert-Equal -Actual $guardOccupancyState.SwitchExitCode -Expected 128 `
        -Message 'Competing switch result must remain observable after cleanup'
    Assert-False -Condition ([System.IO.Directory]::Exists($guardOccupancyState.Path)) `
        -Message 'Successful cleanup must remove the exact task-owned guard path'
    Assert-False -Condition ([System.IO.Directory]::Exists($guardCompetitorWorktree)) `
        -Message 'Rejected competing add must not leave a worktree path'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Guard occupancy fixture must release the owner lock'

    # native guard取得直前へactorを差し込む。通常worktree addが先着した場合も
    # cleanup側のguard取得が拒否され、H/configを保持してowner lockを解放する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-checkout-race', $localExpectedHeadOid) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', 'branch.fix/local-checkout-race.remote', 'origin') | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', 'branch.fix/local-checkout-race.merge', 'refs/heads/fix/local-checkout-race') | Out-Null
    $checkoutRaceWorktree = Join-Path $testRoot 'local-checkout-race-worktree'
    $checkoutRaceHook = {
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @('worktree', 'add', $checkoutRaceWorktree, 'fix/local-checkout-race') | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-checkout-race' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterWorktreeGateForTest $checkoutRaceHook | Out-Null
        } `
        -Pattern 'Guard worktree could not acquire exclusive branch occupancy' `
        -Message 'A checkout interleaving immediately before guard acquisition must fail closed'
    $checkoutRaceTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-checkout-race')).Output
    Assert-Equal -Actual $checkoutRaceTip -Expected $localExpectedHeadOid `
        -Message 'Checkout interleaving rejection must preserve the exact branch tip'
    $checkoutRaceConfig = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get', 'branch.fix/local-checkout-race.remote') `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $checkoutRaceConfig.Output -Expected 'origin' `
        -Message 'Checkout interleaving rejection must preserve branch config'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Checkout interleaving rejection must release the owner lock'
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('worktree', 'remove', $checkoutRaceWorktree) | Out-Null

    # config観測とrenameの間へactor更新を差し込み、rename後のexact snapshot差分で
    # CASを拒否する。actor payloadはowner temp、refは元OID、guard/lockは外部回復用に残す。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'branch',
            'fix/local-config-rename-race',
            $localExpectedHeadOid
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-config-rename-race.remote',
            'origin'
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-config-rename-race.merge',
            'refs/heads/fix/local-config-rename-race'
        ) | Out-Null
    $configRenameRaceHook = {
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                'branch.fix/local-config-rename-race.remote',
                'actor-origin'
            ) | Out-Null
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                'branch.fix/local-config-rename-race.merge',
                'refs/heads/actor/config-rename-race'
            ) | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-config-rename-race' `
                -ExpectedOid $localExpectedHeadOid `
                -BeforeConfigRenameForTest $configRenameRaceHook | Out-Null
        } `
        -Pattern (
            'Branch config changed while owner isolation was acquired.*' +
            'Automatic owner config rename-back was refused'
        ) `
        -Message 'A config update between observation and rename must fail closed'
    $configRenameRaceTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-config-rename-race'
        )).Output
    Assert-Equal -Actual $configRenameRaceTip -Expected $localExpectedHeadOid `
        -Message 'Config observation-to-rename drift must preserve the exact branch ref'
    $configRenameRaceOriginal = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get-regexp',
            '^branch\.fix/local-config-rename-race\.'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $configRenameRaceOriginal -Expected 1 `
        -Message 'The drifted payload must remain isolated instead of being guessed back'
    $configRenameRaceTemporary = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get-regexp',
            '^branch\.codex-cleanup-.*\.(remote|merge)$'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $configRenameRaceTemporary -Expected 0 `
        -Message 'Config observation-to-rename drift must preserve the actor payload'
    $configRenameRaceSectionMatch = [regex]::Match(
        $configRenameRaceTemporary.Output,
        (
            '(?m)^(?<section>branch\.codex-cleanup-[0-9a-f]{32})' +
            '\.remote\s+actor-origin$'
        )
    )
    Assert-True -Condition $configRenameRaceSectionMatch.Success `
        -Message 'The drifted config must remain attributable to the owner nonce'
    Assert-True -Condition (
        $configRenameRaceTemporary.Output -cmatch
            '\.merge\s+refs/heads/actor/config-rename-race'
    ) -Message 'The exact actor merge target must survive the failed isolation'
    $configRenameRaceGuardPath = Join-Path `
        $tempParent `
        (
            'codex-isolated-worktree-cleanup-guard-' +
            $configRenameRaceSectionMatch.Groups['section'].Value.Substring(
                'branch.codex-cleanup-'.Length
            )
        )
    Assert-True -Condition ([System.IO.Directory]::Exists($configRenameRaceGuardPath)) `
        -Message 'Config observation-to-rename drift must preserve native occupancy'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Config observation-to-rename drift must preserve the cleanup lock'

    # fixture外部回復は元section不在を確認済みのため、owner tempを明示renameする。
    # exact guardとlockだけを片付け、actor payload/refが不変であることを再確認する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--rename-section',
            $configRenameRaceSectionMatch.Groups['section'].Value,
            'branch.fix/local-config-rename-race'
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $configRenameRaceGuardPath
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)
    $configRenameRaceRestoredRemote = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-config-rename-race.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $configRenameRaceRestoredRemote.Output -Expected 'actor-origin' `
        -Message 'Explicit recovery must retain the actor remote value'
    $configRenameRaceRestoredMerge = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-config-rename-race.merge'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal `
        -Actual $configRenameRaceRestoredMerge.Output `
        -Expected 'refs/heads/actor/config-rename-race' `
        -Message 'Explicit recovery must retain the actor merge value'
    Assert-False -Condition ([System.IO.Directory]::Exists($configRenameRaceGuardPath)) `
        -Message 'Explicit recovery must remove only the exact retained guard'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Explicit recovery must release only the exact retained lock'

    # configを持たないbranchをCAS直前にsecond actorがHからRへ進めた場合、
    # old=Hのupdate-refだけを拒否し、Rのref/reflogを保持してowner stateを解放する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-delete-drift', $localExpectedHeadOid) | Out-Null
    $localExpectedTreeOid = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', "$localExpectedHeadOid^{tree}")).Output
    $localAdvancedOid = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'commit-tree',
            $localExpectedTreeOid,
            '-p',
            $localExpectedHeadOid,
            '-m',
            'advance local branch'
        )).Output
    $localDriftHook = {
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'update-ref',
                'refs/heads/fix/local-delete-drift',
                $localAdvancedOid,
                $localExpectedHeadOid
            ) | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-delete-drift' `
                -ExpectedOid $localExpectedHeadOid `
                -BeforeCasForTest $localDriftHook | Out-Null
        } `
        -Pattern '^Expected-OID local branch deletion was rejected; preserving the new tip\.$' `
        -Message 'Local cleanup must reject deletion after another actor advances the branch'
    $driftedLocalTipAfterDelete = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-delete-drift')).Output
    Assert-Equal -Actual $driftedLocalTipAfterDelete -Expected $localAdvancedOid `
        -Message 'Rejected local cleanup must preserve the exact second-actor tip'
    $driftedLocalReflog = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('reflog', 'exists', 'refs/heads/fix/local-delete-drift') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $driftedLocalReflog -Expected 0 `
        -Message 'Rejected local cleanup must preserve the advanced branch reflog'
    $driftedLocalConfig = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get', 'branch.fix/local-delete-drift.remote') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $driftedLocalConfig -Expected 1 `
        -Message 'Rejected configless cleanup must not invent branch config'
    $temporaryConfigAfterDrift = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get-regexp', '^branch\.codex-cleanup-') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $temporaryConfigAfterDrift -Expected 1 `
        -Message 'Rejected configless CAS must leave no owner temporary config'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Rejected configless CAS must release the exact owner lock'

    # 初回configless観測後、BeforeCas actorが元branch sectionを作成するraceを
    # writer lock取得後の最終再照合で拒否する。CAS前なのでactor ref/configを保持する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'branch',
            'fix/local-configless-config-race',
            $localExpectedHeadOid
        ) | Out-Null
    $configlessConfigRaceState = [pscustomobject]@{
        GuardPath = $null
    }
    $configlessConfigRaceHook = {
        param($cleanupLock, $cleanupGuard)

        $configlessConfigRaceState.GuardPath = $cleanupGuard.Path
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                'branch.fix/local-configless-config-race.remote',
                'actor-origin'
            ) | Out-Null
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                'branch.fix/local-configless-config-race.merge',
                'refs/heads/actor/configless-race'
            ) | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-configless-config-race' `
                -ExpectedOid $localExpectedHeadOid `
                -BeforeCasForTest $configlessConfigRaceHook | Out-Null
        } `
        -Pattern 'Original branch config appeared before configless CAS' `
        -Message 'A configless-to-config race must be rejected under the final writer lock'
    $configlessConfigRaceTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-configless-config-race'
        )).Output
    Assert-Equal -Actual $configlessConfigRaceTip -Expected $localExpectedHeadOid `
        -Message 'Configless-to-config race refusal must preserve the exact branch ref'
    $configlessConfigRaceRemote = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-configless-config-race.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $configlessConfigRaceRemote.Output -Expected 'actor-origin' `
        -Message 'Configless-to-config race refusal must preserve actor config'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Configless-to-config race refusal must release common-dir/config.lock'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Configless-to-config race refusal must release the owner cleanup lock'
    Assert-False `
        -Condition (
            [System.IO.Directory]::Exists($configlessConfigRaceState.GuardPath) -or
            [System.IO.File]::Exists($configlessConfigRaceState.GuardPath)
        ) `
        -Message 'Configless-to-config race refusal must release the exact native guard'

    # 同nonceを知ったwriterがCAS直前にowner temp payloadを書き換えても、
    # snapshot差分でCASを拒否し、actor payload/ref/guard/lockを外部回復用に残す。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-owner-config-writer', $localExpectedHeadOid) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-owner-config-writer.remote',
            'origin'
        ) | Out-Null
    $localOwnerConfigWriterHook = {
        param($cleanupLock)

        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                "branch.codex-cleanup-$($cleanupLock.Nonce).remote",
                'actor-origin'
            ) | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-owner-config-writer' `
                -ExpectedOid $localExpectedHeadOid `
                -BeforeCasForTest $localOwnerConfigWriterHook | Out-Null
        } `
        -Pattern (
            'Owner temporary config changed immediately before CAS.*' +
            'Automatic owner config rename-back was refused'
        ) `
        -Message 'A targeted same-nonce writer must block CAS without losing its payload'
    $ownerConfigWriterTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-owner-config-writer')).Output
    Assert-Equal -Actual $ownerConfigWriterTip -Expected $localExpectedHeadOid `
        -Message 'Same-nonce config drift must preserve the exact branch ref'
    $ownerConfigWriterTemporary = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get-regexp',
            '^branch\.codex-cleanup-.*\.remote$'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $ownerConfigWriterTemporary -Expected 0 `
        -Message 'Same-nonce drift must preserve the actor-owned temporary payload'
    $ownerConfigWriterMatch = [regex]::Match(
        $ownerConfigWriterTemporary.Output,
        '^(?<section>branch\.codex-cleanup-[0-9a-f]{32})\.remote\s+actor-origin$'
    )
    Assert-True -Condition $ownerConfigWriterMatch.Success `
        -Message 'Actor payload must remain attributable to the exact owner nonce'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Same-nonce drift must preserve the cleanup lock'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Same-nonce refusal must release only its exact Git config writer lock'
    $ownerConfigWriterGuardPath = Join-Path `
        $tempParent `
        (
            'codex-isolated-worktree-cleanup-guard-' +
            $ownerConfigWriterMatch.Groups['section'].Value.Substring(
                'branch.codex-cleanup-'.Length
            )
        )
    Assert-True -Condition ([System.IO.Directory]::Exists($ownerConfigWriterGuardPath)) `
        -Message 'Same-nonce drift must preserve native branch occupancy'

    # fixture外部でactor payloadを元branchへ明示renameし、owner識別子だけを解放する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--rename-section',
            $ownerConfigWriterMatch.Groups['section'].Value,
            'branch.fix/local-owner-config-writer'
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $ownerConfigWriterGuardPath
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)
    $ownerConfigWriterRestored = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-owner-config-writer.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $ownerConfigWriterRestored.Output -Expected 'actor-origin' `
        -Message 'Explicit recovery must retain the targeted writer payload'
    Assert-False -Condition ([System.IO.Directory]::Exists($ownerConfigWriterGuardPath)) `
        -Message 'Explicit recovery must remove only the exact retained guard'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Explicit recovery must release only the exact retained lock'

    # config隔離後、CAS拒否前にactorが元sectionを再作成した場合、owner payloadを
    # 上書きも破棄もできない。explicit recovery conflictとして両section、
    # advanced ref、native guard、cleanup lockをまとめて保持する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'branch',
            'fix/local-recovery-config-conflict',
            $localExpectedHeadOid
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-recovery-config-conflict.remote',
            'origin'
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            'branch.fix/local-recovery-config-conflict.merge',
            'refs/heads/fix/local-recovery-config-conflict'
        ) | Out-Null
    $localRecoveryConflictOid = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'commit-tree',
            $localExpectedTreeOid,
            '-p',
            $localExpectedHeadOid,
            '-m',
            'advance before config recovery conflict'
        )).Output
    $localRecoveryConflictHook = {
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'update-ref',
                'refs/heads/fix/local-recovery-config-conflict',
                $localRecoveryConflictOid,
                $localExpectedHeadOid
            ) | Out-Null
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                'branch.fix/local-recovery-config-conflict.remote',
                'actor-origin'
            ) | Out-Null
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'config',
                'branch.fix/local-recovery-config-conflict.merge',
                'refs/heads/actor/config-conflict'
            ) | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-recovery-config-conflict' `
                -ExpectedOid $localExpectedHeadOid `
                -BeforeCasForTest $localRecoveryConflictHook | Out-Null
        } `
        -Pattern (
            'Original branch config was recreated immediately before CAS.*' +
            'Automatic owner config rename-back was refused'
        ) `
        -Message 'Recreated original config must become an explicit recovery conflict'
    $recoveryConflictTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-recovery-config-conflict'
        )).Output
    Assert-Equal -Actual $recoveryConflictTip -Expected $localRecoveryConflictOid `
        -Message 'Config recovery conflict must preserve the advanced actor tip'
    $recoveryConflictActorRemote = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-recovery-config-conflict.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $recoveryConflictActorRemote.Output -Expected 'actor-origin' `
        -Message 'Config recovery conflict must preserve actor remote config'
    $recoveryConflictActorMerge = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-recovery-config-conflict.merge'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal `
        -Actual $recoveryConflictActorMerge.Output `
        -Expected 'refs/heads/actor/config-conflict' `
        -Message 'Config recovery conflict must preserve actor merge config'
    $recoveryConflictOwnerConfig = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get-regexp',
            '^branch\.codex-cleanup-.*\.(remote|merge)$'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $recoveryConflictOwnerConfig -Expected 0 `
        -Message 'Config recovery conflict must preserve owner temporary payload'
    $recoveryConflictSectionMatch = [regex]::Match(
        $recoveryConflictOwnerConfig.Output,
        '(?m)^(?<section>branch\.codex-cleanup-[0-9a-f]{32})\.remote\s+origin$'
    )
    Assert-True -Condition $recoveryConflictSectionMatch.Success `
        -Message 'Preserved conflict payload must remain attributable to owner nonce'
    Assert-True -Condition (
        $recoveryConflictOwnerConfig.Output -cmatch
            '\.merge\s+refs/heads/fix/local-recovery-config-conflict'
    ) -Message 'Preserved conflict payload must retain the original merge target'
    $recoveryConflictGuardPath = Join-Path `
        $tempParent `
        (
            'codex-isolated-worktree-cleanup-guard-' +
            $recoveryConflictSectionMatch.Groups['section'].Value.Substring(
                'branch.codex-cleanup-'.Length
            )
        )
    Assert-True -Condition ([System.IO.Directory]::Exists($recoveryConflictGuardPath)) `
        -Message 'Config recovery conflict must preserve native guard occupancy'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Config recovery conflict must preserve the cleanup lock'

    # fixture外部回復ではactor sectionを正本としてowner tempだけを明示削除する。
    # guard/lockを片付けた後もactor ref/configが変わらないことを再確認する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--remove-section',
            $recoveryConflictSectionMatch.Groups['section'].Value
        ) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $recoveryConflictGuardPath
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)
    Assert-False -Condition ([System.IO.Directory]::Exists($recoveryConflictGuardPath)) `
        -Message 'External conflict recovery must remove only the exact owner guard'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'External conflict recovery must release only the preserved owner lock'
    $recoveryConflictOwnerAfterRecovery = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get-regexp', '^branch\.codex-cleanup-') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $recoveryConflictOwnerAfterRecovery -Expected 1 `
        -Message 'External conflict recovery must remove owner temporary config'
    $recoveryConflictActorAfterRecovery = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-recovery-config-conflict.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-Equal `
        -Actual $recoveryConflictActorAfterRecovery.Output `
        -Expected 'actor-origin' `
        -Message 'External conflict recovery must preserve actor config'
    $recoveryConflictTipAfterRecovery = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-recovery-config-conflict'
        )).Output
    Assert-Equal `
        -Actual $recoveryConflictTipAfterRecovery `
        -Expected $localRecoveryConflictOid `
        -Message 'External conflict recovery must preserve the actor tip'

    # config隔離後にowner nonceが不一致になった場合、CASとcatch内のconfig操作を
    # ともに拒否する。branch/reflogと隔離済みconfig payload、uncertain lockを残す。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-owner-drift', $localExpectedHeadOid) | Out-Null
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', 'branch.fix/local-owner-drift.remote', 'origin') | Out-Null
    $localOwnerMismatchHook = {
        param($cleanupLock)

        $localForeignNonce = if ($cleanupLock.Nonce -ceq ('a' * 32)) {
            'b' * 32
        } else {
            'a' * 32
        }
        $localForeignNonceBytes = $utf8NoBom.GetBytes($localForeignNonce)
        $cleanupLock.Stream.SetLength(0)
        $cleanupLock.Stream.Position = 0
        $cleanupLock.Stream.Write(
            $localForeignNonceBytes,
            0,
            $localForeignNonceBytes.Length
        )
        $cleanupLock.Stream.Flush()
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-owner-drift' `
                -ExpectedOid $localExpectedHeadOid `
                -BeforeCasForTest $localOwnerMismatchHook 3>$null | Out-Null
        } `
        -Pattern 'ownership is uncertain' `
        -Message 'Owner mismatch after config isolation must reject CAS'
    $ownerMismatchTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-owner-drift')).Output
    Assert-Equal -Actual $ownerMismatchTip -Expected $localExpectedHeadOid `
        -Message 'Mid-cleanup owner mismatch must preserve the expected branch tip'
    $ownerMismatchReflog = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('reflog', 'exists', 'refs/heads/fix/local-owner-drift') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $ownerMismatchReflog -Expected 0 `
        -Message 'Mid-cleanup owner mismatch must preserve the branch reflog'
    $ownerMismatchTemporaryConfig = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get-regexp', '^branch\.codex-cleanup-.*\.remote$') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $ownerMismatchTemporaryConfig -Expected 0 `
        -Message 'Mid-cleanup owner mismatch must preserve the isolated config payload'
    $ownerMismatchConfigMatch = [regex]::Match(
        $ownerMismatchTemporaryConfig.Output,
        '^(?<section>branch\.codex-cleanup-[0-9a-f]{32})\.remote\s+origin$'
    )
    Assert-True -Condition $ownerMismatchConfigMatch.Success `
        -Message 'Preserved owner config must remain attributable to its nonce section'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Mid-cleanup owner mismatch must preserve the uncertain lock'
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--rename-section',
            $ownerMismatchConfigMatch.Groups['section'].Value,
            'branch.fix/local-owner-drift'
        ) | Out-Null
    $ownerMismatchGuardPath = Join-Path `
        $tempParent `
        (
            'codex-isolated-worktree-cleanup-guard-' +
            $ownerMismatchConfigMatch.Groups['section'].Value.Substring(
                'branch.codex-cleanup-'.Length
            )
        )
    Assert-True -Condition ([System.IO.Directory]::Exists($ownerMismatchGuardPath)) `
        -Message 'Owner mismatch must preserve the exact native guard for recovery'
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $ownerMismatchGuardPath
        ) | Out-Null
    Assert-False -Condition ([System.IO.Directory]::Exists($ownerMismatchGuardPath)) `
        -Message 'External owner recovery must remove only its exact guard worktree'
    [System.IO.File]::Delete($localCleanupLockPath)
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Cleanup may continue only after external uncertain-lock resolution'
    $ownerMismatchRestoredConfig = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get', 'branch.fix/local-owner-drift.remote') `
        -AllowedExitCodes @(0, 1)
    Assert-Equal -Actual $ownerMismatchRestoredConfig.Output -Expected 'origin' `
        -Message 'External recovery must restore the preserved config to its exact branch'
    $ownerMismatchTemporaryConfigAfterRecovery = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get-regexp', '^branch\.codex-cleanup-') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $ownerMismatchTemporaryConfigAfterRecovery -Expected 1 `
        -Message 'External owner recovery must leave no temporary config residue'

    # configless CAS成功後へuncooperative actorの同名branch再作成を差し込む。
    # config writerは標準lockで排他済みなので、actorのR/reflogだけを保持する。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-recreate', $localExpectedHeadOid) | Out-Null
    $localRecreatedOid = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'commit-tree',
            $localExpectedTreeOid,
            '-p',
            $localExpectedHeadOid,
            '-m',
            'recreate local branch'
        )).Output
    $localRecreateHook = {
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @('update-ref', 'refs/heads/fix/local-recreate', $localRecreatedOid) | Out-Null
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-recreate' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterCasForTest $localRecreateHook | Out-Null
        } `
        -Pattern 'recreated after CAS' `
        -Message 'A branch recreation interleaving after CAS must fail closed'
    $recreatedLocalTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-recreate')).Output
    Assert-Equal -Actual $recreatedLocalTip -Expected $localRecreatedOid `
        -Message 'Post-CAS recreation must preserve the exact actor tip'
    $recreatedLocalConfig = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get', 'branch.fix/local-recreate.remote') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $recreatedLocalConfig -Expected 1 `
        -Message 'Post-CAS branch recreation must not invent branch config'
    $recreatedLocalReflog = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('reflog', 'exists', 'refs/heads/fix/local-recreate') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $recreatedLocalReflog -Expected 0 `
        -Message 'Post-CAS recreation must preserve the actor branch reflog'
    $temporaryConfigAfterRecreate = Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('config', '--local', '--get-regexp', '^branch\.codex-cleanup-') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $temporaryConfigAfterRecreate -Expected 1 `
        -Message 'Post-CAS recreation must not invent owner temporary config'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Post-CAS recreation rejection must release the owner lock'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Post-CAS recreation rejection must release the Git config writer lock'

    # CAS後にactorがbranchを再作成し、guard rootへ予期しないentryも置く。
    # exact owner invariantが崩れた場合はnormal/force removeとも行わず、ref、
    # guard metadata/path、custom lockを保持して外部回復へ渡す。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-guard-release-failure', $localExpectedHeadOid) | Out-Null
    $guardReleaseFailureState = [pscustomobject]@{
        Path = $null
        UnexpectedPath = $null
    }
    $guardReleaseFailureHook = {
        param($cleanupGuard)

        $guardReleaseFailureState.Path = $cleanupGuard.Path
        $guardReleaseFailureState.UnexpectedPath = Join-Path `
            $cleanupGuard.Path `
            'fixture-unexpected.txt'
        Invoke-Git -Repository $localDeleteRepository `
            -Arguments @(
                'update-ref',
                'refs/heads/fix/local-guard-release-failure',
                $localRecreatedOid
            ) | Out-Null
        Write-FixtureFile `
            -Path $guardReleaseFailureState.UnexpectedPath `
            -Content "fixture-owned unexpected entry`n"
    }
    Assert-Throws `
        -Action {
            Invoke-LocalBranchCleanupCore `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-guard-release-failure' `
                -ExpectedOid $localExpectedHeadOid `
                -AfterCasForTest $guardReleaseFailureHook | Out-Null
        } `
        -Pattern 'guard recovery failed.*No fallback branch deletion was attempted' `
        -Message 'Unexpected guard entry must fail closed without force cleanup'
    $guardReleaseFailureTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-guard-release-failure'
        )).Output
    Assert-Equal -Actual $guardReleaseFailureTip -Expected $localRecreatedOid `
        -Message 'Guard cleanup failure must not additionally delete the recreated branch'
    $guardReleaseFailureConfig = Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'config',
            '--local',
            '--get',
            'branch.fix/local-guard-release-failure.remote'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $guardReleaseFailureConfig -Expected 1 `
        -Message 'Guard cleanup failure path must not invent branch config'
    Assert-True -Condition ([System.IO.Directory]::Exists($guardReleaseFailureState.Path)) `
        -Message 'Unexpected-entry failure must preserve the exact guard path'
    Assert-True -Condition ([System.IO.File]::Exists($guardReleaseFailureState.UnexpectedPath)) `
        -Message 'Unexpected-entry failure must not remove the foreign-looking entry'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Unexpected-entry failure must preserve the owner cleanup lock'
    Assert-False -Condition ([System.IO.File]::Exists($localConfigWriterLockPath)) `
        -Message 'Guard cleanup failure must still release the exact Git config writer lock'
    [System.IO.File]::Delete($guardReleaseFailureState.UnexpectedPath)
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @(
            'worktree',
            'remove',
            '--force',
            $guardReleaseFailureState.Path
        ) | Out-Null
    [System.IO.File]::Delete($localCleanupLockPath)
    Assert-False -Condition ([System.IO.Directory]::Exists($guardReleaseFailureState.Path)) `
        -Message 'External recovery must remove only the exact task-owned guard'
    $guardReleaseRecoveredTip = (Invoke-Git `
        -Repository $localDeleteRepository `
        -Arguments @(
            'rev-parse',
            'refs/heads/fix/local-guard-release-failure'
        )).Output
    Assert-Equal -Actual $guardReleaseRecoveredTip -Expected $localRecreatedOid `
        -Message 'External guard recovery must preserve the recreated branch tip'

    # active/stale/ownership不一致のlockは推測して削除せず、nonblockingで拒否して
    # branchを保持する。ownerだけがfinallyでnonce一致を確認してreleaseする。
    Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('branch', 'fix/local-lock', $localExpectedHeadOid) | Out-Null
    $ownerLock = New-LocalCleanupLock -Path $localCleanupLockPath
    Assert-True -Condition ($null -ne $ownerLock) `
        -Message 'The first cleanup actor must acquire the common lock'
    Assert-True -Condition (Test-LocalCleanupLockOwnership -Lock $ownerLock) `
        -Message 'The acquired cleanup lock must contain the owner nonce'
    Assert-Throws `
        -Action {
            Remove-IsolatedWorktreeLocalBranch `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-lock' `
                -ExpectedOid $localExpectedHeadOid | Out-Null
        } `
        -Pattern 'lock is unavailable' `
        -Message 'A second cleanup actor must fail immediately while the lock is held'
    $lockedLocalTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-lock')).Output
    Assert-Equal -Actual $lockedLocalTip -Expected $localExpectedHeadOid `
        -Message 'Lock contention must preserve the local branch tip'
    Assert-True -Condition (Close-LocalCleanupLock -Lock $ownerLock) `
        -Message 'The owner must release its matching cleanup lock'
    Assert-False -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Owner release must remove the common cleanup lock'

    Write-FixtureFile -Path $localCleanupLockPath -Content 'stale-state-uncertain'
    Assert-Throws `
        -Action {
            Remove-IsolatedWorktreeLocalBranch `
                -RepositoryPath $localDeleteRepository `
                -TaskSlug 'local-lock' `
                -ExpectedOid $localExpectedHeadOid | Out-Null
        } `
        -Pattern 'lock is unavailable' `
        -Message 'An uncertain stale lock must fail closed without recovery guesses'
    Assert-Equal -Actual ([System.IO.File]::ReadAllText($localCleanupLockPath)) `
        -Expected 'stale-state-uncertain' `
        -Message 'An uncertain stale lock must remain untouched'
    $staleLockedTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-lock')).Output
    Assert-Equal -Actual $staleLockedTip -Expected $localExpectedHeadOid `
        -Message 'An uncertain stale lock must preserve the branch'
    [System.IO.File]::Delete($localCleanupLockPath)

    $mismatchedOwnerLock = New-LocalCleanupLock -Path $localCleanupLockPath
    Assert-True -Condition ($null -ne $mismatchedOwnerLock) `
        -Message 'The ownership-mismatch fixture must acquire a lock'
    $foreignNonce = if ($mismatchedOwnerLock.Nonce -ceq ('f' * 32)) {
        'e' * 32
    } else {
        'f' * 32
    }
    $foreignNonceBytes = $utf8NoBom.GetBytes($foreignNonce)
    $mismatchedOwnerLock.Stream.SetLength(0)
    $mismatchedOwnerLock.Stream.Position = 0
    $mismatchedOwnerLock.Stream.Write($foreignNonceBytes, 0, $foreignNonceBytes.Length)
    $mismatchedOwnerLock.Stream.Flush()
    Assert-Throws `
        -Action { Assert-LocalCleanupLockOwnership -Lock $mismatchedOwnerLock } `
        -Pattern 'ownership is uncertain' `
        -Message 'A nonce mismatch must block destructive cleanup'
    $mismatchedLockTip = (Invoke-Git -Repository $localDeleteRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-lock')).Output
    Assert-Equal -Actual $mismatchedLockTip -Expected $localExpectedHeadOid `
        -Message 'A nonce mismatch must preserve the branch'
    Assert-False -Condition (Close-LocalCleanupLock -Lock $mismatchedOwnerLock) `
        -Message 'A mismatched owner must not delete the uncertain lock'
    Assert-True -Condition ([System.IO.File]::Exists($localCleanupLockPath)) `
        -Message 'Ownership mismatch must leave the uncertain lock in place'
    [System.IO.File]::Delete($localCleanupLockPath)

    $lockRecoveryDelete = Remove-IsolatedWorktreeLocalBranch `
        -RepositoryPath $localDeleteRepository `
        -TaskSlug 'local-lock' `
        -ExpectedOid $localExpectedHeadOid
    Assert-Equal -Actual $lockRecoveryDelete.BranchRef `
        -Expected 'refs/heads/fix/local-lock' `
        -Message 'Cleanup may resume only after the uncertain lock is resolved externally'

    # ambient GIT_DIRなどが別repoを指しても、helperの-Repository境界をredirect
    # させない。targetだけをcleanupし、redirect repoとprocess envをexact保持する。
    $environmentTargetRepository = Join-Path $testRoot 'local-env-target'
    Initialize-FixtureRepository -Path $environmentTargetRepository
    Invoke-Git -Repository $environmentTargetRepository `
        -Arguments @('switch', '-c', 'fix/local-env-boundary') | Out-Null
    Add-Commit -Repository $environmentTargetRepository `
        -RelativePath 'environment.txt' `
        -Content "environment boundary`n" `
        -Message 'local environment boundary'
    $environmentExpectedHeadOid = (Invoke-Git `
        -Repository $environmentTargetRepository `
        -Arguments @('rev-parse', 'refs/heads/fix/local-env-boundary')).Output
    Invoke-Git -Repository $environmentTargetRepository `
        -Arguments @('switch', 'main') | Out-Null

    $environmentRedirectRepository = Join-Path $testRoot 'local-env-redirect'
    Invoke-Git -Repository $testRoot `
        -Arguments @(
            'clone',
            '--no-local',
            $environmentTargetRepository,
            $environmentRedirectRepository
        ) | Out-Null
    Invoke-Git -Repository $environmentRedirectRepository `
        -Arguments @(
            'branch',
            'fix/local-env-boundary',
            $environmentExpectedHeadOid
        ) | Out-Null
    Invoke-Git -Repository $environmentRedirectRepository `
        -Arguments @(
            'config',
            'branch.fix/local-env-boundary.remote',
            'redirect-origin'
        ) | Out-Null
    $environmentRedirectGitDir = (Invoke-Git `
        -Repository $environmentRedirectRepository `
        -Arguments @('rev-parse', '--absolute-git-dir')).Output
    $environmentRedirectObjectDir = Join-Path `
        $environmentRedirectGitDir `
        'objects'
    $environmentTargetLockPath = Get-LocalCleanupLockPath `
        -RepositoryPath $environmentTargetRepository
    $environmentRedirectLockPath = Get-LocalCleanupLockPath `
        -RepositoryPath $environmentRedirectRepository

    $environmentBeforeHostileFixture = Get-GitProcessEnvironmentSnapshot
    try {
        Clear-GitProcessEnvironment
        Set-ProcessEnvironmentValue -Name 'GIT_DIR' `
            -Value $environmentRedirectGitDir
        Set-ProcessEnvironmentValue -Name 'GIT_WORK_TREE' `
            -Value $environmentRedirectRepository
        Set-ProcessEnvironmentValue -Name 'GIT_COMMON_DIR' `
            -Value $environmentRedirectGitDir
        Set-ProcessEnvironmentValue -Name 'GIT_OBJECT_DIRECTORY' `
            -Value $environmentRedirectObjectDir
        Set-ProcessEnvironmentValue -Name 'GIT_TERMINAL_PROMPT' -Value '1'
        Set-ProcessEnvironmentValue -Name 'GIT_CONFIG_NOSYSTEM' -Value '0'
        Set-ProcessEnvironmentValue -Name 'GIT_CONFIG_GLOBAL' `
            -Value $isolatedGlobalConfig
        if (-not $isWindowsPlatform) {
            # POSIX hostではcase-variantを同時に置き、production helperの
            # clear/restoreが両方をexactに戻すことを既存snapshot比較で検証する。
            Set-ProcessEnvironmentValue `
                -Name 'GIT_CODEX_CASE_VARIANT' `
                -Value 'upper-environment'
            Set-ProcessEnvironmentValue `
                -Name 'git_codex_case_variant' `
                -Value 'lower-environment'
        }
        $hostileGitEnvironment = Get-GitProcessEnvironmentSnapshot

        $environmentCleanup = Remove-IsolatedWorktreeLocalBranch `
            -RepositoryPath $environmentTargetRepository `
            -TaskSlug 'local-env-boundary' `
            -ExpectedOid $environmentExpectedHeadOid
        Assert-Equal -Actual $environmentCleanup.BranchRef `
            -Expected 'refs/heads/fix/local-env-boundary' `
            -Message 'Environment-isolated cleanup must report the requested target branch'
        $gitEnvironmentAfterCleanup = Get-GitProcessEnvironmentSnapshot
        Assert-True -Condition (
            Test-GitProcessEnvironmentSnapshotEqual `
                -Left $hostileGitEnvironment `
                -Right $gitEnvironmentAfterCleanup
        ) -Message 'Local cleanup must restore every ambient GIT variable exactly'

        $environmentTargetRef = Invoke-Git `
            -Repository $environmentTargetRepository `
            -Arguments @(
                'show-ref',
                '--verify',
                '--quiet',
                'refs/heads/fix/local-env-boundary'
            ) `
            -AllowedExitCodes @(0, 1)
        Assert-ExitCode -Result $environmentTargetRef -Expected 1 `
            -Message 'Ambient Git routing must not prevent deletion in the requested repository'
        $environmentTargetReflog = Invoke-Git `
            -Repository $environmentTargetRepository `
            -Arguments @(
                'reflog',
                'exists',
                'refs/heads/fix/local-env-boundary'
            ) `
            -AllowedExitCodes @(0, 1)
        Assert-ExitCode -Result $environmentTargetReflog -Expected 1 `
            -Message 'Requested-repository cleanup must remove its exact branch reflog'
        $environmentTargetConfig = Invoke-Git `
            -Repository $environmentTargetRepository `
            -Arguments @(
                'config',
                '--local',
                '--get',
                'branch.fix/local-env-boundary.remote'
            ) `
            -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $environmentTargetConfig -Expected 1 `
        -Message 'Requested-repository cleanup must not invent branch config'

        $environmentRedirectTip = (Invoke-Git `
            -Repository $environmentRedirectRepository `
            -Arguments @(
                'rev-parse',
                'refs/heads/fix/local-env-boundary'
            )).Output
        Assert-Equal `
            -Actual $environmentRedirectTip `
            -Expected $environmentExpectedHeadOid `
            -Message 'Ambient GIT_DIR target must preserve its exact branch tip'
        $environmentRedirectReflog = Invoke-Git `
            -Repository $environmentRedirectRepository `
            -Arguments @(
                'reflog',
                'exists',
                'refs/heads/fix/local-env-boundary'
            ) `
            -AllowedExitCodes @(0, 1)
        Assert-ExitCode -Result $environmentRedirectReflog -Expected 0 `
            -Message 'Ambient GIT_DIR target must preserve its branch reflog'
        $environmentRedirectConfig = Invoke-Git `
            -Repository $environmentRedirectRepository `
            -Arguments @(
                'config',
                '--local',
                '--get',
                'branch.fix/local-env-boundary.remote'
            ) `
            -AllowedExitCodes @(0, 1)
        Assert-Equal `
            -Actual $environmentRedirectConfig.Output `
            -Expected 'redirect-origin' `
            -Message 'Ambient GIT_DIR target must preserve its branch config'
        Assert-False `
            -Condition ([System.IO.File]::Exists($environmentTargetLockPath)) `
            -Message 'Requested repository must release its cleanup lock'
        Assert-False `
            -Condition ([System.IO.File]::Exists($environmentRedirectLockPath)) `
            -Message 'Redirect repository must not receive a cleanup lock'
    }
    finally {
        Clear-GitProcessEnvironment
        foreach ($name in $environmentBeforeHostileFixture.Keys) {
            Set-ProcessEnvironmentValue `
                -Name $name `
                -Value $environmentBeforeHostileFixture[$name]
        }
    }

    # remote branch削除は、別sessionがPR merge後にrefを前進させても
    # そのcommitを消さないことをdisposable bare originで固定する。
    $remoteOriginRepository = Join-Path $testRoot 'remote-origin.git'
    New-Item -ItemType Directory -Path $remoteOriginRepository | Out-Null
    Invoke-Git -Repository $remoteOriginRepository -Arguments @('init', '--bare', '-b', 'main') | Out-Null

    $remoteOwnerRepository = Join-Path $testRoot 'remote-owner'
    Initialize-FixtureRepository -Path $remoteOwnerRepository
    Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @('remote', 'add', 'origin', $remoteOriginRepository) | Out-Null
    Invoke-Git -Repository $remoteOwnerRepository -Arguments @('push', '-u', 'origin', 'main') | Out-Null
    Invoke-Git -Repository $remoteOwnerRepository -Arguments @('switch', '-c', 'fix/remote-delete') | Out-Null
    Add-Commit -Repository $remoteOwnerRepository -RelativePath 'remote.txt' `
        -Content "expected`n" -Message 'remote delete expected head'
    $remoteExpectedHeadOid = (Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @('rev-parse', 'fix/remote-delete')).Output
    Invoke-Git -Repository $remoteOwnerRepository -Arguments @(
        'push',
        'origin',
        'fix/remote-delete:refs/heads/fix/lease-positive',
        'fix/remote-delete:refs/heads/fix/lease-drift'
    ) | Out-Null

    # expected Hのままなら削除できるpositive pathを先に固定する。
    $positiveRemoteDelete = Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @(
            'push',
            "--force-with-lease=refs/heads/fix/lease-positive:$remoteExpectedHeadOid",
            'origin',
            ':refs/heads/fix/lease-positive'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $positiveRemoteDelete -Expected 0 `
        -Message 'Remote cleanup must delete a branch that still equals the expected PR head'
    $positiveRemoteAfterDelete = Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @('ls-remote', '--exit-code', '--heads', 'origin', 'refs/heads/fix/lease-positive') `
        -AllowedExitCodes @(0, 2)
    Assert-ExitCode -Result $positiveRemoteAfterDelete -Expected 2 `
        -Message 'The exact expected remote branch must be absent after guarded deletion'

    # second actorだけをRへ進め、owner側のlocal Hは意図的に不変に保つ。
    $remoteActorRepository = Join-Path $testRoot 'remote-actor'
    Invoke-Git -Repository $testRoot `
        -Arguments @('clone', $remoteOriginRepository, $remoteActorRepository) | Out-Null
    Invoke-Git -Repository $remoteActorRepository `
        -Arguments @('config', 'user.name', 'Remote Drift Actor') | Out-Null
    $remoteActorEmail = 'remote-drift-actor' + '@' + 'example.invalid'
    Invoke-Git -Repository $remoteActorRepository `
        -Arguments @('config', 'user.email', $remoteActorEmail) | Out-Null
    Invoke-Git -Repository $remoteActorRepository -Arguments @(
        'switch',
        '-c',
        'actor/remote-delete',
        '--track',
        'origin/fix/lease-drift'
    ) | Out-Null
    Add-Commit -Repository $remoteActorRepository -RelativePath 'remote-actor.txt' `
        -Content "advanced`n" -Message 'advance remote branch'
    $remoteAdvancedOid = (Invoke-Git -Repository $remoteActorRepository `
        -Arguments @('rev-parse', 'HEAD')).Output
    Invoke-Git -Repository $remoteActorRepository `
        -Arguments @('push', 'origin', 'HEAD:refs/heads/fix/lease-drift') | Out-Null
    Assert-NotEqual -Actual $remoteAdvancedOid -Expected $remoteExpectedHeadOid `
        -Message 'The second actor must advance the remote branch beyond the expected PR head'
    $remoteOwnerTip = (Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @('rev-parse', 'fix/remote-delete')).Output
    Assert-Equal -Actual $remoteOwnerTip -Expected $remoteExpectedHeadOid `
        -Message 'The owner local branch must remain equal to the merged PR head'

    # expected Hを明示したleaseにより、check後の競合もserver側でatomicに拒否する。
    $driftedRemoteDelete = Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @(
            'push',
            "--force-with-lease=refs/heads/fix/lease-drift:$remoteExpectedHeadOid",
            'origin',
            ':refs/heads/fix/lease-drift'
        ) `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $driftedRemoteDelete -Expected 1 `
        -Message 'Remote cleanup must reject a branch advanced by another actor'
    $driftedRemoteAfterDelete = Invoke-Git -Repository $remoteOwnerRepository `
        -Arguments @('ls-remote', '--exit-code', '--heads', 'origin', 'refs/heads/fix/lease-drift') `
        -AllowedExitCodes @(0, 2)
    Assert-ExitCode -Result $driftedRemoteAfterDelete -Expected 0 `
        -Message 'Rejected cleanup must preserve the advanced remote branch'
    Assert-Equal -Actual $driftedRemoteAfterDelete.Output `
        -Expected "$remoteAdvancedOid`trefs/heads/fix/lease-drift" `
        -Message 'Rejected cleanup must preserve the exact second-actor remote tip'

    Write-Host "Cleanup guard regression test passed ($assertionCount assertions)."
}
catch {
    # Preserve the primary failure so a later cleanup failure cannot mask it.
    $primaryFailure = $_
    throw
}
finally {
    try {
        Remove-FixtureRoot -Root $testRoot -TemporaryParent $tempParent
    }
    catch {
        if ($null -eq $primaryFailure) {
            throw
        }
        Write-Warning 'Fixture cleanup also failed after the primary test failure.'
    }
}
