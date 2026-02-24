param (
    [Parameter(Mandatory=$true)]
    [string]$vCenter,
    [Parameter(Mandatory=$true)]
    [string]$FilePath,
    [string]$Username,
    [string]$Password
)

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
    Start-Sleep -Seconds 10  


    #Run Prechecks on the Draft Configuration
    Invoke-PrecheckClusterDraftAsync -Cluster $clusterId -Draft $draftId -Confirm:$false
    Start-Sleep -Seconds 120

    #Apply Config Profile Draft to the Cluster
    Invoke-ApplyClusterDraft -Cluster $clusterId -Draft $draftId -Confirm:$false

    #Monitor the Job
    #Check Cluster Compliance Status
    Invoke-CheckComplianceClusterConfigurationAsync -Cluster $clusterId -Confirm:$false

    Start-Sleep -Seconds 120
    $complianceResult = Invoke-GetClusterConfigurationReportsLastComplianceResult -Cluster $clusterId
    Write-Host "Cluster Compliance Status:" $complianceResult.ClusterStatus
    Write-Host "Cluster Compliance Summary:" $complianceResult.Summary.DefaultMessage
    Write-Host "Compliant Hosts:"  $complianceResult.CompliantHosts
   

} catch {
    Write-Error "Failed to update VCP configuration: $_"
} finally {
    Disconnect-VIServer -Server $conn -Confirm:$false
}