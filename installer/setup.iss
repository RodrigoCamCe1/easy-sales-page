; EasyExpert - Inno Setup Script
; Generates a Windows installer for the Flutter desktop app

#define MyAppName "EasyExpert"
#define MyAppVersion "1.4.9"
#define MyAppPublisher "EasySales IA"
#define MyAppExeName "EasyExpert.exe"

[Setup]
AppId={{B8F2A3D1-4E5C-6F7A-8B9C-0D1E2F3A4B5C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=..\dist
OutputBaseFilename=EasyExpert-Setup-{#MyAppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
CloseApplications=force
RestartApplications=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs
Source: "bundled\ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "bundled\audio_sniffer-x64.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Crear acceso directo en el escritorio"

[Run]
; Register virtual audio capturer for system audio loopback
Filename: "regsvr32"; Parameters: "/s ""{app}\audio_sniffer-x64.dll"""; Flags: runhidden; StatusMsg: "Registrando captura de audio virtual..."
Filename: "{app}\{#MyAppExeName}"; Description: "Iniciar {#MyAppName}"; Flags: nowait postinstall

[UninstallRun]
Filename: "regsvr32"; Parameters: "/u /s ""{app}\audio_sniffer-x64.dll"""; Flags: runhidden
