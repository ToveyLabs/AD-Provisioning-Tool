# AD User Provisioning Tool

`ADUserProvisioningTool-vNext.ps1` is a Windows PowerShell 5.1 WinForms application for staged CSV user provisioning and separate OU-based password maintenance.

## Requirements

- Windows 10/11 or a Windows Server administration workstation.
- Windows PowerShell 5.1 (not PowerShell 7 for normal operation).
- Microsoft ActiveDirectory PowerShell module supplied by RSAT.
- An account with only the AD permissions required for the intended operation.

The program has no third-party dependencies and does not change execution policy. If local policy blocks scripts, use your organisation's approved signing or launch process; do not weaken machine-wide policy.

## Start

Open Windows PowerShell 5.1, change to this folder, and run:

```powershell
.\ADUserProvisioningTool-vNext.ps1
```

Preview mode is enabled by default. Use **Connect** to validate either current Windows credentials or an alternate identity in `DOMAIN\username` or UPN form. Every AD read and write is routed through the chosen server and credential.

## Import Users

1. Load a CSV.
2. Review the ten column mappings. First and last name are required.
3. Choose username, target OU, full UPN suffix, password, group and optional home-folder attribute settings.
4. Select **Validate and Preview**. Invalid rows are skipped individually; the grid reports Ready, Warning, Invalid and Already exists counts. Use the Include checkbox and status filter to review the exact plan.
5. Run in Preview first. Turn Preview off only when ready for a live preflight and import.

The home-folder option sets the AD `homeDrive` and `homeDirectory` attributes only. It does not create folders or change share/file permissions. The UNC root and drive letter are configurable.

For live-created accounts, the application offers a sensitive initial-password CSV export and attempts to restrict its NTFS ACL to the current operator. It also supports a separate password-free results export.

## Password Maintenance

1. Connect to AD and choose an OU/container.
2. Select container-only or subtree scope, optionally refine the service-account exclusion regular expression, and load users.
3. Disabled and protected/admin accounts are excluded by default. Review and manually change Include checkboxes as appropriate.
4. Choose unique secure passwords (recommended) or a fixed password, length, force-change behavior, and optional unlock.
5. Preview first. A live run requires the exact typed phrase `RESET <count> USERS`.

Users are processed independently. After a live run, only successfully reset passwords are eligible for the sensitive CSV. A separate password-free audit CSV is offered. Previous passwords are never read, stored or exported.

## Security notes

- Generated passwords use `RandomNumberGenerator`, default to 16 characters in the interface (configurable from 6 to 128, subject to domain policy), and contain uppercase, lowercase, digit and permitted special characters.
- Domain minimum length and complexity settings are checked where exposed by the default domain password policy. Fine-grained policy, password history, banned-password filters and identity-dependent rules can still reject a password at execution time.
- Plaintext passwords are never written to the ordinary audit log, status bar or results messages.
- Password CSVs are inherently sensitive. The ACL hardening result is shown; verify permissions and storage controls yourself.
- Preview performs AD reads when connected but never invokes an AD write cmdlet.

## Development without a domain

CSV parsing, mapping, username generation, row validation, filters and the full interface can be exercised offline in Preview mode. AD reads/writes are isolated in connection-aware functions (`Invoke-ADConnectionValidation`, `Test-ImportTargetPreflight`, `Invoke-OneImportRow`, `Load-ResetUsers`, and `Invoke-OnePasswordReset`), making them straightforward to mock in a test harness. Offline rows are marked Warning because existence, OU and group checks cannot be completed.

## Verification status

The supplied development notes report a successful PowerShell parser check and static checks for centralized AD parameters, weak random-number use, execution-policy changes and console password output. The publication review inspected the source and documentation; it did not rerun the PowerShell parser or test the Windows interface or live AD operations. See [the manual test checklist](MANUAL-TEST-CHECKLIST.md) for verification in a test domain.

## Download

Choose **Code > Download ZIP** on GitHub, then extract the archive before running the script. This repository contains the PowerShell source and documentation; no installer is required.

See [CHANGELOG.md](CHANGELOG.md) for development history.

.\ADUserProvisioningTool-vNext.ps1

sample-users.csv is supplied to test with

## Important Notes
- Test in a lab environment before using in production
- Ensure you have appropriate permissions in Active Directory
- No credentials are stored by the tool

## License
MIT License

## Author
Graham Tovey


