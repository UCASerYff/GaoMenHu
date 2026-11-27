#ifndef ProductVersion
  #error ProductVersion is required
#endif
#ifndef FileVersion
  #error FileVersion is required
#endif

[Setup]
AppId={{4E316375-9453-4D02-999A-567E10C5AC3D}
AppName=搞门户
AppVersion={#ProductVersion}
AppVerName=搞门户 {#ProductVersion}
AppPublisher=搞系列
AppPublisherURL=https://github.com/UCASerYff/GaoMenHu
AppSupportURL=https://github.com/UCASerYff/GaoMenHu/issues
DefaultDirName={localappdata}\Programs\GaoMenHu
DefaultGroupName=搞门户
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.14393
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
UninstallDisplayIcon={app}\GaoMenHu.exe
Uninstallable=not IsPortable
CreateUninstallRegKey=not IsPortable
OutputDir=dist
OutputBaseFilename=GaoMenHu-Windows-{#ProductVersion}-x64-Setup
SetupIconFile=build\release-assets\GaoMenHu.ico
VersionInfoVersion={#FileVersion}
VersionInfoProductName=搞门户
VersionInfoProductVersion={#ProductVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
RestartApplications=no

[Files]
Source: "build\release-bin\GaoMenHu\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "build\release-bin\GaoMenHu-bridge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\release-bin\GaoMenHu-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\release-assets\cn.mendao.bridge.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "GaoCapabilities.Windows.json"; DestDir: "{app}"; DestName: "GaoCapabilities.json"; Flags: ignoreversion
Source: "..\BrowserExtension\*"; DestDir: "{app}\BrowserExtension"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "README.md"; DestDir: "{app}"; DestName: "使用说明.md"; Flags: ignoreversion
Source: "..\Docs\Mail\OAuthSetup.txt"; DestDir: "{app}"; DestName: "邮件授权配置.txt"; Flags: ignoreversion
Source: "build\MicrosoftEdgeWebview2Setup.exe"; Flags: dontcopy noencryption

[Tasks]
Name: "startmenu"; Description: "在开始菜单创建搞门户快捷方式"
Name: "browserhost"; Description: "注册 Chrome 和 Edge 的搞门户助手"

[Icons]
Name: "{autoprograms}\搞门户"; Filename: "{app}\GaoMenHu.exe"; Tasks: startmenu; Check: not IsPortable

[Registry]
Root: HKCU; Subkey: "Software\Google\Chrome\NativeMessagingHosts\cn.mendao.bridge"; ValueType: string; ValueData: "{app}\cn.mendao.bridge.json"; Tasks: browserhost; Check: not IsPortable
Root: HKCU; Subkey: "Software\Microsoft\Edge\NativeMessagingHosts\cn.mendao.bridge"; ValueType: string; ValueData: "{app}\cn.mendao.bridge.json"; Tasks: browserhost; Check: not IsPortable
Root: HKCU; Subkey: "Software\GaoSeries\GaoAction\cn.mendao.launcher"; ValueType: string; ValueName: "Executable"; ValueData: "{app}\GaoMenHu.exe"; Check: not IsPortable
Root: HKCU; Subkey: "Software\GaoSeries\GaoAction\cn.mendao.launcher"; ValueType: string; ValueName: "Capabilities"; ValueData: "{app}\GaoCapabilities.json"; Check: not IsPortable

[Run]
Filename: "{app}\GaoMenHu.exe"; Description: "打开搞门户"; Flags: nowait postinstall skipifsilent; Check: not IsPortable

[Code]
const
  WebViewRuntimeKey = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  ChromeHostKey = 'Software\Google\Chrome\NativeMessagingHosts\cn.mendao.bridge';
  EdgeHostKey = 'Software\Microsoft\Edge\NativeMessagingHosts\cn.mendao.bridge';
  GaoActionKey = 'Software\GaoSeries\GaoAction\cn.mendao.launcher';

function IsPortable: Boolean;
begin
  Result := ExpandConstant('{param:PORTABLE|0}') = '1';
end;

function RuntimeAt(Root: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(Root, WebViewRuntimeKey, 'pv', Version) and
    (Version <> '') and (Version <> '0.0.0.0');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if IsPortable or RuntimeAt(HKLM32) or RuntimeAt(HKCU) then Exit;
  ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
  if not Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '',
      SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    Result := '无法运行 Microsoft Edge WebView2 安装程序。'
  else if not (RuntimeAt(HKLM32) or RuntimeAt(HKCU)) then
    Result := 'Microsoft Edge WebView2 Runtime 未安装。请联网安装 Microsoft Edge WebView2 Runtime 后重试。';
end;

procedure RemoveOwnedValue(const Key, ValueName, RelativePath: String);
var
  Current, Expected: String;
begin
  Expected := ExpandConstant('{app}\') + RelativePath;
  if RegQueryStringValue(HKCU, Key, ValueName, Current) and (CompareText(Current, Expected) = 0) then begin
    RegDeleteValue(HKCU, Key, ValueName);
    RegDeleteKeyIfEmpty(HKCU, Key);
  end;
end;

procedure CurUninstallStepChanged(Step: TUninstallStep);
begin
  if Step = usUninstall then begin
    RemoveOwnedValue(ChromeHostKey, '', 'cn.mendao.bridge.json');
    RemoveOwnedValue(EdgeHostKey, '', 'cn.mendao.bridge.json');
    RemoveOwnedValue(GaoActionKey, 'Executable', 'GaoMenHu.exe');
    RemoveOwnedValue(GaoActionKey, 'Capabilities', 'GaoCapabilities.json');
  end;
end;
