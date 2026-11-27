param(
    [Parameter(Mandatory)] [string] $Setup,
    [string] $LegacyExe,
    [string] $PreviousSetup,
    [string] $PlaywrightPackage,
    [string] $PeerPython,
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
$providerKey = 'HKCU:\Software\GaoSeries\GaoAction\cn.mendao.launcher'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{4E316375-9453-4D02-999A-567E10C5AC3D}_is1'
$installAttempt = $false

function Wait-Portal($Process, $Root) {
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
    $previousOverride = $env:GAOMENHU_DATA_DIR
    $env:GAOMENHU_DATA_DIR = $Root
    try {
        Start-Process -FilePath $Path -ArgumentList @('--data-dir', ('"' + $Root + '"'), '--serve', '--no-browser', '--port', '0') -PassThru -WindowStyle Hidden
    } finally {
        $env:GAOMENHU_DATA_DIR = $previousOverride
    }
}

function Start-Install($File, $LogFile, [switch] $Portable, [switch] $IsolatedUninstaller) {
    $expectedHash = ((Get-Content -LiteralPath "$($File.FullName).sha256" -Raw).Trim() -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash -ne $expectedHash) { throw "Installer hash differs" }
    $setupArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCLOSEAPPLICATIONS',
        (('/DIR="{0}"') -f $installDir), (('/LOG="{0}"') -f $LogFile), '/MERGETASKS="!startmenu"')
    if ($Portable) { $setupArguments += '/PORTABLE=1' }
    if ($IsolatedUninstaller) { $setupArguments += '/ISOLATEDSMOKE=1' }
    $proc = Start-Process -FilePath $File.FullName -ArgumentList $setupArguments -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 12 | Write-Output }
        throw "Installer exited with $($proc.ExitCode)"
    }
}

function Wait-IsolatedEvent([scriptblock] $Probe, [string] $Description) {
    $deadline = (Get-Date).AddSeconds(18)
    do {
        $match = & $Probe
        if ($match) { return $match }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for $Description"
}

function Test-InstalledAction {
    $provider = (Call-Portal '/api/actions/providers').providers | Where-Object bundleID -eq 'cn.mendao.launcher'
    if (-not $provider) { throw 'The live portal did not discover its installed capability descriptor' }
    $outbound = Call-Portal '/api/actions/send' @{ target = 'cn.mendao.launcher'; urls = @('https://fixture.example.test/example.pdf'); privacy = 'strip' }
    $requestID = $outbound.record.id
    if ($outbound.deliveryError -or -not $requestID) { throw "Installed GaoAction could not dispatch: $($outbound.deliveryError)" }
    $request = Wait-IsolatedEvent { (Call-Portal '/api/downloads/state').requests | Where-Object id -eq $requestID } 'registered process to receive the request'
    if ($request.stage -ne 'awaitingReview') { throw 'The installed receiver skipped the download review' }
    Call-Portal '/api/downloads/request-reject' @{ id = $requestID } | Out-Null
    $reply = Call-Portal '/api/downloads/request-result' @{ id = $requestID; phase = 'final'; send = $true }
    if (-not $reply.delivered -or $reply.deliveryError) { throw "The installed receiver did not dispatch its result: $($reply.deliveryError)" }
    $review = Wait-IsolatedEvent {
        $current = (Call-Portal '/api/actions/queue').review
        if ($current.kind -eq 'result' -and $current.inReplyTo -eq $requestID) { $current }
    } 'automatically delivered result review'
    Call-Portal '/api/actions/decide' @{ id = $review.id; approve = $true } | Out-Null
    $replay = Call-Portal '/api/actions/open' @{ path = $reply.package }
    if (-not $replay.repeated) { throw 'The same installed result could be offered more than once' }
    $result = (Call-Portal '/api/actions/history').records | Where-Object id -eq $requestID
    if ($result.status -ne 'cancelled' -or $result.deliveries.Count -ne 1) { throw 'GaoAction history did not correlate the final cancellation' }
    Write-Output 'Installed GaoAction discovery, child-process delivery, receiver review and final result correlation passed.'
}

function Test-InstalledBrowser($HostInfo) {
    $arguments = @((Join-Path $PSScriptRoot 'browser-native.cjs'), (Resolve-Path -LiteralPath $PlaywrightPackage).Path,
                   $installDir, $dataDir, $smokeRoot, $origin)
    $registeredAliases = [System.Collections.Generic.List[string]]::new()
    try {
        if (-not $Register) {
            $alias = 'cn.mendao.bridge.smoke_' + [guid]::NewGuid().ToString('N')
            $aliasManifest = Join-Path $installDir "$alias.json"
            $HostInfo.name = $alias
            [IO.File]::WriteAllText($aliasManifest, ($HostInfo | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
            foreach ($normalKey in @($chromeKey, $edgeKey)) {
                $key = Join-Path (Split-Path $normalKey -Parent) $alias
                if (Test-Path -LiteralPath $key) { throw "Fixture Native Messaging alias already exists: $key" }
                New-Item -Path $key -Force | Out-Null
                $registeredAliases.Add($key)
                Set-Item -LiteralPath $key -Value $aliasManifest
            }
            $arguments += $alias
        }
        & node @arguments
        if ($LASTEXITCODE) { throw 'Browser Native Messaging smoke failed' }
    } finally {
        foreach ($key in $registeredAliases) { Remove-Item -LiteralPath $key -Force }
    }
}

try {
    if ($PreviousSetup -and $LegacyExe) { throw "Choose either -PreviousSetup or -LegacyExe" }
    if ($PeerPython -and -not $Register) { throw 'Peer smoke requires a registered installation' }
    if ($Register) {
        foreach ($key in @($chromeKey, $edgeKey, $providerKey, $uninstallKey)) {
            if (Test-Path -LiteralPath $key) { throw "Run -Register only when the GaoMenHu registration is unused: $key" }
        }
    }
    $app = Join-Path $installDir 'GaoMenHu.exe'
    $native = Join-Path $installDir 'GaoMenHu-bridge.exe'
    $console = Join-Path $installDir 'GaoMenHu-cli.exe'
    $manifest = Join-Path $installDir 'cn.mendao.bridge.json'
    $descriptor = Join-Path $installDir 'GaoCapabilities.json'
    if ($PreviousSetup) {
        Start-Install (Get-Item -LiteralPath $PreviousSetup) (Join-Path $smokeRoot 'previous.log') -Portable
        $LegacyExe = $app
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
        if ($PreviousSetup) {
            $target = (New-Item -Path (Join-Path $smokeRoot 'fixture-downloads') -ItemType Directory).FullName
            $destination = (Call-Portal '/api/downloads/destination' @{ path = $target }).destination
            $queued = (Call-Portal '/api/downloads/create' @{
                urls = @('https://downloads.example.test/fixture.pdf'); destinationID = $destination.id; run = $false
            }).items | Where-Object destinationID -eq $destination.id
            if (-not $queued.id) { throw 'Could not seed an isolated download on the previous package' }
            Call-Portal '/api/mail/account' @{ account = @{ id = 'upgrade-mail'; email = 'fixture@example.test' } } | Out-Null
            Call-Portal '/api/mail/settings' @{ preferences = @{ appearance = 'dark'; showPreviews = $true } } | Out-Null
            $oldDraft = (Call-Portal '/api/mail/draft' @{ draft = @{
                accountID = 'upgrade-mail'; to = 'recipient@example.test'; subject = '升级验证草稿'; body = '仅使用合成资料'
            } }).draft
        }
        Stop-Portal $launcher
        $launcher = $null
        $libraryPath = Join-Path $dataDir 'library.json'
        $legacyHash = (Get-FileHash -LiteralPath $libraryPath).Hash
        Remove-Item -LiteralPath "$dataDir.native.json" -ErrorAction SilentlyContinue
    }
    $installAttempt = $true
    Start-Install $setupFile (Join-Path $smokeRoot 'setup.log') -Portable:(-not $Register) -IsolatedUninstaller:(-not $Register)
    foreach ($file in @($app, $native, $console)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing executable $file" }
        $bytes = [IO.File]::ReadAllBytes($file)
        if ([BitConverter]::ToUInt16($bytes, [BitConverter]::ToInt32($bytes, 60) + 4) -ne 0x8664) { throw "Expected AMD64 PE: $file" }
        $fileVersion = (Get-Item -LiteralPath $file).VersionInfo
        if ($fileVersion.ProductVersion.Trim() -ne '1.19' -or $fileVersion.FileVersion.Trim() -ne $setupFile.VersionInfo.FileVersion.Trim()) {
            throw "Unexpected release or build version: $file"
        }
    }
    $hostInfo = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $extension = Get-Content -LiteralPath (Join-Path $installDir 'BrowserExtension\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($hostInfo.name -ne 'cn.mendao.bridge' -or $hostInfo.path -ne 'GaoMenHu-bridge.exe' -or $extension.version -ne '1.19.0') { throw "Unexpected helper bundle" }
    $capabilities = (& $console --capabilities | Out-String | ConvertFrom-Json)
    if ($LASTEXITCODE -or $capabilities.bundleID -ne 'cn.mendao.launcher' -or $capabilities.appVersion -ne '1.19' -or -not $capabilities.actions) { throw "Installed CLI did not describe the portal capabilities" }
    if ($Register) {
        foreach ($key in @($chromeKey, $edgeKey)) {
            if ((Get-Item -LiteralPath $key).GetValue('') -ne $manifest) { throw "Host was not registered at $key" }
        }
        $provider = Get-Item -LiteralPath $providerKey
        if (($provider.GetValue('Executable') -ne $app) -or ($provider.GetValue('Capabilities') -ne $descriptor)) { throw "GaoAction provider was not registered" }
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
    if ($PreviousSetup) {
        $downloads = Call-Portal '/api/downloads/state'
        $mail = Call-Portal '/api/mail/state'
        $keptDownload = $downloads.items | Where-Object id -eq $queued.id
        $keptDestination = $downloads.destinations | Where-Object id -eq $destination.id
        $keptDraft = (Call-Portal '/api/mail/draft-read' @{ id = $oldDraft.id }).draft
        if (-not $keptDownload -or -not $keptDestination -or $keptDownload.state -notin @('queued', 'paused')) { throw 'The upgraded queue lost its saved job or destination' }
        if (-not ($mail.accounts | Where-Object id -eq 'upgrade-mail') -or $mail.preferences.appearance -ne 'dark' -or -not $mail.preferences.showPreviews -or $keptDraft.body -ne $oldDraft.body) { throw 'The upgraded mail library lost its account, preferences or draft' }
        Write-Output 'Upgrade preserved the previous download job and destination, mail account, theme, preview setting and draft.'
    }
    if ($Register) { Test-InstalledAction }
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
    if ($PlaywrightPackage) { Test-InstalledBrowser $hostInfo }
    Stop-Portal $launcher
    $launcher = $null
    $starter = Start-Process -FilePath $app -ArgumentList @('--data-dir', ('"' + $dataDir + '"'), '--window-smoke', ('"' + $report + '"')) -PassThru -WindowStyle Hidden
    if (-not $starter.WaitForExit(90000)) { Stop-Portal $starter; throw "WebView2 smoke timed out" }
    if (-not (Test-Path -LiteralPath $report)) { throw "WebView2 smoke exited before recording results: $($starter.ExitCode)" }
    $nativeText = Get-Content -LiteralPath $report -Raw -Encoding UTF8
    try { $nativeResult = $nativeText | ConvertFrom-Json } catch { throw "WebView2 reported: $nativeText" }
    if ($starter.ExitCode -ne 0 -or -not ($nativeResult.launcher -and $nativeResult.bridge -and $nativeResult.token -and $nativeResult.browserDiagnostics) -or $nativeResult.windows.Count -ne 4) { throw "WebView2 smoke exited with $($starter.ExitCode): $nativeText" }
    if ($nativeResult.mailFloating.rail.Count -ne 2 -or $nativeResult.mailFloating.card.Count -ne 2 -or $nativeResult.mailFloating.card[0] -le $nativeResult.mailFloating.rail[0]) { throw "Native mail floating smoke failed: $nativeText" }
    Write-Output ("Native mail rail and card at {0} DPI: {1} → {2}" -f $nativeResult.mailFloating.dpi, ($nativeResult.mailFloating.rail -join 'x'), ($nativeResult.mailFloating.card -join 'x'))
    if ($PeerPython) {
        $fixtureInterpreter = (Resolve-Path -LiteralPath $PeerPython).Path
        & $fixtureInterpreter (Join-Path $PSScriptRoot 'gaoaction-installed-peer.py') --portal $app
        if ($LASTEXITCODE) { throw "Independent installed GaoAction peer smoke failed" }
    }
    Write-Output "Installer, x64 PE, loopback routes, DPAPI, browser identity and hidden WebView2 diagnosis passed; legacy upgrade=$([bool]$LegacyExe); registry=$([bool]$Register)"
} finally {
    Stop-Portal $launcher
    if ($installAttempt -and (Test-Path -LiteralPath (Join-Path $installDir 'unins000.exe'))) {
        $keptLibrary = Join-Path $dataDir 'library.json'
        $beforeUninstall = if (Test-Path -LiteralPath $keptLibrary) { (Get-FileHash -LiteralPath $keptLibrary).Hash }
        $uninstallArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        if (-not $Register) { $uninstallArgs += '/PORTABLE=1', '/ISOLATEDSMOKE=1' }
        $uninstall = Start-Process -FilePath (Join-Path $installDir 'unins000.exe') -ArgumentList $uninstallArgs -PassThru -Wait -WindowStyle Hidden
        if ($uninstall.ExitCode -ne 0 -or (Test-Path -LiteralPath $app)) { throw 'The test uninstall failed to remove its own application' }
        if ($Register -and ((Test-Path $chromeKey) -or (Test-Path $edgeKey) -or (Test-Path $providerKey) -or (Test-Path $uninstallKey))) { throw 'The test uninstall failed to remove its own registration' }
        if ($beforeUninstall -and (Get-FileHash -LiteralPath $keptLibrary).Hash -ne $beforeUninstall) { throw 'The test uninstall changed isolated user data' }
        Write-Output "Uninstall removed installed files and preserved isolated user data; registry=$([bool]$Register)"
    }
    $buildRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\build')).Path.TrimEnd('\') + '\'
    $resolvedRoot = (Resolve-Path -LiteralPath $smokeRoot).Path
    if (-not $resolvedRoot.StartsWith($buildRoot + 'install-smoke-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Smoke cleanup path was outside of the project build folder' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
