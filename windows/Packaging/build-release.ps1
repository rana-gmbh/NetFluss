# Builds the NetFluss for Windows release files.
#
#   pwsh windows/Packaging/build-release.ps1 -Version 1.0.0|1.0.0-beta.1 [-Stage All|Publish|Package|Checksums]
#                                            [-Architectures x64,arm64] [-SkipInstaller]
#
# For each architecture: a self-contained publish (no .NET install needed on the target),
# the helper service in a Helper\ folder beside the app (the folder the in-app installer
# copies into Program Files), a portable .zip, and — when Inno Setup's iscc.exe is
# available — the per-user installer. SHA256SUMS.txt covers every file and, with
# NETFLUSS_UPDATE_SIGNING_KEY set, is signed into SHA256SUMS.txt.sig; the in-app updater
# refuses an installer it cannot match against a correctly signed list.
#
# Code signing happens between stages, because an installer has to be built from binaries
# that are already signed — SignPath cannot sign files inside an Inno Setup installer:
#
#   Publish    builds both architectures and gathers the executables to sign into
#              artifacts\sign\binaries\<arch>\  (NetFluss.exe, NetFluss.Service.exe)
#   ...        CI has them signed and extracts the result into artifacts\signed\binaries
#   Package    puts signed executables back (when present), builds the portable zips and the
#              installers, and gathers the installers into artifacts\sign\installers
#   ...        CI has those signed into artifacts\signed\installers
#   Checksums  puts the signed installers in place, writes SHA256SUMS.txt and its signature
#
# All (the default) runs the three in a row, for a local build. Set NETFLUSS_SIGN_PFX and
# NETFLUSS_SIGN_PASSWORD to sign locally with a .pfx along the way.
#
# Output: windows/artifacts/release/

[CmdletBinding()]
param(
    # 2.6.0, or a pre-release such as 2.6.0-beta.1 (the in-app updater orders them by semver).
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+(-(alpha|beta|rc)\.\d+)?$')] [string] $Version,
    [ValidateSet('All', 'Publish', 'Package', 'Checksums')] [string] $Stage = 'All',
    [string[]] $Architectures = @('x64', 'arm64'),
    [switch] $SkipInstaller
)

$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $windows 'artifacts'
$release = Join-Path $artifacts 'release'
$toSign = Join-Path $artifacts 'sign'
$signed = Join-Path $artifacts 'signed'

function Invoke-Checked([string] $File, [string[]] $Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File exited with $LASTEXITCODE" }
}

# Optional local Authenticode signing with a .pfx; CI signs through SignPath instead.
$signtool = if ($env:NETFLUSS_SIGN_PFX) {
    Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Sign([string[]] $Files) {
    if (-not $env:NETFLUSS_SIGN_PFX) { return }
    if (-not $signtool) { throw 'NETFLUSS_SIGN_PFX is set but signtool.exe was not found.' }
    Invoke-Checked $signtool (@('sign', '/fd', 'SHA256', '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256',
        '/f', $env:NETFLUSS_SIGN_PFX, '/p', $env:NETFLUSS_SIGN_PASSWORD) + $Files)
}

# Copies $From over $To and checks that each copy carries an Authenticode signature, so a
# signing step that silently returned unsigned files cannot ship.
function Use-Signed([string] $From, [string] $To) {
    Copy-Item $From $To -Force
    if (-not (Get-AuthenticodeSignature $To).SignerCertificate) { throw "$To came back from signing without a signature." }
    Write-Host "signed: $To"
}

function Publish {
    if (Test-Path $artifacts) { Remove-Item $artifacts -Recurse -Force }
    New-Item -ItemType Directory -Force $release | Out-Null

    foreach ($arch in $Architectures) {
        $rid = "win-$arch"
        $publish = Join-Path $artifacts "publish\$arch"
        Write-Host "== $rid =="

        $common = @('-c', 'Release', '-r', $rid, '--self-contained', 'true', "-p:Version=$Version", '-p:DebugType=none', '-nologo')
        Invoke-Checked dotnet (@('publish', (Join-Path $windows 'src\NetFluss.Service\NetFluss.Service.csproj'), '-o', (Join-Path $publish 'Helper')) + $common)
        Invoke-Checked dotnet (@('publish', (Join-Path $windows 'src\NetFluss.App\NetFluss.App.csproj'), '-o', $publish) + $common)

        if (-not (Test-Path (Join-Path $publish 'Helper\NetFluss.Service.exe'))) { throw "The helper is missing from the $arch publish." }
        if (-not (Test-Path (Join-Path $publish 'SpeedTest'))) { throw "The speed test assets are missing from the $arch publish." }
        Sign @((Join-Path $publish 'NetFluss.exe'), (Join-Path $publish 'Helper\NetFluss.Service.exe'))

        # NetFluss's own executables, flat per architecture: the layout the SignPath artifact
        # configuration "binaries" (windows/Packaging/signpath/binaries.xml) describes.
        $batch = Join-Path $toSign "binaries\$arch"
        New-Item -ItemType Directory -Force $batch | Out-Null
        Copy-Item (Join-Path $publish 'NetFluss.exe') $batch
        Copy-Item (Join-Path $publish 'Helper\NetFluss.Service.exe') $batch
    }
}

function Package {
    $iscc = @(
        (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source,
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    New-Item -ItemType Directory -Force $release | Out-Null
    foreach ($arch in $Architectures) {
        $publish = Join-Path $artifacts "publish\$arch"
        if (-not (Test-Path $publish)) { throw "Nothing published for $arch; run the Publish stage first." }

        $signedBatch = Join-Path $signed "binaries\$arch"
        if (Test-Path $signedBatch) {
            Use-Signed (Join-Path $signedBatch 'NetFluss.exe') (Join-Path $publish 'NetFluss.exe')
            Use-Signed (Join-Path $signedBatch 'NetFluss.Service.exe') (Join-Path $publish 'Helper\NetFluss.Service.exe')
        }

        Compress-Archive -Path (Join-Path $publish '*') -DestinationPath (Join-Path $release "NetFluss-$Version-$arch-portable.zip") -CompressionLevel Optimal

        if ($SkipInstaller) { continue }
        if (-not $iscc) { throw 'Inno Setup 6 (iscc.exe) was not found. Install it, or pass -SkipInstaller.' }
        # Windows' file-version field is numbers only; a beta's suffix stays in AppVersion.
        Invoke-Checked $iscc @("/DAppVersion=$Version", "/DNumericVersion=$($Version -replace '-.*', '')", "/DArch=$arch", "/DSource=$publish", (Join-Path $PSScriptRoot 'NetFluss.iss'))
        $setup = Join-Path $release "NetFluss-Setup-$Version-$arch.exe"
        Sign @($setup)

        # The layout the SignPath artifact configuration "installers" describes.
        $batch = Join-Path $toSign 'installers'
        New-Item -ItemType Directory -Force $batch | Out-Null
        Copy-Item $setup $batch
    }
}

function Checksums {
    $signedInstallers = Join-Path $signed 'installers'
    if (Test-Path $signedInstallers) {
        foreach ($setup in Get-ChildItem $signedInstallers -Filter 'NetFluss-Setup-*.exe') {
            Use-Signed $setup.FullName (Join-Path $release $setup.Name)
        }
    }

    # "<sha256>  <name>" — the format sha256sum -c and the in-app updater both read.
    $sums = Get-ChildItem $release -File | Where-Object Name -notlike 'SHA256SUMS.txt*' | Sort-Object Name | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    }
    # LF line endings: sha256sum -c on Linux or WSL reads a CRLF line as a file name ending in \r.
    [IO.File]::WriteAllText((Join-Path $release 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), [Text.Encoding]::ASCII)

    # The signature the in-app updater requires (NetFluss.Core/UpdateSignature.cs). Without the
    # key the release files are still built, but installed copies will refuse to update to them.
    if ($env:NETFLUSS_UPDATE_SIGNING_KEY) {
        Invoke-Checked dotnet @('run', '--project', (Join-Path $windows 'tools\UpdateSigning'), '-c', 'Release', '--',
            'sign', (Join-Path $release 'SHA256SUMS.txt'))
    } else {
        Write-Warning 'NETFLUSS_UPDATE_SIGNING_KEY is not set: SHA256SUMS.txt is unsigned, and the in-app updater will not install this build.'
    }

    Get-ChildItem $release | Format-Table Name, Length
}

switch ($Stage) {
    'Publish' { Publish }
    'Package' { Package }
    'Checksums' { Checksums }
    default { Publish; Package; Checksums }
}
