<#
===============================================================================
  rdp sesin menicir  -  lightweight RDS session, process and performance manager
  belesware  /  fikired by ugur.es

  A single-file replacement for Task Manager on Remote Desktop Session Hosts
  (Windows Server 2016 / 2019 / 2022). No external dependencies, no modules,
  no installer. Just a .ps1 file.

  WHY NOT TASK MANAGER
    Task Manager freezes on a busy RDSH because of the APIs it calls, not the
    amount of data. This tool deliberately avoids every one of them:

      Responding        -> SendMessageTimeout, blocks 5s on every hung window
      MainWindowTitle   -> cross-session desktop enumeration, blocks
      -IncludeUserName  -> OpenProcessToken per process
      Win32_Process     -> WMI enumeration, hangs when the provider is sick
      Path/Company/Ver  -> opens the EXE on disk, I/O per process
      Modules / icons   -> full DLL list and file reads, the most expensive
      AD / LDAP lookup  -> one DC query per session

    What it uses instead:
      NtQuerySystemInformation    -> one call: name, session, RAM, handles,
                                     threads and CPU time for every process
      WTSEnumerateSessions        -> one call, locale independent
      WTSQuerySessionInformation  -> per session, and TIMED (see below)
      Win32_PerfFormattedData_*   -> single-instance counters, ~20 ms total

  STUCK SESSION DETECTION
    WTSQuerySessionInformation is exactly the call that blocks on a broken
    session - the same thing that freezes Task Manager. Each session's query
    is timed separately, so the tool points at the session responsible
    instead of just hanging with it.

  TWO SAMPLING LOOPS
    Performance panel : cheap counters, every 2s
    Sessions/processes: heavier enumeration, manual or every 10/30s
    Both run in background runspaces; the UI thread never blocks.

  USAGE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\RdpSesinMenicir.ps1

    Run as Administrator. Without elevation you cannot message, log off or
    reset other users' sessions; the tool offers to restart elevated and
    shows "limited rights" if you decline.

  NOTE FOR CONTRIBUTORS
    .NET types cannot be unloaded from a PowerShell session. The C# block
    carries a Build constant that must match $AppVersion - bump both together
    or the tool refuses to start in a session holding an older build.
===============================================================================
#>

#requires -version 5.1

$ErrorActionPreference = 'Stop'

[string]$AppName    = 'rdp sesin menicir'
[string]$AppVersion = '1.3.1'

[int]$EnumTimeoutSeconds = 6      # session/process enumeration timeout
[int]$PerfTimeoutSeconds = 8      # performance counter timeout
[int]$HistoryPoints      = 30     # 30 samples x 2s = 60s of sparkline
[int]$SlowQueryMs        = 1000   # session slower than this = stuck candidate
[int]$DiskWarnMs         = 20     # disk latency warning threshold

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
# Settings (read early - the UI language comes from here)
# ============================================================================
$script:SettingsPath = Join-Path $env:APPDATA 'belesware\rdp-sesin-menicir\settings.json'

function Read-Settings {
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            return (Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    } catch { }
    return $null
}

$script:Config = Read-Settings

# ============================================================================
# Localization
# ============================================================================
# NOTE: keep this file ASCII-only. PowerShell 5.1 reads a UTF-8 file without
# a BOM as ANSI, which mangles non-ASCII characters. Save as "UTF-8 with BOM"
# if you want to use accented text.
$script:Str = @{

    en = @{
        'app.limited'      = 'limited rights'
        'btn.refresh'      = 'Refresh'
        'btn.hidePanel'    = 'Hide panel'
        'btn.showPanel'    = 'Show panel'
        'btn.csv'          = 'CSV'
        'btn.msg'          = 'Notify'
        'btn.disc'         = 'Disconnect'
        'btn.logoff'       = 'Log off'
        'btn.kill'         = 'End task'
        'btn.reset'        = 'Force reset'
        'auto.0'           = 'auto: off'
        'auto.1'           = 'auto: 10s'
        'auto.2'           = 'auto: 30s'
        'find.hint'        = 'Search  (Ctrl+F)'
        'kpi.active'       = 'active'
        'kpi.disc'         = 'disconnected'
        'kpi.ram'          = 'total ram'
        'kpi.stuck'        = 'stuck candidates'
        'perf.header'      = 'performance  -  last 60s'
        'perf.cpu'         = 'cpu'
        'perf.mem'         = 'memory'
        'perf.disk'        = 'disk C:'
        'perf.net'         = 'network'
        'perf.kernel'      = 'kernel {0}%'
        'perf.free'        = '{0}%  -  {1} GB free'
        'perf.queue'       = 'queue {0}  -  threshold {1} ms'
        'perf.io'          = 'in {0}  out {1}  -  {2}'
        'perf.delayed'     = 'counter delayed, showing last value'
        'info.server'      = 'server'
        'info.uptime'      = 'uptime'
        'info.handles'     = 'total handles'
        'info.threads'     = 'total threads'
        'info.uptimeFmt'   = '{0}d {1}h'
        'sess.header'      = 'sessions  -  {0} sessions, {1} processes'
        'proc.header'      = 'processes  -  {0}   (session {1})   -   {2} processes'
        'proc.none'        = 'processes  -  select a session above'
        'col.id'           = 'id'
        'col.user'         = 'user'
        'col.session'      = 'session'
        'col.state'        = 'state'
        'col.idle'         = 'idle min'
        'col.logon'        = 'logon'
        'col.proc'         = 'proc'
        'col.cpu'          = 'cpu %'
        'col.ram'          = 'ram (mb)'
        'col.ramDelta'     = 'ram delta'
        'col.query'        = 'query ms'
        'col.note'         = 'note'
        'col.pid'          = 'pid'
        'col.name'         = 'name'
        'col.handle'       = 'handles'
        'col.handleDelta'  = 'handle delta'
        'col.thread'       = 'threads'
        'col.protected'    = 'protected'
        'val.yes'          = 'yes'
        'note.slow'        = 'slow response ({0} ms) - stuck candidate'
        'note.state'       = 'state: {0}'
        'note.noproc'      = 'no processes - possibly stuck'
        'menu.msg'         = 'Send notification'
        'menu.disc'        = 'Disconnect'
        'menu.logoff'      = 'Log off'
        'menu.reset'       = 'Force reset (rwinsta)'
        'menu.shadow'      = 'Shadow this session'
        'menu.copyUser'    = 'Copy user name'
        'menu.copyId'      = 'Copy session ID'
        'menu.kill'        = 'End task'
        'menu.copyPid'     = 'Copy PID'
        'menu.copyName'    = 'Copy process name'
        'dlg.noSelTitle'   = 'Nothing selected'
        'dlg.noSel'        = 'Select a session first.'
        'dlg.noProcSel'    = 'Select a process first.'
        'dlg.andMore'      = '   ... and {0} more'
        'dlg.msgTitle'     = 'Send notification'
        'dlg.msgOne'       = "{0}`n`nSend the notification?"
        'dlg.msgMany'      = "{0} sessions:`n`n{1}`n`nSend the notification?"
        'dlg.msgOffline'   = "`n`nNOTE: {0} session(s) are not Active, nobody will see the message."
        'dlg.discTitle'    = 'Disconnect'
        'dlg.discOne'      = "{0}`n`nDisconnect? Processes keep running."
        'dlg.discMany'     = "{0} sessions:`n`n{1}`n`nDisconnect? Processes keep running."
        'dlg.logoffTitle'  = 'Log off - cannot be undone'
        'dlg.logoffOne'    = "{0}`n`nLog this session off now?"
        'dlg.logoffMany'   = "{0} sessions:`n`n{1}`n`nLog these sessions off now?"
        'dlg.resetMultiT'  = 'No bulk reset'
        'dlg.resetMulti'   = 'Force reset applies to one session at a time. Select a single row.'
        'dlg.resetT1'      = 'Force reset 1/2'
        'dlg.resetB1'      = "{0}`n`nForce reset (rwinsta) destroys the session at kernel level.`nUse it only when a normal log off does not complete.`n`nHave you tried Log off first?"
        'dlg.resetT2'      = 'Force reset 2/2'
        'dlg.resetB2'      = "FINAL CONFIRMATION`n`nTarget : session {0} - {1}`nAction : rwinsta {0}`n`nAll unsaved data is lost and the profile may not unload cleanly.`nTHIS CANNOT BE UNDONE.`n`nAre you sure?"
        'dlg.killTitle'    = 'End task - cannot be undone'
        'dlg.killBody'     = "Process : {0}  (PID {1})`nSession : {2} - {3}`n`nThe process will be terminated. Unsaved data in that application is lost and this CANNOT BE UNDONE.`n`nContinue?"
        'dlg.protectedT'   = 'Blocked'
        'dlg.protected'    = '{0} is a protected system process. Ending it would break the session or the server.'
        'status.refresh'   = 'refreshing...'
        'status.refreshS'  = 'refreshing... session {0} ({1:n1}s)'
        'status.updated'   = 'updated {0}  -  {1} ms'
        'status.stuck'     = 'STUCK SESSION {0} - no response for {1}s'
        'status.stuckStg'  = 'enumeration stalled ({0}s, {1})'
        'status.msgSent'   = 'notification sent to {0} / {1} sessions'
        'status.msgFail'   = '{0} / {1} sent, {2} failed'
        'status.disc'      = '{0} session(s) disconnected'
        'status.logoff'    = 'log off sent to {0} session(s)'
        'status.killed'    = '{0} (PID {1}) terminated'
        'status.reset'     = 'session {0}: rwinsta executed'
        'status.csv'       = 'CSV written'
        'err.msgTitle'     = 'Notification failed'
        'err.discTitle'    = 'Disconnect failed'
        'err.logoffTitle'  = 'Log off failed'
        'err.killTitle'    = 'Could not end task'
        'err.csvTitle'     = 'CSV error'
        'err.shadowTitle'  = 'Shadow failed'
        'err.resetTitle'   = 'rwinsta error'
        'err.failedList'   = "Sessions that failed:`n`n{0}{1}"
        'err.accessDenied' = "`n`nError 5 = access denied. Run the tool as Administrator."
        'admin.title'      = 'Administrator rights'
        'admin.question'   = "Without administrator rights you cannot notify, log off or reset other users' sessions.`n`nRestart as administrator?"
        'admin.failed'     = "Could not elevate, continuing with limited rights.`n`n{0}"
        'warn.typeTitle'   = 'Restart required'
        'warn.type'        = "A different version ({0}) of this tool is already loaded into this PowerShell session, and .NET types cannot be unloaded.`n`nPlease open a NEW PowerShell window and try again."
        'msg.notify'       = 'Your session will be closed. Please save your work.'
        'msg.notifyTitle'  = 'System notification'
        'tip.refresh'      = 'Refresh the session and process list now  (F5)'
        'tip.auto'         = 'Automatic refresh interval. Skipped while several sessions are selected. CPU %% is the average between two refreshes.'
        'tip.find'         = 'Filter by user, session or process name  (Ctrl+F)'
        'tip.perf'         = 'Hides the performance panel and stops collecting counters'
        'tip.csv'          = 'Save the session list as a CSV file'
        'tip.lang'         = 'Interface language'
        'tip.msg'          = 'Sends a message to the selected sessions. No data loss.'
        'tip.disc'         = 'Disconnects the session. Processes keep running and the user resumes where they left off.'
        'tip.logoff'       = 'Logs the session off cleanly. Unsaved data is lost and this cannot be undone.'
        'tip.kill'         = 'Terminates the selected process. Unsaved data in that application is lost.'
        'tip.reset'        = 'rwinsta - destroys the session at kernel level. Last resort, only when Log off hangs.'
    }

    tr = @{
        'app.limited'      = 'sinirli yetki'
        'btn.refresh'      = 'Yenile'
        'btn.hidePanel'    = 'Paneli gizle'
        'btn.showPanel'    = 'Paneli goster'
        'btn.csv'          = 'CSV'
        'btn.msg'          = 'Uyari'
        'btn.disc'         = 'Disconnect'
        'btn.logoff'       = 'Log off'
        'btn.kill'         = 'Sonlandir'
        'btn.reset'        = 'Zorla reset'
        'auto.0'           = 'otomatik: kapali'
        'auto.1'           = 'otomatik: 10 sn'
        'auto.2'           = 'otomatik: 30 sn'
        'find.hint'        = 'Ara  (Ctrl+F)'
        'kpi.active'       = 'aktif'
        'kpi.disc'         = 'disconnected'
        'kpi.ram'          = 'toplam ram'
        'kpi.stuck'        = 'takilma adayi'
        'perf.header'      = 'performans  -  son 60 sn'
        'perf.cpu'         = 'cpu'
        'perf.mem'         = 'bellek'
        'perf.disk'        = 'disk C:'
        'perf.net'         = 'ag'
        'perf.kernel'      = 'kernel {0}%'
        'perf.free'        = '%{0}  -  {1} GB bos'
        'perf.queue'       = 'kuyruk {0}  -  esik {1} ms'
        'perf.io'          = 'in {0}  out {1}  -  {2}'
        'perf.delayed'     = 'sayac gecikti, son deger gosteriliyor'
        'info.server'      = 'sunucu'
        'info.uptime'      = 'uptime'
        'info.handles'     = 'toplam handle'
        'info.threads'     = 'toplam thread'
        'info.uptimeFmt'   = '{0} gun {1} sa'
        'sess.header'      = 'oturumlar  -  {0} oturum, {1} process'
        'proc.header'      = 'process  -  {0}   (session {1})   -   {2} process'
        'proc.none'        = 'process  -  yukaridan bir oturum secin'
        'col.id'           = 'id'
        'col.user'         = 'kullanici'
        'col.session'      = 'oturum'
        'col.state'        = 'durum'
        'col.idle'         = 'bosta dk'
        'col.logon'        = 'giris'
        'col.proc'         = 'proc'
        'col.cpu'          = 'cpu %'
        'col.ram'          = 'ram (mb)'
        'col.ramDelta'     = 'ram fark'
        'col.query'        = 'sorgu ms'
        'col.note'         = 'not'
        'col.pid'          = 'pid'
        'col.name'         = 'ad'
        'col.handle'       = 'handle'
        'col.handleDelta'  = 'handle fark'
        'col.thread'       = 'thread'
        'col.protected'    = 'korumali'
        'val.yes'          = 'evet'
        'note.slow'        = 'yavas yanit ({0} ms) - takilma adayi'
        'note.state'       = 'durum: {0}'
        'note.noproc'      = 'process yok - takilmis olabilir'
        'menu.msg'         = 'Uyari gonder'
        'menu.disc'        = 'Disconnect'
        'menu.logoff'      = 'Log off'
        'menu.reset'       = 'Zorla reset (rwinsta)'
        'menu.shadow'      = 'Shadow ile izle'
        'menu.copyUser'    = 'Kullanici adini kopyala'
        'menu.copyId'      = 'Session ID kopyala'
        'menu.kill'        = 'Process sonlandir'
        'menu.copyPid'     = 'PID kopyala'
        'menu.copyName'    = 'Process adini kopyala'
        'dlg.noSelTitle'   = 'Secim yok'
        'dlg.noSel'        = 'Once bir oturum secin.'
        'dlg.noProcSel'    = 'Once bir process secin.'
        'dlg.andMore'      = '   ... ve {0} tane daha'
        'dlg.msgTitle'     = 'Uyari gonder'
        'dlg.msgOne'       = "{0}`n`nUyari gonderilsin mi?"
        'dlg.msgMany'      = "{0} oturum:`n`n{1}`n`nUyari gonderilsin mi?"
        'dlg.msgOffline'   = "`n`nNOT: {0} oturum Active degil, mesaji kimse gormez."
        'dlg.discTitle'    = 'Disconnect'
        'dlg.discOne'      = "{0}`n`nBaglanti kesilecek, process'ler ayakta kalir. Devam?"
        'dlg.discMany'     = "{0} oturum:`n`n{1}`n`nBaglantilar kesilecek, process'ler ayakta kalir. Devam?"
        'dlg.logoffTitle'  = 'Log off - geri alinamaz'
        'dlg.logoffOne'    = "{0}`n`nBaglantisi kesilecek simdi?"
        'dlg.logoffMany'   = "{0} oturum:`n`n{1}`n`nBaglantilari kesilecek simdi?"
        'dlg.resetMultiT'  = 'Toplu reset yok'
        'dlg.resetMulti'   = 'Zorla reset tek seferde tek oturuma uygulanir. Tek satir secin.'
        'dlg.resetT1'      = 'Zorla reset 1/2'
        'dlg.resetB1'      = "{0}`n`nZorla reset (rwinsta) oturumu kernel seviyesinde yok eder.`nSadece normal Log off tamamlanmadiginda kullanilmalidir.`n`nOnce Log off denendi mi?"
        'dlg.resetT2'      = 'Zorla reset 2/2'
        'dlg.resetB2'      = "SON ONAY`n`nHedef : session {0} - {1}`nIslem : rwinsta {0}`n`nTum kaydedilmemis veri kaybolur, profil duzgun unload edilmeyebilir.`nGERI ALMA YOKTUR.`n`nEmin misiniz?"
        'dlg.killTitle'    = 'Process sonlandir - geri alinamaz'
        'dlg.killBody'     = "Process : {0}  (PID {1})`nSession : {2} - {3}`n`nProcess zorla sonlandirilacak. Uygulamanin kaydedilmemis verisi kaybolur ve GERI ALMA YOKTUR.`n`nDevam edilsin mi?"
        'dlg.protectedT'   = 'Engellendi'
        'dlg.protected'    = "{0} korumali sistem process'i. Sonlandirilmasi oturumu veya sunucuyu cokertir."
        'status.refresh'   = 'yenileniyor...'
        'status.refreshS'  = 'yenileniyor... session {0} ({1:n1} sn)'
        'status.updated'   = 'guncellendi {0}  -  {1} ms'
        'status.stuck'     = 'TAKILI SESSION {0} - {1} sn yanit yok'
        'status.stuckStg'  = 'enumerate takildi ({0} sn, {1})'
        'status.msgSent'   = '{0} / {1} oturuma uyari gonderildi'
        'status.msgFail'   = '{0} / {1} gonderildi, {2} hata'
        'status.disc'      = '{0} oturum disconnect edildi'
        'status.logoff'    = '{0} oturuma log off gonderildi'
        'status.killed'    = '{0} (PID {1}) sonlandirildi'
        'status.reset'     = 'session {0}: rwinsta calistirildi'
        'status.csv'       = 'CSV yazildi'
        'err.msgTitle'     = 'Uyari gonderilemedi'
        'err.discTitle'    = 'Disconnect basarisiz'
        'err.logoffTitle'  = 'Log off basarisiz'
        'err.killTitle'    = 'Sonlandirilamadi'
        'err.csvTitle'     = 'CSV hatasi'
        'err.shadowTitle'  = 'Shadow hatasi'
        'err.resetTitle'   = 'rwinsta hatasi'
        'err.failedList'   = "Basarisiz oturumlar:`n`n{0}{1}"
        'err.accessDenied' = "`n`nHata 5 = erisim reddedildi. Araci Yonetici olarak calistirin."
        'admin.title'      = 'Yonetici yetkisi'
        'admin.question'   = "Yonetici yetkisi olmadan baska kullanicilarin oturumlarina mesaj gonderemez, log off veya reset yapamazsiniz.`n`nYonetici olarak yeniden baslatilsin mi?"
        'admin.failed'     = "Yukseltme yapilamadi, sinirli yetkiyle devam ediliyor.`n`n{0}"
        'warn.typeTitle'   = 'Yeniden baslatma gerekli'
        'warn.type'        = "Bu PowerShell oturumuna aracin farkli bir surumu ({0}) yuklenmis ve .NET tipleri kaldirilamiyor.`n`nLutfen YENI bir PowerShell penceresi acip tekrar deneyin."
        'msg.notify'       = 'Oturumunuz kapatilacaktir, lutfen calismalarinizi kaydediniz.'
        'msg.notifyTitle'  = 'Sistem Uyarisi'
        'tip.refresh'      = 'Oturum ve process listesini simdi yenile  (F5)'
        'tip.auto'         = 'Otomatik yenileme araligi. Birden fazla oturum seciliyken atlanir. CPU %% iki yenileme arasindaki ortalamadir.'
        'tip.find'         = 'Kullanici, oturum veya process adina gore filtrele  (Ctrl+F)'
        'tip.perf'         = 'Performans panelini gizler ve sayac toplamayi durdurur'
        'tip.csv'          = 'Oturum listesini CSV dosyasina kaydet'
        'tip.lang'         = 'Arayuz dili'
        'tip.msg'          = 'Secili oturumlara uyari mesaji gonderir. Veri kaybi yok.'
        'tip.disc'         = "Baglantiyi keser, process'ler ayakta kalir. Kullanici kaldigi yerden devam eder."
        'tip.logoff'       = 'Oturumu duzgun sekilde kapatir. Kaydedilmemis veri kaybolur, geri alinamaz.'
        'tip.kill'         = "Secili process'i zorla sonlandirir. Uygulamanin kaydedilmemis verisi kaybolur."
        'tip.reset'        = 'rwinsta - oturumu kernel seviyesinde yok eder. Son care, sadece Log off takildiginda.'
    }
}

# Default is English; a saved setting overrides it.
$script:Lang = 'en'
if ($script:Config -and $script:Config.Lang -and $script:Str.ContainsKey([string]$script:Config.Lang)) {
    $script:Lang = [string]$script:Config.Lang
}

function L {
    param([string]$Key)
    $d = $script:Str[$script:Lang]
    if ($d.ContainsKey($Key)) { return $d[$Key] }
    return $script:Str['en'][$Key]
}

# ============================================================================
# Elevation
# ============================================================================
$script:IsAdmin = ([Security.Principal.WindowsPrincipal] `
                   [Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $script:IsAdmin) {
    $ans = [System.Windows.Forms.MessageBox]::Show(
        (L 'admin.question'), "$AppName $AppVersion", 'YesNo', 'Question', 'Button1')

    if ($ans -eq 'Yes') {
        try {
            if (-not $PSCommandPath) { throw 'script path not available' }
            $exe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $exe -Verb RunAs `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            exit
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                ((L 'admin.failed') -f $_.Exception.Message), (L 'admin.title'), 'OK', 'Warning')
        }
    }
}

# ============================================================================
# Native types
# ============================================================================
# .NET types load once per PowerShell session and cannot be unloaded, so
# running the script twice in the same window would throw "type already
# exists". We skip Add-Type when the types are present - but if they came
# from a DIFFERENT build we stop instead of silently running stale code.
$script:NeedTypes = $true
if ('Rds.Sys' -as [type]) {
    $loaded = $null
    try { $loaded = [Rds.Sys]::Build } catch { }
    if ($loaded -eq $AppVersion) {
        $script:NeedTypes = $false
    } else {
        [void][System.Windows.Forms.MessageBox]::Show(
            ((L 'warn.type') -f $loaded), (L 'warn.typeTitle'), 'OK', 'Warning')
        exit
    }
}

if ($script:NeedTypes) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Rds {

    public class SessRow {
        public int      SessionId;
        public string   WinStation = "";
        public string   State      = "";
        public string   User       = "";
        public string   Domain     = "";
        public int      IdleMin    = -1;
        public DateTime LogonTime  = DateTime.MinValue;
    }

    public static class Wts {

        static readonly IntPtr LOCAL = IntPtr.Zero;

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern int WTSEnumerateSessionsW(IntPtr hServer, int Reserved, int Version,
                                                ref IntPtr ppSessionInfo, ref int pCount);

        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr pMemory);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool WTSQuerySessionInformationW(IntPtr hServer, int sessionId, int infoClass,
                                                       out IntPtr ppBuffer, out int pBytesReturned);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        static extern bool WTSLogoffSession(IntPtr hServer, int SessionId, bool bWait);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        static extern bool WTSDisconnectSession(IntPtr hServer, int SessionId, bool bWait);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool WTSSendMessageW(IntPtr hServer, int SessionId,
                                           string pTitle,   int TitleLength,
                                           string pMessage, int MessageLength,
                                           int Style, int Timeout, out int pResponse, bool bWait);

        [StructLayout(LayoutKind.Sequential)]
        struct WTS_SESSION_INFO {
            public int    SessionId;
            public IntPtr pWinStationName;
            public int    State;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WTSINFO {
            public int State;
            public int SessionId;
            public int IncomingBytes;
            public int OutgoingBytes;
            public int IncomingFrames;
            public int OutgoingFrames;
            public int IncomingCompressedBytes;
            public int OutgoingCompressedBytes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
            public long ConnectTime;
            public long DisconnectTime;
            public long LastInputTime;
            public long LogonTime;
            public long CurrentTime;
        }

        static string StateName(int s) {
            switch (s) {
                case 0: return "Active";
                case 1: return "Connected";
                case 2: return "ConnQuery";
                case 3: return "Shadow";
                case 4: return "Disc";
                case 5: return "Idle";
                case 6: return "Listen";
                case 7: return "Reset";
                case 8: return "Down";
                case 9: return "Init";
                default: return "?" + s;
            }
        }

        // Cheap: one call, the whole session table. Never blocks.
        public static SessRow[] EnumSessions() {
            IntPtr buf = IntPtr.Zero;
            int count = 0;
            List<SessRow> list = new List<SessRow>();
            if (WTSEnumerateSessionsW(LOCAL, 0, 1, ref buf, ref count) == 0)
                throw new Exception("WTSEnumerateSessions failed " + Marshal.GetLastWin32Error());
            try {
                int sz = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                for (int i = 0; i < count; i++) {
                    IntPtr p = new IntPtr(buf.ToInt64() + (i * sz));
                    WTS_SESSION_INFO si = (WTS_SESSION_INFO)Marshal.PtrToStructure(p, typeof(WTS_SESSION_INFO));
                    SessRow r = new SessRow();
                    r.SessionId  = si.SessionId;
                    r.WinStation = Marshal.PtrToStringUni(si.pWinStationName);
                    r.State      = StateName(si.State);
                    list.Add(r);
                }
            } finally { WTSFreeMemory(buf); }
            return list.ToArray();
        }

        // Per-session detail. THIS is the call that blocks on a broken
        // session, which is why the caller times it individually.
        public static SessRow GetDetail(int sessionId) {
            SessRow r = new SessRow();
            r.SessionId = sessionId;
            IntPtr buf; int bytes;

            if (WTSQuerySessionInformationW(LOCAL, sessionId, 24, out buf, out bytes) && bytes > 0) {
                try {
                    WTSINFO i = (WTSINFO)Marshal.PtrToStructure(buf, typeof(WTSINFO));
                    r.User       = i.UserName;
                    r.Domain     = i.Domain;
                    r.State      = StateName(i.State);
                    r.WinStation = i.WinStationName;
                    if (i.LogonTime > 0) { try { r.LogonTime = DateTime.FromFileTime(i.LogonTime); } catch { } }
                    if (i.LastInputTime > 0 && i.CurrentTime > i.LastInputTime)
                        r.IdleMin = (int)((i.CurrentTime - i.LastInputTime) / 600000000L);
                    else r.IdleMin = 0;
                    return r;
                } finally { WTSFreeMemory(buf); }
            }

            // Fallback: WTSUserName = 5, WTSDomainName = 7
            if (WTSQuerySessionInformationW(LOCAL, sessionId, 5, out buf, out bytes)) {
                try { r.User = Marshal.PtrToStringUni(buf); } finally { WTSFreeMemory(buf); }
            }
            if (WTSQuerySessionInformationW(LOCAL, sessionId, 7, out buf, out bytes)) {
                try { r.Domain = Marshal.PtrToStringUni(buf); } finally { WTSFreeMemory(buf); }
            }
            return r;
        }

        // The message box opens on the user's desktop. Without MB_TOPMOST and
        // MB_SETFOREGROUND it lands BEHIND a full screen application and the
        // user never sees it.
        //   MB_OK 0x0 | MB_ICONEXCLAMATION 0x30 | MB_SYSTEMMODAL 0x1000
        //   | MB_SETFOREGROUND 0x10000 | MB_TOPMOST 0x40000
        const int MSG_STYLE = 0x51030;

        // returns 0 on success, otherwise the Win32 error code
        public static int SendMessage(int sessionId, string title, string text) {
            int resp;
            // Lengths are in BYTES and include the null terminator
            bool ok = WTSSendMessageW(LOCAL, sessionId,
                                      title, (title.Length + 1) * 2,
                                      text,  (text.Length  + 1) * 2,
                                      MSG_STYLE, 0, out resp, false);
            if (ok) { return 0; }
            int err = Marshal.GetLastWin32Error();
            return (err == 0) ? -1 : err;
        }

        public static bool Logoff(int sessionId)     { return WTSLogoffSession(LOCAL, sessionId, false); }
        public static bool Disconnect(int sessionId) { return WTSDisconnectSession(LOCAL, sessionId, false); }
    }

    public class ProcInfo {
        public int    Pid;
        public string Name = "";
        public int    SessionId;
        public long   WorkingSet;
        public int    Handles;
        public int    Threads;
        public long   CpuTicks;   // kernel + user, 100ns units
    }

    // Get-Process does not expose CPU time; obtaining it means opening a
    // handle per process, which is expensive with 1400 processes.
    // NtQuerySystemInformation returns everything in ONE call: name, session,
    // RAM, handles, threads and CPU. Get-Process already calls this
    // internally - .NET just does not surface the CPU field.
    public static class Sys {

        // Must match $AppVersion. .NET types cannot be unloaded from a
        // PowerShell session, so this stamp catches a stale build.
        public const string Build = "1.3.1";

        [DllImport("ntdll.dll")]
        static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returned);

        const int SystemProcessInformation = 5;
        const uint STATUS_INFO_LENGTH_MISMATCH = 0xC0000004;

        // Offsets below are for the x64 SYSTEM_PROCESS_INFORMATION layout.
        // On 32-bit the caller falls back to Get-Process.
        public static bool IsSupported() { return IntPtr.Size == 8; }

        public static ProcInfo[] Snapshot() {
            int len = 1024 * 1024;
            IntPtr buf = IntPtr.Zero;
            int ret;

            for (int attempt = 0; attempt < 6; attempt++) {
                buf = Marshal.AllocHGlobal(len);
                int st = NtQuerySystemInformation(SystemProcessInformation, buf, len, out ret);
                if (st == 0) { break; }
                Marshal.FreeHGlobal(buf);
                buf = IntPtr.Zero;
                if ((uint)st == STATUS_INFO_LENGTH_MISMATCH) {
                    len = (ret > len ? ret : len * 2) + 65536;
                    continue;
                }
                throw new Exception("NtQuerySystemInformation 0x" + st.ToString("X8"));
            }
            if (buf == IntPtr.Zero) { throw new Exception("could not allocate process snapshot"); }

            try {
                List<ProcInfo> list = new List<ProcInfo>();
                long p = buf.ToInt64();
                while (true) {
                    IntPtr cur = new IntPtr(p);
                    int next = Marshal.ReadInt32(cur, 0x00);

                    ProcInfo pi = new ProcInfo();
                    pi.Threads   = Marshal.ReadInt32(cur, 0x04);
                    long user    = Marshal.ReadInt64(cur, 0x28);
                    long kernel  = Marshal.ReadInt64(cur, 0x30);
                    pi.CpuTicks  = user + kernel;

                    short nameLen  = Marshal.ReadInt16(cur, 0x38);
                    IntPtr namePtr = Marshal.ReadIntPtr(cur, 0x40);
                    if (namePtr != IntPtr.Zero && nameLen > 0) {
                        pi.Name = Marshal.PtrToStringUni(namePtr, nameLen / 2);
                        if (pi.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) {
                            pi.Name = pi.Name.Substring(0, pi.Name.Length - 4);
                        }
                    } else {
                        pi.Name = "Idle";
                    }

                    pi.Pid        = (int)Marshal.ReadIntPtr(cur, 0x50).ToInt64();
                    pi.Handles    = Marshal.ReadInt32(cur, 0x60);
                    pi.SessionId  = Marshal.ReadInt32(cur, 0x64);
                    pi.WorkingSet = Marshal.ReadInt64(cur, 0x90);

                    list.Add(pi);
                    if (next == 0) { break; }
                    p += next;
                }
                return list.ToArray();
            } finally {
                Marshal.FreeHGlobal(buf);
            }
        }
    }
}
'@
}

# The default renderer paints the selected menu item with the system blue,
# which is unreadable on a dark menu. Supply our own colour table.
if (-not ('RdsUi.DarkMenuColors' -as [type])) {
try {
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharp -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;

namespace RdsUi {
    public class DarkMenuColors : ProfessionalColorTable {
        static Color C(string h) { return ColorTranslator.FromHtml(h); }
        public override Color ToolStripDropDownBackground    { get { return C("#16161A"); } }
        public override Color MenuBorder                     { get { return C("#2A2A30"); } }
        public override Color MenuItemBorder                 { get { return C("#00B3FA"); } }
        public override Color MenuItemSelected               { get { return C("#123A4E"); } }
        public override Color MenuItemSelectedGradientBegin  { get { return C("#123A4E"); } }
        public override Color MenuItemSelectedGradientEnd    { get { return C("#123A4E"); } }
        public override Color MenuItemPressedGradientBegin   { get { return C("#0E2A38"); } }
        public override Color MenuItemPressedGradientEnd     { get { return C("#0E2A38"); } }
        public override Color ImageMarginGradientBegin       { get { return C("#16161A"); } }
        public override Color ImageMarginGradientMiddle      { get { return C("#16161A"); } }
        public override Color ImageMarginGradientEnd         { get { return C("#16161A"); } }
        public override Color SeparatorDark                  { get { return C("#2A2A30"); } }
        public override Color SeparatorLight                 { get { return C("#2A2A30"); } }
    }
}
'@
} catch { }
}

# ============================================================================
# Theme
# ============================================================================
function Hex([string]$h) { [System.Drawing.ColorTranslator]::FromHtml($h) }

$T = @{
    Bg       = Hex '#131316'
    Panel    = Hex '#16161A'
    Bar      = Hex '#0E0E11'
    RowAlt   = Hex '#1A1A1F'
    Border   = Hex '#2A2A30'
    Line     = Hex '#1F1F25'
    Thumb    = Hex '#3A3A44'
    ThumbHot = Hex '#4E4E5A'
    Text     = Hex '#D9D9DE'
    Dim      = Hex '#7C7C85'
    Faint    = Hex '#4E4E56'
    Accent   = Hex '#00B3FA'
    Ok       = Hex '#5ABE78'
    Warn     = Hex '#F0B428'
    Danger   = Hex '#FF5C5C'
    DangerBg = Hex '#231619'
    Sel      = Hex '#123A4E'
}

$F = @{
    Body  = New-Object System.Drawing.Font('Segoe UI', 9)
    Small = New-Object System.Drawing.Font('Segoe UI', 8)
    Head  = New-Object System.Drawing.Font('Segoe UI', 8)
    Big   = New-Object System.Drawing.Font('Segoe UI', 15)
    Mono  = New-Object System.Drawing.Font('Consolas', 9)
}

$script:ThemeThumb    = $T.Thumb
$script:ThemeThumbHot = $T.ThumbHot

# Greyed out in the list and never terminable.
$script:Protected = @(
    'System','Idle','Registry','Memory Compression','smss','csrss','wininit',
    'winlogon','services','lsass','lsm','svchost','fontdrvhost','dwm',
    'LogonUI','sihost','rdpclip','TermService','MsMpEng','conhost','spoolsv'
)

# ============================================================================
# Action log
# ============================================================================
$script:LogPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'RdpSesinMenicir.log' }
                  else { Join-Path $env:TEMP 'RdpSesinMenicir.log' }

function Write-ActionLog {
    param([string]$Action, [string]$Target, [string]$Result)
    $line = "{0}`t{1}`t{2}`t{3}`t{4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $env:USERNAME, $Action, $Target, $Result
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-Settings {
    try {
        $dir = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $max = ($form.WindowState -eq 'Maximized')
        $b   = if ($max) { $form.RestoreBounds } else { $form.Bounds }
        [pscustomobject]@{
            Version     = $AppVersion
            Lang        = $script:Lang
            X           = $b.X
            Y           = $b.Y
            Width       = $b.Width
            Height      = $b.Height
            Maximized   = $max
            Splitter    = $split.SplitterDistance
            AutoIndex   = $cboAuto.SelectedIndex
            PerfVisible = $perf.Visible
        } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch { }
}

# ============================================================================
# Background job: sessions + processes
# ============================================================================
$script:Prog = [hashtable]::Synchronized(@{ Stage = 'idle'; Current = -1 })

$script:EnumScript = {
    param($Prog)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sessions = New-Object System.Collections.ArrayList

    $Prog.Stage = 'sessions'; $Prog.Current = -1
    $enum = @()
    try { $enum = [Rds.Wts]::EnumSessions() } catch { }

    foreach ($s in $enum) {
        if ($s.State -eq 'Listen') { continue }

        # Publish which session we are on, so a hang can be attributed
        $Prog.Current = $s.SessionId
        $qs = [System.Diagnostics.Stopwatch]::StartNew()
        $d  = $null
        try { $d = [Rds.Wts]::GetDetail($s.SessionId) } catch { }
        $qs.Stop()

        $user  = if ($d -and $d.User)   { $d.User }   else { '' }
        $dom   = if ($d -and $d.Domain) { $d.Domain } else { '' }
        $state = if ($d -and $d.State)  { $d.State }  else { $s.State }
        $name  = if ($user) { if ($dom) { "$dom\$user" } else { $user } } else { '-' }
        $logon = if ($d -and $d.LogonTime -gt [datetime]'2000-01-01') { $d.LogonTime } else { [datetime]::MinValue }

        [void]$sessions.Add([pscustomobject]@{
            Id      = [int]$s.SessionId
            User    = $name
            Win     = $(if ($s.WinStation) { $s.WinStation } else { '(disc)' })
            State   = $state
            IdleMin = $(if ($d) { [int]$d.IdleMin } else { -1 })
            Logon   = $logon
            QueryMs = [int]$qs.ElapsedMilliseconds
        })
    }

    $Prog.Stage = 'processes'; $Prog.Current = -1
    $procs = New-Object System.Collections.ArrayList

    if ([Rds.Sys]::IsSupported()) {
        foreach ($p in [Rds.Sys]::Snapshot()) {
            [void]$procs.Add([pscustomobject]@{
                Id        = $p.Pid
                Name      = $p.Name
                SessionId = $p.SessionId
                MB        = [int]($p.WorkingSet / 1MB)
                Handles   = $p.Handles
                Threads   = $p.Threads
                CpuTicks  = $p.CpuTicks
            })
        }
    } else {
        # 32-bit PowerShell: struct offsets differ, fall back without CPU
        foreach ($pr in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                [void]$procs.Add([pscustomobject]@{
                    Id        = $pr.Id
                    Name      = $pr.ProcessName
                    SessionId = $pr.SessionId
                    MB        = [int]($pr.WorkingSet64 / 1MB)
                    Handles   = [int]$pr.HandleCount
                    Threads   = [int]$pr.Threads.Count
                    CpuTicks  = 0
                })
            } catch { }
        }
    }

    $sw.Stop()
    $Prog.Stage = 'done'

    [pscustomobject]@{
        Sessions  = @($sessions)
        Processes = @($procs)
        Ms        = [int]$sw.ElapsedMilliseconds
        Stamp     = Get-Date
    }
}

# ============================================================================
# Background job: performance counters
# ============================================================================
$script:PerfScript = {
    $o = [ordered]@{}
    $o.Cpu = $null; $o.Kernel = $null
    $o.RamUsedGB = $null; $o.RamTotalGB = $null; $o.RamPct = $null
    $o.DiskRaw = $null; $o.DiskBase = $null; $o.DiskFreq = $null; $o.DiskQueue = $null
    $o.NetRx = $null; $o.NetTx = $null; $o.NetName = ''
    $o.BootTime = $null

    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $o.Cpu    = [int]$p.PercentProcessorTime
        $o.Kernel = [int]$p.PercentPrivilegedTime
    } catch { }

    try {
        $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $tot  = [double]$os.TotalVisibleMemorySize / 1MB
        $free = [double]$os.FreePhysicalMemory / 1MB
        $o.RamTotalGB = [math]::Round($tot, 1)
        $o.RamUsedGB  = [math]::Round($tot - $free, 1)
        if ($tot -gt 0) { $o.RamPct = [int](100 * ($tot - $free) / $tot) }
        $o.BootTime = $os.LastBootUpTime
    } catch { }

    # Disk latency: the FORMATTED class truncates sub-second values to zero,
    # so we compute it from RAW counters across two samples.
    try {
        $d = Get-CimInstance Win32_PerfRawData_PerfDisk_LogicalDisk -Filter "Name='C:'" -ErrorAction Stop
        $o.DiskRaw   = [int64]$d.AvgDisksecPerTransfer
        $o.DiskBase  = [int64]$d.AvgDisksecPerTransfer_Base
        $o.DiskFreq  = [int64]$d.Frequency_PerfTime
        $o.DiskQueue = [int]$d.CurrentDiskQueueLength
    } catch { }

    try {
        $st = Get-NetAdapterStatistics -ErrorAction Stop |
              Sort-Object ReceivedBytes -Descending | Select-Object -First 1
        if ($st) {
            $o.NetName = $st.Name
            $o.NetRx   = [int64]$st.ReceivedBytes
            $o.NetTx   = [int64]$st.SentBytes
        }
    } catch { }

    $o.At = Get-Date
    [pscustomobject]$o
}

# ============================================================================
# State
# ============================================================================
$script:Pool = [runspacefactory]::CreateRunspacePool(2, 4)
$script:Pool.Open()

$script:EnumJob    = $null
$script:PerfJob    = $null
$script:Refreshing = $false

$script:Sessions   = @()
$script:Processes  = @()
$script:BySession  = @{}
$script:PrevProcs  = @{}
$script:PrevSessMB = @{}
$script:PrevPerf   = $null
$script:PrevCpu    = @{}
$script:PrevCpuAt  = $null
$script:CpuPct     = @{}
$script:Cores      = [Environment]::ProcessorCount
$script:SelSession = -1
$script:Filter     = ''

$script:HistCpu  = New-Object System.Collections.Generic.Queue[double]
$script:HistRam  = New-Object System.Collections.Generic.Queue[double]
$script:HistDisk = New-Object System.Collections.Generic.Queue[double]
$script:HistNet  = New-Object System.Collections.Generic.Queue[double]

function Push-Hist {
    param($Queue, [double]$Value)
    [void]$Queue.Enqueue($Value)
    while ($Queue.Count -gt $HistoryPoints) { [void]$Queue.Dequeue() }
}

# ============================================================================
# UI helpers
# ============================================================================
function New-DarkGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock                      = 'Fill'
    $g.BackgroundColor           = $T.Bg
    $g.GridColor                 = $T.Line
    $g.BorderStyle               = 'None'
    $g.Font                      = $F.Body
    $g.RowHeadersVisible         = $false
    $g.AllowUserToAddRows        = $false
    $g.AllowUserToDeleteRows     = $false
    $g.AllowUserToResizeRows     = $false
    $g.AllowUserToResizeColumns  = $false
    $g.ReadOnly                  = $true
    $g.SelectionMode             = 'FullRowSelect'
    $g.MultiSelect               = $false
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $g.ColumnHeadersHeight       = 26
    $g.ColumnHeadersBorderStyle  = 'Single'
    $g.CellBorderStyle           = 'SingleHorizontal'
    $g.RowTemplate.Height        = 22
    # Columns fill the width, so a horizontal scrollbar never appears
    $g.AutoSizeColumnsMode       = 'Fill'
    # Vertical scrolling is handled by our own thin dark scrollbar
    $g.ScrollBars                = 'None'
    $g.ColumnHeadersDefaultCellStyle.BackColor = $T.Bar
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $T.Dim
    $g.ColumnHeadersDefaultCellStyle.Font      = $F.Head
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $T.Bar
    $g.ColumnHeadersDefaultCellStyle.SelectionForeColor = $T.Dim
    $g.ColumnHeadersDefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding(6,0,6,0)
    $g.DefaultCellStyle.BackColor          = $T.Bg
    $g.DefaultCellStyle.ForeColor          = $T.Text
    $g.DefaultCellStyle.SelectionBackColor = $T.Sel
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $g.DefaultCellStyle.Padding            = New-Object System.Windows.Forms.Padding(6,0,6,0)
    $g.AlternatingRowsDefaultCellStyle.BackColor = $T.RowAlt
    return $g
}

function Add-Col {
    param($Grid, [string]$Name, [type]$Type = [string],
          [int]$Weight = 10, [int]$Min = 60, [string]$Align = 'MiddleLeft',
          [string]$Format = '', [switch]$Mono)
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name          = $Name
    $c.ValueType     = $Type
    $c.FillWeight    = $Weight
    $c.MinimumWidth  = $Min
    $c.SortMode      = 'Automatic'
    $c.DefaultCellStyle.Alignment = $Align
    if ($Format) { $c.DefaultCellStyle.Format = $Format }
    if ($Mono)   { $c.DefaultCellStyle.Font = $F.Mono }
    [void]$Grid.Columns.Add($c)
}

# The native DataGridView scrollbar is always painted light and clashes with
# the dark theme, so we turn it off and draw a 9 px one ourselves.
function Add-DarkScrollbar {
    param($Grid)

    $wrap = New-Object System.Windows.Forms.Panel
    $wrap.Dock      = 'Fill'
    $wrap.BackColor = $T.Bg

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock      = 'Right'
    $bar.Width     = 9
    $bar.BackColor = $T.Bg
    $bar.Tag       = @{ Grid = $Grid; Hot = $false }

    $wrap.Controls.Add($Grid)
    $wrap.Controls.Add($bar)

    $bar.Add_Paint({
        param($s, $e)
        $g = $s.Tag.Grid
        if ($g.Rows.Count -eq 0) { return }
        $rowH  = [math]::Max(1, $g.RowTemplate.Height)
        $vis   = [math]::Max(1, [int](($g.ClientSize.Height - $g.ColumnHeadersHeight) / $rowH))
        $total = $g.Rows.Count
        if ($total -le $vis) { return }
        $h = $s.ClientSize.Height
        $thumbH = [math]::Max(28, [int]($h * $vis / $total))
        $first = $g.FirstDisplayedScrollingRowIndex
        if ($first -lt 0) { $first = 0 }
        $maxFirst = $total - $vis
        $y = if ($maxFirst -gt 0) { [int](($h - $thumbH) * $first / $maxFirst) } else { 0 }
        $col = if ($s.Tag.Hot) { $script:ThemeThumbHot } else { $script:ThemeThumb }
        $br = New-Object System.Drawing.SolidBrush($col)
        $e.Graphics.FillRectangle($br, 2, $y, 5, $thumbH)
        $br.Dispose()
    })

    $scrollTo = {
        param($s, $y)
        $g = $s.Tag.Grid
        $rowH = [math]::Max(1, $g.RowTemplate.Height)
        $vis  = [math]::Max(1, [int](($g.ClientSize.Height - $g.ColumnHeadersHeight) / $rowH))
        $maxFirst = [math]::Max(0, $g.Rows.Count - $vis)
        if ($maxFirst -le 0) { return }
        $ratio = [double]$y / [math]::Max(1, $s.ClientSize.Height)
        $idx = [int]([math]::Round($ratio * $maxFirst))
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -gt $maxFirst) { $idx = $maxFirst }
        try { $g.FirstDisplayedScrollingRowIndex = $idx } catch { }
        $s.Invalidate()
    }
    $bar.Tag.ScrollTo = $scrollTo

    $bar.Add_MouseDown({ param($s,$e) $s.Tag.Hot = $true; & $s.Tag.ScrollTo $s $e.Y })
    $bar.Add_MouseMove({ param($s,$e) if ($e.Button -eq 'Left') { & $s.Tag.ScrollTo $s $e.Y } })
    $bar.Add_MouseUp({ param($s,$e) $s.Tag.Hot = $false; $s.Invalidate() })
    $bar.Add_MouseEnter({ $this.Tag.Hot = $true;  $this.Invalidate() })
    $bar.Add_MouseLeave({ $this.Tag.Hot = $false; $this.Invalidate() })

    $Grid.Tag = $bar
    $Grid.Add_MouseWheel({
        param($s, $e)
        $rowH = [math]::Max(1, $s.RowTemplate.Height)
        $vis  = [math]::Max(1, [int](($s.ClientSize.Height - $s.ColumnHeadersHeight) / $rowH))
        $maxFirst = [math]::Max(0, $s.Rows.Count - $vis)
        if ($maxFirst -le 0) { return }
        $first = $s.FirstDisplayedScrollingRowIndex
        if ($first -lt 0) { $first = 0 }
        $n = $first - ([int]($e.Delta / 120) * 3)
        if ($n -lt 0) { $n = 0 }
        if ($n -gt $maxFirst) { $n = $maxFirst }
        try { $s.FirstDisplayedScrollingRowIndex = $n } catch { }
        $s.Tag.Invalidate()
    })
    $Grid.Add_Scroll({ param($s,$e) $s.Tag.Invalidate() })
    $Grid.Add_SelectionChanged({ if ($this.Tag) { $this.Tag.Invalidate() } })
    $Grid.Add_Resize({ if ($this.Tag) { $this.Tag.Invalidate() } })

    return $wrap
}

function New-DarkButton {
    param([string]$Text, [int]$W = 110, $Fore = $null, [switch]$Danger)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Width     = $W
    $b.Height    = 28
    $b.Font      = $F.Body
    $b.FlatStyle = 'Flat'
    $b.BackColor = if ($Danger) { $T.DangerBg } else { $T.Bg }
    $b.ForeColor = if ($Danger) { $T.Danger } elseif ($Fore) { $Fore } else { $T.Text }
    $b.FlatAppearance.BorderColor = if ($Danger) { Hex '#7A2B2B' } else { Hex '#33333B' }
    $b.FlatAppearance.BorderSize  = 1
    return $b
}

function New-Label {
    param([string]$Text, $Font, $Color, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 18, [string]$Align = 'MiddleLeft')
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.Font      = $Font
    $l.ForeColor = $Color
    $l.Location  = New-Object System.Drawing.Point($X, $Y)
    $l.Width     = $W
    $l.Height    = $H
    $l.TextAlign = $Align
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-SectionHeader {
    param([string]$Text)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock      = 'Top'
    $p.Height    = 26
    $p.BackColor = $T.Bar
    $lbl = New-Label $Text $F.Small $T.Dim 12 5 700 16
    $p.Controls.Add($lbl)
    $line = New-Object System.Windows.Forms.Panel
    $line.Dock = 'Bottom'; $line.Height = 1; $line.BackColor = $T.Border
    $p.Controls.Add($line)
    $p.Tag = $lbl
    return $p
}

function New-Sep {
    $s = New-Object System.Windows.Forms.Panel
    $s.Dock = 'Top'; $s.Height = 1; $s.BackColor = $T.Border
    return $s
}

function New-VSep {
    param([int]$X)
    $s = New-Object System.Windows.Forms.Panel
    $s.Location  = New-Object System.Drawing.Point($X, 12)
    $s.Size      = New-Object System.Drawing.Size(1, 20)
    $s.BackColor = $T.Border
    return $s
}

# Icon is drawn in code so the script stays a single portable file.
function New-AppIcon {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $bg   = New-Object System.Drawing.SolidBrush((Hex '#0E0E11'))
    $edge = New-Object System.Drawing.Pen((Hex '#3A3A44'), 1)
    $acc  = New-Object System.Drawing.SolidBrush((Hex '#00B3FA'))
    $mid  = New-Object System.Drawing.SolidBrush((Hex '#7C7C85'))
    $dim  = New-Object System.Drawing.SolidBrush((Hex '#4E4E56'))

    $g.FillRectangle($bg, 1, 1, 29, 29)
    $g.DrawRectangle($edge, 1, 1, 29, 29)
    $g.FillRectangle($acc, 6,  8, 20, 4)
    $g.FillRectangle($mid, 6, 15, 14, 4)
    $g.FillRectangle($dim, 6, 22, 17, 4)

    foreach ($o in @($bg, $edge, $acc, $mid, $dim)) { $o.Dispose() }
    $g.Dispose()
    $script:IconBmp = $bmp
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ============================================================================
# Window
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text          = "$AppName  $AppVersion"
$form.Size          = New-Object System.Drawing.Size(1400, 900)
$form.MinimumSize   = New-Object System.Drawing.Size(1100, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $T.Bg
$form.ForeColor     = $T.Text
$form.Font          = $F.Body
$form.KeyPreview    = $true
try { $form.Icon = New-AppIcon } catch { }

# --- split: sessions on top, processes below --------------------------------
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock          = 'Fill'
$split.Orientation   = 'Horizontal'
$split.BackColor     = $T.Border
$split.SplitterWidth = 6
$form.Controls.Add($split)

$gridS = New-DarkGrid
$gridS.MultiSelect = $true
Add-Col $gridS 'Id'    ([int])      4 44  'MiddleRight' '' -Mono
Add-Col $gridS 'User'  ([string])  20 160
Add-Col $gridS 'Win'   ([string])  11 100
Add-Col $gridS 'State' ([string])   7 72
Add-Col $gridS 'Idle'  ([int])      7 68  'MiddleRight'
Add-Col $gridS 'Logon' ([string])   8 84
Add-Col $gridS 'Proc'  ([int])      5 52  'MiddleRight'
Add-Col $gridS 'Cpu'   ([double])   6 62  'MiddleRight' 'N1'
Add-Col $gridS 'MB'    ([int])      7 76  'MiddleRight' 'N0'
Add-Col $gridS 'DMB'   ([int])      6 70  'MiddleRight' '+#,0;-#,0;0'
Add-Col $gridS 'Ms'    ([int])      7 76  'MiddleRight' '' -Mono
Add-Col $gridS 'Note'  ([string])  18 130

$hdrS = New-SectionHeader ''
$split.Panel1.Controls.Add((Add-DarkScrollbar $gridS))
$split.Panel1.Controls.Add($hdrS)

$gridP = New-DarkGrid
Add-Col $gridP 'Pid'  ([int])      6 60  'MiddleRight' '' -Mono
Add-Col $gridP 'Name' ([string])  24 180
Add-Col $gridP 'Cpu'  ([double])   7 66  'MiddleRight' 'N1'
Add-Col $gridP 'MB'   ([int])      8 80  'MiddleRight' 'N0'
Add-Col $gridP 'DMB'  ([int])      7 72  'MiddleRight' '+#,0;-#,0;0'
Add-Col $gridP 'Hnd'  ([int])      8 76  'MiddleRight' 'N0'
Add-Col $gridP 'DHnd' ([int])      8 86  'MiddleRight' '+#,0;-#,0;0'
Add-Col $gridP 'Thr'  ([int])      7 66  'MiddleRight'
Add-Col $gridP 'Prot' ([string])   7 72

$hdrP = New-SectionHeader ''
$split.Panel2.Controls.Add((Add-DarkScrollbar $gridP))
$split.Panel2.Controls.Add($hdrP)

# --- left performance panel -------------------------------------------------
$perf = New-Object System.Windows.Forms.Panel
$perf.Dock      = 'Left'
$perf.Width     = 218
$perf.BackColor = $T.Border
$form.Controls.Add($perf)

$script:Tiles = @{}
function New-PerfTile {
    param([string]$Key, $Queue, $Color, [double]$Max)
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock      = 'Top'
    $p.Height    = 104
    $p.BackColor = $T.Panel

    $lbl = New-Label '' $F.Small $T.Dim   12 8  180 14
    $val = New-Label '-' $F.Big   $Color   12 24 190 28
    $sub = New-Label '' $F.Small $T.Faint 12 82 194 14

    $spark = New-Object System.Windows.Forms.Panel
    $spark.Location  = New-Object System.Drawing.Point(12, 56)
    $spark.Size      = New-Object System.Drawing.Size(192, 24)
    $spark.Anchor    = 'Top,Left,Right'
    $spark.BackColor = $T.Panel
    $spark.Tag       = @{ Queue = $Queue; Color = $Color; Max = $Max }
    $spark.Add_Paint({
        param($s, $e)
        $t = $s.Tag
        $q = @($t.Queue.ToArray())
        if ($q.Count -lt 2) { return }
        $max = [double]$t.Max
        foreach ($v in $q) { if ($v -gt $max) { $max = $v } }
        if ($max -le 0) { $max = 1 }
        $w = $s.ClientSize.Width; $h = $s.ClientSize.Height
        $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        for ($i = 0; $i -lt $q.Count; $i++) {
            $x = [float]($i * ($w - 1) / [math]::Max(1, ($q.Count - 1)))
            $y = [float]($h - 1 - (($q[$i] / $max) * ($h - 2)))
            $pts.Add((New-Object System.Drawing.PointF($x, $y)))
        }
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $pen = New-Object System.Drawing.Pen($t.Color, 1.4)
        try { $e.Graphics.DrawLines($pen, $pts.ToArray()) } catch { }
        $pen.Dispose()
    })

    $p.Controls.AddRange(@($lbl, $val, $spark, $sub))
    $script:Tiles[$Key] = @{ Panel = $p; Lbl = $lbl; Val = $val; Sub = $sub; Spark = $spark }
    return $p
}

# Uptime comes from the Win32_OperatingSystem query we already run for
# memory; handle and thread totals come from the process snapshot.
$script:Info = @{}
$script:ServerIp = try {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
             Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
             Select-Object -ExpandProperty IPAddress -Unique)
    if ($ips.Count -gt 2) { ($ips[0..1] -join ', ') + ' +' + ($ips.Count - 2) }
    else { $ips -join ', ' }
} catch { '' }

function New-InfoPanel {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock      = 'Top'
    $p.Height    = 132
    $p.BackColor = $T.Panel

    $head = New-Label '' $F.Small $T.Dim 12 8 180 14
    $p.Controls.Add($head)
    $script:Info['head'] = $head
    $p.Controls.Add((New-Label $env:COMPUTERNAME $F.Body $T.Text 12 25 194 18))
    $p.Controls.Add((New-Label $script:ServerIp $F.Small $T.Dim 12 44 194 16))

    $y = 68
    foreach ($k in @('up','hnd','thr')) {
        $lbl = New-Label '' $F.Small $T.Faint 12 $y 96 16
        $val = New-Label '-' $F.Small $T.Text 108 $y 98 16 'MiddleRight'
        $p.Controls.AddRange(@($lbl, $val))
        $script:Info["$k.lbl"] = $lbl
        $script:Info[$k]       = $val
        $y += 19
    }
    return $p
}

# Dock Top stacks bottom-up: the last control added ends up on top.
$perf.Controls.Add((New-InfoPanel))
$perf.Controls.Add((New-Sep))
$perf.Controls.Add((New-PerfTile 'net'  $script:HistNet  $T.Dim    10))
$perf.Controls.Add((New-Sep))
$perf.Controls.Add((New-PerfTile 'disk' $script:HistDisk $T.Warn   $DiskWarnMs))
$perf.Controls.Add((New-Sep))
$perf.Controls.Add((New-PerfTile 'ram'  $script:HistRam  $T.Dim    100))
$perf.Controls.Add((New-Sep))
$perf.Controls.Add((New-PerfTile 'cpu'  $script:HistCpu  $T.Accent 100))
$perfHdr = New-SectionHeader ''
$perf.Controls.Add($perfHdr)

# --- single line summary strip ----------------------------------------------
$kpi = New-Object System.Windows.Forms.FlowLayoutPanel
$kpi.Dock          = 'Top'
$kpi.Height        = 28
$kpi.BackColor     = $T.Bar
$kpi.WrapContents  = $false
$kpi.Padding       = New-Object System.Windows.Forms.Padding(12, 5, 0, 0)
$form.Controls.Add($kpi)

$script:KpiVals = @{}
$script:KpiLbls = @{}
function Add-Kpi {
    param([string]$Key, $Color)
    $l = New-Object System.Windows.Forms.Label
    $l.Font = $F.Small; $l.ForeColor = $T.Faint
    $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(0,3,5,0)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = '-'; $v.Font = $F.Body; $v.ForeColor = $Color
    $v.AutoSize = $true; $v.Margin = New-Object System.Windows.Forms.Padding(0,1,22,0)
    $kpi.Controls.AddRange(@($l, $v))
    $script:KpiLbls[$Key] = $l
    $script:KpiVals[$Key] = $v
}
Add-Kpi 'active' $T.Ok
Add-Kpi 'disc'   $T.Warn
Add-Kpi 'ram'    $T.Text
Add-Kpi 'stuck'  $T.Faint

# --- top bar ----------------------------------------------------------------
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 44; $top.BackColor = $T.Bar
$form.Controls.Add($top)

$btnRefresh = New-DarkButton '' 84 $T.Accent
$btnRefresh.Location = New-Object System.Drawing.Point(12, 8)
$top.Controls.Add($btnRefresh)

$cboAuto = New-Object System.Windows.Forms.ComboBox
$cboAuto.DropDownStyle = 'DropDownList'
$cboAuto.Width     = 116
$cboAuto.Location  = New-Object System.Drawing.Point(104, 10)
$cboAuto.BackColor = $T.Bg
$cboAuto.ForeColor = $T.Text
$cboAuto.FlatStyle = 'Flat'
$cboAuto.Font      = $F.Body
$top.Controls.Add($cboAuto)

$top.Controls.Add((New-VSep 234))

$txtFind = New-Object System.Windows.Forms.TextBox
$txtFind.Width       = 240
$txtFind.Location    = New-Object System.Drawing.Point(250, 10)
$txtFind.BackColor   = $T.Bg
$txtFind.ForeColor   = $T.Faint
$txtFind.BorderStyle = 'FixedSingle'
$txtFind.Font        = $F.Body
$top.Controls.Add($txtFind)

$top.Controls.Add((New-VSep 504))

$lblAdmin = New-Label '' $F.Small $T.Warn 518 14 150 16
$top.Controls.Add($lblAdmin)

$cboLang = New-Object System.Windows.Forms.ComboBox
$cboLang.DropDownStyle = 'DropDownList'
$cboLang.Width     = 58
$cboLang.Location  = New-Object System.Drawing.Point(0, 10)
$cboLang.BackColor = $T.Bg
$cboLang.ForeColor = $T.Text
$cboLang.FlatStyle = 'Flat'
$cboLang.Font      = $F.Body
$cboLang.Anchor    = 'Top,Right'
[void]$cboLang.Items.AddRange(@('EN','TR'))
$cboLang.SelectedIndex = $(if ($script:Lang -eq 'tr') { 1 } else { 0 })
$top.Controls.Add($cboLang)

$btnPerf = New-DarkButton '' 116
$btnPerf.Anchor = 'Top,Right'
$top.Controls.Add($btnPerf)

$btnCsv = New-DarkButton '' 62
$btnCsv.Anchor = 'Top,Right'
$top.Controls.Add($btnCsv)

$lblStatus = New-Label '' $F.Body $T.Dim 0 13 360 18 'MiddleRight'
$lblStatus.Anchor = 'Top,Right'
$top.Controls.Add($lblStatus)

# --- action bar -------------------------------------------------------------
$actBar = New-Object System.Windows.Forms.Panel
$actBar.Dock = 'Bottom'; $actBar.Height = 46; $actBar.BackColor = $T.Bar
$form.Controls.Add($actBar)

$btnMsg  = New-DarkButton '' 96
$btnDisc = New-DarkButton '' 100
$btnOff  = New-DarkButton '' 92 $T.Warn
$btnKill = New-DarkButton '' 100
$btnRst  = New-DarkButton '' 116 -Danger

$x = 12
foreach ($b in @($btnMsg, $btnDisc, $btnOff, $btnKill)) {
    $b.Location = New-Object System.Drawing.Point($x, 9)
    $actBar.Controls.Add($b)
    $x += $b.Width + 8
}
# extra gap so the destructive button is not part of the row rhythm
$x += 28
$btnRst.Location = New-Object System.Drawing.Point($x, 9)
$actBar.Controls.Add($btnRst)

# --- footer -----------------------------------------------------------------
$foot = New-Object System.Windows.Forms.Panel
$foot.Dock = 'Bottom'; $foot.Height = 22; $foot.BackColor = $T.Bar
$form.Controls.Add($foot)

$foot.Controls.Add((New-Label "belesware   v$AppVersion" $F.Small $T.Faint 12 3 200 16))
$lblFik = New-Label 'fikired by ugur.es' $F.Small $T.Faint 0 3 170 16 'MiddleRight'
$lblFik.Anchor = 'Top,Right'
$foot.Controls.Add($lblFik)
$script:LblFik = $lblFik

$split.BringToFront()

function Layout-Bars {
    $btnCsv.Location    = New-Object System.Drawing.Point(($top.Width - 74), 8)
    $btnPerf.Location   = New-Object System.Drawing.Point(($top.Width - 198), 8)
    $cboLang.Location   = New-Object System.Drawing.Point(($top.Width - 264), 10)
    $lblStatus.Location = New-Object System.Drawing.Point(($top.Width - 636), 13)
    if ($script:LblFik) { $script:LblFik.Location = New-Object System.Drawing.Point(($foot.Width - 184), 3) }
}
$top.Add_Resize({ Layout-Bars })
$actBar.Add_Resize({ Layout-Bars })
$foot.Add_Resize({ Layout-Bars })

# ============================================================================
# Language application
# ============================================================================
$script:Tooltip = $null

function Apply-Language {
    $btnRefresh.Text = L 'btn.refresh'
    $btnCsv.Text     = L 'btn.csv'
    $btnPerf.Text    = if ($perf.Visible) { L 'btn.hidePanel' } else { L 'btn.showPanel' }
    $btnMsg.Text     = L 'btn.msg'
    $btnDisc.Text    = L 'btn.disc'
    $btnOff.Text     = L 'btn.logoff'
    $btnKill.Text    = L 'btn.kill'
    $btnRst.Text     = L 'btn.reset'

    $idx = $cboAuto.SelectedIndex
    $cboAuto.Items.Clear()
    [void]$cboAuto.Items.AddRange(@((L 'auto.0'), (L 'auto.1'), (L 'auto.2')))
    $cboAuto.SelectedIndex = $(if ($idx -ge 0) { $idx } else { 2 })

    $script:FindHint = L 'find.hint'
    if ($txtFind.ForeColor -eq $T.Faint -or $txtFind.Text.Trim() -eq '') {
        $txtFind.Text = $script:FindHint
        $txtFind.ForeColor = $T.Faint
    }

    $lblAdmin.Text = if ($script:IsAdmin) { '' } else { L 'app.limited' }
    $form.Text = if ($script:IsAdmin) { "$AppName  $AppVersion" }
                 else { "$AppName  $AppVersion  -  " + (L 'app.limited') }

    foreach ($k in @('active','disc','ram','stuck')) { $script:KpiLbls[$k].Text = L "kpi.$k" }

    $perfHdr.Tag.Text = L 'perf.header'
    $script:Tiles['cpu'].Lbl.Text  = L 'perf.cpu'
    $script:Tiles['ram'].Lbl.Text  = L 'perf.mem'
    $script:Tiles['disk'].Lbl.Text = L 'perf.disk'
    $script:Tiles['net'].Lbl.Text  = L 'perf.net'

    $script:Info['head'].Text    = L 'info.server'
    $script:Info['up.lbl'].Text  = L 'info.uptime'
    $script:Info['hnd.lbl'].Text = L 'info.handles'
    $script:Info['thr.lbl'].Text = L 'info.threads'

    $sCols = @{ Id='col.id'; User='col.user'; Win='col.session'; State='col.state';
                Idle='col.idle'; Logon='col.logon'; Proc='col.proc'; Cpu='col.cpu';
                MB='col.ram'; DMB='col.ramDelta'; Ms='col.query'; Note='col.note' }
    foreach ($k in $sCols.Keys) { $gridS.Columns[$k].HeaderText = L $sCols[$k] }

    $pCols = @{ Pid='col.pid'; Name='col.name'; Cpu='col.cpu'; MB='col.ram';
                DMB='col.ramDelta'; Hnd='col.handle'; DHnd='col.handleDelta';
                Thr='col.thread'; Prot='col.protected' }
    foreach ($k in $pCols.Keys) { $gridP.Columns[$k].HeaderText = L $pCols[$k] }

    $menuS.Items[0].Text = L 'menu.msg'
    $menuS.Items[1].Text = L 'menu.disc'
    $menuS.Items[2].Text = L 'menu.logoff'
    $menuS.Items[3].Text = L 'menu.reset'
    $menuS.Items[5].Text = L 'menu.shadow'
    $menuS.Items[7].Text = L 'menu.copyUser'
    $menuS.Items[8].Text = L 'menu.copyId'
    $menuP.Items[0].Text = L 'menu.kill'
    $menuP.Items[2].Text = L 'menu.copyPid'
    $menuP.Items[3].Text = L 'menu.copyName'

    if ($script:Tooltip) {
        $script:Tooltip.SetToolTip($btnRefresh, (L 'tip.refresh'))
        $script:Tooltip.SetToolTip($cboAuto,    ((L 'tip.auto') -f $null))
        $script:Tooltip.SetToolTip($txtFind,    (L 'tip.find'))
        $script:Tooltip.SetToolTip($cboLang,    (L 'tip.lang'))
        $script:Tooltip.SetToolTip($btnPerf,    (L 'tip.perf'))
        $script:Tooltip.SetToolTip($btnCsv,     (L 'tip.csv'))
        $script:Tooltip.SetToolTip($btnMsg,     (L 'tip.msg'))
        $script:Tooltip.SetToolTip($btnDisc,    (L 'tip.disc'))
        $script:Tooltip.SetToolTip($btnOff,     (L 'tip.logoff'))
        $script:Tooltip.SetToolTip($btnKill,    (L 'tip.kill'))
        $script:Tooltip.SetToolTip($btnRst,     (L 'tip.reset'))
    }

    if ($script:Sessions.Count) { Update-Views }
    else {
        $hdrS.Tag.Text = (L 'sess.header') -f 0, 0
        $hdrP.Tag.Text = L 'proc.none'
    }
}

# ============================================================================
# View refresh
# ============================================================================
function Update-Views {
    $bySession = @{}
    foreach ($p in $script:Processes) {
        if (-not $bySession.ContainsKey($p.SessionId)) {
            $bySession[$p.SessionId] = New-Object System.Collections.ArrayList
        }
        [void]$bySession[$p.SessionId].Add($p)
    }
    $script:BySession = $bySession

    # Preserve every selected row, not just the first
    $selIds = @{}
    foreach ($r in $gridS.SelectedRows) { $selIds[[int]$r.Cells['Id'].Value] = $true }
    if ($selIds.Count -eq 0 -and $script:SelSession -ge 0) { $selIds[[int]$script:SelSession] = $true }

    $f = $script:Filter.ToLower()
    $nAct = 0; $nDisc = 0; $nStuck = 0; $totMB = 0
    $newSessMB = @{}

    $gridS.SuspendLayout()
    $gridS.Rows.Clear()
    foreach ($s in $script:Sessions) {
        $list = if ($bySession.ContainsKey($s.Id)) { $bySession[$s.Id] } else { @() }
        $mb = 0; foreach ($p in $list) { $mb += $p.MB }
        $newSessMB[$s.Id] = $mb
        $totMB += $mb

        if ($s.State -eq 'Active') { $nAct++ }
        elseif ($s.State -eq 'Disc') { $nDisc++ }

        $note = ''
        if ($s.QueryMs -gt $SlowQueryMs) {
            $note = (L 'note.slow') -f $s.QueryMs; $nStuck++
        } elseif ($s.State -in @('Down','Init','Reset')) {
            $note = (L 'note.state') -f $s.State; $nStuck++
        } elseif ($list.Count -eq 0 -and $s.Id -gt 0) {
            $note = L 'note.noproc'; $nStuck++
        }

        if ($f -and -not ("$($s.User) $($s.Win) $($s.State) $($s.Id)".ToLower().Contains($f))) { continue }

        $dmb = 0
        if ($script:PrevSessMB.ContainsKey($s.Id)) { $dmb = $mb - $script:PrevSessMB[$s.Id] }
        $logon = if ($s.Logon -gt [datetime]'2000-01-01') { $s.Logon.ToString('dd.MM HH:mm') } else { '' }
        $idle  = if ($s.IdleMin -ge 0) { [int]$s.IdleMin } else { 0 }

        $scpu = 0.0
        foreach ($p in $list) { if ($script:CpuPct.ContainsKey($p.Id)) { $scpu += $script:CpuPct[$p.Id] } }
        $scpu = [math]::Round($scpu, 1)

        $i = $gridS.Rows.Add([int]$s.Id, $s.User, $s.Win, $s.State, $idle, $logon,
                             [int]$list.Count, [double]$scpu, [int]$mb, [int]$dmb,
                             [int]$s.QueryMs, $note)
        $row = $gridS.Rows[$i]
        if ($scpu -ge 25) { $row.Cells['Cpu'].Style.ForeColor = $T.Danger }
        elseif ($scpu -ge 10) { $row.Cells['Cpu'].Style.ForeColor = $T.Warn }
        $row.Cells['State'].Style.ForeColor = switch ($s.State) {
            'Active' { $T.Ok }
            'Disc'   { $T.Warn }
            'Down'   { $T.Danger }
            'Init'   { $T.Danger }
            'Reset'  { $T.Danger }
            default  { $T.Dim }
        }
        if ($dmb -gt 500) { $row.Cells['DMB'].Style.ForeColor = $T.Warn }
        if ($s.QueryMs -gt $SlowQueryMs) {
            $row.Cells['Ms'].Style.ForeColor = $T.Danger
            $row.DefaultCellStyle.BackColor  = $T.DangerBg
        }
        if ($note) { $row.Cells['Note'].Style.ForeColor = $T.Warn }
        $row.Selected = $selIds.ContainsKey([int]$s.Id)
    }
    $gridS.ResumeLayout()
    $script:PrevSessMB = $newSessMB

    $script:KpiVals['active'].Text = "$nAct"
    $script:KpiVals['disc'].Text   = "$nDisc"
    $script:KpiVals['ram'].Text    = "{0:N1} GB" -f ($totMB / 1024)
    $script:KpiVals['stuck'].Text  = "$nStuck"
    $script:KpiVals['stuck'].ForeColor = if ($nStuck -gt 0) { $T.Danger } else { $T.Faint }

    $totH = 0; $totT = 0
    foreach ($p in $script:Processes) { $totH += $p.Handles; $totT += $p.Threads }
    $script:Info['hnd'].Text = "{0:N0}" -f $totH
    $script:Info['hnd'].ForeColor = if ($totH -gt 500000) { $T.Warn } else { $T.Text }
    $script:Info['thr'].Text = "{0:N0}" -f $totT

    $hdrS.Tag.Text = (L 'sess.header') -f $script:Sessions.Count, $script:Processes.Count
    Update-ProcessView
    $gridS.Tag.Invalidate()
}

function Update-ProcessView {
    if ($gridS.SelectedRows.Count -eq 0) {
        $gridP.Rows.Clear()
        $hdrP.Tag.Text = L 'proc.none'
        $gridP.Tag.Invalidate()
        return
    }
    $sid  = [int]$gridS.SelectedRows[0].Cells['Id'].Value
    $user = [string]$gridS.SelectedRows[0].Cells['User'].Value
    $script:SelSession = $sid

    $selPid = -1
    if ($gridP.SelectedRows.Count -gt 0) { $selPid = [int]$gridP.SelectedRows[0].Cells['Pid'].Value }

    $f = $script:Filter.ToLower()
    $gridP.SuspendLayout()
    $gridP.Rows.Clear()
    $shown = 0
    if ($script:BySession -and $script:BySession.ContainsKey($sid)) {
        foreach ($p in ($script:BySession[$sid] | Sort-Object MB -Descending)) {
            if ($f -and -not $p.Name.ToLower().Contains($f)) { continue }
            $prot = $script:Protected -contains $p.Name
            $dmb = 0; $dh = 0
            if ($script:PrevProcs.ContainsKey($p.Id)) {
                $dmb = $p.MB      - $script:PrevProcs[$p.Id].MB
                $dh  = $p.Handles - $script:PrevProcs[$p.Id].Handles
            }
            $cpu = if ($script:CpuPct.ContainsKey($p.Id)) { [double]$script:CpuPct[$p.Id] } else { 0.0 }
            $i = $gridP.Rows.Add([int]$p.Id, $p.Name, [double]$cpu, [int]$p.MB, [int]$dmb,
                                 [int]$p.Handles, [int]$dh, [int]$p.Threads,
                                 $(if ($prot) { L 'val.yes' } else { '' }))
            $row = $gridP.Rows[$i]
            if ($prot) { $row.DefaultCellStyle.ForeColor = $T.Faint }
            if ($cpu -ge 25) { $row.Cells['Cpu'].Style.ForeColor = $T.Danger }
            elseif ($cpu -ge 10) { $row.Cells['Cpu'].Style.ForeColor = $T.Warn }
            if ($p.Handles -gt 10000) { $row.Cells['Hnd'].Style.ForeColor = $T.Warn }
            if ($dh -gt 200)  { $row.Cells['DHnd'].Style.ForeColor = $T.Danger }
            if ($dmb -gt 200) { $row.Cells['DMB'].Style.ForeColor  = $T.Warn }
            if ([int]$p.Id -eq $selPid) { $row.Selected = $true }
            $shown++
        }
    }
    $gridP.ResumeLayout()
    $hdrP.Tag.Text = (L 'proc.header') -f $user, $sid, $shown
    $gridP.Tag.Invalidate()
}

# ============================================================================
# Enumeration loop
# ============================================================================
function Start-Refresh {
    if ($script:Refreshing) { return }
    $script:Refreshing = $true
    $lblStatus.ForeColor = $T.Accent
    $lblStatus.Text      = L 'status.refresh'
    $script:Prog.Stage = 'start'; $script:Prog.Current = -1

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($script:EnumScript.ToString())
    [void]$ps.AddArgument($script:Prog)

    $script:EnumJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date; Killed = $false }
}

function Complete-Refresh {
    if (-not $script:EnumJob) { return }
    $elapsed = ((Get-Date) - $script:EnumJob.Started).TotalSeconds

    if (-not $script:EnumJob.Handle.IsCompleted) {
        if ($elapsed -gt $EnumTimeoutSeconds -and -not $script:EnumJob.Killed) {
            $script:EnumJob.Killed = $true
            try { [void]$script:EnumJob.PS.BeginStop($null, $null) } catch { }
            $stuck = $script:Prog.Current
            $stage = $script:Prog.Stage
            $lblStatus.ForeColor = $T.Danger
            $lblStatus.Text = if ($stuck -ge 0) {
                (L 'status.stuck') -f $stuck, [int]$elapsed
            } else {
                (L 'status.stuckStg') -f [int]$elapsed, $stage
            }
            Write-ActionLog 'ENUM-TIMEOUT' ("session={0} stage={1} {2}s" -f $stuck, $stage, [int]$elapsed) 'ABORTED'
            try { $script:EnumJob.PS.Dispose() } catch { }
            $script:EnumJob = $null
            $script:Refreshing = $false
        } elseif ($script:Prog.Current -ge 0) {
            $lblStatus.ForeColor = $T.Dim
            $lblStatus.Text = (L 'status.refreshS') -f $script:Prog.Current, $elapsed
        }
        return
    }

    $result = $null
    try { $result = $script:EnumJob.PS.EndInvoke($script:EnumJob.Handle) } catch { }
    try { $script:EnumJob.PS.Dispose() } catch { }
    $script:EnumJob    = $null
    $script:Refreshing = $false

    if ($result -and $result.Count -gt 0) {
        $r = $result[0]

        # CPU% : tick delta between two snapshots / (elapsed x cores)
        $pct = @{}
        if ($script:PrevCpuAt) {
            $dt = ($r.Stamp - $script:PrevCpuAt).TotalSeconds
            if ($dt -gt 0.5) {
                foreach ($p in $r.Processes) {
                    if (-not $script:PrevCpu.ContainsKey($p.Id)) { continue }
                    $d = ($p.CpuTicks - $script:PrevCpu[$p.Id]) / 1e7
                    if ($d -le 0) { continue }
                    $v = [math]::Round((($d / $dt) / $script:Cores) * 100, 1)
                    if ($v -gt 0) { $pct[$p.Id] = $v }
                }
            }
        }
        $script:CpuPct = $pct

        $newCpu = @{}
        $newPrev = @{}
        foreach ($p in $r.Processes) {
            $newCpu[$p.Id]  = $p.CpuTicks
            $newPrev[$p.Id] = @{ MB = $p.MB; Handles = $p.Handles }
        }

        $script:Sessions  = $r.Sessions
        $script:Processes = $r.Processes
        Update-Views
        $script:PrevProcs = $newPrev
        $script:PrevCpu   = $newCpu
        $script:PrevCpuAt = $r.Stamp
        $lblStatus.ForeColor = $T.Ok
        $lblStatus.Text = (L 'status.updated') -f $r.Stamp.ToString('HH:mm:ss'), $r.Ms
    }
}

# ============================================================================
# Performance loop
# ============================================================================
function Tick-Perf {
    if ($script:PerfJob) {
        $el = ((Get-Date) - $script:PerfJob.Started).TotalSeconds
        if ($script:PerfJob.Handle.IsCompleted) {
            $res = $null
            try { $res = $script:PerfJob.PS.EndInvoke($script:PerfJob.Handle) } catch { }
            try { $script:PerfJob.PS.Dispose() } catch { }
            $script:PerfJob = $null
            if ($res -and $res.Count -gt 0) { Apply-Perf $res[0] }
        } elseif ($el -gt $PerfTimeoutSeconds) {
            try { [void]$script:PerfJob.PS.BeginStop($null, $null) } catch { }
            try { $script:PerfJob.PS.Dispose() } catch { }
            $script:PerfJob = $null
            # Do NOT blank the values - keep the last known reading visible
            $script:Tiles['cpu'].Sub.Text = L 'perf.delayed'
            foreach ($k in @('cpu','ram','disk','net')) { $script:Tiles[$k].Val.ForeColor = $T.Faint }
        }
        return
    }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($script:PerfScript.ToString())
    $script:PerfJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
}

function Apply-Perf {
    param($p)

    if ($null -ne $p.Cpu) {
        $script:Tiles['cpu'].Val.Text = "{0}%" -f $p.Cpu
        $script:Tiles['cpu'].Sub.Text = (L 'perf.kernel') -f $p.Kernel
        Push-Hist $script:HistCpu ([double]$p.Cpu)
        $script:Tiles['cpu'].Val.ForeColor = if ($p.Cpu -ge 90) { $T.Danger }
                                            elseif ($p.Cpu -ge 70) { $T.Warn } else { $T.Accent }
    }

    if ($null -ne $p.RamPct) {
        $script:Tiles['ram'].Val.Text = "{0} GB" -f $p.RamUsedGB
        $script:Tiles['ram'].Sub.Text = (L 'perf.free') -f $p.RamPct, [math]::Round($p.RamTotalGB - $p.RamUsedGB, 1)
        Push-Hist $script:HistRam ([double]$p.RamPct)
        $script:Tiles['ram'].Val.ForeColor = if ($p.RamPct -ge 92) { $T.Danger }
                                            elseif ($p.RamPct -ge 80) { $T.Warn } else { $T.Text }
    }

    if ($null -ne $p.DiskRaw -and $script:PrevPerf -and $null -ne $script:PrevPerf.DiskRaw) {
        $dNum  = $p.DiskRaw  - $script:PrevPerf.DiskRaw
        $dBase = $p.DiskBase - $script:PrevPerf.DiskBase
        if ($dBase -gt 0 -and $p.DiskFreq -gt 0) {
            $ms = [math]::Round((($dNum / $dBase) / $p.DiskFreq) * 1000, 1)
            if ($ms -lt 0) { $ms = 0 }
            $script:Tiles['disk'].Val.Text = "{0} ms" -f $ms
            $script:Tiles['disk'].Sub.Text = (L 'perf.queue') -f $p.DiskQueue, $DiskWarnMs
            Push-Hist $script:HistDisk ([double]$ms)
            $script:Tiles['disk'].Val.ForeColor = if ($ms -ge ($DiskWarnMs * 2)) { $T.Danger }
                                                  elseif ($ms -ge $DiskWarnMs) { $T.Warn } else { $T.Ok }
        }
    }

    if ($null -ne $p.NetRx -and $script:PrevPerf -and $null -ne $script:PrevPerf.NetRx) {
        $secs = ($p.At - $script:PrevPerf.At).TotalSeconds
        if ($secs -gt 0.2) {
            $rx = [math]::Round((($p.NetRx - $script:PrevPerf.NetRx) * 8 / 1MB) / $secs, 1)
            $tx = [math]::Round((($p.NetTx - $script:PrevPerf.NetTx) * 8 / 1MB) / $secs, 1)
            if ($rx -lt 0) { $rx = 0 }
            if ($tx -lt 0) { $tx = 0 }
            $script:Tiles['net'].Val.Text = "{0} Mb/s" -f ([math]::Round($rx + $tx, 1))
            $script:Tiles['net'].Sub.Text = (L 'perf.io') -f $rx, $tx, $p.NetName
            Push-Hist $script:HistNet ([double]($rx + $tx))
        }
    }

    if ($p.BootTime) {
        $up = (Get-Date) - $p.BootTime
        $script:Info['up'].Text = (L 'info.uptimeFmt') -f [int]$up.TotalDays, $up.Hours
        $script:Info['up'].ForeColor = if ($up.TotalDays -ge 60) { $T.Warn } else { $T.Text }
    }

    $script:PrevPerf = $p
    foreach ($k in @('cpu','ram','disk','net')) { $script:Tiles[$k].Spark.Invalidate() }
}

# ============================================================================
# Actions
# ============================================================================
function Get-SelSessions {
    if ($gridS.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((L 'dlg.noSel'), (L 'dlg.noSelTitle'), 'OK', 'Information')
        return @()
    }
    $out = @()
    foreach ($r in $gridS.SelectedRows) {
        $out += [pscustomobject]@{
            Id    = [int]$r.Cells['Id'].Value
            User  = [string]$r.Cells['User'].Value
            State = [string]$r.Cells['State'].Value
            Proc  = [int]$r.Cells['Proc'].Value
        }
    }
    return @($out | Sort-Object Id)
}

function Get-SelSession {
    if ($gridS.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((L 'dlg.noSel'), (L 'dlg.noSelTitle'), 'OK', 'Information')
        return $null
    }
    $r = $gridS.SelectedRows[0]
    [pscustomobject]@{
        Id    = [int]$r.Cells['Id'].Value
        User  = [string]$r.Cells['User'].Value
        State = [string]$r.Cells['State'].Value
        Proc  = [int]$r.Cells['Proc'].Value
    }
}

function Format-SessionList {
    param($Sessions, [int]$Max = 12)
    $lines = @($Sessions | Select-Object -First $Max | ForEach-Object { "   {0}   {1}" -f $_.Id, $_.User })
    if ($Sessions.Count -gt $Max) { $lines += (L 'dlg.andMore') -f ($Sessions.Count - $Max) }
    $lines -join "`n"
}

function Confirm-Action {
    param([string]$Title, [string]$Body, [switch]$Second)
    $icon = if ($Second) { 'Stop' } else { 'Warning' }
    ([System.Windows.Forms.MessageBox]::Show($Body, $Title, 'YesNo', $icon, 'Button2') -eq 'Yes')
}

$btnMsg.Add_Click({
  try {
    $ss = @(Get-SelSessions); if ($ss.Count -eq 0) { return }

    # A disconnected session has nobody at the screen: the box opens but
    # is never seen. Say so up front.
    $off  = @($ss | Where-Object { $_.State -ne 'Active' })
    $warn = if ($off.Count) { (L 'dlg.msgOffline') -f $off.Count } else { '' }

    $body = if ($ss.Count -eq 1) {
        ((L 'dlg.msgOne') -f $ss[0].User) + $warn
    } else {
        ((L 'dlg.msgMany') -f $ss.Count, (Format-SessionList $ss)) + $warn
    }
    if (Confirm-Action (L 'dlg.msgTitle') $body) {
        $n = 0; $fail = @()
        foreach ($s in $ss) {
            $rc = [Rds.Wts]::SendMessage($s.Id, (L 'msg.notifyTitle'), (L 'msg.notify'))
            if ($rc -eq 0) {
                $n++
                Write-ActionLog 'MSG' "$($s.User) (session $($s.Id))" 'ok'
            } else {
                $fail += "$($s.Id) -> error $rc"
                Write-ActionLog 'MSG' "$($s.User) (session $($s.Id))" "ERROR $rc"
            }
        }
        if ($fail.Count) {
            $hint = if ($fail -match 'error 5') { L 'err.accessDenied' } else { '' }
            $lblStatus.ForeColor = $T.Danger
            $lblStatus.Text = (L 'status.msgFail') -f $n, $ss.Count, $fail.Count
            [void][System.Windows.Forms.MessageBox]::Show(
                ((L 'err.failedList') -f ($fail -join "`n"), $hint),
                (L 'err.msgTitle'), 'OK', 'Warning')
        } else {
            $lblStatus.ForeColor = $T.Ok
            $lblStatus.Text = (L 'status.msgSent') -f $n, $ss.Count
        }
    }
  } catch {
    Write-ActionLog 'MSG' 'handler' ("ERROR: " + $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.msgTitle'), 'OK', 'Error')
  }
})

$btnDisc.Add_Click({
  try {
    $ss = @(Get-SelSessions); if ($ss.Count -eq 0) { return }
    $body = if ($ss.Count -eq 1) {
        (L 'dlg.discOne') -f $ss[0].User
    } else {
        (L 'dlg.discMany') -f $ss.Count, (Format-SessionList $ss)
    }
    if (Confirm-Action (L 'dlg.discTitle') $body) {
        foreach ($s in $ss) {
            $ok = [Rds.Wts]::Disconnect($s.Id)
            Write-ActionLog 'DISCONNECT' "$($s.User) (session $($s.Id))" $ok
        }
        $lblStatus.ForeColor = $T.Ok
        $lblStatus.Text = (L 'status.disc') -f $ss.Count
        Start-Refresh
    }
  } catch {
    Write-ActionLog 'DISCONNECT' 'handler' ("ERROR: " + $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.discTitle'), 'OK', 'Error')
  }
})

$btnOff.Add_Click({
  try {
    $ss = @(Get-SelSessions); if ($ss.Count -eq 0) { return }
    $body = if ($ss.Count -eq 1) {
        (L 'dlg.logoffOne') -f $ss[0].User
    } else {
        (L 'dlg.logoffMany') -f $ss.Count, (Format-SessionList $ss)
    }
    if (Confirm-Action (L 'dlg.logoffTitle') $body) {
        foreach ($s in $ss) {
            $ok = [Rds.Wts]::Logoff($s.Id)
            Write-ActionLog 'LOGOFF' "$($s.User) (session $($s.Id))" $ok
        }
        $lblStatus.ForeColor = $T.Warn
        $lblStatus.Text = (L 'status.logoff') -f $ss.Count
        Start-Refresh
    }
  } catch {
    Write-ActionLog 'LOGOFF' 'handler' ("ERROR: " + $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.logoffTitle'), 'OK', 'Error')
  }
})

$btnRst.Add_Click({
    if ($gridS.SelectedRows.Count -gt 1) {
        [void][System.Windows.Forms.MessageBox]::Show(
            (L 'dlg.resetMulti'), (L 'dlg.resetMultiT'), 'OK', 'Warning')
        return
    }
    $s = Get-SelSession; if (-not $s) { return }
    if (-not (Confirm-Action (L 'dlg.resetT1') ((L 'dlg.resetB1') -f $s.User))) { return }
    if (-not (Confirm-Action (L 'dlg.resetT2') ((L 'dlg.resetB2') -f $s.Id, $s.User) -Second)) { return }
    try {
        Start-Process -FilePath 'rwinsta.exe' -ArgumentList "$($s.Id)" -WindowStyle Hidden
        Write-ActionLog 'RWINSTA' "$($s.User) (session $($s.Id))" 'sent'
        $lblStatus.ForeColor = $T.Danger
        $lblStatus.Text = (L 'status.reset') -f $s.Id
    } catch {
        Write-ActionLog 'RWINSTA' "session $($s.Id)" ("ERROR: " + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.resetTitle'), 'OK', 'Error')
    }
    Start-Refresh
})

$btnKill.Add_Click({
    if ($gridP.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show((L 'dlg.noProcSel'), (L 'dlg.noSelTitle'), 'OK', 'Information')
        return
    }
    $s = Get-SelSession; if (-not $s) { return }
    $r    = $gridP.SelectedRows[0]
    $tpid = [int]$r.Cells['Pid'].Value
    $name = [string]$r.Cells['Name'].Value

    if ($script:Protected -contains $name) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ((L 'dlg.protected') -f $name), (L 'dlg.protectedT'), 'OK', 'Stop')
        return
    }

    if (Confirm-Action (L 'dlg.killTitle') ((L 'dlg.killBody') -f $name, $tpid, $s.Id, $s.User)) {
        try {
            Stop-Process -Id $tpid -Force -ErrorAction Stop
            Write-ActionLog 'KILL' "$name pid=$tpid session=$($s.Id) user=$($s.User)" 'ok'
            $lblStatus.ForeColor = $T.Ok
            $lblStatus.Text = (L 'status.killed') -f $name, $tpid
        } catch {
            Write-ActionLog 'KILL' "$name pid=$tpid" ("ERROR: " + $_.Exception.Message)
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.killTitle'), 'OK', 'Error')
        }
        Start-Refresh
    }
})

$btnCsv.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = 'CSV (*.csv)|*.csv'
    $dlg.FileName = "sessions_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try {
        $rows = foreach ($s in $script:Sessions) {
            $list = if ($script:BySession.ContainsKey($s.Id)) { $script:BySession[$s.Id] } else { @() }
            $mb = 0; foreach ($p in $list) { $mb += $p.MB }
            [pscustomobject]@{
                Id = $s.Id; User = $s.User; Session = $s.Win; State = $s.State
                IdleMin = $s.IdleMin; Logon = $s.Logon; Processes = $list.Count
                RamMB = $mb; QueryMs = $s.QueryMs
            }
        }
        $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        $lblStatus.ForeColor = $T.Ok
        $lblStatus.Text = L 'status.csv'
        Write-ActionLog 'EXPORT' $dlg.FileName 'ok'
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.csvTitle'), 'OK', 'Error')
    }
})

# --- context menus ----------------------------------------------------------
$menuS = New-Object System.Windows.Forms.ContextMenuStrip
$menuS.BackColor = $T.Panel
$menuS.ForeColor = $T.Text
$menuS.Font      = $F.Body
$menuS.ShowImageMargin = $false
try { $menuS.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object RdsUi.DarkMenuColors)) } catch { }

[void]$menuS.Items.Add('').Add_Click({ $btnMsg.PerformClick() })
[void]$menuS.Items.Add('').Add_Click({ $btnDisc.PerformClick() })
[void]$menuS.Items.Add('').Add_Click({ $btnOff.PerformClick() })
[void]$menuS.Items.Add('').Add_Click({ $btnRst.PerformClick() })
[void]$menuS.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menuS.Items.Add('').Add_Click({
    if (-not $gridS.SelectedRows.Count) { return }
    $id = [int]$gridS.SelectedRows[0].Cells['Id'].Value
    try {
        Start-Process 'mstsc.exe' -ArgumentList "/shadow:$id /control"
        Write-ActionLog 'SHADOW' "session $id" 'started'
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, (L 'err.shadowTitle'), 'OK', 'Error')
    }
})
[void]$menuS.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menuS.Items.Add('').Add_Click({
    if ($gridS.SelectedRows.Count) { [System.Windows.Forms.Clipboard]::SetText([string]$gridS.SelectedRows[0].Cells['User'].Value) }
})
[void]$menuS.Items.Add('').Add_Click({
    if ($gridS.SelectedRows.Count) { [System.Windows.Forms.Clipboard]::SetText([string]$gridS.SelectedRows[0].Cells['Id'].Value) }
})
$gridS.ContextMenuStrip = $menuS

$gridS.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -ne 'Right' -or $e.RowIndex -lt 0) { return }
    # Move to the right-clicked row unless it is already part of the selection
    if (-not $s.Rows[$e.RowIndex].Selected) {
        $s.ClearSelection()
        $s.Rows[$e.RowIndex].Selected = $true
    }
})

$menuP = New-Object System.Windows.Forms.ContextMenuStrip
$menuP.BackColor = $T.Panel
$menuP.ForeColor = $T.Text
$menuP.Font      = $F.Body
$menuP.ShowImageMargin = $false
try { $menuP.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object RdsUi.DarkMenuColors)) } catch { }

[void]$menuP.Items.Add('').Add_Click({ $btnKill.PerformClick() })
[void]$menuP.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menuP.Items.Add('').Add_Click({
    if ($gridP.SelectedRows.Count) { [System.Windows.Forms.Clipboard]::SetText([string]$gridP.SelectedRows[0].Cells['Pid'].Value) }
})
[void]$menuP.Items.Add('').Add_Click({
    if ($gridP.SelectedRows.Count) { [System.Windows.Forms.Clipboard]::SetText([string]$gridP.SelectedRows[0].Cells['Name'].Value) }
})
$gridP.ContextMenuStrip = $menuP

$gridP.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -ne 'Right' -or $e.RowIndex -lt 0) { return }
    $s.ClearSelection()
    $s.Rows[$e.RowIndex].Selected = $true
})

# --- dark owner-drawn tooltips ----------------------------------------------
$tip = New-Object System.Windows.Forms.ToolTip
$tip.OwnerDraw    = $true
$tip.InitialDelay = 450
$tip.ReshowDelay  = 200
$tip.AutoPopDelay = 12000
$script:Tooltip   = $tip

$tip.Add_Popup({
    param($s, $e)
    $txt = $s.GetToolTip($e.AssociatedControl)
    $sz  = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $F.Body)
    $e.ToolTipSize = New-Object System.Drawing.Size(($sz.Width + 16), ($sz.Height + 12))
})

$tip.Add_Draw({
    param($s, $e)
    $bg = New-Object System.Drawing.SolidBrush($T.Panel)
    $pn = New-Object System.Drawing.Pen($T.Border)
    $e.Graphics.FillRectangle($bg, $e.Bounds)
    $e.Graphics.DrawRectangle($pn, 0, 0, ($e.Bounds.Width - 1), ($e.Bounds.Height - 1))
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.ToolTipText, $F.Body,
        (New-Object System.Drawing.Point(8, 6)), $T.Text)
    $bg.Dispose(); $pn.Dispose()
})

# ============================================================================
# Events and timers
# ============================================================================
$gridS.Add_SelectionChanged({ Update-ProcessView })
$btnRefresh.Add_Click({ Start-Refresh })

$txtFind.Add_Enter({
    if ($this.Text -eq $script:FindHint) { $this.Text = ''; $this.ForeColor = $T.Text }
})
$txtFind.Add_Leave({
    if ($this.Text.Trim() -eq '') { $this.Text = $script:FindHint; $this.ForeColor = $T.Faint }
})
$txtFind.Add_TextChanged({
    $t = $txtFind.Text
    $script:Filter = if ($t -eq $script:FindHint) { '' } else { $t }
    if ($script:Sessions.Count) { Update-Views }
})

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 200
$pollTimer.Add_Tick({ Complete-Refresh })

$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 30000
$autoTimer.Add_Tick({
    # Do not pull the list out from under a multi-row selection
    if ($gridS.SelectedRows.Count -gt 1) { return }
    Start-Refresh
})

$perfTimer = New-Object System.Windows.Forms.Timer
$perfTimer.Interval = 2000
$perfTimer.Add_Tick({ Tick-Perf })

$btnPerf.Add_Click({
    if ($perf.Visible) {
        $perf.Visible = $false; $perfTimer.Stop()
    } else {
        $perf.Visible = $true;  $perfTimer.Start()
    }
    $btnPerf.Text = if ($perf.Visible) { L 'btn.hidePanel' } else { L 'btn.showPanel' }
})

$cboAuto.Add_SelectedIndexChanged({
    $autoTimer.Stop()
    switch ($cboAuto.SelectedIndex) {
        1 { $autoTimer.Interval = 10000; $autoTimer.Start() }
        2 { $autoTimer.Interval = 30000; $autoTimer.Start() }
    }
})

$cboLang.Add_SelectedIndexChanged({
    $new = if ($cboLang.SelectedIndex -eq 1) { 'tr' } else { 'en' }
    if ($new -eq $script:Lang) { return }
    $script:Lang = $new
    Apply-Language
})

$form.Add_KeyDown({
    if ($_.KeyCode -eq 'F5') { Start-Refresh; $_.Handled = $true }
    if ($_.Control -and $_.KeyCode -eq 'F') { $txtFind.Focus(); $txtFind.SelectAll(); $_.Handled = $true }
    if ($_.Control -and $_.KeyCode -eq 'A' -and $gridS.Focused) { $gridS.SelectAll(); $_.Handled = $true }
    if ($_.KeyCode -eq 'Delete' -and $gridP.Focused) { $btnKill.PerformClick(); $_.Handled = $true }
    if ($_.KeyCode -eq 'Escape') { $form.Close() }
})

$form.Add_FormClosing({
    Write-Settings
    $pollTimer.Stop(); $autoTimer.Stop(); $perfTimer.Stop()
    foreach ($j in @($script:EnumJob, $script:PerfJob)) {
        if ($j) { try { $j.PS.Dispose() } catch { } }
    }
    try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
})

# ============================================================================
# Start
# ============================================================================
Write-ActionLog 'START' "$AppName $AppVersion" $(if ($script:IsAdmin) { 'admin' } else { 'limited' })

Apply-Language

$form.Add_Shown({
    $cfg = $script:Config
    if ($cfg) {
        try {
            if ($cfg.Width -ge $form.MinimumSize.Width -and $cfg.Height -ge $form.MinimumSize.Height) {
                $form.Size = New-Object System.Drawing.Size([int]$cfg.Width, [int]$cfg.Height)
                $pt = New-Object System.Drawing.Point([int]$cfg.X, [int]$cfg.Y)
                # Ignore a saved position that is no longer on any screen
                if ([System.Windows.Forms.Screen]::AllScreens |
                    Where-Object { $_.WorkingArea.Contains($pt) }) {
                    $form.Location = $pt
                }
            }
            if ($null -ne $cfg.AutoIndex) { $cboAuto.SelectedIndex = [int]$cfg.AutoIndex }
            if ($cfg.PerfVisible -eq $false) { $btnPerf.PerformClick() }
            if ($cfg.Maximized) { $form.WindowState = 'Maximized' }
        } catch { }
    }

    if ($cfg -and $cfg.Splitter -and [int]$cfg.Splitter -gt 80 -and [int]$cfg.Splitter -lt ($split.Height - 80)) {
        try { $split.SplitterDistance = [int]$cfg.Splitter } catch { }
    } else {
        $split.SplitterDistance = [int]($split.Height * 0.56)
    }

    Layout-Bars
    $actBar.PerformLayout(); $foot.PerformLayout()

    switch ($cboAuto.SelectedIndex) {
        1       { $autoTimer.Interval = 10000; $autoTimer.Start() }
        2       { $autoTimer.Interval = 30000; $autoTimer.Start() }
        default { $autoTimer.Stop() }
    }

    $pollTimer.Start()
    if ($perf.Visible) { $perfTimer.Start(); Tick-Perf }
    Start-Refresh
})

[void]$form.ShowDialog()
