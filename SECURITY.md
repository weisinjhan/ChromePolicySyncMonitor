# Security and privacy

## What this project changes

The measurement modes temporarily modify this machine-level Windows policy:

```text
HKLM\SOFTWARE\Policies\Google\Chrome\DeveloperToolsAvailability
```

Changing an `HKLM` policy can affect every Chrome profile on the computer. The
temporary Chrome profile created by this project isolates browser profile data;
it does **not** isolate the machine policy. Run the tool only on a test computer
or during an approved maintenance window.

The program saves the original registry state before a measurement and restores
it in a `finally` block. `Recover.cmd` can restore unfinished backups after an
abnormal interruption. Keep the local `data` directory until recovery has been
verified.

## Local data and privacy

The `data` directory is intentionally ignored by Git. Generated files can
contain:

- Windows computer and user names;
- local Chrome and project paths;
- Chrome, Windows and PowerShell versions;
- timestamps and test identifiers;
- the previous registry value and type;
- diagnostic error text.

Do not publish `data`, `results.csv`, `monitor.log`, `backup-*.json`, Chrome test
profiles, validation reports or probe output without reviewing and redacting
them. The compiled `CdpProbeHelper.exe` is also ignored and is rebuilt locally
from `CdpProbeHelper.cs`.

## Remote debugging exposure

The isolated Chrome process is started with a loopback remote-debugging endpoint
and a random available port. While a test is running, local processes belonging
to the same user may be able to connect to that endpoint. Do not use the isolated
test profile for real credentials or sensitive browsing.

## Credentials and GitHub

This project does not require API keys, passwords or GitHub tokens. Never place
credentials in source files, command files, Git remote URLs or issue reports.
Use the operating system credential manager or GitHub's browser-based login.

## Reporting a vulnerability

Because this repository is private, report security concerns to the repository
owner through a private GitHub channel. Include reproduction steps, affected
versions and impact, but remove credentials, registry exports and personal data.