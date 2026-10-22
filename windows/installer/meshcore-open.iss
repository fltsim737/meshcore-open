; Inno Setup script for MeshCore Open on Windows. Build with
; windows\installer\build-windows.ps1, which builds the app, adds the Visual
; C++ runtime and passes the version.
;
; Installs per user (no administrator rights needed) and registers an
; uninstaller under Settings > Apps.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "MeshCore Open SOS Voice"
#define AppExe "meshcore_open_sos_voice.exe"
; Must match appUserModelId in lib/services/notification_service.dart.
#define AppUserModelId "org.meshcore.open.sosvoice"
#define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"

[Setup]
AppId={{F330C7AB-BE84-44C3-851F-0EFF95CBBACC}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=MeshCore Open contributors
AppPublisherURL=https://github.com/zjs81/meshcore-open
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\windows\installer
OutputBaseFilename=MeshCore-Open-SOS-Voice-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
; The app keeps running in the tray: close it before replacing its files.
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startonlogin"; Description: "Start {#AppName} when I sign in (hidden in the tray, listening for SOS alerts)"; GroupDescription: "Background:"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelId}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Start on sign-in, chosen here or later in the app's settings (same value).
Root: HKCU; Subkey: "{#RunKey}"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExe}"" --hidden"; Tasks: startonlogin
; Removed on uninstall however it was set. ValueType none creates nothing.
Root: HKCU; Subkey: "{#RunKey}"; ValueType: none; ValueName: "{#AppName}"; Flags: uninsdeletevalue dontcreatekey
; Notification registration the app writes on first run.
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\{#AppUserModelId}"; ValueType: none; Flags: uninsdeletekey dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\{#AppUserModelId}"; ValueType: none; Flags: uninsdeletekey dontcreatekey

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Quit the copy running in the tray so its files can be removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "StopApp"

[Code]
// Messages, contacts and settings are kept by default, so reinstalling or
// updating carries on where it left off. Offer to delete them too.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and not UninstallSilent then
  begin
    if MsgBox('Also delete MeshCore Open SOS Voice''s messages, contacts and settings from this computer?'
        + #13#10#13#10 + 'Choose No to keep them for a later reinstall.',
        mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    begin
      DelTree(ExpandConstant('{userappdata}\com.meshcore\meshcore_open_sos_voice'), True, True, True);
      DelTree(ExpandConstant('{localappdata}\com.meshcore\meshcore_open_sos_voice'), True, True, True);
    end;
  end;
end;
