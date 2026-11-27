param(
    [string] $Python = "python",
    [string] $InnoSetup,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot "dist"),
    [switch] $SkipDependencies,
    [switch] $SkipTests,
    [switch] $ExecutablesOnly
)

$ErrorActionPreference = "Stop"
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
Push-Location -LiteralPath $PSScriptRoot
try {

    function Invoke-Checked($Program, [string[]] $Arguments) {
        & $Program @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
    }

    if (-not $SkipDependencies) {
        Invoke-Checked $Python @("-m", "pip", "install", "--disable-pip-version-check", "-r", "requirements-dev.txt")
    }
    if (-not $SkipTests) {
        Invoke-Checked $Python @("-m", "pytest", "-q")
    }

    $releaseAssets = Join-Path $PSScriptRoot "build\release-assets"
    $releaseBin = Join-Path $PSScriptRoot "build\release-bin"
    New-Item -ItemType Directory -Path $releaseAssets, $releaseBin -Force | Out-Null
    $env:PYINSTALLER_CONFIG_DIR = Join-Path $PSScriptRoot "build\pyinstaller-cache"
    Invoke-Checked $Python @("prepare_release.py")
    $version = (Get-Content -Raw -LiteralPath "..\VERSION").Trim()
    $fileVersion = (Get-Content -Raw -LiteralPath "$releaseAssets\version.txt").Trim()
    $icon = Join-Path $releaseAssets "GaoMenHu.ico"
    $common = @("-m", "PyInstaller", "--noconfirm", "--paths", "src", "--distpath", $releaseBin,
                "--icon", $icon, "--version-file", (Join-Path $releaseAssets "version-info.txt"))

    $portalAssets = (Resolve-Path -LiteralPath "..\Resources").Path
    $windowsAssets = (Resolve-Path -LiteralPath "src\gaomenhu\assets").Path
    $mark = Join-Path $releaseAssets "Mark.png"
    Invoke-Checked $Python ($common + @("--name", "GaoMenHu", "--onedir", "--windowed", "--collect-all", "webview", "--collect-all", "pythonnet",
        "--collect-all", "clr_loader", "--add-data", "$windowsAssets;gaomenhu_assets", "--add-data", "$icon;gaomenhu_assets",
        "--add-data", "$portalAssets;gaomenhu_portal", "--add-data", "$mark;gaomenhu_portal",
        "--workpath", "build\release-gui", "--specpath", "build\release-gui", "launch.py"))
    Invoke-Checked $Python ($common + @("--name", "GaoMenHu-bridge", "--onefile", "--console",
        "--workpath", "build\release-bridge", "--specpath", "build\release-bridge", "bridge.py"))
    Copy-Item -LiteralPath (Join-Path $releaseBin "GaoMenHu-bridge.exe") -Destination (Join-Path $releaseBin "GaoMenHu-cli.exe") -Force

    if ($ExecutablesOnly) { return }
    if (-not $InnoSetup) {
        $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($compiler) { $InnoSetup = $compiler.Source }
        else { $InnoSetup = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe" }
    }
    if (-not (Test-Path -LiteralPath $InnoSetup -PathType Leaf)) {
        throw "Inno Setup 6.5 or newer is required. Pass the path to ISCC.exe with -InnoSetup."
    }
    $bootstrap = Join-Path $PSScriptRoot "build\MicrosoftEdgeWebview2Setup.exe"
    if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
        Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $bootstrap -UseBasicParsing
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "CN=Microsoft Corporation,") {
        throw "WebView2 Bootstrapper signature verification failed"
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Invoke-Checked $InnoSetup @("/DProductVersion=$version", "/DFileVersion=$fileVersion", "/O$OutputDirectory", "installer.iss")
    $setup = Get-Item -LiteralPath (Join-Path $OutputDirectory "GaoMenHu-Windows-$version-x64-Setup.exe")
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup.FullName).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$($setup.FullName).sha256", "$hash  $($setup.Name)`n", [Text.Encoding]::ASCII)
    Write-Output $setup.FullName
    Write-Output "$($setup.FullName).sha256"
} finally {
    Pop-Location
}
