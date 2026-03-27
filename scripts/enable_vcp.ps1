param (
    [Parameter(Mandatory=$true)]
    [string]$FilePath,
    [Parameter(Mandatory=$false)]
    [string]$Username,
    [Parameter(Mandatory=$false)]
    [string]$Password
)
function Write-TaskProgress {
    param (
        [string]$taskId
        
    )
    $percent = 0
    $status = "RUNNING"
    do {
        # Refresh the task info
        $taskInfo = Invoke-GetTask -Task $taskId
        
        # Extract completion percentage
        $percent = $taskInfo.Progress.Completed
        $status = $taskInfo.Status

        # Normalize for APIs that omit Progress or Progress.Completed (e.g. Validation task)
        if ($null -eq $percent -or $percent -eq '') { $percent = 0 }
        $percent = [Math]::Min(100, [Math]::Max(0, [int]$percent))
        if ([string]::IsNullOrEmpty($status)) { $status = "RUNNING" }

        # Display the dynamic progress bar
        Write-Progress -Activity "vSphere Lifecycle Manager: Compliance Check" `
                    -Status "Status: $status" `
                    -PercentComplete $percent `
                    -CurrentOperation "Checking cluster configuration..."

        # Wait a moment before polling again to avoid spamming the API
        if ($percent -lt 100) { Start-Sleep -Seconds 2 }

    } while ($percent -lt 100 -and $status -ne "FAILED")
    
}
# 1. Load Configurations
$newConfig = Get-Content $FilePath | ConvertFrom-Yaml
try {
    $oldConfigRaw = git show HEAD~1:vcp_managed_clusters.yaml
    $oldConfig = $oldConfigRaw | ConvertFrom-Yaml
} catch {
    Write-Host "First run detected. Processing all clusters."
    $oldConfig = @{}
}

# 2. Iterate vCenters
foreach ($vcName in $newConfig.Keys) {
    $newClusters = $newConfig.$vcName.clusters
    $oldClusters = if ($oldConfig.$vcName) { $oldConfig.$vcName.clusters } else { @() }

    # Identify New Clusters only
    $addedClusters = $newClusters | Where-Object { 
        $currentName = $_.name
        -not ($oldClusters | Where-Object { $_.name -eq $currentName })
    }

    if ($addedClusters.Count -gt 0) {
        Write-Host "Connecting to vCenter: $vcName"
        $conn = Connect-VIServer -Server $vcName -User $Username -Password $Password -ErrorAction Stop
        
        foreach ($cluster in $addedClusters) {
            $cName = $cluster.name
            $hostRef = $cluster.refHost
            $isVCP = $cluster.managedByVCP
            
            if ($isVCP -eq $true) {
                Write-Host "Processing Transition for $cName..."
                
                $clusterView = Get-Cluster -Name $cName | Get-View
                $hostView = Get-VMHost -Name $hostRef | Get-View
                $ClusterId = $clusterView.MoRef.Value
                $HostId = $hostView.MoRef.Value

                # Validate Enablement
                $status = Invoke-GetClusterEnablementConfiguration -Cluster $ClusterId
                write-host "vSphere Configuration Profile Enabled on Cluster $cName is $status "
                if (-not $status.Enabled) {
                    Write-Host "[$cname]Initiating VCP Transition tasks..."
                    $EligibilityTaskId = Invoke-CheckEligibilityClusterConfigurationTransitionAsync -Cluster $ClusterId -Confirm:$false 
                    Write-TaskProgress -taskId $EligibilityTaskId

                    Write-Host "[$cName]Import Cluster Configuration from the Reference Host $hostRef"
                    $transitionTaskid = Invoke-ImportFromHostClusterConfigurationTransitionAsync -Body $HostId -Cluster $ClusterId -Confirm:$false
                    Write-TaskProgress -taskId $transitionTaskid

                    Write-Host "[$cName]Validating Cluster Config"
                    $ValidationTaskId = Invoke-ValidateConfigClusterConfigurationTransitionAsync -Cluster $ClusterId -Confirm:$false
                    Write-TaskProgress -taskId $ValidationTaskId

                    Write-Host "[$cName]Enabling VCP"
                    $EnableTaskId = Invoke-EnableClusterConfigurationTransitionAsync -Cluster $ClusterId -Confirm:$false 
                    Write-TaskProgress -taskId $EnableTaskId

                    $status = Invoke-GetClusterEnablementConfiguration -Cluster $ClusterId
                    write-host "vSphere Configuration Profile Enabled on Cluster $cName is $status"    
                    
                }else{
                    write-Host "Cluster $cName is already VCP enabled. Skipping transition."
                }

                
                write-host "[$cName]Exporting Cluster Config to GitHub under $vcName/$cname.json "
                # 3. Export RAW JSON (No conversion needed as it is already formatted string)
                $ClusterConfig = Invoke-GetClusterConfiguration -Cluster $ClusterId
                $rawJson = $ClusterConfig.Config 

                if (-not (Test-Path $vcName)) { New-Item -ItemType Directory -Path $vcName | Out-Null }
                
                # Write raw string directly to avoid escape characters
                [System.IO.File]::WriteAllText("$pwd/$vcName/$cName.json", $rawJson)
                Write-Host "Created $vcName/$cName.json"
            }
        }
        Disconnect-VIServer -Server $conn -Confirm:$false
    }
}
