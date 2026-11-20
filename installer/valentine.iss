; Windows installer, built by build.yml from the packaged dist\ folder:
;   ISCC /DAppVersion=1.2.3 installer\valentine.iss
; Installs per user by default (no admin prompt); state stays in %APPDATA%\Valentine,
; so an upgrade or uninstall never touches panes, scrollback or settings.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

[Setup]
AppId={{6B0E3C1A-2F4D-4E8B-9A57-3C1D8E2F7A40}
AppName=Valentine
AppVersion={#AppVersion}
AppVerName=Valentine {#AppVersion}
AppPublisher=Tuntii
AppPublisherURL=https://github.com/Tuntii/valentine
AppSupportURL=https://github.com/Tuntii/valentine/issues
AppUpdatesURL=https://github.com/Tuntii/valentine/releases/latest
DefaultDirName={autopf}\Valentine
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE
SetupIconFile=..\assets\valentine.ico
UninstallDisplayIcon={app}\valentine.exe
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Valentine hides to the tray on WM_CLOSE, so an upgrade has to end it for real.
; Its state is crash-safe (SQLite WAL), so this loses nothing.
CloseApplications=force
RestartApplications=no
OutputDir=..
OutputBaseFilename=valentine-windows-x64-setup

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{autoprograms}\Valentine"; Filename: "{app}\valentine.exe"
Name: "{autodesktop}\Valentine"; Filename: "{app}\valentine.exe"; Tasks: desktopicon

[Registry]
; "Start at login" (set from the app) points at this exe; drop it with the app.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Valentine"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\valentine.exe"; Description: "{cm:LaunchProgram,Valentine}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im valentine.exe"; Flags: runhidden; RunOnceId: "StopValentine"
