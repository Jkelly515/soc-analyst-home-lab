# ============================================================
# SOC Lab - Domain Activity Simulator
# Simulates realistic domain-authenticated activity on Windows 11
# against the TestDomain.ie domain controller for log generation.
# ============================================================

# ---- Configuration ----
$DomainUsersCSV = "C:\Tools\lab-users.csv"
$Domain         = "TESTDOMAIN"
$DomainFQDN     = "TestDomain.ie"
$DC             = "192.168.56.13"   # Update if your DC uses a different IP
$LogFile        = "C:\Tools\domain-simulator-log.txt"

# ---- Logging helper: writes to both the log file and the console (if visible) ----
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",   # INFO, ALERT, EVENT
        [string]$Color = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line -ForegroundColor $Color
}

# ---- Load domain users from CSV ----
if (-not (Test-Path $DomainUsersCSV)) {
    Write-Log -Message "Cannot find $DomainUsersCSV - aborting." -Level "ALERT" -Color Red
    exit 1
}
$users = Import-Csv $DomainUsersCSV
if (-not $users -or $users.Count -eq 0) {
    Write-Log -Message "No users found in CSV - aborting." -Level "ALERT" -Color Red
    exit 1
}

Write-Log -Message "Loaded $($users.Count) domain users from CSV." -Color Cyan
Write-Log -Message "Domain Activity Simulator started." -Color Cyan

# ---- Helper: attempt a domain logon using New-PSDrive (generates 4624/4625 on the DC) ----
function Invoke-DomainLogonAttempt {
    param(
        [string]$Username,
        [string]$Password,
        [bool]$ShouldSucceed = $true
    )

    $fullUser = "$Domain\$Username"
    $plainPass = if ($ShouldSucceed) { $Password } else { "WrongPassword_$(Get-Random -Maximum 9999)" }
    $securePass = ConvertTo-SecureString $plainPass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($fullUser, $securePass)

    try {
        # Mapping a drive against the DC's admin share forces domain authentication
        New-PSDrive -Name "SimTemp" -PSProvider FileSystem -Root "\\$DC\C$" -Credential $cred -ErrorAction Stop | Out-Null
        Remove-PSDrive -Name "SimTemp" -ErrorAction SilentlyContinue
        Write-Log -Message "Logon success: $fullUser - Event ID 4624 expected" -Level "EVENT" -Color Green
    } catch {
        Write-Log -Message "Logon failed: $fullUser - Event ID 4625 expected" -Level "EVENT" -Color Yellow
    }
}

# ---- Scenario: Normal Domain Logins ----
function Invoke-NormalLogins {
    Write-Log -Message ">>> Running: NormalDomainLogins" -Color Cyan
    $sample = $users | Get-Random -Count ([Math]::Min(3, $users.Count))
    foreach ($u in $sample) {
        Invoke-DomainLogonAttempt -Username $u.Username -Password $u.Password -ShouldSucceed $true
        Start-Sleep -Seconds (Get-Random -Minimum 2 -Maximum 6)
    }
}

# ---- Scenario: Domain Brute Force (single account, many failures) ----
function Invoke-DomainBruteForce {
    Write-Log -Message ">>> Running: DomainBruteForce" -Color Cyan
    $target = $users | Get-Random
    Write-Log -Message "SCENARIO: Brute force targeting '$($target.Username)'" -Level "ALERT" -Color Yellow
    for ($i = 0; $i -lt 6; $i++) {
        Invoke-DomainLogonAttempt -Username $target.Username -Password $target.Password -ShouldSucceed $false
        Start-Sleep -Seconds 1
    }
}

# ---- Scenario: Account Lockout (forces enough failures to trip lockout policy, if configured) ----
function Invoke-AccountLockoutScenario {
    Write-Log -Message ">>> Running: AccountLockoutScenario" -Color Cyan
    $target = $users | Get-Random
    Write-Log -Message "SCENARIO: Lockout attempt targeting '$($target.Username)' - Event ID 4740 expected" -Level "ALERT" -Color Yellow
    for ($i = 0; $i -lt 10; $i++) {
        Invoke-DomainLogonAttempt -Username $target.Username -Password $target.Password -ShouldSucceed $false
        Start-Sleep -Milliseconds 500
    }
}

# ---- Scenario: Privileged (Domain Admin) Login ----
function Invoke-AdminLogin {
    Write-Log -Message ">>> Running: DomainAdminLogin" -Color Cyan
    $admins = $users | Where-Object { $_.IsAdmin -eq "Yes" }
    if ($admins.Count -eq 0) {
        Write-Log -Message "No admin users found in CSV, skipping." -Level "INFO" -Color Gray
        return
    }
    $admin = $admins | Get-Random
    Invoke-DomainLogonAttempt -Username $admin.Username -Password $admin.Password -ShouldSucceed $true
}

# ---- Main loop ----
$scenarios = @(
    { Invoke-NormalLogins },
    { Invoke-NormalLogins },
    { Invoke-DomainBruteForce },
    { Invoke-AdminLogin },
    { Invoke-AccountLockoutScenario }
)

while ($true) {
    $scenario = $scenarios | Get-Random
    & $scenario
    $sleepMinutes = Get-Random -Minimum 3 -Maximum 8
    Write-Log -Message "Next scenario in $sleepMinutes minutes..." -Level "INFO" -Color DarkGray
    Start-Sleep -Seconds ($sleepMinutes * 60)
}
