<#
.SYNOPSIS
    Updates a single JSON template with environment-specific values and writes it beside the template.

.DESCRIPTION
    Loads one JSON template file, updates key fields such as Environment, AppName, Version,
    plus any arbitrary dotted/array-indexed paths via -Set.
    Saves a new JSON next to the template, replacing 'XXXX' in the filename with the Environment,
    or prefixing the Environment if 'XXXX' is not present.

.PARAMETER TemplatePath
    Path to a single JSON template file (e.g. .\json-templates\XXXXCluster.json).

.PARAMETER Environment
    Environment name used for JSON updates and filename substitution (e.g. DEV, UAT, PROD).

.PARAMETER AppName
    Optional application name to set in the JSON.

.PARAMETER Version
    Optional version string to set in the JSON.

.PARAMETER Set
    Hashtable of additional updates. Supports dotted paths and array indices:
    e.g. @{ "Cluster.Name" = "UAT-SQL-CL1"; "Nodes[0].Name" = "SQLU01" }

.EXAMPLE
    .\Update-JsonTemplate.ps1 -TemplatePath .\json-templates\XXXXCluster.json -Environment UAT `
        -AppName Payments -Version 3.1.0 

    .\Update-JsonTemplate.ps1 -TemplatePath .\json-templates\XXXXCluster.json -Environment UAT `
        -AppName Payments -Version 3.1.0 `
        -Set @{ "Cluster.Name"="UAT-SQL-CL1"; "Spec.Settings.Port"=1433 }

    .\Update-JsonTemplate.ps1 -TemplatePath .\json-templates\XXXXCluster.json -Environment UAT `
        -AppName Payments -Version 3.1.0 `
        -Set @{ "Cluster.Name"="UAT-SQL-CL1"; "Spec.Settings.Port"=1433 } -Verbose
		
    .\Update-JsonTemplate.ps1 -TemplatePath .\json-templates\XXXXCluster.json -Environment UAT `
        -AppName Payments -Version 3.1.0 `
        -Set @{ "Cluster.Name"="UAT-SQL-CL1"; "Spec.Settings.Port"=1433 } -Verbose -WhatIf

.NOTES
    Supports -Verbose and -WhatIf (dry run)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TemplatePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Environment,

    [string]$AppName,
    [string]$Version,

    [hashtable]$Set
)

<#
.SYNOPSIS
    Sets a nested JSON property on a PowerShell object.
.DESCRIPTION
    Supports dotted paths (e.g., 'Spec.Settings.Port') and indexed array paths
    (e.g., 'Nodes[0].Name'). Creates intermediate objects/arrays if needed.
.PARAMETER Object
    The PowerShell object representing the JSON.
.PARAMETER Path
    The dotted or indexed property path to set.
.PARAMETER Value
    The value to assign at the specified path.
.EXAMPLE
    Set-JsonProperty -Object $json -Path "Cluster.Nodes[1].Name" -Value "SQLP02"
#>
function Set-JsonProperty {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] $Value
    )

    function Get-PropValue($obj, [string]$name) {
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
        } else {
            return ($obj.PSObject.Properties[$name]).Value
        }
    }
    function Has-Prop($obj, [string]$name) {
        if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
        else { return $null -ne $obj.PSObject.Properties[$name] }
    }
    function Set-PropValue([ref]$obj, [string]$name, $val) {
        if ($obj.Value -is [System.Collections.IDictionary]) {
            $obj.Value[$name] = $val
        } else {
            if ($obj.Value.PSObject.Properties[$name]) {
                $obj.Value.$name = $val
            } else {
                Add-Member -InputObject $obj.Value -NotePropertyName $name -NotePropertyValue $val -Force | Out-Null
            }
        }
    }

    $segments = $Path -split '\.'
    $cursor = $Object

    for ($i = 0; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]

        if ($seg -match '^(?<name>[^\[]+)\[(?<idx>\d+)\]$') {
            $name = $Matches['name']; $idx = [int]$Matches['idx']

            if (-not (Has-Prop $cursor $name)) {
                # new array
                $alist = [System.Collections.ArrayList]::new()
                Set-PropValue ([ref]$cursor) $name $alist
            }

            $list = Get-PropValue $cursor $name
            if (-not ($list -is [System.Collections.IList])) {
                # coerce existing array to ArrayList
                $alist = [System.Collections.ArrayList]::new()
                foreach ($it in @($list)) { [void]$alist.Add($it) }
                Set-PropValue ([ref]$cursor) $name $alist
                $list = $alist
            }

            while ($list.Count -le $idx) { [void]$list.Add($null) }

            if ($i -eq $segments.Count - 1) {
                $list[$idx] = $Value
                return
            } else {
                if ($null -eq $list[$idx]) {
                    $list[$idx] = [pscustomobject]@{}
                }
                $cursor = $list[$idx]
                continue
            }
        }
        else {
            if (-not (Has-Prop $cursor $seg)) {
                Set-PropValue ([ref]$cursor) $seg ([pscustomobject]@{})
            }

            if ($i -eq $segments.Count - 1) {
                Set-PropValue ([ref]$cursor) $seg $Value
                return
            } else {
                $next = Get-PropValue $cursor $seg
                if ($null -eq $next -or -not ($next -is [psobject] -or $next -is [System.Collections.IDictionary])) {
                    Set-PropValue ([ref]$cursor) $seg ([pscustomobject]@{})
                    $next = Get-PropValue $cursor $seg
                }
                $cursor = $next
            }
        }
    }
}

# --- Validate input points to a single file ---
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    throw "TemplatePath must be a single JSON file. Not found or not a file: $TemplatePath"
}
if ([IO.Path]::GetExtension($TemplatePath) -notin @('.json','.JSON')) {
    throw "TemplatePath must be a .json file: $TemplatePath"
}

Write-Verbose "Loading template: $TemplatePath"
$raw = Get-Content -LiteralPath $TemplatePath -Raw
try {
    $json = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "Failed to parse JSON: $TemplatePath - $($_.Exception.Message)"
}

# Apply standard fields if provided
Write-Verbose "Setting Environment = $Environment"
Set-JsonProperty -Object $json -Path 'Environment' -Value $Environment

if ($PSBoundParameters.ContainsKey('AppName')) {
    Write-Verbose "Setting AppName = $AppName"
    $json.AppName = $AppName
}
if ($PSBoundParameters.ContainsKey('Version')) {
    Write-Verbose "Setting Version = $Version"
    $json.Version = $Version
}

# Apply user-specified fields
if ($Set) {
    foreach ($k in $Set.Keys) {
        Write-Verbose "Setting $k = $($Set[$k])"
        Set-JsonProperty -Object $json -Path $k -Value $Set[$k]
    }
}

# Build output filename beside the template
$dir      = (Get-Item -LiteralPath $TemplatePath).DirectoryName
$baseName = [IO.Path]::GetFileNameWithoutExtension($TemplatePath)
$baseName = $baseName -replace '\.json$',''  # defensive

# Replace 'XXXX' or prefix Environment
$replaced = ($baseName -replace 'XXXX', [Regex]::Escape($Environment))
if ($replaced -eq $baseName) { $replaced = "$Environment-$baseName" }

$outPath = Join-Path $dir ($replaced + ".json")

# Avoid clobbering the template if names collide
if ([IO.Path]::GetFullPath($outPath) -eq [IO.Path]::GetFullPath($TemplatePath)) {
    $outPath = Join-Path $dir ($replaced + ".generated.json")
    Write-Verbose "Output name collided with template; using $outPath"
}

# Write (or WhatIf)
$pretty = $json | ConvertTo-Json -Depth 50
if ($PSCmdlet.ShouldProcess($outPath, "Write JSON beside template")) {
    Write-Verbose "Writing: $outPath"
    $pretty | Set-Content -LiteralPath $outPath -Encoding UTF8
    Write-Host "Created $outPath"
} else {
    Write-Host "[WhatIf] Would create $outPath"
}
