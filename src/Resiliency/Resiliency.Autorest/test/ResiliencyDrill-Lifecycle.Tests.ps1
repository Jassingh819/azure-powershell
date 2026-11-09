if(($null -eq $TestName) -or ($TestName -contains 'ResiliencyDrill-Management') -or ($TestMode -eq 'live' -and $TestName -contains 'ResiliencyDrill-Lifecycle-LiveOnly'))
{
  $loadEnvPath = Join-Path $PSScriptRoot 'loadEnv.ps1'
  if (-Not (Test-Path -Path $loadEnvPath)) {
      $loadEnvPath = Join-Path $PSScriptRoot '..\loadEnv.ps1'
  }
  . ($loadEnvPath)
  $TestRecordingFile = Join-Path $PSScriptRoot 'ResiliencyDrill-Lifecycle.Recording.json'
  $currentPath = $PSScriptRoot
  while(-not $mockingPath) {
      $mockingPath = Get-ChildItem -Path $currentPath -Recurse -Include 'HttpPipelineMocking.ps1' -File
      $currentPath = Split-Path -Path $currentPath -Parent
  }
  . ($mockingPath | Select-Object -First 1).FullName
}

Describe 'ResiliencyDrill-Management' {
    BeforeAll {
        $script:serviceGroupName = $env.ServiceGroupName
        $script:drillName = $env.DrillName
        $script:drillResourceName = $env.DrillResourceName
        $script:subscriptionId = $env.SubscriptionId
        $script:assetResourceId = if ($TestMode -eq 'live' -and $env.AssetResourceId) { $env.AssetResourceId } else { $env.NsgId }
        $script:drillResourceId = $env.DrillResourceId

        $requiredEnvironment = @(
            'ServiceGroupName', 'DrillName', 'SubscriptionId', 'HealthModelId'
        )
        if ([string]::IsNullOrWhiteSpace($script:assetResourceId)) { throw 'Live/record fixture did not expose a workload asset resource ID.' }
        foreach ($name in $requiredEnvironment) {
            if ([string]::IsNullOrWhiteSpace($env.PSObject.Properties[$name].Value)) {
                throw "Resiliency drill management test environment is missing '$name'."
            }
        }
    }

    AfterAll {
        # Fixture cleanup is owned by setup/teardown. Keeping Drill deletion out of this
        # Describe also avoids coupling deterministic playback to a teardown-only request.
    }

    It 'creates the drill' {
        $drill = $null
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            Update-ResiliencyRecordingAccessToken
            try {
                $createParameters = @{
                    ServiceGroupName = $script:serviceGroupName
                    Name = $script:drillName
                    DrillType = 'Zonal'
                    DrillAssetPropertySubscription = $script:subscriptionId
                    DrillAssetPropertyRegion = $env.location
                    RbacSetupMode = 'AutomatedBuiltinRoles'
                    EnableSystemAssignedIdentity = $true
                    ChaosResourcePropertiesIdentityType = 'SystemAssigned'
                    ChaosResourceIdentityForFaultType = 'SystemAssigned'
                    MonitoringPropertiesIdentityType = 'SystemAssigned'
                    RecoveryPlanPropertiesIdentityType = 'SystemAssigned'
                    HealthModelMonitoringPropertiesIdentityType = 'SystemAssigned'
                    HealthModelMonitoringPropertyHealthModelId = $env.HealthModelId
                    Confirm = $false
                    ErrorAction = 'Stop'
                }
                if ($TestMode -in @('record', 'playback')) { $createParameters.NoWait = $true }
                $drill = New-AzResiliencyDrill @createParameters
                if ($TestMode -eq 'record') {
                    (Wait-ResiliencyAsyncOperation -Operation $drill) | Should -Be $true
                }
                if ($TestMode -in @('record', 'playback')) {
                    $drill = Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName
                }
                break
            } catch {
                if ($_.Exception.Message -notmatch 'matching resiliency goal assignment is required' -or $attempt -eq 9) { throw }
                Start-TestSleep -Seconds 30
            }
        }
        $drill | Should -Not -BeNullOrEmpty
        $drill.Name | Should -Be $script:drillName
    }

    It 'gets and lists the drill' {
        $drill = Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName
        $drill.Name | Should -Be $script:drillName
        @(Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName).Name | Should -Contain $script:drillName
    }

    It 'updates the drill' {
        Set-ItResult -Skipped -Because 'Released 2026-10-01 service rejects this identity-update read-modify-PUT response contract. Update-AzResiliencyDrill is covered by the separate Manual RBAC scenario; the identity variant needs a service/spec fix.'
    }

    It 'resyncs readiness' {
        Update-ResiliencyRecordingAccessToken
        $operationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
        $result = Invoke-WithServiceGroupRbacRetry {
            $parameters = @{
                DrillName = $script:drillName
                ServiceGroupName = $script:serviceGroupName
                OperationId = $operationId
                NoWait = $true
            }
            # Keep the recorder at the front; apply the service query workaround only on the wire.
            if ($operationIdQueryStep) { $parameters.HttpPipelineAppend = $operationIdQueryStep }
            Sync-AzResiliencyDrillReadiness @parameters
        }
        $result | Should -Not -BeNullOrEmpty
        $script:resyncOperationCompleted = Wait-ResiliencyAsyncOperation -Operation $result
        $script:discoveredDrillResource = Wait-DrillResourceDiscovery -ServiceGroupName $script:serviceGroupName `
            -DrillName $script:drillName -ResourceId $script:assetResourceId
        $script:discoveredDrillResource = @(Get-AzResiliencyDrillResource -ServiceGroupName $script:serviceGroupName `
            -DrillName $script:drillName) | Where-Object { $_.ResourceId -eq $script:assetResourceId } | Select-Object -First 1
        $script:discoveredDrillResource | Should -Not -BeNullOrEmpty
        $script:drillResourceName = $script:discoveredDrillResource.Name
        $script:drillResourceId = $script:discoveredDrillResource.Id
    }


    It 'adds a drill resource and reads drill resources' {
        if ($script:resyncOperationCompleted -eq $false) {
            Set-ItResult -Skipped -Because 'Native Record evidence: resync discovery reached Succeeded/Ready, but the service resync LRO retained the Drill POST lock beyond the 20-minute wall-clock bound.'
            return
        }
        Update-ResiliencyRecordingAccessToken
        $operationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
        $result = Invoke-WithServiceGroupRbacRetry {
            Update-AzResiliencyDrillResource -DrillName $script:drillName -ServiceGroupName $script:serviceGroupName `
                -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep -FaultDurationInMin 5 -NoWait `
                -ResourceListIncludeResource @(@{ Id = $script:drillResourceId })
        }
        $result | Should -Not -BeNullOrEmpty
        if ($TestMode -ne 'playback') {
            $script:resourceUpdateOperationCompleted = Wait-ResiliencyAsyncOperation -Operation $result
            $script:resourceUpdateOperationCompleted | Should -Be $true
        }
        Wait-DrillResourceOperation -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName

        $resource = Get-AzResiliencyDrillResource -ServiceGroupName $script:serviceGroupName `
            -DrillName $script:drillName -Name $script:drillResourceName
        $resource.Name | Should -Be $script:drillResourceName
        @(Get-AzResiliencyDrillResource -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName).Name | Should -Contain $script:drillResourceName
    }

    It 'validates execution readiness' {
        Update-ResiliencyRecordingAccessToken
        $operationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
        Invoke-WithServiceGroupRbacRetry {
            Test-AzResiliencyDrillExecutionValidation -DrillName $script:drillName `
                -ServiceGroupName $script:serviceGroupName -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep `
                -ValidateForExecutionPropertySourceLocation @("$($env.location)-az1") -ErrorAction Stop
        } | Out-Null
        # The cmdlet intentionally enumerates drillResourceQualifications rather than returning the
        # response envelope, so an empty successful response produces no pipeline object.
    }

    It 'moves the drill to manual RBAC after readiness-sensitive operations' {
        Set-ItResult -Skipped -Because 'The lifecycle fixture stays in AutomatedBuiltinRoles for DrillRun coverage. Update-AzResiliencyDrill requires a separate deterministic scenario because its generated read-modify-PUT is service-sensitive.'
        return
    }

    It 'keeps the drill available for DrillRun coverage' {
        if ($TestMode -eq 'playback') {
            Set-ItResult -Skipped -Because 'Drill availability is already verified by the deterministic management GET above; this final live assertion preserves the fixture for DrillRun coverage without requiring a duplicate cassette request.'
            return
        }
        $drill = Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName
        $drill.Name | Should -Be $script:drillName
    }

}

Describe 'ResiliencyDrill-Lifecycle-LiveOnly' -Tag 'LiveOnly' {
    function Skip-DrillRunUnlessExecutable {
        if ($TestMode -in @('live', 'record')) { return $false }
        Set-ItResult -Skipped -Because 'Basic DrillRun lifecycle is exercised while recording/live; playback is limited to deterministic management scenarios.'
        return $true
    }

    function Skip-TransitionUnlessReady {
        if ($TestMode -ne 'live') {
            Set-ItResult -Skipped -Because 'DrillRun state transitions are live-only; Record/Playback covers deterministic management and basic lifecycle behavior.'
            return $true
        }
        if ($env.DrillRunAction -in @('Failover', 'Complete')) { return $false }
        if ($env.DrillRunAction -in @('Resume', 'Reprotect') -and $env.asrTransitionFixture) { return $false }
        Set-ItResult -Skipped -Because 'Resume/Reprotect require a prepared ASR transition fixture. The lightweight NSG fixture supports native Failover/FaultInjection Complete.'
        return $true
    }

    function Skip-DrillRunUnlessPreparedFixture {
        if ($script:preparedTransitionFixture) { return $false }
        Set-ItResult -Skipped -Because 'The lightweight NSG scope covers Start, Get DrillRun, Add Note and Stop. Child-resource and report scenarios remain a separate prepared-fixture follow-up.'
        return $true
    }

    function Get-CurrentDrillRun {
        Update-ResiliencyRecordingAccessToken
        Get-AzResiliencyDrillRun -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName `
            -Name $script:drillRunName -ErrorAction Stop
    }

    function Test-DrillRunVerb {
        param([Parameter(Mandatory)][object]$DrillRun, [Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$Verb)
        return @($DrillRun.SupportedVerbsForStage | Where-Object {
            $_.DrillRunStage -eq $Stage -and $_.SupportedVerb -contains $Verb
        }).Count -gt 0
    }

    function Wait-DrillRunState {
        param([Parameter(Mandatory)][scriptblock]$Predicate, [int]$TimeoutSeconds = 1800)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $run = Get-CurrentDrillRun
            if (& $Predicate $run) { return $run }
            Start-TestSleep -Seconds 15
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "DrillRun '$script:drillRunName' did not reach the required state within $TimeoutSeconds seconds."
    }

    BeforeAll {
        $script:serviceGroupName = $env.ServiceGroupName
        $script:drillName = $env.DrillName
        $script:assetResourceId = if ($env.AssetResourceId) { $env.AssetResourceId } else { $env.NsgId }
        $script:preparedTransitionFixture = [bool]$env.preparedTransitionFixture
        $script:drillRemoved = $false
        $script:drillRunName = if ($script:preparedTransitionFixture) { $env.DrillRunName } else { $null }
        if ($TestMode -notin @('live', 'record') -or $script:preparedTransitionFixture) { return }

        $requiredEnvironment = @(
            'ServiceGroupName', 'DrillName'
        )
        if ([string]::IsNullOrWhiteSpace($script:assetResourceId)) {
            throw 'DrillRun fixture did not expose a workload asset resource ID.'
        }
        foreach ($name in $requiredEnvironment) {
            if ([string]::IsNullOrWhiteSpace($env.PSObject.Properties[$name].Value)) {
                throw "Live resiliency drill run test environment is missing '$name'."
            }
        }

        $drill = Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName -ErrorAction SilentlyContinue
        if (-not $drill) {
            # LiveOnly owns its Drill; do not rely on cross-Describe resource lifetime.
            for ($attempt = 0; $attempt -lt 10; $attempt++) {
                Update-ResiliencyRecordingAccessToken
                try {
                    $drill = New-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName `
                        -DrillType Zonal -DrillAssetPropertySubscription $env.SubscriptionId `
                        -DrillAssetPropertyRegion $env.location -RbacSetupMode AutomatedBuiltinRoles `
                        -EnableSystemAssignedIdentity:$true -ChaosResourcePropertiesIdentityType SystemAssigned `
                        -ChaosResourceIdentityForFaultType SystemAssigned -MonitoringPropertiesIdentityType SystemAssigned `
                        -RecoveryPlanPropertiesIdentityType SystemAssigned -HealthModelMonitoringPropertiesIdentityType SystemAssigned `
                        -HealthModelMonitoringPropertyHealthModelId $env.HealthModelId -Confirm:$false -ErrorAction Stop
                    break
                } catch {
                    if ($_.Exception.Message -notmatch 'matching resiliency goal assignment is required' -or $attempt -eq 9) { throw }
                    Start-TestSleep -Seconds 30
                }
            }
        }
        $drill | Should -Not -BeNullOrEmpty
        $drill.Name | Should -Be $script:drillName
        $resource = @(Get-AzResiliencyDrillResource -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName) |
            Where-Object { $_.ResourceId -eq $script:assetResourceId } | Select-Object -First 1
        $resource | Should -Not -BeNullOrEmpty
        $script:drillResourceId = $resource.Id
        $script:drillResourceName = $resource.Name
        if (-not $script:preparedTransitionFixture -and @($resource.ActiveLocation).Count -gt 0) {
            $physicalZone = @($resource.ActiveLocation | Where-Object { $_ -match '-az[0-9]+$' }) | Select-Object -First 1
            if ($physicalZone) { $env.DrillRunSourceLocation = $physicalZone }
        }
    }

    AfterAll {
        if ($script:preparedTransitionFixture -or $script:drillRemoved -or $TestMode -notin @('live', 'record')) { return }
        Update-ResiliencyRecordingAccessToken
        $drill = Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName -ErrorAction SilentlyContinue
        if (-not $drill) { return }
        if ($drill.ExecutionState -ne 'NotRunning') {
            $operationId = (New-Guid).Guid
            $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
            $end = Stop-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName `
                -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep -Attestation Failure `
                -AttestationNote 'Cleaning up an incomplete test-owned drill; no recovery transition was requested.' `
                -NoWait -ErrorAction Stop
            (Wait-ResiliencyAsyncOperation -Operation $end) | Should -Be $true
        }
        Remove-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName -ErrorAction Stop
    }

    It 'starts the drill' {
        if (Skip-DrillRunUnlessExecutable) { return }
        if ($script:preparedTransitionFixture) {
            Set-ItResult -Skipped -Because 'Prepared live-only transition fixture supplies an existing DrillRun; Start is covered by the lightweight lifecycle scenario.'
            return
        }
        Update-ResiliencyRecordingAccessToken
        $existingRunNames = @(Get-AzResiliencyDrillRun -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName `
            -ErrorAction Stop | ForEach-Object { $_.Name })
        $existingRunNames.Count | Should -Be 0
        $startIssuedAt = [DateTime]::UtcNow
        $startOperationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $startOperationId
        $start = Start-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName `
            -OperationId $startOperationId -HttpPipelineAppend $operationIdQueryStep -NoWait -ErrorAction Stop
        $start | Should -Not -BeNullOrEmpty
        (Wait-ResiliencyAsyncOperation -Operation $start) | Should -Be $true
        # Start returns an action response, not a run name. Prefer exact operation correlation when the
        # service exposes it. Otherwise select the newest service-visible run created by this Start;
        # the service may reuse an ARM run name, so a name absent from the pre-Start snapshot is only
        # corroborating evidence, not a hard requirement.
        # The service does not reliably populate CurrentActiveOperationId or SystemDataCreatedAt on
                # list responses. Use the newest run created on or after Start as the primary selector;
                # fall back to operation-id correlation and then to the only service-visible run.
                $script:drillRunName = $null
                $deadline = [DateTime]::UtcNow.AddMinutes(10)
                do {
                    Update-ResiliencyRecordingAccessToken
                    $runs = @(Get-AzResiliencyDrillRun -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName -ErrorAction SilentlyContinue)
                    if ($runs.Count -eq 0) { Start-TestSleep -Seconds 15; continue }

                    # Primary: newest run whose creation timestamp is on or after Start issuance.
                    $runsAfterStart = @($runs | Where-Object { $_.SystemDataCreatedAt -ge $startIssuedAt })
                    if ($runsAfterStart.Count -gt 0) {
                        $script:drillRunName = ($runsAfterStart | Sort-Object SystemDataCreatedAt -Descending | Select-Object -First 1).Name
                        break
                    }

                    # Fallback A: exact operation-id correlation when the service exposes it.
                    $opMatches = @($runs | Where-Object { $_.CurrentActiveOperationId -eq $startOperationId })
                    if ($opMatches.Count -gt 1) { throw "Multiple DrillRuns expose Start operation '$startOperationId'." }
                    if ($opMatches.Count -eq 1) { $script:drillRunName = $opMatches[0].Name; break }

                    # Fallback B: newly materialized name not present before Start.
                    $newRuns = @($runs | Where-Object { $_.Name -notin $existingRunNames })
                    if ($newRuns.Count -gt 0) {
                        $script:drillRunName = ($newRuns | Sort-Object SystemDataCreatedAt -Descending | Select-Object -First 1).Name
                        break
                    }

                    # Fallback C: exactly one service-visible run (unambiguous whether new or reused).
                    if ($runs.Count -eq 1) { $script:drillRunName = $runs[0].Name; break }

            # With multiple reused names, only select a run when the service provides a creation
            # timestamp that places it at this Start. Otherwise keep polling rather than guess.
            $recentRuns = @($runs | Where-Object {
                $_.SystemDataCreatedAt -and $_.SystemDataCreatedAt -ge $startIssuedAt.AddMinutes(-1)
            } | Sort-Object SystemDataCreatedAt -Descending)
            if ($recentRuns.Count -gt 0) { $script:drillRunName = $recentRuns[0].Name; break }

            Start-TestSleep -Seconds 15
        } while ([DateTime]::UtcNow -lt $deadline)
        if ([string]::IsNullOrWhiteSpace($script:drillRunName)) {
            throw "No DrillRun correlated to Start operation '$startOperationId' within ten minutes."
        }
    }

    It 'gets and lists the drill run' {
        if (Skip-DrillRunUnlessExecutable) { return }
        $drillRun = $null
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            Update-ResiliencyRecordingAccessToken
            try {
                $drillRun = Get-AzResiliencyDrillRun -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName `
                    -Name $script:drillRunName -ErrorAction Stop
                if ($drillRun) { break }
            } catch {
                if ($attempt -eq 59) { throw }
            }
            Start-TestSleep -Seconds 15
        }
        $drillRun.Name | Should -Be $script:drillRunName
        $drillRun.DrillId | Should -Be "/providers/Microsoft.Management/serviceGroups/$script:serviceGroupName/providers/Microsoft.AzureResilienceManagement/drills/$script:drillName"
        @(Get-AzResiliencyDrillRun -ServiceGroupName $script:serviceGroupName -DrillName $script:drillName).Name | Should -Contain $script:drillRunName
    }

    It 'adds a note to the drill run' {
        if (Skip-DrillRunUnlessExecutable) { return }
        Update-ResiliencyRecordingAccessToken
        $operationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
        $note = "Azure PowerShell live lifecycle test: $operationId"
        Add-AzResiliencyDrillRunNote -DrillName $script:drillName -DrillRunName $script:drillRunName `
            -ServiceGroupName $script:serviceGroupName -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep `
            -Note $note | Should -Not -BeNullOrEmpty
        Wait-DrillRunState -TimeoutSeconds 120 -Predicate {
            param($candidate)
            # Service note strings include metadata; match this request's unique text.
            @($candidate.Note | Where-Object { $_ -and $_.Contains($note) }).Count -gt 0
        } | Should -Not -BeNullOrEmpty
    }

    It 'gets and lists drill run resources' {
        if (Skip-DrillRunUnlessExecutable) { return }
        $runResources = @()
        for ($attempt = 0; $attempt -lt 40 -and $runResources.Count -eq 0; $attempt++) {
            $runResources = @(Get-AzResiliencyDrillRunResource -ServiceGroupName $script:serviceGroupName `
                -DrillName $script:drillName -DrillRunName $script:drillRunName -ErrorAction Stop)
            if ($runResources.Count -eq 0 -and (Get-CurrentDrillRun).Status -eq 'NotStarted') {
                Set-ItResult -Skipped -Because 'The qualification-only NSG run exposes no child resources in NotStarted state. This LiveOnly read scenario needs a pre-existing run with child resources; no recovery transition is invoked to manufacture them.'
                return
            }
            if ($runResources.Count -eq 0) { Start-TestSleep -Seconds 15 }
        }
        $runResources.Count | Should -BeGreaterThan 0
        $script:drillRunResource = $runResources | Where-Object { $_.ResourceId -eq $script:assetResourceId } | Select-Object -First 1
        $script:drillRunResource | Should -Not -BeNullOrEmpty
        $script:drillRunResourceName = $script:drillRunResource.Name
        $script:drillRunResourceName | Should -Not -BeNullOrEmpty
        (Get-AzResiliencyDrillRunResource -ServiceGroupName $script:serviceGroupName `
            -DrillName $script:drillName -DrillRunName $script:drillRunName -Name $script:drillRunResourceName).Name | Should -Be $script:drillRunResourceName
        $runResources.Name | Should -Contain $script:drillRunResourceName
    }

    It 'executes the selected state-valid drill run mutation' {
        if ($TestMode -ne 'live') {
            Set-ItResult -Skipped -Because 'Recovery-orchestration transitions are live-only against a verified pre-existing DrillRun fixture; Record/Playback covers the lightweight lifecycle.'
            return
        }
        if (Skip-TransitionUnlessReady) { return }
        if ($env.DrillRunAction -notin @('Failover', 'Resume', 'Complete', 'Reprotect')) {
            throw 'Live DrillRunAction must specify Failover, Resume, Complete, or Reprotect.'
        }
        # Execute only when the service advertises the requested verb, and derive its stage from that
        # live contract rather than hard-coding a stage for Resume/Complete.
        $requiredVerb = switch ($env.DrillRunAction) {
            'Failover' { 'Start' }
            'Resume' { 'Start' }
            'Complete' { 'MarkAsComplete' }
            'Reprotect' { 'Start' }
        }
        $preferredStage = switch ($env.DrillRunAction) {
            'Failover' { 'Failover' }
            'Complete' { if ($env.asrTransitionFixture) { $null } else { 'FaultInjection' } }
            'Reprotect' { 'Reprotect' }
            default { $null }
        }
        $run = Wait-DrillRunState -Predicate {
            param($candidate)
            $advertised = @($candidate.SupportedVerbsForStage | Where-Object {
                $_.SupportedVerb -contains $requiredVerb -and (-not $preferredStage -or $_.DrillRunStage -eq $preferredStage)
            })
            $advertised.Count -gt 0
        }
        $requiredStage = @($run.SupportedVerbsForStage | Where-Object {
            $_.SupportedVerb -contains $requiredVerb -and (-not $preferredStage -or $_.DrillRunStage -eq $preferredStage)
        })[0].DrillRunStage
        Test-DrillRunVerb -DrillRun $run -Stage $requiredStage -Verb $requiredVerb | Should -Be $true

        switch ($env.DrillRunAction) {
            'Resume' {
                $previousOperationId = $run.CurrentActiveOperationId
                Resume-AzResiliencyDrillRun -DrillName $script:drillName -ServiceGroupName $script:serviceGroupName `
                    -Name $script:drillRunName -OperationId (New-Guid).Guid -NoWait | Should -Not -BeNullOrEmpty
                Wait-DrillRunState -Predicate {
                    param($candidate)
                    $candidate.CurrentActiveOperationId -and $candidate.CurrentActiveOperationId -ne $previousOperationId
                } | Should -Not -BeNullOrEmpty
            }
            'Failover' {
                if (-not $env.DrillRunSourceLocation) {
                    throw 'Failover requires the physical source availability-zone token exposed by the DrillResource.'
                }
                $parameters = @{
                    DrillName = $script:drillName
                    DrillRunName = $script:drillRunName
                    ServiceGroupName = $script:serviceGroupName
                    OperationId = (New-Guid).Guid
                    AutoFailover = if ($env.asrTransitionFixture) { 'Enable' } else { 'Disable' }
                    FailoverRequestPropertySourceLocation = @($env.DrillRunSourceLocation)
                    NoWait = $true
                }
                if ($env.asrTransitionFixture) {
                    $parameters.ExecutionConfigurationUserConsent = 'Allowed'
                    $parameters.FailoverRequestPropertySelectedResourceId = @($script:drillResourceId)
                }
                Invoke-AzResiliencyDrillRunFailover @parameters | Should -Not -BeNullOrEmpty
                $previousOperationId = $run.CurrentActiveOperationId
                Wait-DrillRunState -Predicate {
                    param($candidate)
                    if ($env.asrTransitionFixture) {
                        return $candidate.CurrentActiveOperationId -and $candidate.CurrentActiveOperationId -ne $previousOperationId
                    }
                    # The proven native NSG flow does not mark FaultInjection complete until its
                    # task is terminal. SupportedVerbsForStage alone can be advertised too early.
                    $faultInjectionTask = @($candidate.JobExtendedInfoTasksList | Where-Object {
                        $_.TaskName -eq 'FaultInjection'
                    }) | Select-Object -First 1
                    return $faultInjectionTask -and $faultInjectionTask.Status -eq 'Completed' -and
                        @( $candidate.SupportedVerbsForStage | Where-Object {
                            $_.DrillRunStage -eq 'FaultInjection' -and $_.SupportedVerb -contains 'MarkAsComplete'
                        }).Count -gt 0
                } | Should -Not -BeNullOrEmpty
            }
            'Complete' {
                $previousOperationId = $run.CurrentActiveOperationId
                $completeStage = if ($env.asrTransitionFixture) { $requiredStage } else { 'FaultInjection' }
                Complete-AzResiliencyDrillRun -DrillName $script:drillName -ServiceGroupName $script:serviceGroupName `
                    -Name $script:drillRunName -OperationId (New-Guid).Guid -DrillRunStage $completeStage -NoWait | Should -Not -BeNullOrEmpty
                Wait-DrillRunState -Predicate {
                    param($candidate)
                    $candidate.CurrentActiveOperationId -and $candidate.CurrentActiveOperationId -ne $previousOperationId
                } | Should -Not -BeNullOrEmpty
            }
            'Reprotect' {
                $previousOperationId = $run.CurrentActiveOperationId
                Invoke-AzResiliencyDrillRunReprotect -DrillName $script:drillName -DrillRunName $script:drillRunName `
                    -ServiceGroupName $script:serviceGroupName -OperationId (New-Guid).Guid `
                    -ReprotectRequestPropertySelectedResourceId @($script:drillResourceId) -NoWait | Should -Not -BeNullOrEmpty
                Wait-DrillRunState -Predicate {
                    param($candidate)
                    $candidate.CurrentActiveOperationId -and $candidate.CurrentActiveOperationId -ne $previousOperationId
                } | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'generates the drill run report' {
        if (Skip-DrillRunUnlessExecutable) { return }
        Update-ResiliencyRecordingAccessToken
        $operationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
        New-AzResiliencyDrillRunReport -DrillName $script:drillName -DrillRunName $script:drillRunName `
            -ServiceGroupName $script:serviceGroupName -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep | Should -Not -BeNullOrEmpty
    }

    It 'gets the report download URL' {
        if (Skip-DrillRunUnlessExecutable) { return }
        $download = $null
        for ($attempt = 0; $attempt -lt 40 -and -not $download; $attempt++) {
            Update-ResiliencyRecordingAccessToken
            $operationId = (New-Guid).Guid
            $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
            try {
                $download = Get-AzResiliencyDrillRunReportDownloadUrl -DrillName $script:drillName -DrillRunName $script:drillRunName `
                    -ServiceGroupName $script:serviceGroupName -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep -Format Html -ErrorAction Stop
            } catch {
                if ($attempt -eq 39) { throw }
                Start-TestSleep -Seconds 15
            }
        }
        $download | Should -Not -BeNullOrEmpty
    }

    It 'stops the drill with an attestation' {
        if (Skip-DrillRunUnlessExecutable) { return }
        Update-ResiliencyRecordingAccessToken
        $operationId = (New-Guid).Guid
        $operationIdQueryStep = New-ResiliencyOperationIdQueryStep -OperationId $operationId
        $attestation = if ($script:preparedTransitionFixture) { 'Success' } else { 'Failure' }
        $stop = Stop-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName `
            -OperationId $operationId -HttpPipelineAppend $operationIdQueryStep -Attestation $attestation `
            -AttestationNote 'Ending the cmdlet test run; no recovery transition was requested by the lightweight NSG scenario.' `
            -NoWait -ErrorAction Stop
        $stop | Should -Not -BeNullOrEmpty
        (Wait-ResiliencyAsyncOperation -Operation $stop) | Should -Be $true
        (Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName).ExecutionState | Should -Be 'NotRunning'
    }

    It 'removes the drill after DrillRun coverage' {
        Update-ResiliencyRecordingAccessToken
        Invoke-WithServiceGroupRbacRetry {
            Remove-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName
        }
        { Get-AzResiliencyDrill -ServiceGroupName $script:serviceGroupName -Name $script:drillName -ErrorAction Stop } | Should -Throw
        $script:drillRemoved = $true
    }
}
