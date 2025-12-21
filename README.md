# Intune Remote Help RBAC Automation

Automate the creation of custom RBAC roles and security groups for Microsoft Intune Remote Help permissions.

## Overview

This PowerShell script creates four custom RBAC roles in Microsoft Intune, each with specific Remote Help permissions, along with corresponding Entra ID security groups for role assignment. It eliminates the manual, time-consuming process of setting up Remote Help RBAC roles through the Intune portal.

### Created Roles

| Role Name | Permissions | Use Case |
|-----------|-------------|----------|
| Remote Help - View Screen Only | View sharer's screen | Level 1 support, read-only assistance |
| Remote Help - Full Control | Take full control of device | Level 2/3 support, active troubleshooting |
| Remote Help - Elevation | Interact with UAC prompts (Windows) | Elevated administrative tasks |
| Remote Help - Unattended (Android) | Connect without user acceptance | Managed Android device support |

All roles include base permissions:
- Remote Tasks - Offer remote assistance
- Remote Assistance Connector - Read

## Prerequisites

### Required Modules
```powershell
Install-Module Microsoft.Graph.DeviceManagement.Administration
Install-Module Microsoft.Graph.Groups
Install-Module Microsoft.Graph.Authentication
```

### Required Permissions
- `DeviceManagementRBAC.ReadWrite.All`
- `Group.ReadWrite.All`

### Account Requirements
- Global Administrator or Intune Administrator role

## Usage

### Create Roles and Groups
```powershell
.\Create-Intune-Remote-Help-Roles-Groups.ps1
```

### Preview Changes (WhatIf Mode)
```powershell
.\Create-Intune-Remote-Help-Roles-Groups.ps1 -WhatIf
```

### Remove All Roles and Groups
```powershell
.\Create-Intune-Remote-Help-Roles-Groups.ps1 -Remove
```

### Remove with Preview
```powershell
.\Create-Intune-Remote-Help-Roles-Groups.ps1 -Remove -WhatIf
```

## Output Example

```
Connecting to Microsoft Graph...

Creating Remote Help RBAC roles and groups...
=========================================

Processing: Remote Help - View Screen Only
  [SUCCESS] Role created!
    Role ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
  [SUCCESS] Group created!
    Group ID: f9e8d7c6-b5a4-3210-fedc-ba0987654321
    Group Name: Intune-RemoteHelp-ViewScreenOnly

Processing: Remote Help - Full Control
  [INFO] Role already exists, skipping creation
  [INFO] Group already exists, skipping creation

=========================================

Summary:
  Roles created: 2
  Roles already existing: 2
  Roles failed: 0
  Groups created: 2
  Groups already existing: 2
  Groups failed: 0

Note: To assign these roles to groups, go to:
  Intune portal > Tenant administration > Roles > Select role > Assignments
```

## Post-Installation

After running the script:

1. **Add Users to Groups**: Add support staff to the appropriate security groups:
   - `Intune-RemoteHelp-ViewScreenOnly`
   - `Intune-RemoteHelp-FullControl`
   - `Intune-RemoteHelp-Elevation`
   - `Intune-RemoteHelp-Unattended`

2. **Assign Roles to Groups**: In the Intune admin center:
   - Go to **Tenant administration** > **Roles**
   - Select each created role
   - Click **Assignments** > **Assign**
   - Add the corresponding group as **Admin Group**
   - Set the scope (all devices, specific groups, etc.)

## Features

- ✅ Idempotent - safe to run multiple times
- ✅ WhatIf mode - preview changes without making them
- ✅ Remove mode - clean up all created resources
- ✅ Error handling - detailed error messages and summaries
- ✅ Helper functions - optimized and maintainable code

## Documentation

For more information about Remote Help RBAC permissions, see:
- [Planning for Remote Help with Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/remote-help-plan)
- [Role-based access control (RBAC) with Microsoft Intune](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control)

## License

MIT License - See LICENSE file for details

## Author

Martin Bengtsson

## Contributing

Issues and pull requests are welcome!
