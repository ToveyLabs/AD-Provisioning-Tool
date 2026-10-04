# Change log

## vNext password-policy count correction

- Normalized password-policy validation results to arrays before checking their count, preventing strict-mode failures when exactly one policy problem is returned.
- Normalized one-item group and password-maintenance selections so later count checks remain reliable in Windows PowerShell 5.1.

## vNext domain-controller regression correction

- Fixed OU/container browsing when a search or filter returns exactly one AD object; all grid data is now copied into an explicit bindable list rather than cast from the AD object.
- Fixed initial security-group browsing when no groups have yet been selected.
- Replaced timer callbacks that depended on expired local variables with explicit timer-owned operation contexts for both user import and password maintenance.
- Corrected password show/hide handlers so they use the event sender rather than an expired local control variable.
- Added cleanup of queued plaintext password values if the application closes during an operation.

## vNext layout correction

- Prevented the Import Users left column from collapsing when the form first expands from its design-time size.
- Restored the visible CSV path field and **Browse CSV...** button.
- Added bounded proportional splitter sizing and explicit table rows so labels and controls remain aligned at common window sizes and DPI settings.

## vNext

- Renamed the application to **AD User Provisioning Tool** and retained the original source unchanged.
- Replaced scattered globals with one application-state object for connection, CSV, mappings, prepared plan, groups, results and logs.
- Added a permanent connection banner, explicit connect/reconnect/disconnect actions, current/alternate credentials, and Preview/Live state.
- Corrected alternate identities so `DOMAIN\username` and UPN values are preserved exactly.
- Centralised `Server`, optional `Credential`, and terminating error behavior for every AD command.
- Added current-connection validation and blocked disconnected live writes.
- Replaced weak password generation with cryptographically secure, class-balanced passwords of at least 14 characters.
- Added practical checks against the default domain minimum length and complexity policy.
- Added ten-field CSV mapping, safe per-row validation, duplicate detection, existing-user checks, status counts, status filtering, and row inclusion controls.
- Added an immutable import settings snapshot and automatic invalidation after relevant setting changes.
- Added live preflight for OU/container, groups, username collisions and connection state.
- Corrected full UPN suffix handling and home path construction.
- Renamed the home option to **Set home-folder attributes** and made UNC root and drive configurable. Folder creation is deliberately not implied or performed.
- Ensured group failures do not bypass home attribute processing; both are reported independently.
- Added sensitive initial-password export with operator-selected path and attempted per-operator NTFS ACL restriction.
- Added a separate **Password Maintenance** tab with OU/container scope, preview list, protected/disabled/service-account exclusions, manual inclusion, exact counts and individual processing.
- Added typed live-reset confirmation, optional unlock, per-user results, successful-only password export and password-free audit CSV.
- Rebuilt the UI with tabs, layout containers, docking, resizing, maximisation and DPI scaling; removed the old maximum-size restriction.
- Removed the execution-policy bypass, duplicate connection success message, automatic Desktop password export and normal-log password exposure.
- Added timer-queued batch processing so the interface updates between individual operations and all UI changes remain on the UI thread.
