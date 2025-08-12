$LastWeek = (Get-Date).AddDays(-7)

Write-Host "Checking for applications removed in the last 7 days..." -ForegroundColor Green
Write-Host "Start Date: $LastWeek" -ForegroundColor Gray
Write-Host ""

# Method 1: Check for Event ID 11724 (Application uninstall events)
Write-Host "=== Method 1: Application Log Event ID 11724 ===" -ForegroundColor Cyan
try {
    $UninstallEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        ID = 11724
        StartTime = $LastWeek
    } -ErrorAction Stop
    
    if ($UninstallEvents) {
        Write-Host "Found $($UninstallEvents.Count) application uninstall event(s):" -ForegroundColor Yellow
        $UninstallEvents | ForEach-Object {
            try {
                [PSCustomObject]@{
                    TimeCreated = $_.TimeCreated
                    Application = $_.Properties[0].Value
                    Version = if ($_.Properties[1]) { $_.Properties[1].Value } else { "N/A" }
                    Publisher = if ($_.Properties[2]) { $_.Properties[2].Value } else { "N/A" }
                }
            }
            catch {
                [PSCustomObject]@{
                    TimeCreated = $_.TimeCreated
                    Application = "Could not parse application name"
                    Version = "N/A"
                    Publisher = "N/A"
                }
            }
        } | Sort-Object TimeCreated -Descending | Format-Table -AutoSize
    }
    else {
        Write-Host "No Event ID 11724 events found" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error accessing Event ID 11724: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# Method 2: MSI Installer Events (what you already saw working)
Write-Host "=== Method 2: MSI Installer Events ===" -ForegroundColor Cyan
try {
    $InstallerEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        ProviderName = 'MsiInstaller'
        StartTime = $LastWeek
    } -ErrorAction Stop | Where-Object { $_.Message -match 'removal|uninstall|removed' }
    
    if ($InstallerEvents) {
        Write-Host "Found $($InstallerEvents.Count) MSI removal event(s):" -ForegroundColor Yellow
        $InstallerEvents | Select-Object TimeCreated, Message | Sort-Object TimeCreated -Descending | Format-Table -Wrap
    }
    else {
        Write-Host "No MSI removal events found" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error accessing MSI Installer events: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# Method 3: System Event Log for broader installer activity
Write-Host "=== Method 3: System Log Installer Events ===" -ForegroundColor Cyan
try {
    $SystemEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'MsiInstaller'
        StartTime = $LastWeek
    } -ErrorAction Stop | Where-Object { $_.Message -match 'removal|uninstall|removed' }
    
    if ($SystemEvents) {
        Write-Host "Found $($SystemEvents.Count) system installer event(s):" -ForegroundColor Yellow
        $SystemEvents | Select-Object TimeCreated, Id, Message | Sort-Object TimeCreated -Descending | Format-Table -Wrap
    }
    else {
        Write-Host "No system installer events found" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error accessing System log events: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# Method 4: Check for any other relevant events
Write-Host "=== Method 4: Other Uninstall-Related Events ===" -ForegroundColor Cyan
try {
    $OtherEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        StartTime = $LastWeek
    } -ErrorAction Stop | Where-Object {
        $_.Message -match 'uninstall|removal|removed' -and 
        $_.ProviderName -ne 'MsiInstaller' -and 
        $_.Id -ne 11724
    } | Select-Object -First 20
    
    if ($OtherEvents) {
        Write-Host "Found $($OtherEvents.Count) other uninstall-related event(s):" -ForegroundColor Yellow
        $OtherEvents | Select-Object TimeCreated, ProviderName, Id, @{Name = 'Message'; Expression = { $_.Message.Substring(0, [Math]::Min(100, $_.Message.Length)) } } | 
        Sort-Object TimeCreated -Descending | Format-Table -Wrap
    }
    else {
        Write-Host "No other uninstall-related events found" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error accessing other application events: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Green