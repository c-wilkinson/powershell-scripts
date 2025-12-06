param(
    [string]$OutputFolder = "$(Join-Path $PSScriptRoot 'json-domains-tests')",
    [string]$MappingFile  = "$(Join-Path $PSScriptRoot 'DomainMapping.json')",
    [int]   $FileCount    = 100,
    [double]$InvalidRatio = 0.30
)

if (-not (Test-Path $MappingFile)) {
    throw "Mapping file not found at: $MappingFile"
}

# Load mapping
$mapping = Get-Content $MappingFile -Raw | ConvertFrom-Json
$realms  = @($mapping.Realms)
$envs    = @($mapping.Environments)

if (-not $realms.Count -or -not $envs.Count) {
    throw "Invalid mapping file: must contain Realms[] and Environments[]."
}

# Reset folder
if (Test-Path $OutputFolder) {
    Remove-Item -Recurse -Force -Path $OutputFolder
}
New-Item -ItemType Directory -Path $OutputFolder | Out-Null

$firsts = "ted","alice","maria","bob","steve","clark","lois","tony","nat","bruce","peter"
$lasts  = "wayne","stark","banner","parker","dawson","black","hill","romanov"

function Get-RandomOther {
    param(
        [array]$Items,
        [string]$CurrentSlug
    )
    $candidates = $Items | Where-Object { $_.Slug -ne $CurrentSlug }
    return ($candidates | Get-Random)
}

function Get-WrongPair {
    param(
        [string]$RealmSlug,
        [string]$EnvSlug,
        [array]$Realms,
        [array]$Envs
    )

    # 0 = wrong realm, 1 = wrong env, 2 = both
    $mode = Get-Random -Minimum 0 -Maximum 3

    $wrongRealm = $RealmSlug
    $wrongEnv   = $EnvSlug

    if ($mode -eq 0 -or $mode -eq 2) {
        $wrongRealm = (Get-RandomOther -Items $Realms -CurrentSlug $RealmSlug).Slug
    }

    if ($mode -eq 1 -or $mode -eq 2) {
        $wrongEnv = (Get-RandomOther -Items $Envs -CurrentSlug $EnvSlug).Slug
    }

    return @{
        Realm = $wrongRealm
        Env   = $wrongEnv
    }
}

Write-Host "Generating $FileCount test login JSON files into: $OutputFolder" -ForegroundColor Cyan

$formats = @('AtFormat','SlashFormat','Both')

for ($i = 1; $i -le $FileCount; $i++) {

    $realm = $realms | Get-Random
    $env   = $envs   | Get-Random

    # Decide if this whole file is invalid
    $isInvalid = ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt $InvalidRatio)

    # Which login formats are used in this file?
    $formatChoice = $formats | Get-Random

    $first = $firsts | Get-Random
    $last  = $lasts  | Get-Random

    # simple username for slash-style login
    $username = ("{0}{1}" -f $first.Substring(0,1), $last).ToLower()

    $correctRealmSlug = $realm.Slug
    $correctEnvSlug   = $env.Slug

    $correctAtDomain      = "{0}-{1}.com" -f $correctRealmSlug, $correctEnvSlug
    $correctSlashDomain   = "{0}-{1}"     -f $correctRealmSlug, $correctEnvSlug

    $users = @()

    # ----- AtFormat: user@realm-env.com -----
    if ($formatChoice -eq 'AtFormat' -or $formatChoice -eq 'Both') {

        if ($isInvalid) {
            $wrongPair = Get-WrongPair -RealmSlug $correctRealmSlug -EnvSlug $correctEnvSlug -Realms $realms -Envs $envs
            $domainForAt = "{0}-{1}.com" -f $wrongPair.Realm, $wrongPair.Env
        }
        else {
            $domainForAt = $correctAtDomain
        }

        $loginAt = "{0}.{1}@{2}" -f $first.ToLower(), $last.ToLower(), $domainForAt.ToLower()

        $users += [pscustomobject]@{
            User   = $loginAt
            Format = 'AtFormat'
        }
    }

    # ----- SlashFormat: realm-env\username -----
    if ($formatChoice -eq 'SlashFormat' -or $formatChoice -eq 'Both') {

        if ($isInvalid) {
            $wrongPair = Get-WrongPair -RealmSlug $correctRealmSlug -EnvSlug $correctEnvSlug -Realms $realms -Envs $envs
            $slashDomain = "{0}-{1}" -f $wrongPair.Realm, $wrongPair.Env
        }
        else {
            $slashDomain = $correctSlashDomain
        }

        # JSON escaping is handled by ConvertTo-Json later
        $loginSlash = "{0}\{1}" -f $slashDomain.ToLower(), $username

        $users += [pscustomobject]@{
            User   = $loginSlash
            Format = 'SlashFormat'
        }
    }

    # Safety: ensure at least one entry
    if ($users.Count -eq 0) {
        $loginAt = "{0}.{1}@{2}" -f $first.ToLower(), $last.ToLower(), $correctAtDomain.ToLower()
        $users += [pscustomobject]@{
            User   = $loginAt
            Format = 'AtFormat'
        }
        $isInvalid = $false
        $formatChoice = 'AtFormat'
    }

    $fileName = "{0}{1}-User{2}.json" -f $realm.Trigram, $env.Trigram, $i

    $jsonObject = [ordered]@{
        Users         = $users
        ValidExpected = -not $isInvalid
        FormatsUsed   = $formatChoice
    }

    $jsonText = $jsonObject | ConvertTo-Json -Depth 5

    Set-Content -Path (Join-Path $OutputFolder $fileName) `
                -Value $jsonText `
                -Encoding UTF8
}

Write-Host "Generation complete!" -ForegroundColor Green
Write-Host ("~{0} valid files"   -f [int]($FileCount * (1 - $InvalidRatio)))
Write-Host ("~{0} invalid files" -f [int]($FileCount * $InvalidRatio))
Write-Host "Files are in: $OutputFolder"
