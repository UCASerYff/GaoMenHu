param(
    [Parameter(Mandatory)] [string] $Setup,
    [string] $LegacyExe,
    [switch] $Register
)

$ErrorActionPreference = "Stop"
$setupFile = Get-Item -LiteralPath $Setup
$smokeRoot = Join-Path $PSScriptRoot ("..\build\install-smoke-" + [guid]::NewGuid().ToString("N"))
$smokeRoot = (New-Item -Path $smokeRoot -ItemType Directory -Force).FullName
$installDir = Join-Path $smokeRoot "安装"
$dataDir = Join-Path $smokeRoot "MenDao"
$report = Join-Path $smokeRoot "native-window.json"
$launcher = $null
$origin = $null
$headers = $null
$chromeKey = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\cn.mendao.bridge'
$edgeKey = 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\cn.mendao.bridge'

function Wait-Portal($Process, $Root, [switch] $Legacy) {
    $deadline = (Get-Date).AddSeconds(60)
    do {
        if ($Process.HasExited) { throw "Portal exited before startup: $($Process.ExitCode)" }
        try {
            $info = Get-Content -LiteralPath "$Root.native.json" -Raw | ConvertFrom-Json
            $script:origin = "http://127.0.0.1:$($info.port)"
            $page = Invoke-WebRequest -Uri "$script:origin/" -UseBasicParsing -TimeoutSec 2
            $token = [regex]::Match($page.Content, 'name="gao-token" content="([^"]+)"').Groups[1].Value
            if ($page.StatusCode -eq 200 -and $token) {
                $script:headers = @{ "X-Gao-Token" = $token }
                return
            }
        } catch {}
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for the portal page"
}

function Call-Portal($Path, $Body = @{}) {
    Invoke-RestMethod -Uri "$script:origin$Path" -Method POST -Headers $script:headers -ContentType "application/json" -Body (ConvertTo-Json -InputObject $Body -Depth 16 -Compress) -TimeoutSec 5
}

function Stop-Portal($Process) {
    if (-not $Process -or $Process.HasExited) { return }
    if ($script:headers -and $script:origin) {
        try { Call-Portal "/api/shutdown" | Out-Null } catch {}
        if ($Process.WaitForExit(12000)) { return }
    }
    & taskkill.exe /PID $Process.Id /T /F | Out-Null
    $Process.WaitForExit(3000) | Out-Null
}

function Start-Portal($Path, $Root) {
    Start-Process -FilePath $Path -ArgumentList @('--data-dir', ('"' + $Root + '"'), '--serve', '--no-browser', '--port', '0') -PassThru -WindowStyle Hidden
}

try {
    if ($Register -and ((Test-Path $chromeKey) -or (Test-Path $edgeKey))) {
        throw "Run -Register only on a test account without existing GaoMenHu browser registrations"
    }
    $expectedHash = ((Get-Content -LiteralPath "$($setupFile.FullName).sha256" -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $setupFile.FullName -Algorithm SHA256).Hash -ne $expectedHash) { throw "Installer hash differs" }
    $argsForSetup = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCLOSEAPPLICATIONS', (('/DIR="{0}"') -f $installDir), (('/LOG="{0}\setup.log"') -f $smokeRoot))
    if (-not $Register) { $argsForSetup += '/PORTABLE=1' }
    $installer = Start-Process -FilePath $setupFile.FullName -ArgumentList $argsForSetup -Wait -PassThru -WindowStyle Hidden
    if ($installer.ExitCode -ne 0) { throw "Installer exited with $($installer.ExitCode), see $smokeRoot\setup.log" }
    $app = Join-Path $installDir 'GaoMenHu.exe'
    $native = Join-Path $installDir 'GaoMenHu-bridge.exe'
    $manifest = Join-Path $installDir 'cn.mendao.bridge.json'
    foreach ($file in @($app, $native)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing executable $file" }
        $bytes = [IO.File]::ReadAllBytes($file)
        if ([BitConverter]::ToUInt16($bytes, [BitConverter]::ToInt32($bytes, 60) + 4) -ne 0x8664) { throw "Expected AMD64 PE: $file" }
        if ((Get-Item -LiteralPath $file).VersionInfo.ProductVersion -ne '1.19') { throw "Unexpected product version: $file" }
    }
    $hostInfo = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $extension = Get-Content -LiteralPath (Join-Path $installDir 'BrowserExtension\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($hostInfo.name -ne 'cn.mendao.bridge' -or $hostInfo.path -ne 'GaoMenHu-bridge.exe' -or $extension.version -ne '1.19.0') { throw "Unexpected helper bundle" }
    if ($Register) {
        foreach ($key in @($chromeKey, $edgeKey)) {
            if ((Get-Item -LiteralPath $key).GetValue('') -ne $manifest) { throw "Host was not registered at $key" }
        }
    }
    $profileID = '92ecd782-3c6e-4a48-9b8a-94de1c905252'
    $bookmarkedSite = @{
        id = 'sandbox-site'; name = 'Install smoke'; url = 'https://example.test/'; color = '#537CE6'
        allowedBrowsers = @('chrome'); defaultBrowser = 'chrome'; profiles = @{ chrome = $profileID }
        accounts = @(@{ id = 'sandbox-account'; label = 'Test'; username = 'fixture'; loginHosts = @(); hasPassword = $true })
        defaultAccount = 'sandbox-account'
    }
    if ($LegacyExe) {
        $launcher = Start-Portal ((Get-Item -LiteralPath $LegacyExe).FullName) $dataDir
        Wait-Portal $launcher $dataDir
        Call-Portal '/api/sites/save' @{ site = $bookmarkedSite; passwords = @(@{ id = 'sandbox-account'; password = 'isolated-test-secret' }) } | Out-Null
        Stop-Portal $launcher
        $launcher = $null
        $libraryPath = Join-Path $dataDir 'library.json'
        $legacyHash = (Get-FileHash -LiteralPath $libraryPath).Hash
        Remove-Item -LiteralPath "$dataDir.native.json" -ErrorAction SilentlyContinue
    }
    $launcher = Start-Portal $app $dataDir
    Wait-Portal $launcher $dataDir
    foreach ($route in @('/settings', '/downloads', '/mail', '/portal-assets/style.css')) {
        $resource = Invoke-WebRequest -Uri "$origin$route" -UseBasicParsing -TimeoutSec 5
        if ($resource.StatusCode -ne 200) { throw "Failed to load $route" }
    }
    if (-not $LegacyExe) {
        Call-Portal '/api/sites/save' @{ site = $bookmarkedSite; passwords = @(@{ id = 'sandbox-account'; password = 'isolated-test-secret' }) } | Out-Null
    } elseif ((Get-FileHash -LiteralPath $libraryPath).Hash -ne $legacyHash) {
        throw "Existing library changed on initial startup"
    }
    if (-not ((Call-Portal '/api/state').library.sites | Where-Object id -eq 'sandbox-site')) { throw "Site did not persist" }
    $info = Get-Content -LiteralPath "$dataDir.native.json" -Raw | ConvertFrom-Json
    function Call-Helper($Message, $Browser = 'chrome') {
        $Message.profileId = $profileID
        Invoke-RestMethod -Uri "$origin/api/native" -Method POST -Headers @{ 'X-Gao-Host' = $info.token } -ContentType 'application/json' -TimeoutSec 5 -Body (ConvertTo-Json -Depth 8 -Compress @{
            browser = $Browser; extension = 'ipggjapdbehjdikobhedllpdbchkoigf'; message = $Message
        })
    }
    if (-not (Call-Helper @{ type = 'poll' }).ok) { throw "Browser helper did not poll" }
    Call-Portal '/api/vault/unlock' | Out-Null
    $launch = Call-Portal '/api/sites/launch' @{ siteID = 'sandbox-site'; browserID = 'chrome' }
    $requestID = $launch.requestID
    if (-not $requestID -or (Call-Helper @{ type = 'poll' } 'edge').launch -or (Call-Helper @{ type = 'poll' }).launch.id -ne $requestID) { throw "Helper routed the launch to the wrong profile" }
    if (-not (Call-Helper @{ type = 'bind'; requestId = $requestID; tabId = 6 }).ok) { throw "Tab binding failed" }
    if (-not (Call-Helper @{ type = 'launchStatus'; requestId = $requestID; tabId = 6; status = 'opened' }).ok) { throw "Opening was not confirmed" }
    $credential = Call-Helper @{ type = 'credentials'; requestId = $requestID; tabId = 6; url = 'https://example.test/login' }
    if ($credential.password -ne 'isolated-test-secret') { throw "Isolated DPAPI autofill failed" }
    if ((Get-Content -LiteralPath (Join-Path $dataDir 'library.json') -Raw) -match 'isolated-test-secret') { throw 'Password leaked into library file' }
    Stop-Portal $launcher
    $launcher = $null
    $starter = Start-Process -FilePath $app -ArgumentList @('--data-dir', ('"' + $dataDir + '"'), '--window-smoke', ('"' + $report + '"')) -PassThru -WindowStyle Hidden
    if (-not $starter.WaitForExit(90000)) { Stop-Portal $starter; throw "WebView2 smoke timed out" }
    if (-not (Test-Path -LiteralPath $report)) { throw "WebView2 smoke exited before recording results: $($starter.ExitCode)" }
    $nativeText = Get-Content -LiteralPath $report -Raw -Encoding UTF8
    try { $nativeResult = $nativeText | ConvertFrom-Json } catch { throw "WebView2 reported: $nativeText" }
    if ($starter.ExitCode -ne 0 -or -not ($nativeResult.launcher -and $nativeResult.bridge -and $nativeResult.token) -or $nativeResult.windows.Count -ne 4) { throw "WebView2 smoke failed: $nativeText" }
    Write-Output "Installer, x64 PE, loopback routes, DPAPI, browser identity and hidden WebView2 passed; legacy upgrade=$([bool]$LegacyExe); registry=$([bool]$Register)"
} finally {
    Stop-Portal $launcher
    if ($Register -and (Test-Path -LiteralPath (Join-Path $installDir 'unins000.exe'))) {
        $uninstall = Start-Process -FilePath (Join-Path $installDir 'unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -PassThru -Wait -WindowStyle Hidden
        if ($uninstall.ExitCode -ne 0 -or (Test-Path $chromeKey) -or (Test-Path $edgeKey)) { throw 'The test uninstall failed to remove its own registration' }
    }
    $buildRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\build')).Path.TrimEnd('\') + '\'
    $resolvedRoot = (Resolve-Path -LiteralPath $smokeRoot).Path
    if (-not $resolvedRoot.StartsWith($buildRoot + 'install-smoke-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Smoke cleanup path was outside of the project build folder' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
