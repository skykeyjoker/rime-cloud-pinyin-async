[CmdletBinding()]
param(
    [string]$HelperPath = (Join-Path $PSScriptRoot '..\dist\cloud_pinyin_async_helper.exe')
)

$ErrorActionPreference = 'Stop'

function Wait-Condition {
    param(
        [Parameter(Mandatory)] [scriptblock]$Condition,
        [Parameter(Mandatory)] [int]$TimeoutMilliseconds,
        [Parameter(Mandatory)] [string]$FailureMessage
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (& $Condition) {
            return $watch.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds 50
    }
    throw $FailureMessage
}

function Write-TestRequest {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$PinyinInput
    )

    $line = @(
        $Id,
        $PinyinInput,
        $PinyinInput,
        '100',
        '500',
        '5',
        '5'
    ) -join "`t"
    [IO.File]::WriteAllText($Path, $line + "`n", [Text.UTF8Encoding]::new($false))
}

$helper = [IO.Path]::GetFullPath($HelperPath)
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw "Helper does not exist: $helper"
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = Join-Path $temporaryRoot ('rime-cloud-weak-network-' + [guid]::NewGuid().ToString('N'))
$testDirectory = [IO.Path]::GetFullPath($testDirectory)
if (-not $testDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test directory: $testDirectory"
}
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null

$requestPath = Join-Path $testDirectory 'cloud_pinyin_async.request'
$responsePath = Join-Path $testDirectory 'cloud_pinyin_async.response'
$heartbeatPath = Join-Path $testDirectory 'cloud_pinyin_async.heartbeat'
$logPath = Join-Path $testDirectory 'cloud_pinyin_async.log'
$variables = @(
    'RIME_CLOUD_TEST_SOGOU_DELAY_MS',
    'RIME_CLOUD_TEST_GOOGLE_DELAY_MS'
)
$previousEnvironment = @{}
$process = $null

try {
    foreach ($name in $variables) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    [Environment]::SetEnvironmentVariable('RIME_CLOUD_TEST_SOGOU_DELAY_MS', '20', 'Process')
    [Environment]::SetEnvironmentVariable('RIME_CLOUD_TEST_GOOGLE_DELAY_MS', '10000', 'Process')

    $quotedDirectory = '"' + $testDirectory.Replace('"', '\"') + '"'
    $process = Start-Process `
        -FilePath $helper `
        -ArgumentList @($quotedDirectory, '--test-mode') `
        -WindowStyle Hidden `
        -PassThru

    Wait-Condition `
        -Condition { Test-Path -LiteralPath $heartbeatPath } `
        -TimeoutMilliseconds 3000 `
        -FailureMessage 'Helper did not create a heartbeat.' | Out-Null
    $heartbeatBefore = [IO.File]::ReadAllText($heartbeatPath).Trim()

    Write-TestRequest -Path $requestPath -Id 'weak-test-1' -PinyinInput 'ceshi'
    $firstResponseMilliseconds = Wait-Condition `
        -Condition {
            (Test-Path -LiteralPath $responsePath) -and
            ([IO.File]::ReadAllText($responsePath) -match "RIME_CLOUD_V1`tweak-test-1`t")
        } `
        -TimeoutMilliseconds 2000 `
        -FailureMessage 'Fast Sogou result was blocked by the slow Google worker.'

    Wait-Condition `
        -Condition {
            (Test-Path -LiteralPath $logPath) -and
            ([IO.File]::ReadAllText($logPath) -match 'query deadline id=weak-test-1')
        } `
        -TimeoutMilliseconds 2000 `
        -FailureMessage 'The coordinator did not enforce the hard request deadline.' | Out-Null

    Write-TestRequest -Path $requestPath -Id 'weak-test-2' -PinyinInput 'ceshier'
    $secondResponseMilliseconds = Wait-Condition `
        -Condition {
            (Test-Path -LiteralPath $responsePath) -and
            ([IO.File]::ReadAllText($responsePath) -match "RIME_CLOUD_V1`tweak-test-2`t")
        } `
        -TimeoutMilliseconds 2000 `
        -FailureMessage 'A blocked Google worker delayed the next Sogou request.'

    Start-Sleep -Seconds 3
    $heartbeatAfter = [IO.File]::ReadAllText($heartbeatPath).Trim()
    if ($heartbeatAfter -eq $heartbeatBefore) {
        throw 'Heartbeat stopped while a provider worker was blocked.'
    }

    $logText = [IO.File]::ReadAllText($logPath)
    if ($logText -match 'refresh sent') {
        throw 'Test mode injected a global refresh key.'
    }

    [pscustomobject]@{
        Result = 'PASS'
        FirstResponseMilliseconds = $firstResponseMilliseconds
        SecondResponseMilliseconds = $secondResponseMilliseconds
        HeartbeatAdvanced = $true
        SlowProviderDelayMilliseconds = 10000
        HardDeadlineMilliseconds = 500
    }
}
catch {
    if (Test-Path -LiteralPath $logPath) {
        Write-Warning ([IO.File]::ReadAllText($logPath))
    }
    throw
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(3000) | Out-Null
    }
    foreach ($name in $variables) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
    if (Test-Path -LiteralPath $testDirectory) {
        $resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
        if (-not $resolvedTestDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unsafe test directory: $resolvedTestDirectory"
        }
        Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
    }
}
