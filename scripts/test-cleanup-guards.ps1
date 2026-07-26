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
    $snapshot = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name -match '^GIT_') {
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

    # Merge-commit mode preserves the source commits as main ancestors, which
    # is the positive path for guard 2a before a normal branch -d.
    $mergeRepository = Join-Path $testRoot 'merge'
    Initialize-FixtureRepository -Path $mergeRepository
    Invoke-Git -Repository $mergeRepository -Arguments @('switch', '-c', 'fix/merge') | Out-Null
    Add-Commit -Repository $mergeRepository -RelativePath 'feature.txt' -Content "merge`n" -Message 'feature'
    Invoke-Git -Repository $mergeRepository -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -Repository $mergeRepository -Arguments @('merge', '--no-ff', 'fix/merge', '-m', 'merge result') | Out-Null

    $mergeBranchAncestor = Invoke-Git -Repository $mergeRepository `
        -Arguments @('merge-base', '--is-ancestor', 'fix/merge', 'main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $mergeBranchAncestor -Expected 0 `
        -Message 'Guard 2a must accept a branch landed by merge commit'

    # Squash does not make the source commits ancestors of main. Guard 2b's
    # two checks jointly prove the landed result and the unchanged local tip.
    $squashRepository = Join-Path $testRoot 'squash'
    Initialize-FixtureRepository -Path $squashRepository
    Invoke-Git -Repository $squashRepository -Arguments @('switch', '-c', 'fix/squash') | Out-Null
    Add-Commit -Repository $squashRepository -RelativePath 'feature-a.txt' -Content "a`n" -Message 'feature a'
    Add-Commit -Repository $squashRepository -RelativePath 'feature-b.txt' -Content "b`n" -Message 'feature b'
    $squashHeadRefOid = (Invoke-Git -Repository $squashRepository -Arguments @('rev-parse', 'fix/squash')).Output

    Invoke-Git -Repository $squashRepository -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -Repository $squashRepository -Arguments @('merge', '--squash', 'fix/squash') | Out-Null
    Invoke-Git -Repository $squashRepository -Arguments @('commit', '-m', 'squash result') | Out-Null
    $squashMergeCommitOid = (Invoke-Git -Repository $squashRepository -Arguments @('rev-parse', 'main')).Output

    $squashBranchAncestor = Invoke-Git -Repository $squashRepository `
        -Arguments @('merge-base', '--is-ancestor', 'fix/squash', 'main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $squashBranchAncestor -Expected 1 `
        -Message 'Guard 2a must reject a correctly squashed branch'

    $squashResultAncestor = Invoke-Git -Repository $squashRepository `
        -Arguments @('merge-base', '--is-ancestor', $squashMergeCommitOid, 'main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $squashResultAncestor -Expected 0 `
        -Message 'Guard 2b must accept a landed squash result'

    $squashLocalTip = (Invoke-Git -Repository $squashRepository -Arguments @('rev-parse', 'fix/squash')).Output
    Assert-Equal -Actual $squashLocalTip -Expected $squashHeadRefOid `
        -Message 'Guard 2b must accept an unchanged local PR branch'

    # A claimed merge result outside the default branch must block deletion.
    $squashTreeOid = (Invoke-Git -Repository $squashRepository -Arguments @('rev-parse', 'main^{tree}')).Output
    $unrelatedCommitOid = (Invoke-Git -Repository $squashRepository `
        -Arguments @('commit-tree', $squashTreeOid, '-m', 'unrelated result')).Output
    $unrelatedResultAncestor = Invoke-Git -Repository $squashRepository `
        -Arguments @('merge-base', '--is-ancestor', $unrelatedCommitOid, 'main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $unrelatedResultAncestor -Expected 1 `
        -Message 'Guard 2b must reject a merge result outside the default branch'

    # The headRefOid comparison must catch a local commit added after merge.
    Invoke-Git -Repository $squashRepository -Arguments @('switch', 'fix/squash') | Out-Null
    Add-Commit -Repository $squashRepository -RelativePath 'late.txt' -Content "late`n" -Message 'late local commit'
    $advancedLocalTip = (Invoke-Git -Repository $squashRepository -Arguments @('rev-parse', 'fix/squash')).Output
    Assert-NotEqual -Actual $advancedLocalTip -Expected $squashHeadRefOid `
        -Message 'Guard 2b must reject local commits added after the merged PR head'

    # Rebase merge rewrites commit IDs. Preserve the original PR branch while
    # rebasing a copy, then fast-forward main to synthesize GitHub's topology.
    $rebaseRepository = Join-Path $testRoot 'rebase'
    Initialize-FixtureRepository -Path $rebaseRepository
    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', '-c', 'fix/rebase') | Out-Null
    Add-Commit -Repository $rebaseRepository -RelativePath 'feature-a.txt' -Content "a`n" -Message 'feature a'
    Add-Commit -Repository $rebaseRepository -RelativePath 'feature-b.txt' -Content "b`n" -Message 'feature b'
    $rebaseHeadRefOid = (Invoke-Git -Repository $rebaseRepository -Arguments @('rev-parse', 'fix/rebase')).Output

    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', 'main') | Out-Null
    Add-Commit -Repository $rebaseRepository -RelativePath 'base-next.txt' -Content "next`n" -Message 'advance base'
    Invoke-Git -Repository $rebaseRepository -Arguments @('branch', 'rebased-result', 'fix/rebase') | Out-Null
    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', 'rebased-result') | Out-Null
    Invoke-Git -Repository $rebaseRepository -Arguments @('rebase', 'main') | Out-Null
    $rebaseMergeCommitOid = (Invoke-Git -Repository $rebaseRepository -Arguments @('rev-parse', 'rebased-result')).Output
    Invoke-Git -Repository $rebaseRepository -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -Repository $rebaseRepository -Arguments @('merge', '--ff-only', 'rebased-result') | Out-Null

    # Fail at the rewritten-history premise itself so later topology checks
    # cannot be the only signal that the synthetic rebase actually rewrote it.
    Assert-NotEqual -Actual $rebaseMergeCommitOid -Expected $rebaseHeadRefOid `
        -Message 'The landed rebase commit must differ from the original PR head'

    $rebaseBranchAncestor = Invoke-Git -Repository $rebaseRepository `
        -Arguments @('merge-base', '--is-ancestor', 'fix/rebase', 'main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $rebaseBranchAncestor -Expected 1 `
        -Message 'Guard 2a must reject a correctly rebased branch with rewritten commits'

    $rebaseResultAncestor = Invoke-Git -Repository $rebaseRepository `
        -Arguments @('merge-base', '--is-ancestor', $rebaseMergeCommitOid, 'main') `
        -AllowedExitCodes @(0, 1)
    Assert-ExitCode -Result $rebaseResultAncestor -Expected 0 `
        -Message 'Guard 2b must accept the landed rebase result'

    $rebaseLocalTip = (Invoke-Git -Repository $rebaseRepository -Arguments @('rev-parse', 'fix/rebase')).Output
    Assert-Equal -Actual $rebaseLocalTip -Expected $rebaseHeadRefOid `
        -Message 'Guard 2b must accept the unchanged original PR head after rebase merge'

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
