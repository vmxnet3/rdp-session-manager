# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.3.1] - 2026-09-03

### Fixed
- The tool closed immediately on start. `$cboAuto.SelectedIndex = 2` ran
  before `Apply-Language` had populated the combo box, so assigning an index
  to an empty list threw a terminating error and the window never appeared.
  The interval is now set solely by `Apply-Language`.
- `Run.cmd` reports a non-zero exit code and prints the command to run for
  the full error message, instead of closing silently.

## [1.3.0] - 2026-09-03

First public release.

### Added
- English and Turkish interface, switchable at runtime from the toolbar.
  English is the default; the choice is remembered.
- Real **CPU %** for every session and process, via `NtQuerySystemInformation`.
  One call returns name, session, RAM, handles, threads and CPU time without
  opening a handle per process, so this costs nothing extra.
- Elevation prompt on start: restart as administrator, or continue with
  **limited rights** shown in the toolbar and title bar.
- Version number in the title bar, footer and log file.
- Settings persisted to `%APPDATA%\belesware\rdp-sesin-menicir\settings.json`:
  window size and position, splitter, refresh interval, panel visibility,
  language.
- `Ctrl+A` selects all sessions.
- `Run.cmd` launcher, so the tool can be started by double-clicking without
  touching the machine's execution policy.
- Build stamp in the C# block that must match `$AppVersion`, so a stale type
  loaded in the same PowerShell session is detected instead of silently used.

### Changed
- Toolbar reorganised into groups with separators; the search box now carries
  its own placeholder instead of a separate label.
- Removed the "cpu sn" checkbox — CPU is now always available and free.
- Column headers clarified (`ram (mb)`, `ram delta`, `handle delta`).
- Code comments translated to English.

## [1.2.0] - internal

### Added
- Left vertical performance panel (CPU, memory, disk latency, network) with
  sparklines, sampled on its own 2 second loop.
- Server summary: hostname, IP, uptime, total handles, total threads.
- Summary strip: active, disconnected, total RAM, stuck candidates.
- Delta columns for RAM and handle count.
- Search box, sortable columns, CSV export.
- Custom dark scrollbars; the native ones are always painted light.
- Owner-drawn dark tooltips on every control.
- Application icon drawn in code, so the script stays a single file.

### Fixed
- Notifications never appeared: the message box opened behind full screen
  applications. Now sent with `MB_TOPMOST | MB_SETFOREGROUND`, with lengths
  including the null terminator, and the Win32 error code is surfaced instead
  of being swallowed.
- Right-aligned controls were positioned only on `Resize`, so on first paint
  the Force reset button overlapped the Notify button and swallowed its
  clicks.
- Multi-row selection was destroyed by the automatic refresh; selections are
  now preserved and auto-refresh is skipped while several rows are selected.
- Performance values blanked out on a slow counter query; the last known
  value is kept and only marked as delayed.
- Button click handlers failed silently, because WinForms swallows errors
  raised inside them. They now report the error and log it.

## [1.1.0] - internal

### Added
- Multi-select for notify, disconnect and log off.
- Right-click menus on both lists.
- Session enumeration switched from parsing `quser.exe` to the WTS API —
  locale independent, and it made per-session timing possible.
- **Stuck session detection**: each `WTSQuerySessionInformation` call is timed
  and the responsible session ID is reported when enumeration stalls.

## [1.0.0] - internal

Initial version: session and process lists, notify / disconnect / log off /
end task / force reset, protected process list, action logging, background
runspace enumeration with timeout.
