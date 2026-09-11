#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#define ProjectRoot AddBackslash(SourcePath) + "..\.."
#ifndef AppId
  #define AppId "{{39426386-713C-4E56-A981-26E3C8C0C204}"
#endif
#ifndef AppMutex
  #define AppMutex "QingJuan.Application"
#endif

[Setup]
AppId={#AppId}
AppName=青卷
AppVersion={#AppVersion}
AppVerName=青卷 {#AppVersion}
VersionInfoVersion={#AppVersion}.{#BuildNumber}
AppPublisher=Tavre
AppPublisherURL=https://github.com/Tavre/QingJuan
AppSupportURL=https://github.com/Tavre/QingJuan/issues
AppUpdatesURL=https://github.com/Tavre/QingJuan/releases/latest
DefaultDirName={localappdata}\Programs\QingJuan
DefaultGroupName=青卷
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
SetupIconFile={#ProjectRoot}\assets\app_icon.ico
UninstallDisplayIcon={app}\qingjuan.exe
LicenseFile={#ProjectRoot}\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=QingJuan-v{#AppVersion}-windows-x64-setup
Compression=lzma2/ultra64
SolidCompression=yes
AppMutex={#AppMutex}
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked

[Files]
; Never ship, overwrite or uninstall user data. Portable upgrades use the same directory.
; Public HTTPS CA bundles have been allowlisted by package_windows.ps1.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "backend\data\*,*.db,*.sqlite,*.sqlite3,*.log,.env,settings.json,*.key"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\青卷"; Filename: "{app}\qingjuan.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\青卷"; Filename: "{app}\qingjuan.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\qingjuan.exe"; Description: "启动青卷"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Code]
function OpenProcess(Access: LongWord; Inherit: Boolean; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function InitializeSetup(): Boolean;
var
  UpdatePid: Integer;
  ProcessHandle: THandle;
begin
  Result := True;
  UpdatePid := StrToIntDef(ExpandConstant('{param:UPDATEPID|0}'), 0);
  if UpdatePid <= 0 then Exit;
  ProcessHandle := OpenProcess($00100000, False, UpdatePid);
  if ProcessHandle = 0 then begin
    { ERROR_INVALID_PARAMETER means the process has already exited. }
    Result := DLLGetLastError = 87;
  end else begin
    try
      Result := WaitForSingleObject(ProcessHandle, 30000) = 0;
    finally
      CloseHandle(ProcessHandle);
    end;
  end;
  if not Result then
    MsgBox('青卷尚未退出，无法更新。请关闭青卷后重新运行安装程序。', mbError, MB_OK);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  { Online updates must keep the current directory and its backend/data. }
  Result := (PageID = wpSelectDir) and
    (StrToIntDef(ExpandConstant('{param:UPDATEPID|0}'), 0) > 0);
end;
