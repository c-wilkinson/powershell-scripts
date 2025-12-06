# PowerShell Scripts
A personal collection of PowerShell scripts for solving annoyances, automating repetitive tasks, and experimenting with new ideas.  
Some are polished, some are quick hacks - all are here because they proved useful at least once.

---

## Contents

| Script                        | Description |
|------------------------------|-------------|
| [`create-test-db.ps1`](create-test-db.ps1)        | Automates setup of a SQL Server Docker container, waits for readiness, and runs an init script to create a schema with users, products, and orders tables plus supporting indexes, views, and procs. |
| [`update-json-template.ps1`](update-json-template.ps1) | Updates a single JSON template with environment-specific values and optional nested property changes. Supports `-Verbose` and `-WhatIf` for safe pipeline use. |
| [`validate-jsondomains.ps1`](validate-jsondomains.ps1) | Scans JSON files to ensure all domains use the correct `realm-env` format based on file naming conventions. Supports both `user@realm-env.com` and `realm-env\user` formats. Generates Pass/Fail/Warning results with detailed mismatches. |
| [`generate-testjsonfiles.ps1`](generate-testjsonfiles.ps1) | Creates sample JSON files for automated validation. Randomly mixes realms, environments, login formats, and expected validity to support testing the validator or CI pipelines. Includes metadata so expected vs actual validation results can be compared. |

---
These scripts are provided as-is. There's no hand-holding. If something here helps you, feel free to adapt and reuse however you like.
