; FiveT for Windows - installer script (Inno Setup 6).
;
; Built by ..\build.ps1 -Installer, which passes the version, the architecture and the folder to package:
;   ISCC.exe /DAppVersion=1.3.0 /DArch=x64 /DSourceDir=..\dist /DOutputDir=..\release FiveT.iss
;   ISCC.exe /DAppVersion=1.3.0 /DArch=arm64 /DSourceDir=..\dist-arm64 /DOutputDir=..\release FiveT.iss
; (x64 is what runs on every 64-bit PC; arm64 is the native build for Snapdragon PCs, FiveT-Setup-<ver>-arm64.exe.)
;
; What the user gets: one FiveT-Setup-<version>.exe. Double-click, accept the UAC prompt, and the
; app is in Program Files with a Start Menu entry, an Add/Remove Programs entry, and (by default) a
; logon task so every later start is elevated without a prompt. The same file installs a new version
; over an existing copy, keeping the connections in %LOCALAPPDATA%\FiveT.

#define AppName "FiveT"
#define AppPublisher "FiveT"
#define AppUrl "https://github.com/FiveT-Gate/FiveT"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist"
#endif
#ifndef OutputDir
  #define OutputDir "..\release"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#if Arch == "arm64"
  #define ArchSuffix "-arm64"
#else
  #define ArchSuffix ""
#endif

[Setup]
; Never change AppId: it is how Windows recognises an existing FiveT and upgrades it in place.
AppId={{916DEEA9-C522-4137-A722-08D587F4AE6F}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppCopyright=(c) 2026 FiveT
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\FiveT
DefaultGroupName=FiveT
UninstallDisplayName={#AppName} {#AppVersion}
UninstallDisplayIcon={app}\FiveT.exe
OutputDir={#OutputDir}
OutputBaseFilename=FiveT-Setup-{#AppVersion}{#ArchSuffix}
SetupIconFile=..\src\FiveT\Resources\AppIcon.ico

; FiveT.exe runs elevated (it creates the tunnel adapter, routes and NRPT rules), so Program Files
; must not be writable by standard users: this is a per-machine install and setup needs admin.
PrivilegesRequired=admin
; (PrivilegesRequiredOverridesAllowed is left unset, so /CURRENTUSER cannot downgrade the install.)
#if Arch == "arm64"
; The native build: only for ARM PCs.
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; x64 also installs on an ARM PC (Windows emulates it), see InitializeSetup below.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0.17763

; Least fuss: no welcome page, no directory page, no "ready to install" page. The only thing the
; user is asked is the two checkboxes under [Tasks], and on an update even those are remembered.
WizardStyle=modern
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes

; The folder is ~160 MB of mostly compressible .NET and WinUI assemblies; lzma2/max with solid
; compression takes the download to roughly a third of that.
Compression=lzma2/max
SolidCompression=yes
LZMANumBlockThreads=4

; Local\FiveT.tray is the single-instance mutex in Program.cs. Setup and the uninstaller use it to
; notice a running copy and ask for it to be closed instead of failing on a locked FiveT.exe.
AppMutex=Local\FiveT.tray
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "logintask"; Description: "Start FiveT when I sign in (as administrator, with no UAC prompt)"
Name: "desktopicon"; Description: "Create a shortcut on the desktop"; Flags: unchecked

[Files]
; The whole published folder: FiveT.exe, fivetctl.exe, the .NET runtime and the Windows App SDK.
; build.ps1 puts OpenConnect in dist\openconnect\ (Setup.CandidatePaths looks there first), so the
; setup file brings its own VPN engine and the user installs nothing else, like the Mac app's
; built-in openfortivpn.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\FiveT"; Filename: "{app}\FiveT.exe"; Comment: "FiveT - FortiGate SSL-VPN"
Name: "{autodesktop}\FiveT"; Filename: "{app}\FiveT.exe"; Comment: "FiveT - FortiGate SSL-VPN"; Tasks: desktopicon

[Run]
; Registers the logon task through the app itself (Program.cs --install-login-task), so setup and
; Settings -> General create exactly the same task. Runs under /VERYSILENT too, so a scripted
; install still ends up with the task pointing at the new copy.
Filename: "{app}\FiveT.exe"; Parameters: "--install-login-task"; StatusMsg: "Registering the logon task..."; Flags: runhidden waituntilterminated; Tasks: logintask
; Offered at the end of a normal install; skipped under /VERYSILENT, where nothing should pop up.
Filename: "{app}\FiveT.exe"; Description: "Start FiveT now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Runs while FiveT.exe is still on disk. Leaving the task behind would make Windows try to start a
; program that no longer exists at every sign-in. The same call removes the fivet:// link
; registration the app made for the user (HKCU\Software\Classes\fivet).
Filename: "{app}\FiveT.exe"; Parameters: "--remove-login-task"; RunOnceId: "RemoveLoginTask"; Flags: runhidden waituntilterminated

[UninstallDelete]
; Written next to the exe at run time (compiled XAML caches), so setup does not know about them.
Type: filesandordirs; Name: "{app}"

[Code]
{ Inno only adds files, so an upgrade over a folder from build.ps1 -Install (or from a release before
  1.2.2) would keep that copy's whole payload forever: the 89 language folders and the Windows AI
  runtime this build no longer ships, leaving ~295 MB on disk instead of ~162 MB. Clear the old files
  before the new ones are copied. Two things are kept: the uninstaller, which setup is still using,
  and any openconnect\ someone put there by hand - when it was packaged instead, [Files] restores it.
  Nothing here touches %LOCALAPPDATA%\FiveT, so connections and the log are never at risk. }
procedure CleanProgramFolder;
var
  FindRec: TFindRec;
  Base, Name: String;
begin
  Base := ExpandConstant('{app}');
  if not DirExists(Base) then
    Exit;
  if FindFirst(Base + '\*', FindRec) then
  try
    repeat
      Name := FindRec.Name;
      if (Name = '.') or (Name = '..') then
        Continue;
      if CompareText(Copy(Name, 1, 5), 'unins') = 0 then
        Continue;
      if CompareText(Name, 'openconnect') = 0 then
        Continue;
      if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        DelTree(Base + '\' + Name, True, True, True)
      else
        DeleteFile(Base + '\' + Name);
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    CleanProgramFolder;
end;

{ The Intel/AMD build installs on an ARM PC too, but Windows has to translate every instruction of it:
  measured on a Snapdragon laptop it used about five times the memory and nine times the start-up CPU of
  the native build. Say so once in an interactive setup (a silent one never asks). }
function InitializeSetup(): Boolean;
begin
  Result := True;
#if Arch == "x64"
  if IsArm64 and not WizardSilent then
    Result := MsgBox('This PC has an ARM processor, and this setup is FiveT for Intel/AMD PCs. It works here, but Windows has to translate it, so it uses several times the memory and processor time of the ARM version.' + #13#10#13#10 +
                     'The ARM version is the file called FiveT-Setup-{#AppVersion}-arm64.exe. Install this one anyway?',
                     mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
#endif
end;
