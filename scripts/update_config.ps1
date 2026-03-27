param (
    [Parameter(Mandatory=$true)]
    [string]$vCenter,
    [Parameter(Mandatory=$true)]
    [string]$FilePath,
    [string]$Username,
    [string]$Password
)
function Write-TaskProgress {
    param (
        [Parameter(Mandatory=$true)]
        [string]$taskId,
        $taskDescription,
        $cluster

    )

    $lastPercent = -1
    $status = "INITIALIZING"

    Write-Host "[$cluster][$taskDescription] Task ID: $taskId" -ForegroundColor Cyan

    do {
        # 1. Refresh the task info
        try {
            $taskInfo = Invoke-GetTask -Task $taskId
            $status = $taskInfo.Status
            
            # 2. Safe extraction of Progress (normalize for APIs that omit Progress or Completed)
            $currentPercent = 0
            if ($null -ne $taskInfo.Progress -and $null -ne $taskInfo.Progress.Completed) {
                $currentPercent = [int]$taskInfo.Progress.Completed
            }
            $currentPercent = [Math]::Min(100, [Math]::Max(0, $currentPercent))
            if ([string]::IsNullOrEmpty($status)) { $status = "RUNNING" }
        } catch {
            Write-Host "Warning: Could not retrieve task status. Retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
            continue
        }

        # 3. Only print to GitHub logs if the percentage has moved
        if ($currentPercent -ne $lastPercent) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            Write-Host "[$cluster][$taskDescription] [$taskId] Task Progress: $currentPercent% | Status: $status"
            $lastPercent = $currentPercent
        }

        # 4. Exit conditions
        if ($status -eq "SUCCEEDED" -or $status -eq "FAILED") {
            break
        }

        # 5. Polling interval
        Start-Sleep -Seconds 5

    } while ($true)

    # Final Summary
    if ($status -eq "SUCCEEDED") {
        Write-Host " Task Completed Successfully." -ForegroundColor Green
    } else {
        Write-Error " Task Failed with status: $status"
        exit 1 # Signal failure to the GitHub Action
    }
}
# 1. Connect to vCenter
$conn = Connect-VIServer -Server $vCenter -User $Username -Password $Password -ErrorAction Stop

try {
    # 2. Extract Cluster Name from filename (e.g., "cluster1.json" -> "cluster1")
    $clusterName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $clusterView = Get-Cluster -Name $clusterName | Get-View
    $clusterId = $clusterView.MoRef.Value

    Write-Host "Detected changes for Cluster: $clusterName on $vCenter"

    # 3. Read the updated JSON content from the repo
    $newConfigJson = Get-Content -Path $FilePath -Raw | ConvertFrom-Json

    

    #Initialize the UpdateSpec using the JSON STRING
    $DraftSpec = $newConfigJson | ConvertTo-Json -Depth 10
    $updatedSpec = Initialize-SettingsClustersConfigurationDraftsUpdateSpec -Config $DraftSpec 


    #Invoke the update to the Cluster Draft
    $draftId = Invoke-CreateClusterConfigurationDrafts -Cluster $clusterId -Confirm:$false
    Write-Host "Initialized Configuration Draft ID:" $draftId
    Invoke-UpdateClusterDraft -Cluster $clusterId -Draft $draftId -EsxSettingsClustersConfigurationDraftsUpdateSpec $updatedSpec -Confirm:$false

    Write-Host "Waiting for Draft import to complete..."
   


    #Run Prechecks on the Draft Configuration
    $precheckTaskId = Invoke-PrecheckClusterDraftAsync -Cluster $clusterId -Draft $draftId -Confirm:$false

    Write-TaskProgress -taskId $precheckTaskId -taskDescription "Precheck" -cluster $clusterName

    #Apply Config Profile Draft to the Cluster
    Invoke-ApplyClusterDraft -Cluster $clusterId -Draft $draftId -Confirm:$false

    #Monitor the Job
    #Check Cluster Compliance Status
    $complianceTaskId = Invoke-CheckComplianceClusterConfigurationAsync -Cluster $clusterId -Confirm:$false
    Write-TaskProgress -taskId $complianceTaskId -taskDescription "Compliance" -cluster $clusterName

    $complianceResult = Invoke-GetClusterConfigurationReportsLastComplianceResult -Cluster $clusterId
    Write-Host "Cluster Compliance Status:" $complianceResult.ClusterStatus
    Write-Host "Cluster Compliance Summary:" $complianceResult.Summary.DefaultMessage
    Write-Host "Compliant Hosts:"  $complianceResult.CompliantHosts
   

} catch {
    Write-Error "Failed to update VCP configuration: $_"
} finally {
    Disconnect-VIServer -Server $conn -Confirm:$false
}
