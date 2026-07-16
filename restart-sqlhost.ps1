#Requires -Modules dbatools

<#
.SYNOPSIS
    Gracefully restarts a Windows server hosting SQL Server instances.

.DESCRIPTION
    The script:

    1. Accepts a Windows server name.
    2. Discovers all running SQL Server Database Engine instances.
    3. Discovers Availability Groups currently primary on those instances.
    4. Discovers eligible secondary replicas automatically.
    5. Prefers replicas hosted in Region A.
    6. Fails over each Availability Group without allowing data loss.
    7. Verifies every failover.
    8. Verifies that no Availability Group remains primary on the server.
    9. Restarts the Windows server.

    The restart is aborted if any discovery, validation, failover or
    verification operation fails.

.PARAMETER ServerName
    Windows server to be gracefully restarted.

    Expected naming convention:

        [A-Z]{5}[A-B][A-Z]{6}[0-9]{3}

    The sixth character identifies the region:

        A = preferred region
        B = secondary region

.EXAMPLE
    .\Restart-SqlServerGracefully.ps1 -ServerName ABCDEAFGHIJK123

    Discovers SQL Server instances on ABCDEAFGHIJK123, safely fails over
    locally primary Availability Groups, and then restarts the machine.

.EXAMPLE
    .\Restart-SqlServerGracefully.ps1 `
        -ServerName ABCDEAFGHIJK123 `
        -WhatIf

    Displays the proposed failovers and restart without making changes.

.NOTES
    This script handles SQL Server Always On Availability Groups.

    It does not fail over SQL Server Failover Cluster Instances.
#>

[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = 'High'
)]
param (
    [Parameter(
        Mandatory,
        Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string] $ServerName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module dbatools -ErrorAction Stop

$ServerNamePattern = '^(?<Prefix>[A-Z]{5})(?<Region>[AB])(?<Suffix>[A-Z]{6})(?<Number>[0-9]{3})$'

$FailoverTimeoutSeconds = 120
$VerificationInterval   = 5

# Tracks successful failovers so that useful information can be reported
# if a later failover fails.
$CompletedFailovers = [System.Collections.Generic.List[object]]::new()


function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the console.

    .DESCRIPTION
        Writes an informational, warning, error or success message with a
        timestamp. Warning messages use Write-Warning, while error and
        success messages are displayed using appropriate console colours.

    .PARAMETER Message
        The text to write to the console.

    .PARAMETER Level
        The severity of the message.

        Valid values are:

            INFO
            WARNING
            ERROR
            SUCCESS

        The default value is INFO.

    .EXAMPLE
        Write-Log -Message 'Beginning SQL Server discovery.'

    .EXAMPLE
        Write-Log `
            -Message 'Availability Group failover completed.' `
            -Level SUCCESS

    .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    switch ($Level) {
        'WARNING' {
            Write-Warning "[$timestamp] $Message"
        }

        'ERROR' {
            Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red
        }

        'SUCCESS' {
            Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green
        }

        default {
            Write-Host "[$timestamp] [INFO] $Message"
        }
    }
}


function Get-ShortHostName {
    <#
    .SYNOPSIS
        Extracts the short Windows hostname from a SQL Server name.

    .DESCRIPTION
        Removes an optional SQL Server instance name and DNS suffix from a
        server or SQL instance name.

        The returned hostname is converted to uppercase.

        Supported input formats include:

            SERVER
            SERVER\INSTANCE
            SERVER.domain.example
            SERVER.domain.example\INSTANCE

    .PARAMETER Name
        The server, DNS or SQL instance name to normalise.

    .EXAMPLE
        Get-ShortHostName -Name 'SQLSERVER01.domain.example\REPORTING'

        Returns:

            SQLSERVER01

    .OUTPUTS
        System.String.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Name
    )

    $serverPart = ($Name.Trim() -split '\\', 2)[0]
    $shortName  = ($serverPart -split '\.', 2)[0]

    return $shortName.ToUpperInvariant()
}

function Get-SqlInstanceNamePart {
    <#
    .SYNOPSIS
        Extracts the SQL Server instance-name portion of a SQL instance.

    .DESCRIPTION
        Returns the named-instance portion of a SQL Server connection name.

        If no named instance is present, the function returns MSSQLSERVER to
        represent the default SQL Server instance.

    .PARAMETER SqlInstance
        SQL Server instance name to examine.

    .EXAMPLE
        Get-SqlInstanceNamePart -SqlInstance 'SQLSERVER01\REPORTING'

        Returns:

            REPORTING

    .EXAMPLE
        Get-SqlInstanceNamePart -SqlInstance 'SQLSERVER01'

        Returns:

            MSSQLSERVER

    .OUTPUTS
        System.String.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $SqlInstance
    )

    $parts = $SqlInstance.Trim() -split '\\', 2

    if ($parts.Count -eq 2) {
        return $parts[1].ToUpperInvariant()
    }

    return 'MSSQLSERVER'
}

function Get-NormalisedSqlInstance {
    <#
    .SYNOPSIS
        Converts a SQL instance name into a consistent comparison format.

    .DESCRIPTION
        Normalises a SQL instance as an uppercase short hostname followed by
        its instance name.

        Default SQL Server instances are represented using MSSQLSERVER.

        This allows values such as the following to be compared consistently:

            SQLSERVER01
            SQLSERVER01.domain.example
            SQLSERVER01\MSSQLSERVER

    .PARAMETER SqlInstance
        SQL Server instance name to normalise.

    .EXAMPLE
        Get-NormalisedSqlInstance `
            -SqlInstance 'sqlserver01.domain.example\Reporting'

        Returns:

            SQLSERVER01\REPORTING

    .OUTPUTS
        System.String.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $SqlInstance
    )

    $hostName     = Get-ShortHostName -Name $SqlInstance
    $instanceName = Get-SqlInstanceNamePart -SqlInstance $SqlInstance

    return "$hostName\$instanceName"
}

function Test-SameSqlInstance {
    <#
    .SYNOPSIS
        Determines whether two names refer to the same SQL Server instance.

    .DESCRIPTION
        Normalises two SQL Server instance names and performs a
        case-insensitive comparison.

        The comparison tolerates differences such as DNS suffixes, character
        casing and the explicit or implicit use of MSSQLSERVER for a default
        SQL Server instance.

    .PARAMETER First
        First SQL Server instance name to compare.

    .PARAMETER Second
        Second SQL Server instance name to compare.

    .EXAMPLE
        Test-SameSqlInstance `
            -First 'SQLSERVER01.domain.example' `
            -Second 'sqlserver01'

        Returns True.

    .OUTPUTS
        System.Boolean.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $First,

        [Parameter(Mandatory)]
        [string] $Second
    )

    return (
        (Get-NormalisedSqlInstance -SqlInstance $First) -eq
        (Get-NormalisedSqlInstance -SqlInstance $Second)
    )
}

function Get-ServerRegion {
    <#
    .SYNOPSIS
        Determines the region represented by a server name.

    .DESCRIPTION
        Validates the short server name against the configured naming
        convention and returns the region identifier captured from the sixth
        character.

        A matching server returns either A or B.

        A name that does not match the expected naming convention returns
        null.

    .PARAMETER Name
        Server, DNS or SQL instance name to inspect.

    .EXAMPLE
        Get-ServerRegion -Name 'ABCDEAFGHIJK123'

        Returns:

            A

    .EXAMPLE
        Get-ServerRegion -Name 'INVALID-SERVER'

        Returns null.

    .OUTPUTS
        System.String or null.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Name
    )

    $shortName = Get-ShortHostName -Name $Name

    $match = [regex]::Match(
        $shortName,
        $ServerNamePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['Region'].Value.ToUpperInvariant()
}

function Get-RunningSqlInstances {
    <#
    .SYNOPSIS
        Discovers running SQL Server Database Engine instances on a machine.

    .DESCRIPTION
        Uses Get-DbaService to discover running SQL Server Database Engine
        services on the specified Windows computer.

        The function returns the SQL connection name associated with each
        running service. A fallback connection name is constructed if
        Get-DbaService does not return the SqlInstance property.

    .PARAMETER ComputerName
        Windows computer on which to discover SQL Server services.

    .EXAMPLE
        Get-RunningSqlInstances -ComputerName 'ABCDEAFGHIJK123'

    .OUTPUTS
        System.String[].

        Returns one or more SQL Server instance names.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $ComputerName
    )

    Write-Log "Discovering running SQL Server instances on '$ComputerName'."

    $services = @(
        Get-DbaService `
            -ComputerName $ComputerName `
            -Type Engine `
            -AdvancedProperties `
            -EnableException |
        Where-Object {
            [string] $_.State -eq 'Running'
        }
    )

    if ($services.Count -eq 0) {
        throw "No running SQL Server Database Engine services were found on '$ComputerName'."
    }

    $instances = foreach ($service in $services) {
        $sqlInstance = [string] $service.SqlInstance

        if (-not [string]::IsNullOrWhiteSpace($sqlInstance)) {
            $sqlInstance
            continue
        }

        # Defensive fallback if SqlInstance was not returned.
        if ([string] $service.InstanceName -eq 'MSSQLSERVER') {
            $ComputerName
        }
        else {
            '{0}\{1}' -f $ComputerName, $service.InstanceName
        }
    }

    $instances = @(
        $instances |
        Sort-Object -Unique
    )

    foreach ($instance in $instances) {
        Write-Log "Discovered running instance '$instance'."
    }

    return $instances
}

function Get-PrimaryAvailabilityGroups {
    <#
    .SYNOPSIS
        Gets Availability Groups currently primary on a SQL instance.

    .DESCRIPTION
        Connects to the specified SQL Server instance and checks whether
        Always On Availability Groups are enabled.

        If Always On is enabled, the function returns the Availability Groups
        for which the local replica currently has the Primary role.

        If Always On is not enabled, no objects are returned.

    .PARAMETER SqlInstance
        SQL Server instance to inspect.

    .EXAMPLE
        Get-PrimaryAvailabilityGroups `
            -SqlInstance 'ABCDEAFGHIJK123\REPORTING'

    .OUTPUTS
        Availability Group objects returned by Get-DbaAvailabilityGroup.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $SqlInstance
    )

    Write-Log "Checking Always On configuration on '$SqlInstance'."

    $server = Connect-DbaInstance `
        -SqlInstance $SqlInstance `
        -EnableException

    if (-not $server.IsHadrEnabled) {
        Write-Log "Always On is not enabled on '$SqlInstance'."
        return
    }

    $availabilityGroups = @(
        Get-DbaAvailabilityGroup `
            -SqlInstance $SqlInstance `
            -EnableException |
        Where-Object {
            [string] $_.LocalReplicaRole -eq 'Primary'
        }
    )

    foreach ($availabilityGroup in $availabilityGroups) {
        Write-Log (
            "Availability Group '{0}' is primary on '{1}'." -f
            $availabilityGroup.Name,
            $SqlInstance
        )
    }

    return $availabilityGroups
}

function Get-ReplicaAssessments {
    <#
    .SYNOPSIS
        Assesses the secondary replicas available for an Availability Group.

    .DESCRIPTION
        Examines every secondary replica belonging to an Availability Group
        and determines whether it is safe to use as a planned failover target.

        A replica is rejected when any of the following are true:

        - It is hosted on the Windows server being restarted.
        - Its hostname does not match the expected naming convention.
        - Its connection state is not Connected.
        - It is not using synchronous commit.
        - Its replica synchronization state is not Synchronized.
        - No database replica state information is available.
        - An Availability Group database is not joined.
        - Data movement is suspended.
        - An Availability Group database is not synchronized.
        - An Availability Group database is not failover ready.

        The returned assessment includes the replica name, host, region,
        failover mode, eligibility and any rejection reasons.

    .PARAMETER AvailabilityGroup
        Availability Group object to assess.

        This is normally an object returned by Get-DbaAvailabilityGroup.

    .PARAMETER SourceServer
        Short hostname of the Windows server that is going to be restarted.

        Replicas hosted on this server are excluded from consideration.

    .EXAMPLE
        Get-ReplicaAssessments `
            -AvailabilityGroup $availabilityGroup `
            -SourceServer 'ABCDEAFGHIJK123'

    .OUTPUTS
        PSCustomObject[].

        Each returned object contains:

            ReplicaName
            HostName
            Region
            FailoverMode
            Eligible
            RejectionCause
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $AvailabilityGroup,

        [Parameter(Mandatory)]
        [string] $SourceServer
    )

    $replicas = @(
        Get-DbaAgReplica `
            -InputObject $AvailabilityGroup `
            -EnableException
    )

    $databaseStates = @(
        Get-DbaAgDatabaseReplicaState `
            -InputObject $AvailabilityGroup `
            -EnableException
    )

    $assessments = foreach ($replica in $replicas) {
        if ([string] $replica.Role -ne 'Secondary') {
            continue
        }

        $replicaName = [string] $replica.Name
        $replicaHost = Get-ShortHostName -Name $replicaName
        $region      = Get-ServerRegion -Name $replicaName

        $reasons = [System.Collections.Generic.List[string]]::new()

        # Never move an AG to another SQL instance on the same Windows
        # machine because that machine is about to be restarted.
        if ($replicaHost -eq $SourceServer) {
            $reasons.Add(
                'Replica is hosted on the server being restarted'
            )
        }

        if ($null -eq $region) {
            $reasons.Add(
                "Hostname '$replicaHost' does not match the expected naming convention"
            )
        }

        if ([string] $replica.ConnectionState -ne 'Connected') {
            $reasons.Add(
                "Connection state is '$($replica.ConnectionState)'"
            )
        }

        if ([string] $replica.AvailabilityMode -ne 'SynchronousCommit') {
            $reasons.Add(
                "Availability mode is '$($replica.AvailabilityMode)'"
            )
        }

        if (
            [string] $replica.RollupSynchronizationState -ne
            'Synchronized'
        ) {
            $reasons.Add(
                "Replica synchronization state is " +
                "'$($replica.RollupSynchronizationState)'"
            )
        }

        $replicaDatabaseStates = @(
            $databaseStates |
            Where-Object {
                Test-SameSqlInstance `
                    -First ([string] $_.ReplicaServerName) `
                    -Second $replicaName
            }
        )

        if ($replicaDatabaseStates.Count -eq 0) {
            $reasons.Add(
                'No database replica state information was returned'
            )
        }

        foreach ($databaseState in $replicaDatabaseStates) {
            $databaseName = [string] $databaseState.DatabaseName

            if (-not $databaseState.IsJoined) {
                $reasons.Add(
                    "Database '$databaseName' is not joined"
                )
            }

            if ($databaseState.IsSuspended) {
                $reasons.Add(
                    "Database '$databaseName' has suspended data movement"
                )
            }

            if (
                [string] $databaseState.SynchronizationState -ne
                'Synchronized'
            ) {
                $reasons.Add(
                    "Database '$databaseName' is " +
                    "'$($databaseState.SynchronizationState)'"
                )
            }

            if ($databaseState.IsFailoverReady -ne $true) {
                $reasons.Add(
                    "Database '$databaseName' is not failover ready"
                )
            }
        }

        [pscustomobject] @{
            ReplicaName    = $replicaName
            HostName       = $replicaHost
            Region         = $region
            FailoverMode   = [string] $replica.FailoverMode
            Eligible       = ($reasons.Count -eq 0)
            RejectionCause = @($reasons | Select-Object -Unique)
        }
    }

    return $assessments
}

function Select-FailoverTarget {
    <#
    .SYNOPSIS
        Selects the preferred safe failover target for an Availability Group.

    .DESCRIPTION
        Assesses all secondary replicas and selects the best eligible
        failover target.

        Eligible replicas are ranked in the following order:

        1. Region A replicas.
        2. Region B replicas.
        3. Replicas configured for automatic failover.
        4. Replica name alphabetically as a deterministic tie-break.

        Region B is selected only when no eligible Region A replica is
        available.

        The function throws an exception if no safe target can be found.

    .PARAMETER AvailabilityGroup
        Availability Group object for which a target should be selected.

    .PARAMETER SourceServer
        Short hostname of the Windows server being restarted.

    .EXAMPLE
        Select-FailoverTarget `
            -AvailabilityGroup $availabilityGroup `
            -SourceServer 'ABCDEAFGHIJK123'

    .OUTPUTS
        PSCustomObject.

        Returns the selected assessment object produced by
        Get-ReplicaAssessments.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $AvailabilityGroup,

        [Parameter(Mandatory)]
        [string] $SourceServer
    )

    $assessments = @(
        Get-ReplicaAssessments `
            -AvailabilityGroup $AvailabilityGroup `
            -SourceServer $SourceServer
    )

    if ($assessments.Count -eq 0) {
        throw (
            "Availability Group '$($AvailabilityGroup.Name)' has no " +
            'secondary replicas.'
        )
    }

    $eligibleReplicas = @(
        $assessments |
        Where-Object Eligible
    )

    if ($eligibleReplicas.Count -eq 0) {
        $assessmentText = $assessments |
            ForEach-Object {
                $reason = if ($_.RejectionCause.Count -gt 0) {
                    $_.RejectionCause -join '; '
                }
                else {
                    'Unknown reason'
                }

                "'$($_.ReplicaName)': $reason"
            }

        throw (
            "No safe failover target was found for Availability Group " +
            "'$($AvailabilityGroup.Name)'. " +
            ($assessmentText -join ' | ')
        )
    }

    # Selection order:
    #
    # 1. Region A
    # 2. Region B
    # 3. Automatic failover mode
    # 4. Alphabetical replica name for a deterministic tie-break
    #
    # FailoverMode is only a tie-breaker. A planned manual failover can
    # still use a replica configured for manual failover.

    $selectedReplica = $eligibleReplicas |
        Sort-Object `
            @{
                Expression = {
                    if ($_.Region -eq 'A') {
                        0
                    }
                    else {
                        1
                    }
                }
            },
            @{
                Expression = {
                    if ($_.FailoverMode -eq 'Automatic') {
                        0
                    }
                    else {
                        1
                    }
                }
            },
            ReplicaName |
        Select-Object -First 1

    if ($selectedReplica.Region -eq 'B') {
        Write-Log (
            "No safe Region A replica is available for Availability Group " +
            "'$($AvailabilityGroup.Name)'. Region B replica " +
            "'$($selectedReplica.ReplicaName)' will be used."
        ) -Level WARNING
    }

    return $selectedReplica
}

function Wait-ForAvailabilityGroupPrimary {
    <#
    .SYNOPSIS
        Waits for an Availability Group to become primary on a replica.

    .DESCRIPTION
        Polls the expected target SQL Server instance until the specified
        Availability Group reports that:

        - The local replica role is Primary.
        - The reported primary replica matches the expected target.

        The function returns successfully when the expected state is reached.

        An exception is thrown if the Availability Group does not reach the
        expected state before the configured failover timeout expires.

    .PARAMETER AvailabilityGroupName
        Name of the Availability Group to monitor.

    .PARAMETER ExpectedPrimary
        SQL Server instance expected to become the new primary replica.

    .EXAMPLE
        Wait-ForAvailabilityGroupPrimary `
            -AvailabilityGroupName 'ProductionAG' `
            -ExpectedPrimary 'ABCDEXFGHIJK123\INSTANCE01'

    .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $AvailabilityGroupName,

        [Parameter(Mandatory)]
        [string] $ExpectedPrimary
    )

    $deadline  = (Get-Date).AddSeconds($FailoverTimeoutSeconds)
    $lastError = $null

    do {
        try {
            $availabilityGroup = Get-DbaAvailabilityGroup `
                -SqlInstance $ExpectedPrimary `
                -AvailabilityGroup $AvailabilityGroupName `
                -EnableException

            if (
                $null -ne $availabilityGroup -and
                [string] $availabilityGroup.LocalReplicaRole -eq 'Primary' -and
                (
                    Test-SameSqlInstance `
                        -First (
                            [string] $availabilityGroup.PrimaryReplicaServerName
                        ) `
                        -Second $ExpectedPrimary
                )
            ) {
                return
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds $VerificationInterval
    }
    while ((Get-Date) -lt $deadline)

    $message = (
        "Availability Group '$AvailabilityGroupName' did not become " +
        "primary on '$ExpectedPrimary' within " +
        "$FailoverTimeoutSeconds seconds."
    )

    if ($lastError) {
        $message += " Last error: $lastError"
    }

    throw $message
}

function Wait-ForNoLocalPrimaryAvailabilityGroups {
    <#
    .SYNOPSIS
        Verifies that no local SQL instance hosts a primary Availability Group.

    .DESCRIPTION
        Polls all supplied SQL Server instances and checks for Availability
        Groups whose local replica role remains Primary.

        The function returns successfully when no locally primary
        Availability Groups are found.

        An exception is thrown when locally primary groups remain after the
        configured timeout or when the state cannot be verified.

        This is the final safety check before the Windows server is restarted.

    .PARAMETER SqlInstances
        SQL Server instances hosted on the Windows server being restarted.

    .EXAMPLE
        Wait-ForNoLocalPrimaryAvailabilityGroups `
            -SqlInstances @(
                'ABCDEAFGHIJK123',
                'ABCDEAFGHIJK123\REPORTING'
            )

    .OUTPUTS
        None.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]] $SqlInstances
    )

    $deadline  = (Get-Date).AddSeconds($FailoverTimeoutSeconds)
    $lastState = @()
    $lastError = $null

    do {
        try {
            $remainingPrimaries =
                [System.Collections.Generic.List[object]]::new()

            foreach ($sqlInstance in $SqlInstances) {
                $server = Connect-DbaInstance `
                    -SqlInstance $sqlInstance `
                    -EnableException

                if (-not $server.IsHadrEnabled) {
                    continue
                }

                $primaryGroups = @(
                    Get-DbaAvailabilityGroup `
                        -SqlInstance $sqlInstance `
                        -EnableException |
                    Where-Object {
                        [string] $_.LocalReplicaRole -eq 'Primary'
                    }
                )

                foreach ($group in $primaryGroups) {
                    $remainingPrimaries.Add(
                        [pscustomobject] @{
                            SqlInstance       = $sqlInstance
                            AvailabilityGroup = [string] $group.Name
                        }
                    )
                }
            }

            $lastState = @($remainingPrimaries)

            if ($lastState.Count -eq 0) {
                return
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Seconds $VerificationInterval
    }
    while ((Get-Date) -lt $deadline)

    if ($lastState.Count -gt 0) {
        $groupList = $lastState |
            ForEach-Object {
                "'$($_.AvailabilityGroup)' on '$($_.SqlInstance)'"
            }

        throw (
            "The server still hosts primary Availability Groups: " +
            ($groupList -join ', ')
        )
    }

    throw (
        "Unable to verify that the server no longer hosts primary " +
        "Availability Groups. Last error: $lastError"
    )
}

try {
    $shortServerName = Get-ShortHostName -Name $ServerName

    if ($shortServerName -notmatch $ServerNamePattern) {
        throw (
            "Server name '$shortServerName' does not match the expected " +
            "pattern '$ServerNamePattern'."
        )
    }

    $sourceRegion = Get-ServerRegion -Name $shortServerName

    Write-Log (
        "Preparing graceful restart of '$shortServerName'. " +
        "The server is in Region $sourceRegion."
    )

    $sqlInstances = @(
        Get-RunningSqlInstances -ComputerName $ServerName
    )

    # Build and validate the complete plan before performing the first
    # failover. If one AG has no safe destination, nothing is moved.
    $failoverPlan = [System.Collections.Generic.List[object]]::new()

    foreach ($sqlInstance in $sqlInstances) {
        $primaryGroups = @(
            Get-PrimaryAvailabilityGroups -SqlInstance $sqlInstance
        )

        foreach ($availabilityGroup in $primaryGroups) {
            $target = Select-FailoverTarget `
                -AvailabilityGroup $availabilityGroup `
                -SourceServer $shortServerName

            $failoverPlan.Add(
                [pscustomobject] @{
                    SourceInstance     = $sqlInstance
                    AvailabilityGroup  = [string] $availabilityGroup.Name
                    TargetInstance     = [string] $target.ReplicaName
                    TargetRegion       = [string] $target.Region
                    FailoverMode       = [string] $target.FailoverMode
                }
            )
        }
    }

    if ($failoverPlan.Count -eq 0) {
        Write-Log (
            "No Availability Groups are currently primary on " +
            "'$shortServerName'."
        )
    }
    else {
        Write-Log (
            "Validated failover plan for $($failoverPlan.Count) " +
            'Availability Group(s).'
        ) -Level SUCCESS

        $failoverPlan |
            Format-Table `
                AvailabilityGroup,
                SourceInstance,
                TargetInstance,
                TargetRegion,
                FailoverMode `
                -AutoSize |
            Out-Host
    }

    foreach ($planItem in $failoverPlan) {
        # Refresh the AG object immediately before failover.
        $availabilityGroup = Get-DbaAvailabilityGroup `
            -SqlInstance $planItem.SourceInstance `
            -AvailabilityGroup $planItem.AvailabilityGroup `
            -EnableException

        if (
            [string] $availabilityGroup.LocalReplicaRole -ne
            'Primary'
        ) {
            Write-Log (
                "Availability Group '$($planItem.AvailabilityGroup)' is no " +
                "longer primary on '$($planItem.SourceInstance)'. No " +
                'failover is required for this group.'
            ) -Level WARNING

            continue
        }

        # Reassess health immediately before making the change. The best
        # target may have changed since the initial plan was created.
        $currentTarget = Select-FailoverTarget `
            -AvailabilityGroup $availabilityGroup `
            -SourceServer $shortServerName

        $planItem.TargetInstance = $currentTarget.ReplicaName
        $planItem.TargetRegion   = $currentTarget.Region
        $planItem.FailoverMode   = $currentTarget.FailoverMode

        $action = (
            "Fail over Availability Group '$($planItem.AvailabilityGroup)' " +
            "from '$($planItem.SourceInstance)' to " +
            "'$($planItem.TargetInstance)'"
        )

        $approved = $PSCmdlet.ShouldProcess(
            $planItem.TargetInstance,
            $action
        )

        if (-not $approved) {
            if ($WhatIfPreference) {
                continue
            }

            throw (
                "Failover of Availability Group " +
                "'$($planItem.AvailabilityGroup)' was not approved. " +
                'The server will not be restarted.'
            )
        }

        Write-Log $action

        Invoke-DbaAgFailover `
            -SqlInstance $planItem.TargetInstance `
            -AvailabilityGroup $planItem.AvailabilityGroup `
            -Confirm:$false `
            -EnableException |
        Out-Null

        Wait-ForAvailabilityGroupPrimary `
            -AvailabilityGroupName $planItem.AvailabilityGroup `
            -ExpectedPrimary $planItem.TargetInstance

        $CompletedFailovers.Add($planItem)

        Write-Log (
            "Availability Group '$($planItem.AvailabilityGroup)' is now " +
            "primary on '$($planItem.TargetInstance)' in Region " +
            "$($planItem.TargetRegion)."
        ) -Level SUCCESS
    }

    if ($WhatIfPreference) {
        Write-Log (
            'WhatIf was specified. No failovers were performed and the ' +
            'server will not be restarted.'
        )

        return
    }

    # Final safety check. The machine must not be restarted while any local
    # SQL instance still owns a primary Availability Group.
    Write-Log (
        "Performing final verification that '$shortServerName' hosts no " +
        'primary Availability Groups.'
    )

    Wait-ForNoLocalPrimaryAvailabilityGroups `
        -SqlInstances $sqlInstances

    Write-Log (
        "'$shortServerName' no longer hosts any primary Availability Groups."
    ) -Level SUCCESS

    $restartAction = (
        'Restart Windows after all locally primary Availability Groups ' +
        'have been safely failed over'
    )

    if (
        -not $PSCmdlet.ShouldProcess(
            $shortServerName,
            $restartAction
        )
    ) {
        throw (
            "Restart of '$shortServerName' was not approved. " +
            'The Availability Groups remain failed over.'
        )
    }

    Write-Log "Restarting Windows server '$shortServerName'." -Level SUCCESS

    Restart-Computer `
        -ComputerName $ServerName `
        -Force `
        -ErrorAction Stop
}
catch {
    Write-Log $_.Exception.Message -Level ERROR

    Write-Log (
        "The restart of '$ServerName' has been aborted."
    ) -Level ERROR

    if ($CompletedFailovers.Count -gt 0) {
        Write-Log (
            'The following Availability Groups were successfully moved ' +
            'before the failure occurred:'
        ) -Level WARNING

        $CompletedFailovers |
            Format-Table `
                AvailabilityGroup,
                SourceInstance,
                TargetInstance,
                TargetRegion `
                -AutoSize |
            Out-Host

        Write-Log (
            'The script will not automatically fail these Availability ' +
            'Groups back.'
        ) -Level WARNING
    }

    throw
}
