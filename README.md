# Get-UserScheduledTasks

> Inventory of custom Windows scheduled tasks across Active Directory servers, with HTML and CSV reports.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-informational.svg)](CHANGELOG.md)

[Version française](README.fr.md)

---

## Overview

`Get-UserScheduledTasks.ps1` queries Windows servers over WinRM and lists the scheduled tasks that were not shipped with the operating system (everything outside `\Microsoft\*`). It highlights risky configurations such as tasks running with a stored password or a named account at the highest privilege level, and produces a standalone, sortable HTML report plus a CSV export. The script is read-only: it never creates, changes or deletes a task.

---

## Features

- Server list taken from Active Directory (Windows Server only) or supplied manually
- Parallel collection through `Invoke-Command` with a configurable throttle limit
- Per task: path, name, state, author, run-as account, logon type, run level, triggers, actions, last/next run, last result
- Risk flags: stored credentials, named account with highest privileges, last run in error, disabled task, unreadable task
- Built-in and well-known service accounts detected by SID, so detection does not depend on the OS language
- Vendor tasks classified separately from custom ones; known Windows/installer noise hidden by default
- Standalone HTML report (light theme, offline, no external request): clickable KPI cards, full-text search, filters, sortable columns, expandable rows, filtered CSV export
- Collection errors reported per server instead of being silently dropped

---

## Requirements

| Dependency | Version |
|------------|---------|
| PowerShell | >= 5.1 |
| ActiveDirectory module (RSAT) | Only when `-ComputerName` is not used |
| WinRM enabled on targets | Windows Server 2012 or later (needs `Get-ScheduledTask`) |
| Rights | Local administrator on the target servers |

---

## Installation

```bash
git clone https://github.com/9LivesITSolutions/Get-UserScheduledTasks.git
cd Get-UserScheduledTasks
```

The script is saved as UTF-8 with BOM so that accented characters are read correctly by Windows PowerShell 5.1. Keep the BOM if you edit it.

---

## Usage

```powershell
# All enabled Windows servers of the domain
.\Get-UserScheduledTasks.ps1

# Specific servers
.\Get-UserScheduledTasks.ps1 -ComputerName srv01,srv02

# Limit to an OU, hide vendor tasks
.\Get-UserScheduledTasks.ps1 -SearchBase "OU=Servers,DC=contoso,DC=local" -ExcludeVendor

# Alternate credentials
.\Get-UserScheduledTasks.ps1 -ComputerName srv01 -Credential (Get-Credential)
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ComputerName` | AD servers | Servers to query |
| `-SearchBase` | whole domain | OU used for the AD lookup |
| `-ExcludeVendor` | off | Hide tasks classified as third-party vendor tasks |
| `-NoisePattern` | see script | Regex (start of name) of Windows/installer tasks hidden by default |
| `-IncludeNoise` | off | Show the tasks matching `-NoisePattern` |
| `-ThrottleLimit` | `32` | Number of servers queried in parallel |
| `-OutputPath` | `.\Output` | Output folder |
| `-Credential` | current user | Credentials used for remoting |

---

## Output

| File | Content |
|------|---------|
| `ScheduledTasks_<timestamp>.html` | Interactive report |
| `ScheduledTasks_<timestamp>.csv` | All tasks (`;` delimiter, UTF-8 with BOM) |
| `Unreachable_<timestamp>.csv` | Collection errors per server (only if any) |

The report labels are in French.

### Flags

| Flag | Meaning |
|------|---------|
| `MotDePasseStocké` | Named account with a `Password` or `InteractiveOrPassword` logon type |
| `CompteNominatif+Highest` | Named account running at the highest run level |
| `DernierRunEnErreur` | Last result is neither success, running nor not-yet-run |
| `ErreurLecture` | Task found but its definition could not be read; details in the description |
| `Désactivée` | Task is disabled |

---

## Limitations

- `MotDePasseStocké` is inferred from the logon type. The Task Scheduler API does not tell whether a password is actually stored, so treat the flag as a strong indication, not a proof.
- Tasks under `\Microsoft\*` are excluded, including custom tasks placed there.
- Clustered scheduled tasks are not returned by `Get-ScheduledTask` and are not covered.
- Servers whose `OperatingSystem` attribute is empty in Active Directory are not returned by the automatic lookup.

---

## Project Structure

```
Get-UserScheduledTasks/
├── Get-UserScheduledTasks.ps1   # Collection script and HTML template
├── README.md
├── README.fr.md
└── CHANGELOG.md
```

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'feat: add my-feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

Please follow [Conventional Commits](https://www.conventionalcommits.org/) for commit messages.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

Maintained by **9 Lives IT Solutions**.
