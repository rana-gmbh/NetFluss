; NetFluss for Windows — installer.
;
; Built by windows/Packaging/build-release.ps1, which passes:
;   /DAppVersion=1.2.3      the version (from the win-vX.Y.Z tag; may be 1.2.3-beta.1)
;   /DNumericVersion=1.2.3  the same without a pre-release suffix
;   /DArch=x64|arm64        the architecture of the published files
;   /DSource=<folder>       the self-contained publish output (app + Helper\)
;
; Per-user and unprivileged, like dropping NetFluss.app into ~/Applications: it installs to
; %LOCALAPPDATA%\Programs\NetFluss and never asks for administrator rights. The optional
; helper service is the one part that needs them, and the app installs it on request.
; The exception is a copy in Program Files: Setup then restarts itself with administrator
; approval (see InitializeSetup).
; The same setup, run with /VERYSILENT /LAUNCH, is what the in-app updater uses.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
; The file-version resource takes numbers only: 2.6.0 for a 2.6.0-beta.1 setup.
#ifndef NumericVersion
  #define NumericVersion AppVersion
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef Source
  #define Source "..\artifacts\publish\" + Arch
#endif

[Setup]
AppId={{6F3C9A41-2E7B-4D58-9C1A-5B0E8D2F7A13}
AppName=NetFluss
AppVersion={#AppVersion}
AppVerName=NetFluss {#AppVersion}
AppPublisher=Rana GmbH
AppPublisherURL=https://github.com/rana-gmbh/NetFluss
AppSupportURL=https://github.com/rana-gmbh/NetFluss/issues
AppUpdatesURL=https://github.com/rana-gmbh/NetFluss/releases
DefaultDirName={localappdata}\Programs\NetFluss
DisableDirPage=auto
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\artifacts\release
OutputBaseFilename=NetFluss-Setup-{#AppVersion}-{#Arch}
SetupIconFile=..\src\NetFluss.App\Assets\NetFluss.ico
UninstallDisplayIcon={app}\NetFluss.exe
UninstallDisplayName=NetFluss
LicenseFile=..\..\LICENSE
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; The app is a tray app; Restart Manager can miss it, so [Code] also asks it to quit.
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#NumericVersion}
; The full version (2.6.0-beta.1) as product and file version text, as NetFluss.exe and the
; helper carry it: code signing checks that every signed file names the same product version.
VersionInfoTextVersion={#AppVersion}
VersionInfoProductVersion={#NumericVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoCompany=Rana GmbH
VersionInfoProductName=NetFluss
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0.19041

[Languages]
; The privacy page comes before the installation, because the app contacts services on its
; own; the tasks page then lets the user switch them off.
Name: "english"; MessagesFile: "compiler:Default.isl"; InfoBeforeFile: "privacy.txt"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"; InfoBeforeFile: "privacy.de.txt"

[CustomMessages]
english.AutoStart=Start NetFluss when I sign in
german.AutoStart=NetFluss bei der Anmeldung starten
english.LaunchNow=Launch NetFluss
german.LaunchNow=NetFluss starten
english.Privacy=Privacy:
german.Privacy=Datenschutz:
english.UpdateCheck=Check for updates once a day (GitHub)
german.UpdateCheck=Einmal täglich nach Updates suchen (GitHub)
english.IpLookups=Look up public IP addresses and countries (ipify, ipwho.is, country.is)
german.IpLookups=Öffentliche IP-Adressen und Länder abfragen (ipify, ipwho.is, country.is)
english.NeedsAdmin=NetFluss is installed in %1, which only administrators can change, so updating it needs administrator approval.
german.NeedsAdmin=NetFluss ist in %1 installiert, das nur Administratoren ändern können. Zum Aktualisieren ist daher die Zustimmung eines Administrators nötig.
english.FolderNeedsAdmin=Only administrators can install into %1. Restart Setup with administrator approval?%n%nChoose No to pick another folder.
german.FolderNeedsAdmin=In %1 können nur Administratoren installieren. Setup mit Zustimmung eines Administrators neu starten?%n%nWählen Sie „Nein“, um einen anderen Ordner auszuwählen.
english.HelperNotMoved=NetFluss was updated, but its helper could not be moved to its new folder (error %1). Install the helper again in NetFluss's settings.
german.HelperNotMoved=NetFluss wurde aktualisiert, aber der Helfer konnte nicht in seinen neuen Ordner verschoben werden (Fehler %1). Installieren Sie den Helfer in den Einstellungen von NetFluss erneut.
english.HelperFolder=This folder belongs to the NetFluss helper. Choose another folder for NetFluss.
german.HelperFolder=Dieser Ordner gehört zum NetFluss-Helfer. Wählen Sie einen anderen Ordner für NetFluss.

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"
Name: "updatecheck"; Description: "{cm:UpdateCheck}"; GroupDescription: "{cm:Privacy}"
Name: "iplookups"; Description: "{cm:IpLookups}"; GroupDescription: "{cm:Privacy}"

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\NetFluss"; Filename: "{app}\NetFluss.exe"

[Registry]
; The same value the app's own "Start with Windows" switch writes, so the two agree.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "NetFluss"; ValueData: """{app}\NetFluss.exe"""; Tasks: autostart; Flags: uninsdeletevalue
; The privacy choices, read once by NetFluss at its next start and then removed. Only from an
; interactive installation: an in-app update runs silently and must not undo a change made
; in Preferences since.
Root: HKCU; Subkey: "Software\NetFluss\InstallerChoices"; ValueType: dword; ValueName: "AutomaticUpdateChecks"; ValueData: "1"; Tasks: updatecheck; Check: not WizardSilent; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\NetFluss\InstallerChoices"; ValueType: dword; ValueName: "AutomaticUpdateChecks"; ValueData: "0"; Tasks: not updatecheck; Check: not WizardSilent; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\NetFluss\InstallerChoices"; ValueType: dword; ValueName: "AllowIpLookups"; ValueData: "1"; Tasks: iplookups; Check: not WizardSilent; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\NetFluss\InstallerChoices"; ValueType: dword; ValueName: "AllowIpLookups"; ValueData: "0"; Tasks: not iplookups; Check: not WizardSilent; Flags: uninsdeletekey

[Run]
; A Setup run as administrator (an install in Program Files) must not start NetFluss
; elevated. runasoriginaluser cannot help there: Setup never elevates itself through Inno
; Setup (PrivilegesRequired=lowest), so its "original user" is the elevated one too. Explorer
; hands the start to the signed-in user's own, unelevated shell.
Filename: "{app}\NetFluss.exe"; Description: "{cm:LaunchNow}"; Flags: nowait postinstall skipifsilent; Check: not IsAdmin
Filename: "{win}\explorer.exe"; Parameters: """{app}\NetFluss.exe"""; Description: "{cm:LaunchNow}"; Flags: nowait postinstall skipifsilent; Check: IsAdmin
; An in-app update runs silently and asks to be relaunched.
Filename: "{app}\NetFluss.exe"; Flags: nowait; Check: LaunchAfterSilentUpdate and not IsAdmin
Filename: "{win}\explorer.exe"; Parameters: """{app}\NetFluss.exe"""; Flags: nowait; Check: LaunchAfterSilentUpdate and IsAdmin

[UninstallRun]
; The helper is a machine-wide service; removing it needs one administrator approval.
Filename: "{app}\Helper\NetFluss.Service.exe"; Parameters: "uninstall"; Verb: "runas"; Flags: shellexec waituntilterminated; Check: HelperInstalled; RunOnceId: "RemoveHelper"

[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F3C9A41-2E7B-4D58-9C1A-5B0E8D2F7A13}_is1';
  // Marks a Setup this script restarted elevated, so it never restarts again.
  ElevatedParam = '/NETFLUSSELEVATED';
  // Also marks that the user already went through the license and privacy pages.
  AcceptedParam = '/NETFLUSSACCEPTED';

var
  // The helper service ran from the app's own Helper folder (issue #70): moved once the files are in.
  MoveHelper: Boolean;
  // Set when this Setup handed over to an elevated one and closes without asking.
  HandedOver: Boolean;

function HelperInstalled: Boolean;
begin
  Result := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\NetFlussHelper');
end;

function LaunchAfterSilentUpdate: Boolean;
begin
  Result := WizardSilent and (Pos('/LAUNCH', UpperCase(GetCmdTail)) > 0);
end;

function SameOrInside(Path, Folder: String): Boolean;
begin
  Path := Lowercase(RemoveBackslashUnlessRoot(Path));
  Folder := Lowercase(RemoveBackslashUnlessRoot(Folder));
  Result := (Path = Folder) or (Pos(AddBackslash(Folder), Path) = 1);
end;

{ Up to 2.7.2-beta.2 the helper service ran from Program Files\NetFluss\Helper. Whoever
  installed NetFluss itself into Program Files\NetFluss shares that folder with it, and Setup
  cannot replace the executable of a running service. }
function HelperRunsFromApp: Boolean;
var
  ImagePath: String;
begin
  Result := False;
  if RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Services\NetFlussHelper', 'ImagePath', ImagePath) then
  begin
    ImagePath := RemoveQuotes(Trim(ImagePath));
    Result := (ImagePath <> '') and SameOrInside(ExtractFileDir(ImagePath), ExpandConstant('{app}'));
  end;
end;

// Program Files, or any folder only administrators may change.
function NeedsAdminFor(Dir: String): Boolean;
begin
  Result := (Dir <> '')
    and (SameOrInside(Dir, ExpandConstant('{commonpf}')) or SameOrInside(Dir, ExpandConstant('{commonpf32}')));
end;

function AppNeedsAdmin: Boolean;
begin
  Result := NeedsAdminFor(ExpandConstant('{app}'));
end;

function HasParam(Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), Name) = 0 then
      Result := True;
end;

function StartsWithText(S, Prefix: String): Boolean;
begin
  Result := CompareText(Copy(S, 1, Length(Prefix)), Prefix) = 0;
end;

// Starts this same setup file again with administrator approval, into Dir, with the
// parameters it was given (an in-app update's /VERYSILENT /LAUNCH among them). False when the
// user declined or Windows could not start it.
function RestartElevated(Dir: String; Accepted: Boolean): Boolean;
var
  Params, S: String;
  I, ErrorCode: Integer;
begin
  // /DIR names the folder outright: an administrator other than the signed-in user would
  // otherwise get their own previous folder, or the default one.
  Params := ElevatedParam + ' /LANG=' + ActiveLanguage + ' /DIR=' + AddQuotes(Dir);
  if Accepted then
    Params := Params + ' ' + AcceptedParam;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    // /SL5, /SPAWNWND and /NOTIFYWND belong to this run of Setup's loader, not the next.
    if not (StartsWithText(S, '/SL5=') or StartsWithText(S, '/SPAWNWND=') or StartsWithText(S, '/NOTIFYWND=')
      or StartsWithText(S, '/LANG=') or StartsWithText(S, '/DIR=')) then
      Params := Params + ' ' + AddQuotes(S);
  end;

  Result := ShellExec('runas', ExpandConstant('{srcexe}'), Params, '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
  Log(Format('Restarting elevated into %s: %d (%d)', [Dir, Ord(Result), ErrorCode]));
end;

// An update of a copy in Program Files: ask for administrator approval right away, before
// any page, rather than failing at the end of the wizard.
function InitializeSetup: Boolean;
var
  Dir: String;
begin
  Result := True;
  if IsAdmin or HasParam(ElevatedParam) then
    Exit;
  if not RegQueryStringValue(HKCU, UninstallKey, 'Inno Setup: App Path', Dir) or not NeedsAdminFor(Dir) then
    Exit;

  if not RestartElevated(Dir, False) then
    SuppressibleMsgBox(FmtMessage(CustomMessage('NeedsAdmin'), [Dir]), mbError, MB_OK, IDOK);
  Result := False;
end;

// After a restart from the folder page the user has seen these already.
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = wpLicense) or (PageID = wpInfoBefore)) and HasParam(AcceptedParam);
end;

{ Asks a running NetFluss to quit cleanly — it saves statistics and the timer on the way
  out — and only then forces the issue. }
procedure StopNetFluss;
var
  ResultCode: Integer;
begin
  if FileExists(ExpandConstant('{app}\NetFluss.exe')) then
  begin
    Exec(ExpandConstant('{app}\NetFluss.exe'), '--quit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(2500);
  end;
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM NetFluss.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  MoveHelper := HelperRunsFromApp;

  { Fail here, before a file is touched, rather than halfway through copying. Only when the
    restart with administrator approval did not happen. }
  if (MoveHelper or AppNeedsAdmin) and not IsAdmin then
  begin
    Result := FmtMessage(CustomMessage('NeedsAdmin'), [ExpandConstant('{app}')]);
    Exit;
  end;

  StopNetFluss;

  if MoveHelper then
  begin
    { net stop waits until the service has stopped; a stop through the service manager does
      not trigger the restart-on-failure actions. }
    Log('The helper runs from the app folder; stopping it.');
    Exec(ExpandConstant('{sys}\net.exe'), 'stop NetFlussHelper', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Log(Format('net stop NetFlussHelper: %d', [ResultCode]));
    Sleep(1000);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep <> ssPostInstall) or not MoveHelper then
    Exit;

  { The new helper's own installer copies it into Program Files\NetFluss Helper, registers
    it there and starts it. Setup already runs as administrator, so no second prompt. }
  if Exec(ExpandConstant('{app}\Helper\NetFluss.Service.exe'), 'install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
  begin
    Log('The helper moved to its own folder.');
    Exit;
  end;

  Log(Format('Moving the helper failed: %d', [ResultCode]));
  { Leave it running from where it was, if it is still registered there. }
  Exec(ExpandConstant('{sys}\net.exe'), 'start NetFlussHelper', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  SuppressibleMsgBox(FmtMessage(CustomMessage('HelperNotMoved'), [IntToStr(ResultCode)]), mbError, MB_OK, IDOK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    Exit;

  if SameOrInside(WizardDirValue, ExpandConstant('{commonpf}\NetFluss Helper')) then
  begin
    MsgBox(CustomMessage('HelperFolder'), mbError, MB_OK);
    Result := False;
    Exit;
  end;

  // A new installation into Program Files: carry on in an elevated Setup, on the same folder.
  if NeedsAdminFor(WizardDirValue) and not IsAdmin then
  begin
    Result := False;
    if MsgBox(FmtMessage(CustomMessage('FolderNeedsAdmin'), [WizardDirValue]), mbConfirmation, MB_YESNO) = IDYES then
      if RestartElevated(WizardDirValue, True) then
      begin
        HandedOver := True;
        WizardForm.Close;
      end;
  end;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if HandedOver then
    Confirm := False;
end;

function InitializeUninstall: Boolean;
begin
  StopNetFluss;
  Result := True;
end;
