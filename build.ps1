[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'cloud_pinyin_async_helper.exe')
)

$ErrorActionPreference = 'Stop'

$frameworkRoots = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319')
)
$compiler = $frameworkRoots |
    ForEach-Object { Join-Path $_ 'csc.exe' } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

if (-not $compiler) {
    throw 'Cannot find the .NET Framework C# compiler (csc.exe). Enable .NET Framework 4.x.'
}

$source = Join-Path $PSScriptRoot 'CloudPinyinAsyncHelper.cs'
$output = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

& $compiler `
    /nologo `
    /target:winexe `
    /platform:x64 `
    /optimize+ `
    /reference:System.Web.Extensions.dll `
    "/out:$output" `
    $source

if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed; csc.exe exit code: $LASTEXITCODE"
}

Write-Output $output
