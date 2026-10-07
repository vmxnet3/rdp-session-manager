# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.4.0] - 2026-10-07

### Added
- With no session selected the process list now shows **every process on the
  server**, with session id and user columns, so a task can be found and ended
  without walking session by session. Combined with the search box this is the
  fastest way to locate a runaway process.
- Ending a task no longer requires a session to be selected; the target session
  and user are read from the process row itself and shown in the confirmation.
- Clear the session selection with Ctrl+Shift+A or the right-click menu.

### Fixed
- Sorting the session list by a column header was lost a few seconds later.
  `Rows.Clear()` discards the sort, and every refresh rebuilds the list, so the
  order silently reverted. The sorted column and direction are now captured
  before the rebuild and re-applied afterwards, for both lists.
- The selection used to come back on the next refresh even after being cleared,
  because the previously selected session was restored as a fallback.

## [1.3.3] - 2026-09-15

### Fixed
- Switching the interface language threw "Cannot convert null to type
  System.Drawing.Color" and left the UI half translated. `Apply-Language` was
  aborting partway through, so buttons were translated but column headers and
  the summary strip were not.
  - The state colour was picked with a `switch` statement. PowerShell does not
    run the `default` branch when the input is `$null`; the statement returns
    nothing and assigning that to `ForeColor` throws. Replaced with a helper
    that always returns a colour.
  - `$T` and `$F` (theme and fonts) are now explicitly `$script:` scoped.
  - `Apply-Language` catches its own errors, so a single bad step can no longer
    leave the interface in a mixed state.

### Added
- A global WinForms exception handler. Instead of the raw .NET crash dialog,
  errors now show a readable message and the full stack trace is appended to
  `RdpSesinMenicir.log`.

## [1.3.2] - 2026-09-15

### Added
- The notification text is now typed in a dialog before sending, instead of
  being a fixed string in the script. The last message is remembered for the
  session and seeded from the language file on first use.

### Fixed
- Searching threw "Cannot convert null to type System.Drawing.Color".
  `Rows.Clear()` and every `Rows.Add()` raise `SelectionChanged`, so
  `Update-ProcessView` ran in the middle of a rebuild against half-written
  state. The event is now suppressed while the session list is being rebuilt,
  which also removes a lot of redundant work per refresh.

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
