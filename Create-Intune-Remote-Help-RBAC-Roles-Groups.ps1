<#
.SYNOPSIS
    Creates Intune RBAC roles and security groups for Remote Help.

.DESCRIPTION
    Creates four custom RBAC roles with their corresponding Entra ID security groups:
    - Remote Help - View Screen Only
    - Remote Help - Full Control
    - Remote Help - Elevation
    - Remote Help - Unattended (Android)
    
    All roles include base permissions:
    - Remote Tasks - Offer remote assistance
    - Remote Assistance Connector - Read
    
    Assign roles to groups manually via Intune portal > Tenant administration > Roles.

.PARAMETER Remove
    Removes all Remote Help roles and groups created by this script.

.PARAMETER WhatIf
    Shows what would happen if the script runs without making any changes.

.EXAMPLE
    .\Create-Intune-Remote-Help-Roles-Groups.ps1
    Creates roles and groups.

.EXAMPLE
    .\Create-Intune-Remote-Help-Roles-Groups.ps1 -Remove
    Removes all roles and groups.

.EXAMPLE
    .\Create-Intune-Remote-Help-Roles-Groups.ps1 -WhatIf
    Shows what would be created without making changes.

.NOTES
    Author: Martin Bengtsson
    Date: December 21, 2025
    Version: 2.0
    
    Version History:
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

param(
    [Parameter(Mandatory=$false)]
    [switch]$Remove,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# Connect to Microsoft Graph with required permissions
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
try {
    Connect-MgGraph -Scopes "DeviceManagementRBAC.ReadWrite.All", "Group.ReadWrite.All" -NoWelcome -ErrorAction Stop
}
catch {
    Write-Host "[ERROR] Failed to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Helper function to get existing role
function Get-ExistingRole {
    param([string]$RoleName)
    
    try {
        return Get-MgDeviceManagementRoleDefinition -All | 
            Where-Object { $_.DisplayName -eq $RoleName }
    }
    catch {
        Write-Host "  [WARNING] Failed to query role: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# Helper function to get existing group
function Get-ExistingGroup {
    param([string]$GroupName)
    
    try {
        return Get-MgGroup -Filter "displayName eq '$GroupName'"
    }
    catch {
        Write-Host "  [WARNING] Failed to query group: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
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
    $removedGroups = @()
    $notFoundRoles = @()
    $notFoundGroups = @()
    $wouldRemoveRoles = @()
    $wouldRemoveGroups = @()
    
    foreach ($role in $roles) {
        Write-Host "Processing: $($role.Name)" -ForegroundColor Yellow
        
        # Remove role
        try {
            $existingRole = Get-ExistingRole -RoleName $role.Name
            
            if ($existingRole) {
                if ($WhatIf) {
                    Write-Host "  [WHATIF] Would remove role" -ForegroundColor Magenta
                    $wouldRemoveRoles += $role.Name
                }
                else {
                    Remove-MgDeviceManagementRoleDefinition -RoleDefinitionId $existingRole.Id -Confirm:$false
                    Write-Host "  [REMOVED] Role deleted" -ForegroundColor Green
                    $removedRoles += $role.Name
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
                if ($WhatIf) {
                    Write-Host "  [WHATIF] Would remove group" -ForegroundColor Magenta
                    $wouldRemoveGroups += $role.GroupName
                }
                else {
                    Remove-MgGroup -GroupId $existingGroup.Id
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
    if ($WhatIf) {
        Write-Host "  Roles would be removed: $($wouldRemoveRoles.Count)" -ForegroundColor Magenta
        Write-Host "  Roles not found: $($notFoundRoles.Count)" -ForegroundColor Cyan
        Write-Host "  Groups would be removed: $($wouldRemoveGroups.Count)" -ForegroundColor Magenta
        Write-Host "  Groups not found: $($notFoundGroups.Count)" -ForegroundColor Cyan
    }
    else {
        Write-Host "  Roles removed: $($removedRoles.Count)" -ForegroundColor Green
        Write-Host "  Roles not found: $($notFoundRoles.Count)" -ForegroundColor Cyan
        Write-Host "  Groups removed: $($removedGroups.Count)" -ForegroundColor Green
        Write-Host "  Groups not found: $($notFoundGroups.Count)" -ForegroundColor Cyan
    }
    
    return
}

Write-Host "`nCreating Remote Help RBAC roles and groups..." -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "[WHATIF MODE] No changes will be made`n" -ForegroundColor Magenta
}

# Track results
$createdRoles = @()
$existingRoles = @()
$failedRoles = @()
$createdGroups = @()
$existingGroups = @()
$failedGroups = @()

# Create each role
foreach ($role in $roles) {
    Write-Host "Processing: $($role.Name)" -ForegroundColor Yellow
    
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
            if ($WhatIf) {
                Write-Host "  [WHATIF] Would create role" -ForegroundColor Magenta
                Write-Host "    Display Name: $($role.Name)" -ForegroundColor Gray
                Write-Host "    Description: $($role.Description)" -ForegroundColor Gray
                $customRole = $null
            }
            else {
                # Build resource actions
                $resourceAction = @{
                    AllowedResourceActions = $role.Permissions
                    NotAllowedResourceActions = @()
                }
                
                $rolePermissions = @(
                    @{
                        ResourceActions = @($resourceAction)
                    }
                )
                
                # Create the custom role definition
                $customRole = New-MgDeviceManagementRoleDefinition `
                    -DisplayName $role.Name `
                    -Description $role.Description `
                    -RolePermissions $rolePermissions `
                    -IsBuiltIn:$false
                
                Write-Host "  [SUCCESS] Role created!" -ForegroundColor Green
                Write-Host "    Role ID: $($customRole.Id)" -ForegroundColor Gray
                
                $createdRoles += $customRole
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
                    $existingGroups += $existingGroup
                }
                else {
                    if ($WhatIf) {
                        Write-Host "  [WHATIF] Would create group" -ForegroundColor Magenta
                        Write-Host "    Display Name: $($role.GroupName)" -ForegroundColor Gray
                        Write-Host "    Description: Intune RBAC role assignment group for $($role.Name)" -ForegroundColor Gray
                    }
                    else {
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
                        
                        $createdGroups += $newGroup
                    }
                }
            }
            catch {
                Write-Host "  [ERROR] Failed to create group" -ForegroundColor Red
                Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
                $failedGroups += $role.GroupName
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
Write-Host "  Roles failed: $($failedRoles.Count)" -ForegroundColor $(if ($failedRoles.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Groups created: $($createdGroups.Count)" -ForegroundColor Green
Write-Host "  Groups already existing: $($existingGroups.Count)" -ForegroundColor Cyan
Write-Host "  Groups failed: $($failedGroups.Count)" -ForegroundColor $(if ($failedGroups.Count -gt 0) { "Red" } else { "Green" })

if ($failedRoles.Count -gt 0) {
    Write-Host "`nFailed roles:" -ForegroundColor Red
    $failedRoles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($failedGroups.Count -gt 0) {
    Write-Host "`nFailed groups:" -ForegroundColor Red
    $failedGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

Write-Host "`nNote: To assign these roles to groups, go to:" -ForegroundColor Cyan
Write-Host "  Intune portal > Tenant administration > Roles > Select role > Assignments" -ForegroundColor Gray
