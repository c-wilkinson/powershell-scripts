# PowerShell Scripts
A personal collection of PowerShell scripts for solving annoyances, automating repetitive tasks, and experimenting with new ideas.  
Some are polished, some are quick hacks - all are here because they proved useful at least once.

---

## Contents

| Script                        | Description |
|------------------------------|-------------|
| [`create-test-db.ps1`](create-test-db.ps1)        | Automates setup of a SQL Server 2022 Docker container, waits for readiness, and runs an init script to create a schema with users, products, and orders tables plus supporting indexes, views, and procs. |
| [`update-json-template.ps1`](update-json-template.ps1) | Updates a single JSON template with environment-specific values and optional nested property changes. Supports `-Verbose` and `-WhatIf` for safe pipeline use. |

---
These scripts are provided as-is. There's no hand-holding. If something here helps you, feel free to adapt and reuse however you like.
