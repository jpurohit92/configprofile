# vSphere Configuration Profile (VCP) GitOps Automation

This repository automates the lifecycle of vSphere Configuration Profiles using a GitOps approach. It supports onboarding new clusters and updating configurations via JSON drafts, ensuring consistency and automation across your vSphere environment.

### 📁 Repository Structure

- **vcp_managed_clusters.yaml**: Source of truth for cluster enablement.
- **vc-*/**: Auto-generated folders named after vCenter FQDNs.
- **vc-*/*.json**: Raw vSphere Configuration Profile for each cluster.
- **scripts/**: PowerShell scripts used by GitHub Actions.
    - `enable_vcp.ps1`: Handles cluster transition and initial JSON export.
    - `update_config.ps1`: Creates and validates vCenter configuration drafts.

### 🚀 Workflow 1: Onboarding New Clusters

**Trigger:** Any change to `vcp_managed_clusters.yaml`.

1. **Modify `vcp_managed_clusters.yaml`:** Add a new cluster entry under the respective vCenter.
     ```yaml
     vc-mgmt-01.vcf.lab:
         clusters:
             - name: "cluster-wld-01"
                 managedByVCP: true
                 refHost: "esx-01.vcf.lab"
     ```
2. **Automation:**
     - Detects the new cluster.
     - Connects to vCenter and initiates the VCP transition (Eligibility check → Import from Host → Enable).
     - Exports the configuration profile to a new folder: `vc-mgmt-01.vcf.lab/cluster-wld-01.json`.
     - A GitHub Bot commits the new JSON back to the main branch.

### 🛠 Workflow 2: Configuration Updates

**Trigger:** Any change to a `.json` file within a `vc-*/` folder.

1. **Modify a JSON file:** Update settings (e.g., NTP, DNS, vSwitch configs) directly in the cluster's JSON file.
2. **Automation:**
     - Detects the modified file.
     - Creates a Configuration Draft in vCenter.
     - Imports the new JSON into that draft.
     - Triggers a Validation Task in vCenter.
     - The GitHub Action log reports if the draft is **VALID**.

> [!IMPORTANT]
> This workflow creates a Draft from the updated config file and applies. Upon successful validation VCP triggers remediation on all the hosts in a cluster.

### 🔐 Setup & Security

#### GitHub Secrets

Configure these secrets in **Settings > Secrets and variables > Actions**:
- `VC_USERNAME`: Service account with VCP and Cluster Administrator privileges.
- `VC_PASSWORD`: Password for the service account.

#### Self-Hosted Runner

This project requires a self-hosted runner with:
- PowerShell 7+ (`pwsh`)
- VCP.PowerCLI Module (v9.0+)
- powershell-yaml Module

### ⚠️ Guidelines for Architects

- **No Manual JSON Creation:** Do not create the `vc-*/` folders manually. Add clusters to `vcp_managed_clusters.yaml` and let the bot handle folder and JSON creation.
- **JSON Validation:** Ensure the JSON structure remains intact. Automation uses `[System.IO.File]` for raw data integrity.
- **Atomic Commits:** Commit one cluster change at a time for cleaner logs, though parallel processing is supported.
