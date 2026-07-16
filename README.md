# PowerShell Scripts
A personal collection of PowerShell scripts for solving annoyances, automating repetitive tasks, and experimenting with new ideas.  
Some are polished, some are quick hacks - all are here because they proved useful at least once.

---

## Contents

| Script                        | Description |
|------------------------------|-------------|
| [`Restart-SqlHost.ps1`](Restart-SqlHost.ps1) | POC: Safely restarts a Windows host running SQL Server by discovering local instances, failing over locally primary Availability Groups to a healthy replica, preferring Region A, verifying every failover, and restarting only when the host no longer owns any primary Availability Groups. |
| [`create-test-db.ps1`](create-test-db.ps1) | Creates or starts a SQL Server Docker container and builds a configurable test database containing users, products, orders, posts, events, indexes, views, functions, and stored procedures. |
| [`update-json-templates.ps1`](update-json-templates.ps1) | Updates a JSON template with environment-specific values and optional nested property changes. Supports dotted paths, array indexes, `-Verbose`, and `-WhatIf`. |
| [`validate-jsondomains.ps1`](validate-jsondomains.ps1) | Scans JSON files and checks that domains use the expected `realm-env` format based on the filename and configured domain mapping. |
| [`generate-testjsonfiles.ps1`](generate-testjsonfiles.ps1) | Generates sample JSON files containing a mixture of valid and invalid domains for testing `validate-jsondomains.ps1` and related CI pipelines. |

## Licence

This repository is released under [The Unlicense](LICENSE).

## Disclaimer

These scripts are provided as-is, without warranty. There's no hand-holding. If something here helps you, feel free to adapt and reuse however you like. Review and test them in a safe environment before using them against anything important.
