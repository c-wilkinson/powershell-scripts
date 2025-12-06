<# 
.SYNOPSIS
    Validates that JSON config files contain only the expected domains,
    based on realm/env trigrams defined in a JSON mapping file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JsonFolder,

    [Parameter(Mandatory = $true)]
    [string]$MappingPath,

    [switch]$FailOnError
)

function Get-DomainMapping {
    <#
    .SYNOPSIS
        Loads realm/environment mapping from JSON and returns two hashtables:
        RealmByTrigram and EnvByTrigram, keyed case-insensitively by trigram.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Mapping file not found at '$Path'."
    }

    $raw = Get-Content -Path $Path -Raw
    $json = $raw | ConvertFrom-Json

    if (-not $json) {
        throw "Mapping JSON '$Path' appears to be empty or invalid."
    }

    $realmByTrigram = @{}
    $envByTrigram   = @{}

    foreach ($realm in @($json.Realms)) {
        if (-not $realm.Trigram -or -not $realm.Slug) {
            throw "Realm entry is missing Trigram or Slug in '$Path'."
        }

        $key = $realm.Trigram.ToUpper()
        if ($realmByTrigram.ContainsKey($key)) {
            throw "Duplicate realm trigram '$key' in '$Path'."
        }

        $realmByTrigram[$key] = $realm
    }

    foreach ($env in @($json.Environments)) {
        if (-not $env.Trigram -or -not $env.Slug) {
            throw "Environment entry is missing Trigram or Slug in '$Path'."
        }

        $key = $env.Trigram.ToUpper()
        if ($envByTrigram.ContainsKey($key)) {
            throw "Duplicate environment trigram '$key' in '$Path'."
        }

        $envByTrigram[$key] = $env
    }

    return [pscustomobject]@{
        RealmByTrigram = $realmByTrigram
        EnvByTrigram   = $envByTrigram
    }
}

function Test-JsonDomain {
    <#
    .SYNOPSIS
        Validates a single JSON file's login identifiers (user@realm-env.com
        and realm-env\user) based on realm/env trigrams.

    .OUTPUTS
        PSCustomObject with:
        File, Prefix, Realm, Environment, Status, Message, BadMatches (string[])
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$RealmByTrigram,

        [Parameter(Mandatory = $true)]
        [hashtable]$EnvByTrigram
    )

    if (-not (Test-Path -Path $Path)) {
        return [pscustomobject]@{
            File        = $Path
            Prefix      = $null
            Realm       = $null
            Environment = $null
            Status      = 'Error'
            Message     = "File not found."
            BadMatches  = @()
        }
    }

    $fileInfo = Get-Item -LiteralPath $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileInfo.Name)

    if ($baseName.Length -lt 6) {
        return [pscustomobject]@{
            File        = $fileInfo.FullName
            Prefix      = $null
            Realm       = $null
            Environment = $null
            Status      = 'Error'
            Message     = "Filename too short to contain realm+env trigrams (need at least 6 chars)."
            BadMatches  = @()
        }
    }

    # First 3 = realm, next 3 = env (case-insensitive)
    $realmTri = $baseName.Substring(0,3).ToUpper()
    $envTri   = $baseName.Substring(3,3).ToUpper()
    $prefix   = "$realmTri$envTri"

    if (-not $RealmByTrigram.ContainsKey($realmTri)) {
        return [pscustomobject]@{
            File        = $fileInfo.FullName
            Prefix      = $prefix
            Realm       = $null
            Environment = $null
            Status      = 'Error'
            Message     = "No realm mapping found for trigram '$realmTri'."
            BadMatches  = @()
        }
    }

    if (-not $EnvByTrigram.ContainsKey($envTri)) {
        return [pscustomobject]@{
            File        = $fileInfo.FullName
            Prefix      = $prefix
            Realm       = $RealmByTrigram[$realmTri].Slug
            Environment = $null
            Status      = 'Error'
            Message     = "No environment mapping found for trigram '$envTri'."
            BadMatches  = @()
        }
    }

    $realm = $RealmByTrigram[$realmTri]
    $env   = $EnvByTrigram[$envTri]

    $realmSlug = $realm.Slug
    $envSlug   = $env.Slug

    if (-not $realmSlug -or -not $envSlug) {
        return [pscustomobject]@{
            File        = $fileInfo.FullName
            Prefix      = $prefix
            Realm       = $realm.Slug
            Environment = $env.Slug
            Status      = 'Error'
            Message     = "Mapping for '$prefix' is missing realm or environment slug."
            BadMatches  = @()
        }
    }

    $expectedDomain      = ("{0}-{1}.com" -f $realmSlug.ToLower(), $envSlug.ToLower())
    $expectedLogonDomain = ("{0}-{1}"     -f $realmSlug.ToLower(), $envSlug.ToLower())
    $content = Get-Content -Path $fileInfo.FullName -Raw
    $badMatches = New-Object System.Collections.Generic.List[string]
    $atPattern   = '(?i)[a-z0-9._%+-]+@(?<domain>[a-z0-9.-]+)'
    $atMatches   = [regex]::Matches($content, $atPattern)

    foreach ($atMatch in $atMatches) {
        $login  = $atMatch.Value
        $domain = $atMatch.Groups['domain'].Value.ToLower()

        # Only care about realm-env.com shape
        $domainMatch = [regex]::Match($domain, '^(?<realmPart>[a-z0-9-]+)-(?<envPart>[a-z0-9-]+)\.com$')
        if (-not $domainMatch.Success) {
            continue
        }

        $realmPart = $domainMatch.Groups['realmPart'].Value.ToLower()
        $envPart   = $domainMatch.Groups['envPart'].Value.ToLower()

        if ($realmPart -ne $realmSlug.ToLower() -or $envPart -ne $envSlug.ToLower()) {
            [void]$badMatches.Add($login)
        }
    }

    $slashPattern = '(?i)(?<logondomain>[a-z0-9.-]+)\\\\[a-z0-9.$_-]+'
    $slashMatches = [regex]::Matches($content, $slashPattern)

    foreach ($slashMatch in $slashMatches) {
        $login       = $slashMatch.Value
        $logonDomain = $slashMatch.Groups['logondomain'].Value.ToLower()
        $logonDomainMatch = [regex]::Match($logonDomain, '^(?<realmPart>[a-z0-9-]+)-(?<envPart>[a-z0-9-]+)$')
        if (-not $logonDomainMatch.Success) {
            continue
        }
		
        $realmPart = $logonDomainMatch.Groups['realmPart'].Value.ToLower()
        $envPart   = $logonDomainMatch.Groups['envPart'].Value.ToLower()
        if ($realmPart -ne $realmSlug.ToLower() -or $envPart -ne $envSlug.ToLower()) {
            [void]$badMatches.Add($login)
        }
    }

    if ($atMatches.Count -eq 0 -and $slashMatches.Count -eq 0) {
        return [pscustomobject]@{
            File        = $fileInfo.FullName
            Prefix      = $prefix
            Realm       = $realmSlug
            Environment = $envSlug
            Status      = 'Warning'
            Message     = "No domains found. Expected realm/env: '$realmSlug-$envSlug'."
            BadMatches  = @()
        }
    }

    if ($badMatches.Count -gt 0) {
        return [pscustomobject]@{
            File        = $fileInfo.FullName
            Prefix      = $prefix
            Realm       = $realmSlug
            Environment = $envSlug
            Status      = 'Fail'
            Message     = "Found domain(s) with incorrect realm/env. Expected ONLY '$expectedDomain' or '$expectedLogonDomain\\<user>'."
            BadMatches  = $badMatches.ToArray()
        }
    }

    return [pscustomobject]@{
        File        = $fileInfo.FullName
        Prefix      = $prefix
        Realm       = $realmSlug
        Environment = $envSlug
        Status      = 'Pass'
        Message     = "All realm/env-style domains match '$expectedDomain' / '$expectedLogonDomain\\<user>'."
        BadMatches  = @()
    }
}

if (-not (Test-Path -Path $JsonFolder)) {
    throw "JSON folder not found at '$JsonFolder'."
}

$mapping = Get-DomainMapping -Path $MappingPath
$realmByTri = $mapping.RealmByTrigram
$envByTri   = $mapping.EnvByTrigram

$jsonFiles = Get-ChildItem -Path $JsonFolder -Filter *.json -File -Recurse

if (-not $jsonFiles) {
    Write-Host "No JSON files found under '$JsonFolder'."
    return
}

$results = foreach ($file in $jsonFiles) {
    Test-JsonDomain -Path $file.FullName -RealmByTrigram $realmByTri -EnvByTrigram $envByTri
}

$results |
    Select-Object File, Prefix, Realm, Environment, Status, Message,
        @{ Name = 'BadMatches'; Expression = { $_.BadMatches -join '; ' } } |
    Format-Table -AutoSize

if ($FailOnError -and ($results.Status -contains 'Fail' -or $results.Status -contains 'Error')) {
    throw "One or more files failed domain validation."
}
