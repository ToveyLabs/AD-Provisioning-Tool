# Manual test checklist

Use a dedicated test OU and non-production accounts. Run Preview cases before Live cases. Record the workstation, Windows PowerShell version, domain controller, operator and outcome.

## Connection and safety

- [ ] Start the tool and confirm Preview is enabled and the banner says Disconnected.
- [ ] Connect with current Windows credentials; confirm domain/server and identity in the banner.
- [ ] Reconnect with `DOMAIN\username`; confirm the identity is not altered and reads use the selected server.
- [ ] Reconnect with a UPN; confirm the UPN is not prefixed or altered.
- [ ] Disconnect, turn Preview off, and confirm a live import and live reset are blocked.
- [ ] Reconnect, interrupt domain connectivity, and confirm live validation fails closed.
- [ ] Confirm the script does not alter process, user or machine execution policy.

## CSV import

- [ ] Load a CSV containing valid rows; map all relevant fields and inspect the preview.
- [ ] Load a CSV with a blank first name, blank last name and malformed email; confirm each bad row is identified without aborting the batch.
- [ ] Include two rows that generate the same username; confirm both are flagged appropriately and the duplicate is not live-importable.
- [ ] Include a username already in AD; confirm **Already exists** during validation and again in live preflight.
- [ ] Test each username format, including employee/student ID and email prefix.
- [ ] Confirm the UPN uses the full configured suffix, including multi-label domains.
- [ ] Use unique generated passwords at lengths 14 and above; confirm domain-policy rejections appear per user without stopping the batch.
- [ ] Use a custom password and confirm it is masked, Show toggles visibility, and practical policy checks run.
- [ ] Change an import-affecting setting after preparation and confirm Run Import is disabled until re-prepared.
- [ ] Filter Ready, Warning, Invalid and Already exists rows; include/exclude individual valid rows and confirm the count.
- [ ] Run Preview and independently verify that no user, membership or home attribute changes occur in AD.
- [ ] Select a missing/inaccessible OU and missing/inaccessible group; confirm live preflight blocks the run.
- [ ] In one live test, assign groups and set home-folder attributes together; confirm group processing does not bypass home attributes and errors are reported independently.
- [ ] Confirm the home directory becomes `\\server\share\username` and the configured drive is set. Confirm no physical folder is created.
- [ ] Cause one user creation failure and confirm later users continue.
- [ ] Export password-free results and inspect the CSV.
- [ ] For successful live creations, save the initial-password CSV to a chosen location; verify only created accounts appear and inspect NTFS permissions.

## OU password reset

- [ ] Choose an OU and load **Selected container only**; compare the grid with direct-child users in AD.
- [ ] Reload with **Include child OUs**; confirm descendant users are added.
- [ ] Confirm disabled accounts are excluded by default with a reason.
- [ ] Confirm `adminCount=1` and built-in Administrator-style protected accounts are excluded by default with a reason.
- [ ] Test the service-account regular-expression filter and confirm matches are excluded; test an invalid expression and confirm a clear error.
- [ ] Manually include/exclude rows and confirm the exact affected count updates.
- [ ] Run Preview and verify no passwords, change-at-logon flags or lock states change.
- [ ] Turn Preview off and confirm the dialog shows domain, OU, scope and exact count.
- [ ] Enter an incorrect typed phrase and confirm execution remains disabled; enter `RESET <count> USERS` exactly and confirm it enables.
- [ ] Use unique passwords (recommended), force change at next logon, and leave Unlock off; verify outcomes.
- [ ] Separately enable Unlock and verify it occurs only when selected.
- [ ] Test a custom fixed password and confirm the conspicuous warning and policy check.
- [ ] Arrange a partial reset failure (for example, one deliberately denied test account); confirm remaining users continue and per-user status is accurate.
- [ ] Confirm the password CSV contains only accounts whose password reset succeeded, never failed or preview-only accounts.
- [ ] Confirm the operator chooses the password CSV location and receives the NTFS protection result.
- [ ] Confirm the separate audit CSV contains timestamp, operator, domain, OU, username, action and result, and contains no password column or plaintext password.
- [ ] Confirm no previous password is requested, retained or exported.

## UI and cleanup

- [ ] Resize and maximise on 100%, 125%, 150% and (if available) 200% display scaling; verify tabs and grids remain usable.
- [ ] Close during idle and after a completed batch; confirm the form, timer and credential references are released without console password output.

