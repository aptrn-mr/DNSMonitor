[CmdletBinding()]
param(
 [string]$TaskName='Monitor DNS Corporativo',
 [int]$IntervalMinutes=5,
 [string]$ScriptPath="$PSScriptRoot\Monitor-DNS.ps1"
)
$engine = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $engine) { $engine = (Get-Command powershell.exe -ErrorAction Stop).Source }
$action = New-ScheduledTaskAction -Execute $engine -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Monitora resolucao DNS, baseline de IP e TCP.' -Force
