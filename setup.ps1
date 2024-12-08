# setup.ps1

# =============================================================================
# Script Name: setup.ps1
# Description: Configures Windows Server 2025 post-installation
# =============================================================================

param (
    [Parameter(Mandatory=$true)]
    [string]$Username
)

# =============================================================================
# Variables
# =============================================================================

# Public SSH key for secure SSH access
$PublicKeyContent = @"
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIYourPublicKeyHere $Username@kvm
"@

# Path to drivers directory
$DriverPaths = @("C:\Drivers")

# =============================================================================
# Function Definitions
# =============================================================================

# Function to install VirtIO Drivers with Verification
function Install-VirtIODrivers {
    foreach ($path in $DriverPaths) {
        if (Test-Path -Path $path) {
            Write-Host "Installing VirtIO drivers from $path..." -ForegroundColor Cyan
            Get-ChildItem -Path $path -Recurse -Include *.inf | ForEach-Object {
                # Verify driver signature before installation
                $signature = Get-AuthenticodeSignature $_.FullName
                if ($signature.Status -eq 'Valid') {
                    PnPUtil.exe /add-driver $_.FullName /install /subdirs
                    Write-Host "Installed driver: $($_.FullName)" -ForegroundColor Green
                } else {
                    Write-Warning "Driver signature invalid for: $($_.FullName). Skipping installation."
                }
            }
        } else {
            Write-Warning "Driver path not found: $path. Skipping VirtIO driver installation."
        }
    }
}

# Function to configure SSH securely
function Configure-SSH {
    Write-Host "Configuring OpenSSH Server..." -ForegroundColor Cyan

    # Install OpenSSH Server
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

    # Start and set SSH service to automatic
    Start-Service sshd
    Set-Service -Name sshd -StartupType 'Automatic'

    # Configure sshd_config for enhanced security
    $sshd_config_path = 'C:\ProgramData\ssh\sshd_config'
    $sshd_config = @"
Port 22
Protocol 2
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::
HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
StrictModes yes
MaxAuthTries 3
AllowUsers $Username
"@

    # Backup existing sshd_config
    if (Test-Path -Path $sshd_config_path) {
        Copy-Item -Path $sshd_config_path -Destination "$sshd_config_path.bak" -Force
        Write-Host "Backed up existing sshd_config to $sshd_config_path.bak" -ForegroundColor Yellow
    }

    # Write new sshd_config
    $sshd_config | Set-Content -Path $sshd_config_path -Encoding ascii
    icacls $sshd_config_path /inheritance:r /grant "NT Service\sshd:(R)" "SYSTEM:(F)" "Administrators:(F)" /T

    Write-Host "sshd_config configured for enhanced security." -ForegroundColor Green
}

# Function to set up SSH authorized keys
function Setup-AuthorizedKeys {
    Write-Host "Setting up SSH authorized_keys..." -ForegroundColor Cyan

    $userProfile = "C:\Users\$Username"
    $sshDir = "$userProfile\.ssh"
    $authorizedKeys = "$sshDir\authorized_keys"

    # Create .ssh directory with secure permissions
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    icacls $sshDir /inheritance:r /grant "$Username:(F)" /T

    # Add public key to authorized_keys
    $PublicKeyContent | Out-File -FilePath $authorizedKeys -Encoding ascii -Force
    icacls $authorizedKeys /inheritance:r /grant "$Username:(R)" "SYSTEM:(F)" /T

    Write-Host "Authorized_keys configured for user $Username." -ForegroundColor Green
}

# Function to configure Windows Firewall
function Configure-Firewall {
    Write-Host "Configuring Windows Firewall..." -ForegroundColor Cyan

    # Open SSH port
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (Inbound)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

    # Open Remote Desktop port
    New-NetFirewallRule -Name "RemoteDesktop-In-TCP" -DisplayName "Remote Desktop (Inbound)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 3389

    # Enable Remote Desktop Firewall rules
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

    Write-Host "Windows Firewall configured with necessary rules." -ForegroundColor Green
}

# Function to enable Remote Desktop and Network Level Authentication
function Enable-RemoteDesktop {
    Write-Host "Enabling Remote Desktop with Network Level Authentication..." -ForegroundColor Cyan

    # Enable Remote Desktop
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0

    # Enable Network Level Authentication
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1

    Write-Host "Remote Desktop and NLA enabled." -ForegroundColor Green
}

# Function to apply additional security settings
function Apply-SecuritySettings {
    Write-Host "Applying additional security settings..." -ForegroundColor Cyan

    # Disable SMB1 Protocol
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force

    # Set Execution Policy to RemoteSigned
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

    Write-Host "Additional security settings applied." -ForegroundColor Green
}

# Function to disable Server Manager at logon
function Disable-ServerManager {
    Write-Host "Disabling Server Manager at logon..." -ForegroundColor Cyan

    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1

    Write-Host "Server Manager disabled at logon." -ForegroundColor Green
}

# Function to optimize power settings for performance
function Optimize-PowerSettings {
    Write-Host "Optimizing power settings for performance..." -ForegroundColor Cyan

    powercfg -Change -standby-timeout-ac 0
    powercfg -Change -hibernate-timeout-ac 0

    Write-Host "Power settings optimized." -ForegroundColor Green
}

# Function to install Windows Updates
function Install-WindowsUpdates {
    Write-Host "Installing Windows Updates..." -ForegroundColor Cyan

    # Install NuGet provider
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser

    # Install PSWindowsUpdate module
    Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser

    # Import PSWindowsUpdate module
    Import-Module PSWindowsUpdate

    # Set Execution Policy to RemoteSigned
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

    # Add Microsoft Update Service
    Add-WUServiceManager -ServiceID "7971f918-a847-4430-9279-4a52d1efe18d"

    # Install all available updates and reboot if necessary
    Get-WindowsUpdate -AcceptAll -Install -AutoReboot

    Write-Host "Windows Updates installation initiated." -ForegroundColor Green
}

# Function to restart the computer
function Restart-System {
    Write-Host "Restarting computer to apply changes..." -ForegroundColor Cyan
    Restart-Computer -Force
}

# =============================================================================
# Main Script Execution
# =============================================================================

try {
    Install-VirtIODrivers
    Configure-SSH
    Setup-AuthorizedKeys
    Configure-Firewall
    Enable-RemoteDesktop
    Apply-SecuritySettings
    Disable-ServerManager
    Optimize-PowerSettings
    Install-WindowsUpdates
    Restart-System
} catch {
    Write-Error "An error occurred during setup: $_"
    Exit 1
}
