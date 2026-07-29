[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Split-Path -Parent $scriptRoot
}

$root = (Resolve-Path -LiteralPath $Path).Path
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
}

function Get-RepoFilePath {
    param([string]$RelativePath)
    return Join-Path $root $RelativePath
}

function Assert-FileExists {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

function Assert-FileContains {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    # Windows PowerShell 5.1の既定ANSI解釈を避け、BOMなしUTF-8 Markdownも
    # PowerShell 7と同じcode point列として検証する。
    $content = [System.IO.File]::ReadAllText($filePath)
    if ($content -notmatch $Pattern) {
        Add-Failure "$RelativePath is missing: $Description"
    }
}

function Assert-FilePatternCount {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [int]$ExpectedCount,
        [string]$Description
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath ($Description)"
        return
    }

    # pattern countもhost既定encodingへ依存させず、両hostで同じUTF-8本文を数える。
    $content = [System.IO.File]::ReadAllText($filePath)
    $actualCount = [regex]::Matches($content, $Pattern).Count
    if ($actualCount -ne $ExpectedCount) {
        Add-Failure (
            "$RelativePath must contain exactly $ExpectedCount $Description " +
            "(actual: $actualCount)."
        )
    }
}

function Assert-FileHasUtf8Bom {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (UTF-8 BOM contract)"
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 3 -or
        $bytes[0] -ne 0xEF -or
        $bytes[1] -ne 0xBB -or
        $bytes[2] -ne 0xBF) {
        Add-Failure "$RelativePath must keep a UTF-8 BOM because Windows PowerShell 5.1 executes its Japanese comments."
    }
}

function Assert-FirstTopLevelProcessInvocationIsBinary {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (first process invocation contract)"
        return
    }

    # 文字列検索だけではfunction定義内の未実行callを先頭と誤認する。
    # ASTの親をたどり、top-levelで実際に評価されるhelper callだけを比較する。
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $filePath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        Add-Failure "$RelativePath could not be parsed for its first process invocation contract."
        return
    }

    $topLevelCalls = @(
        $ast.FindAll(
            {
                param($node)

                if (-not ($node -is [System.Management.Automation.Language.CommandAst]) -or
                    $node.GetCommandName() -ne
                        'Invoke-PrivateMarkerProcess') {
                    return $false
                }

                $ancestor = $node.Parent
                while ($null -ne $ancestor) {
                    if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                        return $false
                    }
                    $ancestor = $ancestor.Parent
                }
                return $true
            },
            $true
        ) | Sort-Object { $_.Extent.StartOffset }
    )
    if ($topLevelCalls.Count -eq 0 -or
        $topLevelCalls[0].Extent.Text -notmatch
            '(?s)-StandardInputBytes\s+\$binaryProbeBytes\b') {
        Add-Failure "$RelativePath must use the exact binary fixture for its first top-level bounded-process invocation."
    }
}

function Assert-FinalScanDeadlineContract {
    param(
        [string]$RelativePath
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (final scan deadline contract)"
        return
    }

    # finding payload と clean result のどちらも、emit直前に同じscan-wide時計を
    # 再確認する。途中のdeadline callが存在するだけでは最終窓を閉じられない。
    $source = [System.IO.File]::ReadAllText($filePath)
    $findingWritePattern = (
        '(?m)^[ \t]*\$standardOutput\.Write\(')
    $guardedFindingWritePattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*\$standardOutput\.Write\(')
    $outputLimitWritePattern = (
        '(?m)^[ \t]*Write-Host[ \t]+' +
        '''Private marker scan aborted: scan-diagnostic-output-limit''' +
        '[ \t]*$')
    $guardedOutputLimitWritePattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*Write-Host[ \t]+' +
        '''Private marker scan aborted: scan-diagnostic-output-limit''' +
        '[ \t]*$')
    $successEmitPattern = (
        '(?m)^[ \t]*Assert-PrivateMarkerScanDeadline[ \t]*\r?\n' +
        '[ \t]*Write-Host[ \t]+' +
        '"Private marker scan passed \(scan target: \$scanMode\)\."[ \t]*$')
    $findingWriteCount = [regex]::Matches(
        $source,
        $findingWritePattern
    ).Count
    $guardedFindingWriteCount = [regex]::Matches(
        $source,
        $guardedFindingWritePattern
    ).Count
    $openStandardOutputCount = [regex]::Matches(
        $source,
        '\[Console\]::OpenStandardOutput\(\)'
    ).Count
    if ($findingWriteCount -ne 1 -or
        $guardedFindingWriteCount -ne $findingWriteCount -or
        $openStandardOutputCount -ne 1) {
        Add-Failure "$RelativePath must recheck the scan-wide deadline immediately before writing finding stdout."
    }
    $outputLimitWriteCount = [regex]::Matches(
        $source,
        $outputLimitWritePattern
    ).Count
    $guardedOutputLimitWriteCount = [regex]::Matches(
        $source,
        $guardedOutputLimitWritePattern
    ).Count
    $writeHostCount = [regex]::Matches(
        $source,
        '(?m)^[ \t]*Write-Host\b'
    ).Count
    if ($outputLimitWriteCount -ne 2 -or
        $guardedOutputLimitWriteCount -ne $outputLimitWriteCount -or
        $writeHostCount -ne 3) {
        Add-Failure "$RelativePath must guard every bounded diagnostic output with an immediate scan-wide deadline check."
    }
    if ($source -notmatch $successEmitPattern) {
        Add-Failure "$RelativePath must recheck the scan-wide deadline immediately before success output."
    }
}

function Test-PrivateMarkerMillisecondWaitContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $tokens = $null
    $parseErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        return $false
    }
    $normalizeNewlines = {
        param([string]$Text)
        return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    }

    # 実際にAdd-Typeへ渡るC# sourceだけを選び、外側のcomment/string decoyを除外する。
    $containedTypeSources = @(
        foreach ($command in @($sourceAst.FindAll({
            param($node)
            $node -is
                [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -ceq 'Add-Type'
        }, $true))) {
            $elements = @($command.CommandElements)
            if ($elements.Count -ne 3 -or
                $elements[1] -isnot
                    [System.Management.Automation.Language.CommandParameterAst] -or
                $elements[1].ParameterName -cne 'TypeDefinition' -or
                $elements[2] -isnot
                    [System.Management.Automation.Language.StringConstantExpressionAst]) {
                continue
            }
            $typeSource = [string]$elements[2].Value
            if ($typeSource.Contains('public sealed class ContainedProcess')) {
                $typeSource
            }
        }
    )
    if ($containedTypeSources.Count -ne 1) {
        return $false
    }

    # C# wrapperは受け取ったmillisecond値を唯一のWin32 waitへ直接渡す。
    $expectedWaitMethod = @'
        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(
                processHandle,
                (uint)milliseconds) == WaitObject0;
        }
'@
    $containedTypeSource = & $normalizeNewlines $containedTypeSources[0]
    $normalizedWaitMethod = & $normalizeNewlines $expectedWaitMethod
    $waitMethodIndex = $containedTypeSource.IndexOf(
        $normalizedWaitMethod,
        [System.StringComparison]::Ordinal
    )
    if ($waitMethodIndex -lt 0 -or
        $waitMethodIndex -ne $containedTypeSource.LastIndexOf(
            $normalizedWaitMethod,
            [System.StringComparison]::Ordinal
        ) -or
        [regex]::Matches(
            $containedTypeSource,
            '(?m)^[ \t]*public bool WaitForExit\s*\('
        ).Count -ne 1) {
        return $false
    }
    $expectedWaitImport = @'
        private static extern uint WaitForSingleObject(
            IntPtr handle,
            uint milliseconds);
'@
    $normalizedWaitImport = & $normalizeNewlines $expectedWaitImport
    $waitImportIndex = $containedTypeSource.IndexOf(
        $normalizedWaitImport,
        [System.StringComparison]::Ordinal
    )
    if ($waitImportIndex -lt 0 -or
        $waitImportIndex -ne $containedTypeSource.LastIndexOf(
            $normalizedWaitImport,
            [System.StringComparison]::Ordinal
        )) {
        return $false
    }

    # pure helper全体をexact化し、100ms sliceと残予算の小さい方だけを返す。
    $expectedRemainingFunction = @'
function Get-PrivateMarkerPollWaitMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [long]$ElapsedMilliseconds,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutMilliseconds
    )

    $remaining = [long]$TimeoutMilliseconds - $ElapsedMilliseconds
    if ($remaining -le 0) {
        return 0
    }
    return [int][Math]::Min(100L, $remaining)
}
'@
    $remainingFunctions = @($sourceAst.FindAll({
        param($node)
        $node -is
            [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-PrivateMarkerPollWaitMilliseconds'
    }, $true))
    if ($remainingFunctions.Count -ne 1 -or
        (& $normalizeNewlines $remainingFunctions[0].Extent.Text) -cne
            (& $normalizeNewlines $expectedRemainingFunction)) {
        return $false
    }

    $invokeFunctions = @($sourceAst.FindAll({
        param($node)
        $node -is
            [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-PrivateMarkerProcess'
    }, $true))
    if ($invokeFunctions.Count -ne 1) {
        return $false
    }

    # receiver名で先に絞らず、operation function内のWaitForExitを全件列挙する。
    # alias receiverへ追加waitを隠しても、総数・順序・引数のexact契約で拒否する。
    $allInvokeMemberCalls = @($invokeFunctions[0].Body.FindAll({
        param($node)
        $node -is
            [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))
    # dynamic memberはruntimeでWaitForExitへ解決し得るため、raw例外にせずfail closedする。
    if (@($allInvokeMemberCalls | Where-Object {
        $_.Member -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst]
    }).Count -gt 0) {
        return $false
    }
    $allWaitCalls = @($allInvokeMemberCalls | Where-Object {
        [string]::Equals(
            [string]$_.Member.Value,
            'WaitForExit',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } | Sort-Object { $_.Extent.StartOffset })
    $expectedWaitReceivers = @('containedProcess', 'process')
    if ($allWaitCalls.Count -ne $expectedWaitReceivers.Count) {
        return $false
    }
    for ($waitIndex = 0;
        $waitIndex -lt $expectedWaitReceivers.Count;
        $waitIndex++) {
        $waitCall = $allWaitCalls[$waitIndex]
        if ($waitCall.Expression -isnot
                [System.Management.Automation.Language.VariableExpressionAst] -or
            $waitCall.Expression.VariablePath.UserPath -cne
                $expectedWaitReceivers[$waitIndex] -or
            $waitCall.Arguments.Count -ne 1 -or
            $waitCall.Arguments[0] -isnot
                [System.Management.Automation.Language.VariableExpressionAst] -or
            $waitCall.Arguments[0].VariablePath.UserPath -cne
                'remaining') {
            return $false
        }
    }
    $containedWaitCall = $allWaitCalls[0]
    $managedWaitCall = $allWaitCalls[1]

    # 最後のremaining代入から両waitまでを実AST extentでexact比較する。
    $expectedWaitRegion = @'
            $remaining = Get-PrivateMarkerPollWaitMilliseconds `
                -ElapsedMilliseconds $clock.ElapsedMilliseconds `
                -TimeoutMilliseconds $TimeoutMilliseconds
            if ($remaining -le 0) {
                break
            }
            if ($null -ne $containedProcess) {
                [void]$containedProcess.WaitForExit($remaining)
            } else {
                [void]$process.WaitForExit($remaining)
'@
    $remainingAssignments = @($invokeFunctions[0].Body.FindAll({
        param($node)
        $node -is
            [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is
                [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ceq 'remaining'
    }, $true) | Where-Object {
        $_.Extent.EndOffset -le $containedWaitCall.Extent.StartOffset
    } | Sort-Object { $_.Extent.StartOffset })
    if ($remainingAssignments.Count -eq 0 -or
        $managedWaitCall.Extent.StartOffset -le
            $containedWaitCall.Extent.StartOffset) {
        return $false
    }
    $lastRemainingAssignment = $remainingAssignments[-1]
    $waitRegionStartOffset =
        $lastRemainingAssignment.Extent.StartOffset -
        ($lastRemainingAssignment.Extent.StartColumnNumber - 1)
    $actualWaitRegion = $Source.Substring(
        $waitRegionStartOffset,
        $managedWaitCall.Extent.EndOffset - $waitRegionStartOffset
    )
    return (& $normalizeNewlines $actualWaitRegion) -ceq
        (& $normalizeNewlines $expectedWaitRegion)
}

function Assert-PrivateMarkerMillisecondWaitContract {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (millisecond wait contract)"
        return
    }
    $source = [System.IO.File]::ReadAllText($filePath)
    if (-not (Test-PrivateMarkerMillisecondWaitContract -Source $source)) {
        Add-Failure '[timeout/millisecond-wait-contract] Expected one unrounded 100ms-or-remaining wait path.'
        return
    }

    # current sourceをmemory上だけで敵対変形し、文字列一致によるfalse greenを防ぐ。
    $lineEnding = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $waitMethod = @'
        public bool WaitForExit(int milliseconds)
        {
            return WaitForSingleObject(
                processHandle,
                (uint)milliseconds) == WaitObject0;
        }
'@
    $waitMethodForSource = $waitMethod.Replace("`n", $lineEnding)
    $roundedCSharpSource = $source.Replace(
        '                (uint)milliseconds) == WaitObject0;',
        '                (uint)(Math.Ceiling(milliseconds / 1000.0) * 1000)) == WaitObject0;'
    )
    $expectedWaitRegion = @'
            $remaining = Get-PrivateMarkerPollWaitMilliseconds `
                -ElapsedMilliseconds $clock.ElapsedMilliseconds `
                -TimeoutMilliseconds $TimeoutMilliseconds
            if ($remaining -le 0) {
                break
            }
            if ($null -ne $containedProcess) {
                [void]$containedProcess.WaitForExit($remaining)
            } else {
                [void]$process.WaitForExit($remaining)
'@
    $waitRegionForSource = $expectedWaitRegion.Replace("`n", $lineEnding)
    $roundedReassignment =
        '            $remaining = [int]([Math]::Ceiling(' +
        '$remaining / 1000.0) * 1000)'
    $roundedRegion = $waitRegionForSource.Replace(
        '            if ($remaining -le 0) {',
        $roundedReassignment + $lineEnding +
            '            if ($remaining -le 0) {'
    )
    $extraRoundedCall =
        '                [void]$containedProcess.WaitForExit(' +
        '[int]([Math]::Ceiling($remaining / 1000.0) * 1000))'
    $mutations = @(
        [pscustomobject]@{
            Label = '[timeout/millisecond-caller-rounding-mutation]'
            Source = $source.Replace(
                '$containedProcess.WaitForExit($remaining)',
                '$containedProcess.WaitForExit([int]([Math]::Ceiling(' +
                    '$remaining / 1000.0) * 1000))'
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-helper-rounding-mutation]'
            Source = $source.Replace(
                'return [int][Math]::Min(100L, $remaining)',
                'return [int]([Math]::Ceiling($remaining / 1000.0) * 1000)'
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-helper-overslice-mutation]'
            Source = $source.Replace(
                'return [int][Math]::Min(100L, $remaining)',
                'return [int][Math]::Min(1000L, $remaining)'
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-comment-decoy-mutation]'
            Source = $source.Replace(
                $waitRegionForSource,
                '            <#' + $lineEnding +
                    $waitRegionForSource + $lineEnding +
                    '            #>' + $lineEnding +
                    $roundedRegion
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-string-decoy-mutation]'
            Source = $source.Replace(
                $waitRegionForSource,
                "            `$millisecondWaitDecoy = @'" +
                    $lineEnding + $waitRegionForSource + $lineEnding +
                    "'@" + $lineEnding + $roundedRegion
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-csharp-comment-decoy-mutation]'
            Source = $roundedCSharpSource + $lineEnding +
                '<#' + $lineEnding + $waitMethodForSource +
                $lineEnding + '#>' + $lineEnding
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-csharp-string-decoy-mutation]'
            Source = $roundedCSharpSource + $lineEnding +
                "`$millisecondWaitMethodDecoy = @'" + $lineEnding +
                $waitMethodForSource + $lineEnding + "'@" + $lineEnding
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-extra-wait-mutation]'
            Source = $source.Replace(
                '                [void]$containedProcess.WaitForExit($remaining)',
                '                [void]$containedProcess.WaitForExit($remaining)' +
                    $lineEnding +
                    '                ' + $extraRoundedCall.TrimStart()
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-receiver-alias-mutation]'
            Source = $source.Replace(
                '                [void]$process.WaitForExit($remaining)',
                '                [void]$process.WaitForExit($remaining)' +
                    $lineEnding +
                    '                $waitAlias = $process' + $lineEnding +
                    '                [void]$waitAlias.WaitForExit(1000)'
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-lowercase-alias-mutation]'
            Source = $source.Replace(
                '                [void]$process.WaitForExit($remaining)',
                '                [void]$process.WaitForExit($remaining)' +
                    $lineEnding +
                    '                $waitAlias = $process' + $lineEnding +
                    '                [void]$waitAlias.waitforexit(1000)'
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-mixed-case-alias-mutation]'
            Source = $source.Replace(
                '                [void]$process.WaitForExit($remaining)',
                '                [void]$process.WaitForExit($remaining)' +
                    $lineEnding +
                    '                $waitAlias = $process' + $lineEnding +
                    '                [void]$waitAlias.wAiTfOrExIt(1000)'
            )
        },
        [pscustomobject]@{
            Label = '[timeout/millisecond-dynamic-member-mutation]'
            Source = $source.Replace(
                '                [void]$process.WaitForExit($remaining)',
                '                [void]$process.WaitForExit($remaining)' +
                    $lineEnding +
                    '                $waitAlias = $process' + $lineEnding +
                    "                `$waitMember = 'WaitForExit'" +
                    $lineEnding +
                    '                [void]$waitAlias.$waitMember(1000)'
            )
        }
    )
    foreach ($mutation in $mutations) {
        if ($mutation.Source -ceq $source -or
            (Test-PrivateMarkerMillisecondWaitContract `
                -Source $mutation.Source)) {
            Add-Failure (
                "$($mutation.Label) Expected the wait contract to reject " +
                'rounding, overslice, or decoy drift.'
            )
        }
    }
}

function Get-LfNormalizedSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    # checkout OSごとの差だけを吸収する。空白、comment、BOM以外のcode pointは
    # 一切正規化せず、review済みhelperのどの1文字のdriftもdigest差分にする。
    $normalizedText = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digestBytes = $sha256.ComputeHash($utf8NoBom.GetBytes($normalizedText))
        return ([System.BitConverter]::ToString($digestBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

# この値は自動更新しない。helperの実diffをreviewした変更だけが、同じPRで
# old/new digestを明示してbaselineを更新できる。
$script:LocalBranchCleanupNormalizedSha256 =
    '255a009c39891dee72d09ba1666999cacaa0f65d4691de405186cb01c85e25ee'

function Test-LocalBranchCleanupContract {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Source
    )

    # open-world AST deny-listでは未知のPowerShell構文を閉じ切れない。helper全体を
    # closed-world fingerprintへ固定し、review済みbaseline以外を最初に拒否する。
    $actualSha256 = Get-LfNormalizedSha256 -Text $Source
    if ($actualSha256 -cne $script:LocalBranchCleanupNormalizedSha256) {
        return $false
    }

    $tokens = $null
    $parseErrors = $null
    $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        return $false
    }

    # digest更新時のhuman reviewを助ける高signal anchorだけを残す。全functionは
    # top-levelに一度ずつ、review済み順序で並び、nested shadowを持たない。
    $expectedFunctionNames = @(
        'New-LocalCleanupRuntimeIntegrityGuard',
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
        'Remove-IsolatedWorktreeLocalBranch'
    )
    $allFunctionDefinitions = @(
        $sourceAst.FindAll(
            {
                param($node)
                $node -is
                    [System.Management.Automation.Language.FunctionDefinitionAst]
            },
            $true
        )
    )
    $topLevelFunctionDefinitions = @(
        $sourceAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }
    )
    if ($allFunctionDefinitions.Count -ne $expectedFunctionNames.Count -or
        $topLevelFunctionDefinitions.Count -ne $expectedFunctionNames.Count) {
        return $false
    }
    for ($functionIndex = 0;
        $functionIndex -lt $expectedFunctionNames.Count;
        $functionIndex++) {
        if ($allFunctionDefinitions[$functionIndex].Name -cne
                $expectedFunctionNames[$functionIndex] -or
            $topLevelFunctionDefinitions[$functionIndex].Name -cne
                $expectedFunctionNames[$functionIndex]) {
            return $false
        }
    }

    # destructive flowの可読なphase索引は各1件かつexact順序に限定する。
    $expectedPhaseMarkers = @(
        '# LOCAL-CAS-PHASE: INPUT-VALIDATION',
        '# LOCAL-CAS-PHASE: LOCK-ACQUIRE',
        '# LOCAL-CAS-PHASE: PRECHECK',
        '# LOCAL-CAS-PHASE: GUARD-ACQUIRE',
        '# LOCAL-CAS-PHASE: CONFIG-ISOLATION',
        '# LOCAL-CAS-PHASE: FINAL-PRE-CAS',
        '# LOCAL-CAS-PHASE: CONFIG-WRITER-LOCK-ACQUIRE',
        '# LOCAL-CAS-PHASE: CAS-DELETE',
        '# LOCAL-CAS-PHASE: POST-CAS-CHECK',
        '# LOCAL-CAS-PHASE: OWNER-CONFIG-CLEANUP',
        '# LOCAL-CAS-PHASE: FINAL-CHECK',
        '# LOCAL-CAS-PHASE: CONFIG-WRITER-LOCK-RELEASE',
        '# LOCAL-CAS-PHASE: GUARD-RELEASE',
        '# LOCAL-CAS-PHASE: LOCK-RELEASE'
    )
    $previousPhaseIndex = -1
    foreach ($phaseMarker in $expectedPhaseMarkers) {
        $phaseMatches = [regex]::Matches(
            $Source,
            [regex]::Escape($phaseMarker)
        )
        $phaseIndex = $Source.IndexOf(
            $phaseMarker,
            [System.StringComparison]::Ordinal
        )
        if ($phaseMatches.Count -ne 1 -or $phaseIndex -le $previousPhaseIndex) {
            return $false
        }
        $previousPhaseIndex = $phaseIndex
    }

    # function外のexecution skeletonを型とassignment targetで小さく固定する。
    # 詳細なoperand/control-flowは全helper digestがclosed-worldで保証する。
    $topLevelResidualStatements = @(
        $sourceAst.EndBlock.Statements | Where-Object {
            -not ($_ -is
                [System.Management.Automation.Language.FunctionDefinitionAst])
        }
    )
    $expectedResidualTypes = @(
        'PipelineAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'IfStatementAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'AssignmentStatementAst',
        'PipelineAst',
        'IfStatementAst'
    )
    if ($topLevelResidualStatements.Count -ne $expectedResidualTypes.Count) {
        return $false
    }
    for ($statementIndex = 0;
        $statementIndex -lt $expectedResidualTypes.Count;
        $statementIndex++) {
        if ($topLevelResidualStatements[$statementIndex].GetType().Name -cne
            $expectedResidualTypes[$statementIndex]) {
            return $false
        }
    }
    $expectedAssignmentTargets = @{
        1 = '$ErrorActionPreference'
        2 = '$script:LocalCleanupGitCommand'
        4 = '$script:LocalCleanupUtf8NoBom'
        5 = '$script:LocalCleanupLockFileName'
        6 = '$script:LocalCleanupConfigWriterLockFileName'
        7 = '$script:LocalCleanupNullConfigPath'
        8 = '$script:LocalCleanupRuntimeIntegrityGuard'
    }
    foreach ($assignmentIndex in $expectedAssignmentTargets.Keys) {
        if ($topLevelResidualStatements[$assignmentIndex].Left.Extent.Text -cne
            $expectedAssignmentTargets[$assignmentIndex]) {
            return $false
        }
    }

    # Gitはapplicationのexact absolute Path、CLIはreview済みfunction providerを使う。
    $normalizedSource = $Source.Replace("`r`n", "`n").Replace("`r", "`n")
    $requiredExecutionAnchors = @(
        (
            'Microsoft.PowerShell.Core\Get-Command git `' + "`n" +
                '        -CommandType Application `'
        ),
        '& $script:LocalCleanupGitCommand.Path `',
        '& ${function:New-LocalCleanupRuntimeIntegrityGuard}',
        '& $script:LocalCleanupRuntimeIntegrityGuard',
        '$result = & ${function:Remove-IsolatedWorktreeLocalBranch} `'
    )
    foreach ($executionAnchor in $requiredExecutionAnchors) {
        if ([regex]::Matches(
            $normalizedSource,
            [regex]::Escape($executionAnchor)
        ).Count -ne 1) {
            return $false
        }
    }

    return $true
}

function Assert-LocalBranchCleanupContract {
    param([string]$RelativePath)

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing file: $RelativePath (local CAS cleanup contract)"
        return
    }

    $source = [System.IO.File]::ReadAllText($filePath)
    $actualSha256 = Get-LfNormalizedSha256 -Text $source
    if (-not (Test-LocalBranchCleanupContract -Source $source)) {
        Add-Failure (
            '[cleanup/local-cas-contract] Expected the reviewed LF-normalized ' +
            'closed-world helper fingerprint and semantic anchors. ' +
            "Expected SHA-256: $script:LocalBranchCleanupNormalizedSha256; " +
            "actual: $actualSha256. Do not auto-refresh the baseline."
        )
        return
    }

    # self-testはclosed-world境界そのものだけを確認する。1文字driftは拒否し、
    # CRLF/LF差は同じreview済みsourceとして受理する。
    $singleCharacterMutation = $source + '#'
    if (Test-LocalBranchCleanupContract -Source $singleCharacterMutation) {
        Add-Failure '[cleanup/local-cas-fingerprint-mutation] Expected one-character drift to be rejected.'
    }
    $lfSource = $source.Replace("`r`n", "`n").Replace("`r", "`n")
    $crlfSource = $lfSource.Replace("`n", "`r`n")
    if ((Get-LfNormalizedSha256 -Text $lfSource) -cne
            (Get-LfNormalizedSha256 -Text $crlfSource) -or
        -not (Test-LocalBranchCleanupContract -Source $crlfSource)) {
        Add-Failure '[cleanup/local-cas-line-ending-normalization] Expected CRLF and LF to share one reviewed digest.'
    }
}
function Get-WorkflowJobLines {
    param(
        [string]$RelativePath,
        [string]$JobName
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return @()
    }

    # workflowはUTF-8/LFでBOMを持たない。Windows PowerShell 5.1 の
    # locale既定decodeでは日本語comment末尾と次行が結合し得るため明示decodeする。
    try {
        $workflowSource = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "Workflow file '$RelativePath' must be valid UTF-8."
        return @()
    }
    $lines = @($workflowSource -split '\r?\n')
    $jobStartIndexes = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $jobMatch = [regex]::Match(
            $lines[$index],
            '^  (?<name>[A-Za-z0-9_-]+):[ \t]*$'
        )
        if ($jobMatch.Success -and
            [string]::Equals(
                $jobMatch.Groups['name'].Value,
                $JobName,
                [System.StringComparison]::Ordinal
            )) {
            $jobStartIndexes.Add($index) | Out-Null
        }
    }
    if ($jobStartIndexes.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must appear exactly once (found $($jobStartIndexes.Count))."
    }
    if ($jobStartIndexes.Count -eq 0) {
        return @()
    }
    $jobStart = $jobStartIndexes[0]

    $jobEnd = $lines.Count
    for ($index = $jobStart + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^  [A-Za-z0-9_-]+:[ \t]*$') {
            $jobEnd = $index
            break
        }
    }
    return @($lines[$jobStart..($jobEnd - 1)])
}

function Assert-WorkflowDocumentShape {
    param(
        [string]$RelativePath,
        [string[]]$ExpectedJobNames
    )

    $filePath = Get-RepoFilePath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Add-Failure "Cannot inspect missing workflow file: $RelativePath"
        return
    }

    # GitHubが解釈するtrigger・permission・job集合を文書全体で固定する。
    # 個別jobだけが正しくても、第二documentや重複root/jobで上書きできれば
    # required CIを無効化できるため、blank/comment以外の構造を順序込みで比較する。
    try {
        $workflowSource = [System.IO.File]::ReadAllText(
            $filePath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
    }
    catch {
        Add-Failure "Workflow file '$RelativePath' must be valid UTF-8."
        return
    }
    $lines = @($workflowSource -split '\r?\n')
    $jobsRootIndexes = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]::Equals(
            $lines[$index],
            'jobs:',
            [System.StringComparison]::Ordinal
        )) {
            $jobsRootIndexes.Add($index) | Out-Null
        }
    }
    if ($jobsRootIndexes.Count -ne 1) {
        Add-Failure "Workflow must contain exactly one ordinal 'jobs:' root key (found $($jobsRootIndexes.Count))."
    }
    if ($jobsRootIndexes.Count -eq 0) {
        return
    }
    $jobsRootIndex = $jobsRootIndexes[0]

    $expectedPrefixLines = @(
        'name: Validate',
        'on:',
        '  pull_request:',
        '  push:',
        '    branches:',
        '      - main',
        'permissions:',
        '  contents: read',
        'jobs:'
    )
    $actualPrefixLines = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -le $jobsRootIndex; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.TrimStart().StartsWith('#', [System.StringComparison]::Ordinal)) {
            continue
        }
        $actualPrefixLines.Add($line) | Out-Null
    }
    $prefixMatches = $actualPrefixLines.Count -eq $expectedPrefixLines.Count
    if ($prefixMatches) {
        for ($index = 0; $index -lt $expectedPrefixLines.Count; $index++) {
            if (-not [string]::Equals(
                $actualPrefixLines[$index],
                $expectedPrefixLines[$index],
                [System.StringComparison]::Ordinal
            )) {
                $prefixMatches = $false
                break
            }
        }
    }
    if (-not $prefixMatches) {
        Add-Failure 'Workflow root must exactly declare Validate, PR/main-push triggers, read-only contents permission, and one jobs mapping.'
    }

    $expectedJobHeadings = @(
        $ExpectedJobNames | ForEach-Object { "  ${_}:" }
    )
    $actualJobHeadings = New-Object System.Collections.Generic.List[string]
    for ($index = $jobsRootIndex + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.TrimStart().StartsWith('#', [System.StringComparison]::Ordinal)) {
            continue
        }

        # jobs配下でindent 0〜3のactive lineはroot keyかdirect job heading。
        # 第二document、未知root、quoted/explicit key、重複jobを全て比較対象にする。
        $firstContentIndex = 0
        while ($firstContentIndex -lt $line.Length -and
            ($line[$firstContentIndex] -eq ' ' -or
             $line[$firstContentIndex] -eq "`t")) {
            $firstContentIndex++
        }
        if ($firstContentIndex -le 3) {
            $actualJobHeadings.Add($line) | Out-Null
        }
    }
    $jobHeadingsMatch =
        $actualJobHeadings.Count -eq $expectedJobHeadings.Count
    if ($jobHeadingsMatch) {
        for ($index = 0; $index -lt $expectedJobHeadings.Count; $index++) {
            if (-not [string]::Equals(
                $actualJobHeadings[$index],
                $expectedJobHeadings[$index],
                [System.StringComparison]::Ordinal
            )) {
                $jobHeadingsMatch = $false
                break
            }
        }
    }
    if (-not $jobHeadingsMatch) {
        Add-Failure 'Workflow jobs mapping must contain exactly validate, validate-ubuntu, and validate-macos in canonical order.'
    }
}

function Get-WorkflowSteps {
    param(
        [string[]]$Lines,
        [string]$JobName
    )

    $stepStartCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $namedStepCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+name:[ \t]+' }
    ).Count
    if ($stepStartCount -ne $namedStepCount) {
        Add-Failure "Workflow job '$JobName' must give every active step an explicit name."
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $currentStep = $null

    foreach ($line in $Lines) {
        $nameMatch = [regex]::Match($line, '^      -[ \t]+name:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($nameMatch.Success) {
            if ($null -ne $currentStep) {
                $steps.Add($currentStep) | Out-Null
            }
            $currentStep = [pscustomobject]@{
                Name = $nameMatch.Groups['value'].Value.Trim("'`"")
                Shell = ''
                Run = ''
                Uses = ''
                ShellCount = 0
                RunCount = 0
                UsesCount = 0
            }
            continue
        }

        if ($null -eq $currentStep) {
            continue
        }

        $shellMatch = [regex]::Match($line, '^        shell:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($shellMatch.Success) {
            $currentStep.Shell = $shellMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.ShellCount++
            continue
        }

        $runMatch = [regex]::Match($line, '^        run:[ \t]*(?<value>[^#\r\n]+?)[ \t]*$')
        if ($runMatch.Success) {
            $currentStep.Run = $runMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.RunCount++
            continue
        }

        $usesMatch = [regex]::Match($line, '^        uses:[ \t]*(?<value>[^#\r\n]+?)[ \t]*(?:#.*)?$')
        if ($usesMatch.Success) {
            $currentStep.Uses = $usesMatch.Groups['value'].Value.Trim("'`"")
            $currentStep.UsesCount++
        }
    }

    if ($null -ne $currentStep) {
        $steps.Add($currentStep) | Out-Null
    }

    return $steps.ToArray()
}

function Assert-WorkflowJobValue {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [string]$Key,
        [string]$ExpectedValue
    )

    $pattern = (
        '^    ' +
        [regex]::Escape($Key) +
        ':[ \t]*' +
        [regex]::Escape($ExpectedValue) +
        '[ \t]*(?:#.*)?$')
    # `$Matches` は -match が更新するautomatic変数なので、結果collectionへ
    # 同名（PowerShellはcase-insensitive）を使わずPS5.1/PS7差を避ける。
    $keyPattern = '^    ' + [regex]::Escape($Key) + ':[ \t]*'
    $keyLines = @(
        $Lines | Where-Object {
            [regex]::IsMatch(
                $_,
                $keyPattern,
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
            )
        }
    )
    $matchingLines = @(
        $keyLines | Where-Object {
            [regex]::IsMatch(
                $_,
                $pattern,
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
            )
        }
    )
    if ($keyLines.Count -ne 1 -or $matchingLines.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must declare exactly one '${Key}: $ExpectedValue' value (total keys $($keyLines.Count), expected values $($matchingLines.Count))."
    }
}

function Assert-WorkflowStepCount {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [int]$ExpectedCount
    )

    if ($Steps.Count -ne $ExpectedCount) {
        Add-Failure "Workflow job '$JobName' must contain exactly $ExpectedCount named steps (found $($Steps.Count))."
    }
}

function Assert-WorkflowJobShape {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [int]$ExpectedStepCount,
        [int]$ExpectedShellCount,
        [int]$ExpectedRunCount
    )

    # expected keyを残したまま `if: false`、continue-on-error、別action等を
    # 足してvalidationを無効化できないよう、indent別の全active entryも数える。
    $jobEntryCount = @(
        $Lines | Where-Object { $_ -match '^    (?![ #\r\n]).+$' }
    ).Count
    $nameKeyCount = @(
        $Lines | Where-Object { $_ -match '^    name:[ \t]*' }
    ).Count
    $stepsKeyCount = @(
        $Lines | Where-Object { $_ -match '^    steps:[ \t]*' }
    ).Count
    $stepItemCount = @(
        $Lines | Where-Object { $_ -match '^      -[ \t]+' }
    ).Count
    $stepPropertyCount = @(
        $Lines | Where-Object { $_ -match '^        (?![ #\r\n]).+$' }
    ).Count
    $shellKeyCount = @(
        $Lines | Where-Object { $_ -match '^        shell:[ \t]*' }
    ).Count
    $runKeyCount = @(
        $Lines | Where-Object { $_ -match '^        run:[ \t]*' }
    ).Count
    $usesKeyCount = @(
        $Lines | Where-Object { $_ -match '^        uses:[ \t]*' }
    ).Count
    $withKeyCount = @(
        $Lines | Where-Object { $_ -match '^        with:[ \t]*(?:#.*)?$' }
    ).Count
    $nestedPropertyCount = @(
        $Lines | Where-Object { $_ -match '^          (?![ #\r\n]).+$' }
    ).Count
    $persistCredentialsFalseCount = @(
        $Lines | Where-Object {
            $_ -match '^          persist-credentials:[ \t]*false[ \t]*(?:#.*)?$'
        }
    ).Count
    $expectedStepPropertyCount =
        2 + $ExpectedShellCount + $ExpectedRunCount

    if ($jobEntryCount -ne 4 -or
        $nameKeyCount -ne 1 -or
        $stepsKeyCount -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain only one name/runs-on/timeout-minutes/steps mapping."
    }
    if ($stepItemCount -ne $ExpectedStepCount) {
        Add-Failure "Workflow job '$JobName' must contain exactly $ExpectedStepCount step items (found $stepItemCount)."
    }
    if ($stepPropertyCount -ne $expectedStepPropertyCount -or
        $shellKeyCount -ne $ExpectedShellCount -or
        $runKeyCount -ne $ExpectedRunCount -or
        $usesKeyCount -ne 1 -or
        $withKeyCount -ne 1 -or
        $nestedPropertyCount -ne 1 -or
        $persistCredentialsFalseCount -ne 1) {
        Add-Failure "Workflow job '$JobName' contains an unexpected, missing, or duplicate step/nested key."
    }
}

function Assert-WorkflowStep {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [string]$Name,
        [string]$Shell,
        [string]$Run
    )

    $matches = @(
        $Steps | Where-Object {
            [string]::Equals(
                $_.Name,
                $Name,
                [System.StringComparison]::Ordinal
            )
        }
    )
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one active step named '$Name' (found $($matches.Count))."
        return
    }

    $step = $matches[0]
    if ($step.ShellCount -ne 1 -or
        $step.RunCount -ne 1 -or
        $step.UsesCount -ne 0) {
        Add-Failure "Workflow job '$JobName' step '$Name' must contain exactly one shell/run and no uses key."
    }
    if (-not [string]::Equals(
        $step.Shell,
        $Shell,
        [System.StringComparison]::Ordinal
    )) {
        Add-Failure "Workflow job '$JobName' step '$Name' must use shell '$Shell' (found '$($step.Shell)')."
    }
    if (-not [string]::Equals(
        $step.Run,
        $Run,
        [System.StringComparison]::Ordinal
    )) {
        Add-Failure "Workflow job '$JobName' step '$Name' must run '$Run' (found '$($step.Run)')."
    }
}

function Assert-WorkflowUsesStep {
    param(
        [object[]]$Steps,
        [string]$JobName,
        [string]$Name,
        [string]$Uses
    )

    $matches = @(
        $Steps | Where-Object {
            [string]::Equals(
                $_.Name,
                $Name,
                [System.StringComparison]::Ordinal
            )
        }
    )
    if ($matches.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one active step named '$Name' (found $($matches.Count))."
        return
    }

    $step = $matches[0]
    if ($step.UsesCount -ne 1 -or
        $step.ShellCount -ne 0 -or
        $step.RunCount -ne 0) {
        Add-Failure "Workflow job '$JobName' step '$Name' must contain exactly one uses key and no shell/run key."
    }
    if (-not [string]::Equals(
        $step.Uses,
        $Uses,
        [System.StringComparison]::Ordinal
    )) {
        Add-Failure "Workflow job '$JobName' step '$Name' must use '$Uses' (found '$($step.Uses)')."
    }
}

function Assert-WorkflowCheckoutStep {
    param(
        [string[]]$Lines,
        [string]$JobName,
        [string]$Uses
    )

    # `with`の存在だけでは別step配下へのmisnestを見逃す。checkout stepのactive
    # blockを切り出し、uses・親mapping・credential policyの順序と所属を固定する。
    $stepStarts = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^      -[ \t]+name:[ \t]*Check out repository[ \t]*$') {
            $stepStarts.Add($index) | Out-Null
        }
    }
    if ($stepStarts.Count -ne 1) {
        Add-Failure "Workflow job '$JobName' must contain exactly one checkout step block (found $($stepStarts.Count))."
        return
    }

    $startIndex = $stepStarts[0]
    $endIndex = $Lines.Count
    for ($index = $startIndex + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^      -[ \t]+') {
            $endIndex = $index
            break
        }
    }

    # blank/commentだけは説明用に許し、それ以外の未知keyや重複はexact比較で拒否する。
    $activeLines = New-Object System.Collections.Generic.List[string]
    for ($index = $startIndex; $index -lt $endIndex; $index++) {
        $line = $Lines[$index]
        if ($line -match '^[ \t]*(?:#.*)?$') {
            continue
        }
        $activeLines.Add($line) | Out-Null
    }

    $expectedLines = @(
        '      - name: Check out repository',
        "        uses: $Uses # v7.0.1",
        '        with:',
        '          persist-credentials: false'
    )
    $matchesExpected = $activeLines.Count -eq $expectedLines.Count
    if ($matchesExpected) {
        for ($index = 0; $index -lt $expectedLines.Count; $index++) {
            if (-not [string]::Equals(
                $activeLines[$index],
                $expectedLines[$index],
                [System.StringComparison]::Ordinal
            )) {
                $matchesExpected = $false
                break
            }
        }
    }
    if (-not $matchesExpected) {
        Add-Failure "Workflow job '$JobName' checkout step must use the exact reviewed revision with persist-credentials false."
    }
}

function Test-SkillFrontmatter {
    $skillPath = Get-RepoFilePath -RelativePath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return
    }

    $lines = [System.IO.File]::ReadAllLines($skillPath)
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        Add-Failure 'SKILL.md must start with YAML frontmatter.'
        return
    }

    $closingIndex = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -eq '---') {
            $closingIndex = $index
            break
        }
    }

    if ($closingIndex -lt 0) {
        Add-Failure 'SKILL.md frontmatter must be closed with --- before content.'
        return
    }

    $frontmatter = $lines[1..($closingIndex - 1)] -join "`n"
    if ($frontmatter -notmatch '(?m)^name:\s*isolated-worktree-pr-flow\s*$') {
        Add-Failure 'SKILL.md frontmatter must declare name: isolated-worktree-pr-flow.'
    }
    if ($frontmatter -notmatch '(?m)^description:\s*\S') {
        Add-Failure 'SKILL.md frontmatter must include a non-empty description.'
    }
    if ($frontmatter.Length -gt 1024) {
        Add-Failure 'SKILL.md frontmatter must stay under 1024 characters.'
    }
}

$requiredFiles = @(
    '.editorconfig',
    '.gitattributes',
    '.gitignore',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/config.yml',
    '.github/pull_request_template.md',
    '.github/workflows/validate.yml',
    'CHANGELOG.md',
    'CODE_OF_CONDUCT.md',
    'CONTRIBUTING.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'SKILL.md',
    'docs/SKILL.ja.md',
    'examples/full-flow-walkthrough.md',
    'examples/cleanup-guard-cheatsheet.md',
    'examples/concurrent-session-collision-checklist.md',
    'scripts/private-marker-process.ps1',
    'scripts/remove-local-branch-cas.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-cleanup-guards.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)

foreach ($requiredFile in $requiredFiles) {
    Assert-FileExists -RelativePath $requiredFile
}

foreach ($japaneseCommentedScript in @(
    'scripts/private-marker-process.ps1',
    'scripts/remove-local-branch-cas.ps1',
    'scripts/scan-private-markers.ps1',
    'scripts/test-cleanup-guards.ps1',
    'scripts/test-scan-private-markers.ps1',
    'scripts/validate-oss-readiness.ps1'
)) {
    Assert-FileHasUtf8Bom -RelativePath $japaneseCommentedScript
}

Assert-LocalBranchCleanupContract `
    -RelativePath 'scripts/remove-local-branch-cas.ps1'

Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Install' -Description 'installation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Validation' -Description 'validation instructions'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Contributing' -Description 'contribution guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?im)^##\s+Security' -Description 'security reporting guidance'
Assert-FileContains -RelativePath 'README.md' -Pattern 'CONTRIBUTING\.md' -Description 'link to CONTRIBUTING.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'SECURITY\.md' -Description 'link to SECURITY.md'
Assert-FileContains -RelativePath 'README.md' -Pattern 'docs/SKILL\.ja\.md' -Description 'link to the Japanese skill version'
Assert-FileContains -RelativePath 'README.md' -Pattern 'macOS 15' -Description 'native macOS validation coverage'
Assert-FileContains -RelativePath 'README.md' -Pattern 'exact expected-OID.*--force-with-lease' -Description 'atomic remote branch deletion summary'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?s)PR #14.*retained pre-merge `headRefOid`.*expected-value lease.*exit 2' -Description 'live exact-head remote deletion evidence'
Assert-FileContains -RelativePath 'README.md' -Pattern '(?s)Live post-observation drift\s+rejection is not checked.*disposable local bare remote' -Description 'live drift rejection evidence boundary'
Assert-FileContains -RelativePath 'SKILL.md' -Pattern 'macOS 15' -Description 'native macOS portability coverage'
Assert-FileContains -RelativePath 'docs/SKILL.ja.md' -Pattern 'macOS 15' -Description 'Japanese native macOS portability coverage'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern 'macOS 15' -Description 'contributor native macOS validation coverage'
Assert-FileContains -RelativePath '.gitignore' -Pattern '\.private-markers\.local' -Description 'ignore local private marker files'
Assert-FileContains -RelativePath 'CONTRIBUTING.md' -Pattern '(?im)no token|never.*token|secret' -Description 'secret-safe contribution guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?im)do not.*public|private|security' -Description 'private vulnerability reporting guidance'
Assert-FileContains -RelativePath 'SECURITY.md' -Pattern '(?i)fail(?:s|ed)? closed' -Description 'fail-closed scanner boundary'

# cleanup guardのnamed operandは、同名tagが存在しても検証対象以外へ解決されない
# fully-qualified refに固定する。短縮refへ戻ると未マージbranchを誤削除し得る。
foreach ($cleanupGuardDocument in @(
    'SKILL.md',
    'docs/SKILL.ja.md',
    'examples/cleanup-guard-cheatsheet.md'
)) {
    Assert-FileContains `
        -RelativePath $cleanupGuardDocument `
        -Pattern 'merge-base --is-ancestor refs/heads/fix/<task> refs/remotes/origin/<default>' `
        -Description 'fully-qualified guard 2a local and remote-tracking refs'
    Assert-FileContains `
        -RelativePath $cleanupGuardDocument `
        -Pattern 'merge-base --is-ancestor <mergeCommit-oid> refs/remotes/origin/<default>' `
        -Description 'fully-qualified guard 2b remote-tracking ref'
    Assert-FileContains `
        -RelativePath $cleanupGuardDocument `
        -Pattern 'rev-parse refs/heads/fix/<task>' `
        -Description 'fully-qualified guard 2b local branch ref'
}
Assert-FileContains `
    -RelativePath 'examples/full-flow-walkthrough.md' `
    -Pattern 'merge-base --is-ancestor refs/heads/fix/<task> refs/remotes/origin/main' `
    -Description 'fully-qualified walkthrough guard 2a local and remote-tracking refs'
foreach ($cleanupGuardDocument in @(
    'SKILL.md',
    'docs/SKILL.ja.md',
    'examples/cleanup-guard-cheatsheet.md',
    'examples/full-flow-walkthrough.md'
)) {
    Assert-FilePatternCount `
        -RelativePath $cleanupGuardDocument `
        -Pattern 'merge-base --is-ancestor fix/<task>' `
        -ExpectedCount 0 `
        -Description 'ambiguous shorthand guard 2a refs'
    Assert-FilePatternCount `
        -RelativePath $cleanupGuardDocument `
        -Pattern 'rev-parse fix/<task>' `
        -ExpectedCount 0 `
        -Description 'ambiguous shorthand guard 2b refs'
    Assert-FilePatternCount `
        -RelativePath $cleanupGuardDocument `
        -Pattern 'merge-base --is-ancestor [^\r\n`]* origin/(?:<default>|main)' `
        -ExpectedCount 0 `
        -Description 'ambiguous shorthand remote-tracking guard refs'
}
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A same-name tag must demonstrate why shorthand guard 2a is ambiguous' `
    -Description 'same-name tag collision premise for guard 2a'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Fully qualified guard 2b must inspect the advanced branch instead of the same-name tag' `
    -Description 'same-name tag collision rejection for guard 2b'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Shorthand guard 2b rev-parse must demonstrate why a same-name tag is unsafe' `
    -Description 'direct shorthand rev-parse collision premise for guard 2b'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A same-name tag must demonstrate why shorthand remote-tracking targets are ambiguous' `
    -Description 'same-name tag collision premise for the fetched default branch'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Fully qualified remote-tracking target must reject a result absent from the fetched default branch' `
    -Description 'same-name tag collision rejection for the fetched default branch'

# guard 2bと2aのforced fallbackは、観測済みheadRefOidをhelperへ渡す。
# helperはrepo-common owner lock内でworktree/ref/config/CASを一続きに実行する。
foreach ($localDeleteContractFile in @(
    'SKILL.md',
    'docs/SKILL.ja.md',
    'examples/cleanup-guard-cheatsheet.md'
)) {
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '\\A\[a-z0-9-\]\+\\z' `
        -Description 'task slug validation before branch construction'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern 'scripts/remove-local-branch-cas\.ps1' `
        -Description 'canonical local branch CAS cleanup helper'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '(?s)-Repository\s+<repo>.*-TaskSlug\s+<task>.*-ExpectedHeadOid\s+<headRefOid>' `
        -Description 'expected PR head OID local cleanup invocation'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern 'codex-isolated-worktree-cleanup\.lock' `
        -Description 'repository-common cleanup lock path'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '(?i)nonblocking.*CreateNew|CreateNew.*nonblocking' `
        -Description 'single-attempt nonblocking lock acquisition'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '(?i)owner nonce' `
        -Description 'owner nonce lock release boundary'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern 'update-ref -d refs/heads/fix/<task> <headRefOid>' `
        -Description 'fully-qualified expected-OID compare-and-delete'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern 'branch\.codex-cleanup-<nonce>' `
        -Description 'owner-scoped temporary branch config'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '(?i)atomic expected-value' `
        -Description 'non-atomic config cleanup refusal rationale'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '(?is)refuses\s+CAS|CAS(?:は|を)\s*拒否' `
        -Description 'config-bearing branch CAS refusal'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern '`--no-checkout` guard worktree' `
        -Description 'Git-native branch occupancy guard'
    Assert-FileContains `
        -RelativePath $localDeleteContractFile `
        -Pattern 'reflog exists refs/heads/fix/<task>' `
        -Description 'local branch reflog cleanup verification'
    Assert-FilePatternCount `
        -RelativePath $localDeleteContractFile `
        -Pattern 'git -C <repo> branch -D fix/<task>' `
        -ExpectedCount 0 `
        -Description 'legacy unconditional local branch deletion commands'
    Assert-FilePatternCount `
        -RelativePath $localDeleteContractFile `
        -Pattern 'git -C <repo> config --local --remove-section branch\.fix/<task>' `
        -ExpectedCount 0 `
        -Description 'unsafe direct removal of a potentially recreated config section'
}
Assert-FileContains `
    -RelativePath 'README.md' `
    -Pattern '(?s)repository-common owner-nonce lock.*expected-OID\s+`update-ref -d` compare-and-delete' `
    -Description 'expected-OID local cleanup summary'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'An unsafe task slug must be rejected before branch construction' `
    -Description 'task slug injection rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Native guard acquisition must reject an exact branch checked out elsewhere' `
    -Description 'checked-out branch native guard rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A checkout interleaving immediately before guard acquisition must fail closed' `
    -Description 'atomic guard-acquisition interleaving rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Native guard must block an ordinary competing worktree add' `
    -Description 'native guard competing add rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Native guard must block an ordinary competing branch switch' `
    -Description 'native guard competing switch rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Guard cleanup failure must not additionally delete the recreated branch' `
    -Description 'unexpected guard entry fail-closed preservation fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Local cleanup must restore every ambient GIT variable exactly' `
    -Description 'ambient Git environment exact restoration fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Snapshot comparer must preserve differently-cased GIT names' `
    -Description 'case-sensitive ambient Git snapshot fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'foreach \(\$invalidOidLength in @\(41, 63\)\)' `
    -Description 'intermediate OID lengths rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A \$invalidOidLength-hex OID must be rejected before repository access' `
    -Description 'invalid OID length assertion'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Ambient GIT_DIR target must preserve its exact branch tip' `
    -Description 'ambient Git redirect repository preservation fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A targeted same-nonce writer must block CAS without losing its payload' `
    -Description 'same-nonce owner config drift preservation fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Recreated original config must become an explicit recovery conflict' `
    -Description 'pre-CAS actor config recovery-conflict fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A branch with owner config must refuse non-atomic automatic cleanup' `
    -Description 'config-bearing local CAS refusal fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Successful update-ref deletion must remove the local branch reflog' `
    -Description 'local reflog cleanup assertion'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Rejected local cleanup must preserve the exact second-actor tip' `
    -Description 'local drift tip preservation assertion'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Rejected configless cleanup must not invent branch config' `
    -Description 'configless local drift preserves config absence'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Post-CAS branch recreation must not invent branch config' `
    -Description 'post-CAS same-name branch preserves config absence'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A second cleanup actor must fail immediately while the lock is held' `
    -Description 'nonblocking active lock contention fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'An uncertain stale lock must remain untouched' `
    -Description 'stale lock uncertainty preservation fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'A mismatched owner must not delete the uncertain lock' `
    -Description 'owner nonce mismatch preservation fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Owner mismatch after config isolation must reject CAS' `
    -Description 'mid-cleanup owner mismatch CAS rejection fixture'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'External recovery must restore the preserved config to its exact branch' `
    -Description 'uncertain owner config recovery fixture'

# remote削除contractは全利用例で同じexact expected-OID leaseに固定する。
# plain deleteやimplicit leaseへ戻ると並行sessionのpost-merge commitを失う。
$remoteDeleteCommand = 'git -C <repo> push --force-with-lease=refs/heads/fix/<task>:<headRefOid> origin :refs/heads/fix/<task>'
$remoteDeleteCommandPattern = [regex]::Escape($remoteDeleteCommand)
foreach ($remoteDeleteContractFile in @(
    'SKILL.md',
    'docs/SKILL.ja.md',
    'examples/cleanup-guard-cheatsheet.md',
    'examples/full-flow-walkthrough.md'
)) {
    Assert-FilePatternCount `
        -RelativePath $remoteDeleteContractFile `
        -Pattern $remoteDeleteCommandPattern `
        -ExpectedCount 1 `
        -Description 'exact expected-OID remote branch deletion command'
    Assert-FilePatternCount `
        -RelativePath $remoteDeleteContractFile `
        -Pattern 'git -C <repo> push origin --delete fix/<task>' `
        -ExpectedCount 0 `
        -Description 'legacy unconditional remote branch deletion commands'
    Assert-FileContains `
        -RelativePath $remoteDeleteContractFile `
        -Pattern '(?s)ls-remote\s+--exit-code\s+--heads\s+origin\s+refs/heads/fix/<task>' `
        -Description 'remote-absent and exact-ref observation contract'
    Assert-FileContains `
        -RelativePath $remoteDeleteContractFile `
        -Pattern '--json headRefOid -q \.headRefOid' `
        -Description 'pre-merge PR head OID retention contract'
}
Assert-FilePatternCount `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern '--force-with-lease=refs/heads/fix/lease-(?:positive|drift):\$remoteExpectedHeadOid' `
    -ExpectedCount 2 `
    -Description 'exact expected-OID local bare-origin lease cases'
Assert-FileContains `
    -RelativePath 'scripts/test-cleanup-guards.ps1' `
    -Pattern 'Rejected cleanup must preserve the exact second-actor remote tip' `
    -Description 'remote drift preservation assertion'

Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'ISOLATED_WORKTREE_PR_FLOW_PRIVATE_MARKERS' -Description 'existing local marker environment contract'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'h8nc4y/isolated-worktree-pr-flow' -Description 'repository-only GitHub URL allowlist'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'Assert-PrivateMarkerScanDeadline' -Description 'scan-wide deadline enforcement'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '(?s)\[ValidateRange\(1,\s*120000\)\]\s*\[int\]\$ScanDeadlineMilliseconds\s*=\s*120000' -Description 'lower-only scan-wide deadline self-test seam'
Assert-FinalScanDeadlineContract -RelativePath 'scripts/scan-private-markers.ps1'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern 'maximumFindingOutputBytes' -Description 'actual UTF-8 finding output cap'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern "'--is-inside-work-tree'" -Description 'Git semantic worktree-root proof'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern "'--show-prefix'" -Description 'Git root-relative prefix proof'
Assert-FileContains -RelativePath 'scripts/scan-private-markers.ps1' -Pattern '\[StringComparison\]::Ordinal' -Description 'ordinal Git root record comparison'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'function\s+Test-PrivateMarkerGitIsolationRootBoundary' -Description 'owned Git isolation-root boundary'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'function\s+New-PrivateMarkerGitIsolationRoot' -Description 'owned Git isolation-root initializer'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\^isolated-worktree-pr-flow-git-\[0-9a-f\]\{32\}\$' -Description 'exact Git isolation-root prefix and GUID contract'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern 'FileAttributes\]::ReparsePoint' -Description 'Git isolation-root reparse-point rejection'
Assert-FileContains -RelativePath 'scripts/private-marker-process.ps1' -Pattern '\.isolated-worktree-pr-flow-owner' -Description 'Git isolation-root owner marker'
Assert-PrivateMarkerMillisecondWaitContract `
    -RelativePath 'scripts/private-marker-process.ps1'
Assert-FilePatternCount `
    -RelativePath 'scripts/private-marker-process.ps1' `
    -Pattern '(?m)^\s*Assert-PrivateMarkerGitIsolationRootState\b' `
    -ExpectedCount 2 `
    -Description 'pre-cleanup Git isolation-root state validations'
Assert-FilePatternCount `
    -RelativePath 'scripts/scan-private-markers.ps1' `
    -Pattern '(?m)^\s*Remove-PrivateMarkerGitIsolationRoot\b' `
    -ExpectedCount 3 `
    -Description 'guarded Git isolation-root cleanup callsites'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'private-marker-process\.ps1' -Description 'shared bounded process boundary in scanner self-test'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'PosixSignal.*IsSuccessfulResult' -Description 'POSIX errno cleanup regression coverage'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '\[byte\[\]\]\$binaryProbeBytes\s*=\s*@\(0x00,\s*0x80,\s*0xFF\)' -Description 'exact binary standard-stream fixture'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'root-probe-zero-width-space' -Description 'Unicode format root-probe regression coverage'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'wrong-name Git isolation root' -Description 'wrong-name Git isolation-root cleanup rejection'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'reparse-point Git isolation root' -Description 'reparse-point Git isolation-root cleanup rejection'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'BeforeFinalValidation' -Description 'deterministic Git isolation-root check/use interleaving seam'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'regular-directory replacement' -Description 'regular-directory ownership replacement regression'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern '\[timeout/millisecond-poll-boundary\]' -Description 'millisecond poll boundary regression'
Assert-FirstTopLevelProcessInvocationIsBinary `
    -RelativePath 'scripts/test-scan-private-markers.ps1'
Assert-FileContains -RelativePath 'scripts/test-scan-private-markers.ps1' -Pattern 'scan-diagnostic-output-limit' -Description 'finding output amplification regression coverage'

# job blockを先に切り出し、timeout/runs-on/checkout/stepを所有job内だけで
# 検証する。後続jobへ跨ぐregexによる誤合格を許さない。
$workflowPath = '.github/workflows/validate.yml'
# tag driftを避け、公式v7.0.1のreviewed commitを3 job共通のexact pinにする。
$checkoutRevision = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
Assert-WorkflowDocumentShape `
    -RelativePath $workflowPath `
    -ExpectedJobNames @('validate', 'validate-ubuntu', 'validate-macos')

$windowsJobName = 'validate'
$windowsJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $windowsJobName)
$windowsSteps = @(Get-WorkflowSteps `
    -Lines $windowsJobLines `
    -JobName $windowsJobName)
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'name' -ExpectedValue 'Validate skill repository'
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'runs-on' -ExpectedValue 'windows-latest'
Assert-WorkflowJobValue -Lines $windowsJobLines -JobName $windowsJobName `
    -Key 'timeout-minutes' -ExpectedValue '25'
Assert-WorkflowStepCount -Steps $windowsSteps -JobName $windowsJobName `
    -ExpectedCount 8
Assert-WorkflowJobShape -Lines $windowsJobLines -JobName $windowsJobName `
    -ExpectedStepCount 8 -ExpectedShellCount 7 -ExpectedRunCount 7
Assert-WorkflowUsesStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowCheckoutStep -Lines $windowsJobLines -JobName $windowsJobName `
    -Uses $checkoutRevision
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Validate OSS readiness' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test cleanup guards (PowerShell 7)' -Shell 'pwsh' `
    -Run './scripts/test-cleanup-guards.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test cleanup guards (Windows PowerShell 5.1)' -Shell 'powershell' `
    -Run './scripts/test-cleanup-guards.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test private marker scan (PowerShell 7)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Test private marker scan (Windows PowerShell 5.1)' `
    -Shell 'powershell' -Run '.\scripts\test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Scan for private markers' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $windowsSteps -JobName $windowsJobName `
    -Name 'Check whitespace' -Shell 'pwsh' `
    -Run 'git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD'

$ubuntuJobName = 'validate-ubuntu'
$ubuntuJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $ubuntuJobName)
$ubuntuSteps = @(Get-WorkflowSteps `
    -Lines $ubuntuJobLines `
    -JobName $ubuntuJobName)
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'name' -ExpectedValue 'Validate skill repository on Ubuntu'
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'runs-on' -ExpectedValue 'ubuntu-24.04'
Assert-WorkflowJobValue -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Key 'timeout-minutes' -ExpectedValue '10'
Assert-WorkflowStepCount -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -ExpectedCount 6
Assert-WorkflowJobShape -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -ExpectedStepCount 6 -ExpectedShellCount 5 -ExpectedRunCount 5
Assert-WorkflowUsesStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowCheckoutStep -Lines $ubuntuJobLines -JobName $ubuntuJobName `
    -Uses $checkoutRevision
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Validate OSS readiness on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test cleanup guards (PowerShell 7 on Ubuntu)' -Shell 'pwsh' `
    -Run './scripts/test-cleanup-guards.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Test private marker scan (PowerShell 7 on Ubuntu)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Scan for private markers on Ubuntu' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $ubuntuSteps -JobName $ubuntuJobName `
    -Name 'Check whitespace' -Shell 'pwsh' `
    -Run 'git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD'

$macosJobName = 'validate-macos'
$macosJobLines = @(Get-WorkflowJobLines `
    -RelativePath $workflowPath `
    -JobName $macosJobName)
$macosSteps = @(Get-WorkflowSteps `
    -Lines $macosJobLines `
    -JobName $macosJobName)
Assert-WorkflowJobValue -Lines $macosJobLines -JobName $macosJobName `
    -Key 'name' -ExpectedValue 'Validate skill repository on macOS'
Assert-WorkflowJobValue -Lines $macosJobLines -JobName $macosJobName `
    -Key 'runs-on' -ExpectedValue 'macos-15'
Assert-WorkflowJobValue -Lines $macosJobLines -JobName $macosJobName `
    -Key 'timeout-minutes' -ExpectedValue '10'
Assert-WorkflowStepCount -Steps $macosSteps -JobName $macosJobName `
    -ExpectedCount 6
Assert-WorkflowJobShape -Lines $macosJobLines -JobName $macosJobName `
    -ExpectedStepCount 6 -ExpectedShellCount 5 -ExpectedRunCount 5
Assert-WorkflowUsesStep -Steps $macosSteps -JobName $macosJobName `
    -Name 'Check out repository' -Uses $checkoutRevision
Assert-WorkflowCheckoutStep -Lines $macosJobLines -JobName $macosJobName `
    -Uses $checkoutRevision
Assert-WorkflowStep -Steps $macosSteps -JobName $macosJobName `
    -Name 'Validate OSS readiness on macOS' -Shell 'pwsh' `
    -Run './scripts/validate-oss-readiness.ps1'
Assert-WorkflowStep -Steps $macosSteps -JobName $macosJobName `
    -Name 'Test cleanup guards (PowerShell 7 on macOS)' -Shell 'pwsh' `
    -Run './scripts/test-cleanup-guards.ps1'
Assert-WorkflowStep -Steps $macosSteps -JobName $macosJobName `
    -Name 'Test private marker scan (PowerShell 7 on macOS)' -Shell 'pwsh' `
    -Run './scripts/test-scan-private-markers.ps1'
Assert-WorkflowStep -Steps $macosSteps -JobName $macosJobName `
    -Name 'Scan for private markers on macOS' -Shell 'pwsh' `
    -Run './scripts/scan-private-markers.ps1'
Assert-WorkflowStep -Steps $macosSteps -JobName $macosJobName `
    -Name 'Check whitespace' -Shell 'pwsh' `
    -Run 'git diff-tree --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD'

Test-SkillFrontmatter

if ($failures.Count -gt 0) {
    Write-Host 'OSS readiness validation failed:'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    exit 1
}

Write-Host "OSS readiness validation passed for $root"
exit 0
