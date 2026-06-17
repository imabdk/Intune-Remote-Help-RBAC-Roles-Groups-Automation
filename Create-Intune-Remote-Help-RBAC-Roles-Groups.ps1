<#
.SYNOPSIS
    Creates Intune RBAC roles and security groups for Remote Help, optionally binding each role to its paired group.

.DESCRIPTION
    Creates four custom RBAC roles with their corresponding Entra ID security groups:
    - Remote Help - View Screen Only
    - Remote Help - Full Control
    - Remote Help - Elevation
    - Remote Help - Unattended (Android)
    
    All roles include base permissions:
    - Remote Tasks - Offer remote assistance
    - Remote Assistance Connector - Read

    Optionally (with -AssignRoles), binds each role to its paired group as an
    Intune role assignment so helpers in the group receive the permissions immediately.
    Otherwise, roles must be assigned manually via Intune portal > Tenant administration > Roles.

.PARAMETER Remove
    Removes all Remote Help roles, groups, and any associated role assignments
    that were created by this script.

.PARAMETER AssignRoles
    Creates an Intune role assignment for each role binding it to its paired
    Entra ID group as the members (helpers). Idempotent: skips assignments
    that already target the same group.

.PARAMETER ApprovalJustification
    Business justification string sent as the 'x-msft-approval-justification'
    request header when creating or removing role assignments and role
    definitions. Required by tenants that have a Multi Admin Approval (MAA)
    access policy enabled for the Role-based access control policy type.
    Default: 'Automated provisioning via Remote Help RBAC script'.
    Used with -AssignRoles and -Remove.

.PARAMETER WhatIf
    Shows what would happen if the script runs without making any changes.

.EXAMPLE
    .\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1
    Creates roles and groups. Assignments must be done manually in the portal.

.EXAMPLE
    .\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -AssignRoles
    Creates roles, groups, AND binds each role to its paired group with the
    scope 'All devices and All users' so helpers can target by user or device.

.EXAMPLE
    .\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -Remove
    Removes all roles, groups, and any role assignments created by this script.

.EXAMPLE
    .\Create-Intune-Remote-Help-RBAC-Roles-Groups.ps1 -AssignRoles -WhatIf
    Shows what would be created without making changes.

.NOTES
    Author: Martin Bengtsson
    Date: June 7, 2026
    Version: 2.5

    Version History:
    - 2.5 (2026-06-07): Added -AssignRoles to bind each role to its paired group with
                        scope 'All devices and All users'. -Remove deletes role definitions
                        only; child role assignments cascade automatically.
                        Multi Admin Approval (MAA) support across all role/assignment
                        create and delete operations via a shared Invoke-MaaAwareRequest
                        helper (x-msft-approval-justification header, 412 handling for
                        queued requests). Replaces SDK cmdlets with raw Graph calls where
                        custom headers are needed. Code cleanup.
    - 2.1 (2026-06-06): Switched to SupportsShouldProcess (-WhatIf/-Confirm),
                        cached role lookups, escaped OData filter,
                        scope verification, Disconnect-MgGraph cleanup
    - 2.0 (2025-12-21): Removed role assignments, added -Remove and -WhatIf parameters, 
                        added helper functions, improved error handling
    - 1.0 (2025-12-21): Initial version with role and group creation
    
    Requires:
    - Microsoft.Graph.DeviceManagement.Administration
    - Microsoft.Graph.Groups
    - Microsoft.Graph.Authentication
    - DeviceManagementRBAC.ReadWrite.All
    - Group.ReadWrite.All
#>

#Requires -Modules Microsoft.Graph.DeviceManagement.Administration, Microsoft.Graph.Groups, Microsoft.Graph.Authentication

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory=$false)]
    [switch]$Remove,

    [Parameter(Mandatory=$false)]
    [switch]$AssignRoles,

    [Parameter(Mandatory=$false)]
    [string]$ApprovalJustification = 'Automated provisioning via Remote Help RBAC script',

    [Parameter(Mandatory=$false)]
    [string]$TenantId
)

$requiredScopes = @("DeviceManagementRBAC.ReadWrite.All", "Group.ReadWrite.All")

# Connect to Microsoft Graph with required permissions
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
try {
    $connectParams = @{ Scopes = $requiredScopes; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    Connect-MgGraph @connectParams
}
catch {
    Write-Host "[ERROR] Failed to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Verify the granted scopes - cached tokens may not include the requested scopes
$context = Get-MgContext
$missingScopes = @($requiredScopes | Where-Object { $_ -notin $context.Scopes })
if ($missingScopes.Count -gt 0) {
    Write-Host "[ERROR] Connected, but missing required scopes: $($missingScopes -join ', ')" -ForegroundColor Red
    Write-Host "        Run Disconnect-MgGraph and re-run the script to re-consent." -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    exit 1
}

# Wrap the main work in try/finally so we always disconnect from Graph
try {

# Cache all role definitions once to avoid querying Graph in a loop
Write-Host "Caching existing role definitions..." -ForegroundColor Cyan
$allRoles = @(Get-MgDeviceManagementRoleDefinition -All)

# Helper function to get existing role from the in-memory cache
function Get-ExistingRole {
    param([string]$RoleName)
    return $allRoles | Where-Object { $_.DisplayName -eq $RoleName }
}

# Helper function to get existing group (escapes single quotes for OData)
function Get-ExistingGroup {
    param([string]$GroupName)
    
    try {
        $escaped = $GroupName.Replace("'", "''")
        return Get-MgGroup -Filter "displayName eq '$escaped'"
    }
    catch {
        Write-Host "  [WARNING] Failed to query group: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# Wraps Invoke-MgGraphRequest with Multi Admin Approval (MAA) awareness.
# On tenants with a Role-based access control MAA access policy, both create
# and delete operations on roles or role assignments return 412 with an
# x-msft-approval-code header. We treat that as a successfully queued approval
# request, not a failure. Returns a normalized result the caller can switch on.
function Invoke-MaaAwareRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [string] $Body,
        [string] $Justification
    )

    # MAA justification header expects Base64-encoded UTF-8.
    $headers = @{}
    if ($Justification) {
        $headers['x-msft-approval-justification'] =
            [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Justification))
    }

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $params.Body        = $Body
        $params.ContentType = 'application/json'
    }

    try {
        $data = Invoke-MgGraphRequest @params
        return [pscustomobject]@{ Status = 'Success'; Data = $data; ApprovalCode = $null; Error = $null }
    }
    catch {
        $statusCode   = $null
        $approvalCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $hdr = $_.Exception.Response.Headers.GetValues('x-msft-approval-code')
            if ($hdr) { $approvalCode = $hdr | Select-Object -First 1 }
        }
        if ($statusCode -eq 412 -and $approvalCode) {
            return [pscustomobject]@{ Status = 'PendingApproval'; Data = $null; ApprovalCode = $approvalCode; Error = $null }
        }
        $err = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $err += " | $($_.ErrorDetails.Message)"
        }
        return [pscustomobject]@{ Status = 'Failed'; Data = $null; ApprovalCode = $null; Error = $err }
    }
}

# Helper function to ensure a role assignment exists binding a role to a group.
# Idempotent: if an assignment already targets the same members group, it is skipped.
# LIST uses GET /roleDefinitions/{id}/roleAssignments (read-only navigation);
# CREATE uses POST /roleAssignments with roleDefinition@odata.bind in the body.
function Set-RemoteHelpRoleAssignment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $RoleDefinition,
        [Parameter(Mandatory)] $EntraGroup,
        [string] $Justification
    )

    $assignmentName = "$($RoleDefinition.DisplayName) Assignment"
    $listUri        = "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions/$($RoleDefinition.Id)/roleAssignments"
    $createUri      = "https://graph.microsoft.com/beta/deviceManagement/roleAssignments"

    # Check for an existing assignment that already targets this group
    try {
        $listResponse = Invoke-MgGraphRequest -Method GET -Uri $listUri -ErrorAction Stop
        $matching = @($listResponse.value) | Where-Object { $_.members -contains $EntraGroup.Id }
    }
    catch {
        Write-Host "  [WARNING] Could not list existing assignments: $($_.Exception.Message)" -ForegroundColor Yellow
        $matching = @()
    }

    if ($matching.Count -gt 0) {
        Write-Host "  [INFO] Role assignment already exists, skipping" -ForegroundColor Cyan
        Write-Host "    Assignment ID: $($matching[0].id)" -ForegroundColor Gray
        return [pscustomobject]@{ Status = 'Existing'; Id = $matching[0].id; Name = $assignmentName }
    }

    # Build assignment body. Notes:
    # - Bind to the role definition via roleDefinition@odata.bind (required when POSTing
    #   to the top-level /roleAssignments collection).
    # - Do NOT include roleScopeTagIds here; scope tags belong to the role definition
    #   and sending them on the assignment triggers 400 BadRequest.
    $body = [ordered]@{
        '@odata.type'               = '#microsoft.graph.deviceAndAppManagementRoleAssignment'
        'roleDefinition@odata.bind' = "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions/$($RoleDefinition.Id)"
        displayName                 = $assignmentName
        description                 = "Auto-assignment of $($RoleDefinition.DisplayName) to $($EntraGroup.DisplayName)"
        members                     = @($EntraGroup.Id)
    }

    # Scope (Groups) = All devices AND All users. This is the documented enum
    # value 'allDevicesAndLicensedUsers' so helpers can locate the target by
    # either user or device. See:
    # https://learn.microsoft.com/graph/api/resources/intune-rbac-roleassignmentscopetype
    $body.scopeType      = 'allDevicesAndLicensedUsers'
    $body.resourceScopes = @()

    if ($PSCmdlet.ShouldProcess("Assignment: $assignmentName", "Create")) {
        $bodyJson = $body | ConvertTo-Json -Depth 5
        $result = Invoke-MaaAwareRequest -Method POST -Uri $createUri -Body $bodyJson -Justification $Justification

        switch ($result.Status) {
            'Success' {
                Write-Host "  [SUCCESS] Role assigned to group!" -ForegroundColor Green
                Write-Host "    Assignment ID: $($result.Data.id)" -ForegroundColor Gray
                return [pscustomobject]@{ Status = 'Created'; Id = $result.Data.id; Name = $assignmentName }
            }
            'PendingApproval' {
                Write-Host "  [PENDING] Assignment '$assignmentName' submitted to Multi Admin Approval." -ForegroundColor Cyan
                Write-Host "    Approval code: $($result.ApprovalCode)" -ForegroundColor Gray
                Write-Host "    Approvers: Intune admin center > Tenant administration > Multi Admin Approval > Received requests" -ForegroundColor Gray
                Write-Host "    Requestor: after approval, return to 'My requests' and select Complete to finalize." -ForegroundColor Gray
                return [pscustomobject]@{ Status = 'PendingApproval'; Id = $result.ApprovalCode; Name = $assignmentName }
            }
            default {
                Write-Host "  [ERROR] Failed to create role assignment: $($result.Error)" -ForegroundColor Red
                return [pscustomobject]@{ Status = 'Failed'; Id = $null; Name = $assignmentName }
            }
        }
    }

    return [pscustomobject]@{ Status = 'WhatIf'; Id = $null; Name = $assignmentName }
}

# Define the base permissions required for all Remote Help roles
$basePermissions = @(
    "Microsoft.Intune_RemoteTasks_RequestRemoteAssistance",
    "Microsoft.Intune_RemoteAssistance_Read"
)

# Define Remote Help roles
$roles = @(
    @{
        Name = "Remote Help - View Screen Only"
        Description = "Allows viewing a sharer's screen without taking control"
        Permissions = $basePermissions + @("Microsoft.Intune_RemoteAssistanceApp_ViewScreen")
        GroupName = "Intune-RemoteHelp-ViewScreenOnly"
    },
    @{
        Name = "Remote Help - Full Control"
        Description = "Allows taking full control of the sharer's device"
        Permissions = $basePermissions + @("Microsoft.Intune_RemoteAssistanceApp_TakeFullControl")
        GroupName = "Intune-RemoteHelp-FullControl"
    },
    @{
        Name = "Remote Help - Elevation"
        Description = "Allows interacting with User Account Control prompts on Windows"
        Permissions = $basePermissions + @("Microsoft.Intune_RemoteAssistanceApp_Elevation")
        GroupName = "Intune-RemoteHelp-Elevation"
    },
    @{
        Name = "Remote Help - Unattended (Android)"
        Description = "Allows connecting to Android devices without requiring user acceptance"
        Permissions = $basePermissions + @("Microsoft.Intune_RemoteAssistanceApp_Unattended")
        GroupName = "Intune-RemoteHelp-Unattended"
    }
)

if ($Remove) {
    Write-Host "`nRemoving Remote Help RBAC roles and groups..." -ForegroundColor Cyan
    Write-Host "=========================================`n" -ForegroundColor Cyan
    
    $removedRoles = @()
    $pendingRoles = @()
    $removedGroups = @()
    $notFoundRoles = @()
    $notFoundGroups = @()
    
    foreach ($role in $roles) {
        Write-Host "Processing: $($role.Name)" -ForegroundColor Yellow
        
        # Remove role. Deleting a role definition cascades to its child role
        # assignments, so we don't delete assignments separately - that would
        # just create extra (and ultimately failing) MAA approval requests.
        try {
            $existingRole = Get-ExistingRole -RoleName $role.Name
            
            if ($existingRole) {
                if ($PSCmdlet.ShouldProcess("Role: $($role.Name)", "Remove")) {
                    $deleteUri = "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions/$($existingRole.Id)"
                    $result = Invoke-MaaAwareRequest -Method DELETE -Uri $deleteUri -Justification $ApprovalJustification

                    switch ($result.Status) {
                        'Success' {
                            Write-Host "  [REMOVED] Role deleted (any role assignments cascaded automatically)" -ForegroundColor Green
                            $removedRoles += $role.Name
                        }
                        'PendingApproval' {
                            Write-Host "  [PENDING] Role '$($role.Name)' deletion submitted to Multi Admin Approval." -ForegroundColor Cyan
                            Write-Host "    Approval code: $($result.ApprovalCode)" -ForegroundColor Gray
                            Write-Host "    Note: approving the role deletion also removes its role assignments." -ForegroundColor Gray
                            $pendingRoles += $role.Name
                        }
                        default {
                            Write-Host "  [ERROR] Failed to remove role: $($result.Error)" -ForegroundColor Red
                        }
                    }
                }
            }
            else {
                Write-Host "  [INFO] Role not found" -ForegroundColor Cyan
                $notFoundRoles += $role.Name
            }
        }
        catch {
            Write-Host "  [ERROR] Failed to remove role: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        # Remove group
        try {
            $existingGroup = Get-ExistingGroup -GroupName $role.GroupName
            
            if ($existingGroup) {
                if ($PSCmdlet.ShouldProcess("Group: $($role.GroupName)", "Remove")) {
                    Remove-MgGroup -GroupId $existingGroup.Id -Confirm:$false
                    Write-Host "  [REMOVED] Group deleted" -ForegroundColor Green
                    $removedGroups += $role.GroupName
                }
            }
            else {
                Write-Host "  [INFO] Group not found" -ForegroundColor Cyan
                $notFoundGroups += $role.GroupName
            }
        }
        catch {
            Write-Host "  [ERROR] Failed to remove group: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        Write-Host ""
    }
    
    # Summary
    Write-Host "=========================================`n" -ForegroundColor Cyan
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Roles removed: $($removedRoles.Count)" -ForegroundColor Green
    Write-Host "  Roles not found: $($notFoundRoles.Count)" -ForegroundColor Cyan
    if ($pendingRoles.Count -gt 0) {
        Write-Host "  Roles pending Multi Admin Approval: $($pendingRoles.Count)" -ForegroundColor Yellow
    }
    Write-Host "  Groups removed: $($removedGroups.Count)" -ForegroundColor Green
    Write-Host "  Groups not found: $($notFoundGroups.Count)" -ForegroundColor Cyan

    if ($pendingRoles.Count -gt 0) {
        Write-Host "`nMulti Admin Approval is active for Role-based access control on this tenant." -ForegroundColor Yellow
        Write-Host "  An approver must approve the queued deletion requests in:" -ForegroundColor Gray
        Write-Host "    Intune admin center > Tenant administration > Multi Admin Approval > Received requests" -ForegroundColor Gray
        Write-Host "  After approval, return to 'My requests' and select Complete on each item." -ForegroundColor Gray
        Write-Host "  The role's role assignments will be removed automatically as part of the cascade." -ForegroundColor Gray
    }
    
    return
}

Write-Host "`nCreating Remote Help RBAC roles and groups..." -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan

if ($AssignRoles) {
    Write-Host "Assignment mode: roles will be bound to their paired groups with scope 'All devices and All users'.`n" -ForegroundColor Cyan
}

# Track results
$createdRoles = @()
$existingRoles = @()
$pendingRolesCreate = @()
$failedRoles = @()
$createdGroups = @()
$existingGroups = @()
$failedGroups = @()
$createdAssignments = @()
$existingAssignments = @()
$pendingAssignments = @()
$failedAssignments = @()

# Create each role
foreach ($role in $roles) {
    Write-Host "Processing: $($role.Name)" -ForegroundColor Yellow

    # Reset per-iteration handles so stale values from previous iterations don't leak
    $customRole  = $null
    $targetGroup = $null

    try {
        # Check if role already exists
        $existingRole = Get-ExistingRole -RoleName $role.Name
        
        if ($existingRole) {
            Write-Host "  [INFO] Role already exists, skipping creation" -ForegroundColor Cyan
            Write-Host "    Role ID: $($existingRole.Id)" -ForegroundColor Gray
            $customRole = $existingRole
            $existingRoles += $customRole
        }
        else {
            if ($PSCmdlet.ShouldProcess("Role: $($role.Name)", "Create")) {
                # Build the role definition body. Using the raw Graph endpoint via
                # Invoke-MaaAwareRequest (instead of New-MgDeviceManagementRoleDefinition)
                # so the x-msft-approval-justification header can be attached on tenants
                # with a Multi Admin Approval (MAA) access policy on the Role profile type.
                $body = [ordered]@{
                    '@odata.type'    = '#microsoft.graph.roleDefinition'
                    displayName      = $role.Name
                    description      = $role.Description
                    isBuiltIn        = $false
                    rolePermissions  = @(
                        @{
                            resourceActions = @(
                                @{
                                    allowedResourceActions    = $role.Permissions
                                    notAllowedResourceActions = @()
                                }
                            )
                        }
                    )
                }

                $createUri = 'https://graph.microsoft.com/beta/deviceManagement/roleDefinitions'
                $bodyJson  = $body | ConvertTo-Json -Depth 6
                $result    = Invoke-MaaAwareRequest -Method POST -Uri $createUri -Body $bodyJson -Justification $ApprovalJustification

                switch ($result.Status) {
                    'Success' {
                        $customRole = $result.Data
                        Write-Host "  [SUCCESS] Role created!" -ForegroundColor Green
                        Write-Host "    Role ID: $($customRole.id)" -ForegroundColor Gray
                        # Re-shape so .Id matches the casing used elsewhere in the script
                        $customRole = [pscustomobject]@{
                            Id          = $customRole.id
                            DisplayName = $customRole.displayName
                        }
                        $createdRoles += $customRole
                    }
                    'PendingApproval' {
                        Write-Host "  [PENDING] Role '$($role.Name)' creation submitted to Multi Admin Approval." -ForegroundColor Cyan
                        Write-Host "    Approval code: $($result.ApprovalCode)" -ForegroundColor Gray
                        Write-Host "    Approvers: Intune admin center > Tenant administration > Multi Admin Approval > Received requests" -ForegroundColor Gray
                        $pendingRolesCreate += $role.Name
                        $customRole = $null
                    }
                    default {
                        Write-Host "  [ERROR] Failed to create role: $($result.Error)" -ForegroundColor Red
                        $failedRoles += $role.Name
                        $customRole = $null
                    }
                }
            }
        }
        
        # Create Entra ID group
        Write-Host "  Checking for Entra ID group: $($role.GroupName)" -ForegroundColor Yellow
        
        try {
                # Check if group already exists
                $existingGroup = Get-ExistingGroup -GroupName $role.GroupName
                
                if ($existingGroup) {
                    Write-Host "  [INFO] Group already exists, skipping creation" -ForegroundColor Cyan
                    Write-Host "    Group ID: $($existingGroup.Id)" -ForegroundColor Gray
                    Write-Host "    Group Name: $($existingGroup.DisplayName)" -ForegroundColor Gray
                    $targetGroup = $existingGroup
                    $existingGroups += $existingGroup
                }
                else {
                    if ($PSCmdlet.ShouldProcess("Group: $($role.GroupName)", "Create")) {
                        $groupParams = @{
                            DisplayName = $role.GroupName
                            Description = "Intune RBAC role assignment group for $($role.Name)"
                            MailEnabled = $false
                            SecurityEnabled = $true
                            MailNickname = $role.GroupName -replace '[^a-zA-Z0-9]', ''
                        }
                        
                        $newGroup = New-MgGroup @groupParams
                        
                        Write-Host "  [SUCCESS] Group created!" -ForegroundColor Green
                        Write-Host "    Group ID: $($newGroup.Id)" -ForegroundColor Gray
                        Write-Host "    Group Name: $($newGroup.DisplayName)" -ForegroundColor Gray
                        
                        $targetGroup = $newGroup
                        $createdGroups += $newGroup
                    }
                }
            }
            catch {
                Write-Host "  [ERROR] Failed to create group" -ForegroundColor Red
                Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
                $failedGroups += $role.GroupName
            }

        # Optionally bind the role to its paired group
        if ($AssignRoles) {
            if ($customRole -and $customRole.Id -and $targetGroup -and $targetGroup.Id) {
                Write-Host "  Checking role assignment: $($customRole.DisplayName) -> $($targetGroup.DisplayName)" -ForegroundColor Yellow
                $result = Set-RemoteHelpRoleAssignment -RoleDefinition $customRole -EntraGroup $targetGroup -Justification $ApprovalJustification
                switch ($result.Status) {
                    'Created'         { $createdAssignments  += $result.Name }
                    'Existing'        { $existingAssignments += $result.Name }
                    'PendingApproval' { $pendingAssignments  += $result.Name }
                    'Failed'          { $failedAssignments   += $result.Name }
                    'WhatIf'          { }
                }
            }
            else {
                Write-Host "  [INFO] Skipped role assignment - role or group not yet created (WhatIf or earlier failure)" -ForegroundColor Cyan
            }
        }
    }
    catch {
        Write-Host "  [ERROR] Failed to create role" -ForegroundColor Red
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
        $failedRoles += $role.Name
    }
    
    Write-Host ""
}

# Summary
Write-Host "=========================================`n" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Roles created: $($createdRoles.Count)" -ForegroundColor Green
Write-Host "  Roles already existing: $($existingRoles.Count)" -ForegroundColor Cyan
if ($pendingRolesCreate.Count -gt 0) {
    Write-Host "  Roles pending Multi Admin Approval: $($pendingRolesCreate.Count)" -ForegroundColor Yellow
}
Write-Host "  Roles failed: $($failedRoles.Count)" -ForegroundColor $(if ($failedRoles.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Groups created: $($createdGroups.Count)" -ForegroundColor Green
Write-Host "  Groups already existing: $($existingGroups.Count)" -ForegroundColor Cyan
Write-Host "  Groups failed: $($failedGroups.Count)" -ForegroundColor $(if ($failedGroups.Count -gt 0) { "Red" } else { "Green" })
if ($AssignRoles) {
    Write-Host "  Assignments created: $($createdAssignments.Count)" -ForegroundColor Green
    Write-Host "  Assignments already existing: $($existingAssignments.Count)" -ForegroundColor Cyan
    if ($pendingAssignments.Count -gt 0) {
        Write-Host "  Assignments pending Multi Admin Approval: $($pendingAssignments.Count)" -ForegroundColor Yellow
    }
    Write-Host "  Assignments failed: $($failedAssignments.Count)" -ForegroundColor $(if ($failedAssignments.Count -gt 0) { "Red" } else { "Green" })
}

if ($failedRoles.Count -gt 0) {
    Write-Host "`nFailed roles:" -ForegroundColor Red
    $failedRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($pendingRolesCreate.Count -gt 0) {
    Write-Host "`nRoles pending Multi Admin Approval (Intune admin center > Tenant administration > Multi Admin Approval):" -ForegroundColor Yellow
    $pendingRolesCreate | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "  After an approver approves the request, return to 'My requests' and select Complete to finalize." -ForegroundColor Gray
    if ($AssignRoles) {
        Write-Host "`n  [HEADS UP] -AssignRoles was specified, but role assignments could NOT be created in this run." -ForegroundColor Yellow
        Write-Host "             Assignments must reference an existing role ID, which does not exist until MAA approval completes." -ForegroundColor Gray
        Write-Host "             On MAA-protected tenants this script must be run TWICE to fully provision roles + assignments:" -ForegroundColor Gray
        Write-Host "               1. First run  : creates roles (queued in MAA) and Entra groups." -ForegroundColor Gray
        Write-Host "               2. Approve role-creation requests in MAA, then Complete them under 'My requests'." -ForegroundColor Gray
        Write-Host "               3. Second run : re-run with -AssignRoles to create the role assignments" -ForegroundColor Gray
        Write-Host "                              (these may also queue in MAA if the tenant policy covers role assignments)." -ForegroundColor Gray
    }
    else {
        Write-Host "  Re-run the script with -AssignRoles after approval to create the paired role assignments." -ForegroundColor Gray
    }
}

if ($failedGroups.Count -gt 0) {
    Write-Host "`nFailed groups:" -ForegroundColor Red
    $failedGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($AssignRoles -and $pendingAssignments.Count -gt 0) {
    Write-Host "`nAssignments pending Multi Admin Approval (Intune admin center > Tenant administration > Multi Admin Approval):" -ForegroundColor Yellow
    $pendingAssignments | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "  After an approver approves the request, return to 'My requests' and select Complete to finalize." -ForegroundColor Gray
}

if ($AssignRoles -and $failedAssignments.Count -gt 0) {
    Write-Host "`nFailed assignments:" -ForegroundColor Red
    $failedAssignments | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($AssignRoles) {
    Write-Host "`nAdd helper user accounts to the paired Entra ID groups to grant them Remote Help permissions." -ForegroundColor Cyan
    Write-Host "  Intune portal > Tenant administration > Roles > Select role > Assignments (to verify)" -ForegroundColor Gray
}
elseif ($pendingRolesCreate.Count -eq 0) {
    Write-Host "`nNote: To assign these roles to groups, go to:" -ForegroundColor Cyan
    Write-Host "  Intune portal > Tenant administration > Roles > Select role > Assignments" -ForegroundColor Gray
    Write-Host "  Or re-run this script with -AssignRoles to bind each role to its paired group automatically." -ForegroundColor Gray
}

}
finally {
    # Disconnect-MgGraph intentionally disabled during development to keep the
    # cached token between runs. Re-enable for production / one-shot usage.
    # Write-Host "`nDisconnecting from Microsoft Graph..." -ForegroundColor Cyan
    # Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
