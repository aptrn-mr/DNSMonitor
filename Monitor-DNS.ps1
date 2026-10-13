[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config.json",
    [string]$TargetsPath = "$PSScriptRoot\DNSMonitor.csv",
    [switch]$TestNotifications,
    [switch]$WhatIfAlerts,
    [switch]$ResetState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:TextLogPath -Value $line -Encoding UTF8
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name, $Default=$null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function ConvertTo-Bool {
    param($Value, [bool]$Default=$false)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    return ([string]$Value).Trim() -match '^(1|true|sim|yes)$'
}

function ConvertTo-StringArray {
    param($Value, [string]$Separator='|')
    if ($null -eq $Value) { return @() }
    return @(([string]$Value -split [regex]::Escape($Separator)) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Save-State {
    $script:State | Export-Clixml -LiteralPath $script:StatePath
}

function Get-SmtpCredential {
    if (-not $script:Config.Email.Enabled) { return $null }
    $path = Join-Path $PSScriptRoot $script:Config.Email.CredentialFile
    if (-not (Test-Path -LiteralPath $path)) { throw "Credencial SMTP ausente: $path. Execute .\New-SmtpCredential.ps1" }
    return Import-Clixml -LiteralPath $path
}

function Send-TeamsAlert {
    param([string]$Title,[string]$Severity,[string]$Message,[hashtable]$Facts)
    if (-not $script:Config.Teams.Enabled) { return }
    if ($WhatIfAlerts) { Write-Log "SIMULACAO Teams: $Title | $Message"; return }

    $uri = [Environment]::GetEnvironmentVariable($script:Config.Teams.WebhookEnvironmentVariable, 'Machine')
    if ([string]::IsNullOrWhiteSpace($uri)) {
        $uri = [Environment]::GetEnvironmentVariable($script:Config.Teams.WebhookEnvironmentVariable, 'User')
    }
    if ([string]::IsNullOrWhiteSpace($uri)) { throw "Variavel de ambiente $($script:Config.Teams.WebhookEnvironmentVariable) nao definida." }

    if ($script:Config.Teams.PayloadMode -eq 'WorkflowGeneric') {
        $payload = [ordered]@{ title=$Title; severity=$Severity; message=$Message; timestamp=(Get-Date).ToString('o'); source=$env:COMPUTERNAME; facts=$Facts }
    } else {
        $factText = ($Facts.GetEnumerator() | Sort-Object Name | ForEach-Object { "**$($_.Name):** $($_.Value)" }) -join "`n`n"
        $payload = @{ text = "**$Title**`n`n$Message`n`n$factText" }
    }
    $json = $payload | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec $script:Config.General.NotificationTimeoutSeconds | Out-Null
}

function Send-EmailAlert {
    param([string]$Subject,[string]$HtmlBody,[string[]]$To)
    if (-not $script:Config.Email.Enabled) { return }
    $recipients = @($To + $script:Config.Email.DefaultRecipients | Where-Object { $_ } | Sort-Object -Unique)
    if ($recipients.Count -eq 0) { Write-Log 'Alerta sem destinatario de e-mail.' 'WARN'; return }
    if ($WhatIfAlerts) { Write-Log "SIMULACAO Email para $($recipients -join ', '): $Subject"; return }

    $cred = Get-SmtpCredential
    $mailParams = @{
        SmtpServer=$script:Config.Email.SmtpServer; Port=[int]$script:Config.Email.Port
        UseSsl=[bool]$script:Config.Email.UseSsl; Credential=$cred
        From=$script:Config.Email.From; To=$recipients
        Subject=$Subject; Body=$HtmlBody; BodyAsHtml=$true; Encoding=[Text.Encoding]::UTF8
    }
    Send-MailMessage @mailParams
}

function Send-Notification {
    param([string]$Kind,[object]$Result,[string[]]$Recipients)
    $isRecovery = $Kind -eq 'RECUPERACAO'
    $severity = if ($isRecovery) { 'OK' } else { 'CRITICO' }
    $title = if ($isRecovery) { "DNS RECUPERADO: $($Result.Hostname)" } else { "ALERTA DNS: $($Result.Hostname)" }
    $message = if ($isRecovery) { 'O alvo voltou ao estado normal.' } else { $Result.Details }
    $facts = [ordered]@{
        Hostname=$Result.Hostname; Equipe=$Result.Team; DNSServer=$Result.DnsServer
        IPsEsperados=$Result.ExpectedIPs; IPsObtidos=$Result.ResolvedIPs
        TempoDNSms=$Result.DnsTimeMs; Porta=$Result.Port; TCP=$Result.TcpStatus
        Estado=$Result.Status; ExecutadoEm=$Result.Timestamp
    }
    $html = @"
<html><body style='font-family:Segoe UI,Arial'><h2>$title</h2><p>$message</p>
<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse'>
$(( $facts.GetEnumerator() | ForEach-Object { "<tr><th align='left'>$($_.Name)</th><td>$([System.Net.WebUtility]::HtmlEncode([string]$_.Value))</td></tr>" } ) -join "`n")
</table><p>Origem: $env:COMPUTERNAME</p></body></html>
"@
    $errors = @()
    try { Send-TeamsAlert -Title $title -Severity $severity -Message $message -Facts $facts } catch { $errors += "Teams: $($_.Exception.Message)" }
    try { Send-EmailAlert -Subject "[$severity] $title" -HtmlBody $html -To $Recipients } catch { $errors += "Email: $($_.Exception.Message)" }
    if ($errors.Count -gt 0) { Write-Log ($errors -join ' | ') 'ERROR' } else { Write-Log "Notificacao enviada: $title" }
}

function Test-DnsTarget {
    param([object]$Target)
    $hostName = ([string]$Target.Hostname).Trim()
    $expected = ConvertTo-StringArray $Target.ExpectedIPs
    $dnsServer = ([string](Get-PropertyValue $Target 'DnsServer' '')).Trim()
    $portText = ([string](Get-PropertyValue $Target 'Port' '')).Trim()
    $port = if ($portText) { [int]$portText } else { 0 }
    $retryCount = [int]$script:Config.General.RetryCount
    $resolved = @(); $ttl = ''; $dnsMs = 0; $dnsError = ''

    for ($attempt=1; $attempt -le ($retryCount + 1); $attempt++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $p = @{ Name=$hostName; Type='A'; DnsOnly=$true; ErrorAction='Stop' }
            if ($dnsServer) { $p.Server = $dnsServer }
            $records = @(Resolve-DnsName @p | Where-Object { $_.Type -eq 'A' -and $_.IPAddress })
            $sw.Stop(); $dnsMs = [math]::Round($sw.Elapsed.TotalMilliseconds,2)
            $resolved = @($records.IPAddress | Sort-Object -Unique)
            $ttl = (@($records.TTL | Sort-Object -Unique) -join ';')
            if ($resolved.Count -gt 0) { break }
            $dnsError = 'A consulta nao retornou registro A.'
        } catch {
            $sw.Stop(); $dnsMs = [math]::Round($sw.Elapsed.TotalMilliseconds,2); $dnsError = $_.Exception.Message
        }
        if ($attempt -le $retryCount) { Start-Sleep -Seconds ([int]$script:Config.General.RetryDelaySeconds) }
    }

    $comparison = ([string](Get-PropertyValue $Target 'ComparisonMode' 'Exact')).Trim()
    $ipOk = $false
    if ($resolved.Count -gt 0 -and $expected.Count -gt 0) {
        if ($comparison -eq 'Any') { $ipOk = @($resolved | Where-Object { $expected -contains $_ }).Count -gt 0 }
        else { $ipOk = (@($resolved | Where-Object { $expected -notcontains $_ }).Count -eq 0 -and @($expected | Where-Object { $resolved -notcontains $_ }).Count -eq 0) }
    }

    $tcpStatus = 'NAO_TESTADO'; $tcpOk = $true
    if ($port -gt 0 -and $resolved.Count -gt 0) {
        try {
            $client = [Net.Sockets.TcpClient]::new()
            $task = $client.ConnectAsync($hostName,$port)
            $tcpOk = $task.Wait([int]$script:Config.General.TcpTimeoutMilliseconds) -and $client.Connected
            $tcpStatus = if ($tcpOk) { 'OK' } else { 'FALHA' }
            $client.Dispose()
        } catch { $tcpOk=$false; $tcpStatus='FALHA' }
    }

    $status='OK'; $details='Resolucao e validacoes realizadas com sucesso.'
    if ($resolved.Count -eq 0) { $status='DNS_FALHA'; $details="Falha de resolucao: $dnsError" }
    elseif (-not $ipOk) { $status='IP_DIVERGENTE'; $details='O conjunto de IPs obtido diverge do baseline.' }
    elseif (-not $tcpOk) { $status='TCP_FALHA'; $details="O DNS esta correto, mas a conexao TCP na porta $port falhou." }
    elseif ($dnsMs -gt [double]$script:Config.General.DnsWarningMilliseconds) { $status='DNS_LENTO'; $details="Resolucao acima do limite de $($script:Config.General.DnsWarningMilliseconds) ms." }

    [pscustomobject][ordered]@{
        Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Hostname=$hostName
        Team=(Get-PropertyValue $Target 'Team' ''); DnsServer=if($dnsServer){$dnsServer}else{'PADRAO_DO_SISTEMA'}
        ExpectedIPs=($expected -join ';'); ResolvedIPs=if($resolved.Count){$resolved -join ';'}else{'SEM_RESPOSTA'}
        TTL=$ttl; DnsTimeMs=$dnsMs; Port=$port; TcpStatus=$tcpStatus; Status=$status; Details=$details
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config nao encontrado: $ConfigPath" }
if (-not (Test-Path -LiteralPath $TargetsPath)) { throw "CSV nao encontrado: $TargetsPath" }
$script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$runtime = Join-Path $PSScriptRoot 'runtime'; New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$script:StatePath = Join-Path $runtime 'state.xml'
$script:TextLogPath = Join-Path $runtime ("monitor_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$historyPath = Join-Path $runtime ("history_{0}.csv" -f (Get-Date -Format 'yyyyMM'))
if ($ResetState -and (Test-Path $script:StatePath)) { Remove-Item $script:StatePath -Force }
$script:State = if (Test-Path $script:StatePath) { Import-Clixml -LiteralPath $script:StatePath } else { @{} }
if ($null -eq $script:State) { $script:State = @{} }

if ($TestNotifications) {
    $sample=[pscustomobject]@{Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');Hostname='teste.local';Team='Teste';DnsServer='PADRAO_DO_SISTEMA';ExpectedIPs='192.0.2.10';ResolvedIPs='192.0.2.99';DnsTimeMs=25;Port=443;TcpStatus='FALHA';Status='TESTE';Details='Mensagem de teste. Nenhuma falha real foi detectada.'}
    Send-Notification -Kind 'FALHA' -Result $sample -Recipients @($script:Config.Email.DefaultRecipients)
    exit 0
}

$targets = @(Import-Csv -LiteralPath $TargetsPath -Delimiter $script:Config.General.CsvDelimiter -Encoding UTF8)
if ($targets.Count -eq 0) { throw 'O CSV nao possui alvos.' }
foreach ($target in $targets) {
    if (-not (ConvertTo-Bool (Get-PropertyValue $target 'Enabled' 'true') $true)) { continue }
    $result = Test-DnsTarget $target
    $result | Export-Csv -LiteralPath $historyPath -Delimiter $script:Config.General.CsvDelimiter -NoTypeInformation -Append -Encoding UTF8
    Write-Log "$($result.Hostname): $($result.Status); obtido=$($result.ResolvedIPs); esperado=$($result.ExpectedIPs); DNS=$($result.DnsTimeMs)ms"

    $key = $result.Hostname.ToLowerInvariant()
    if (-not $script:State.ContainsKey($key)) { $script:State[$key] = @{ Status='DESCONHECIDO'; ConsecutiveFailures=0; LastAlert=$null } }
    $s = $script:State[$key]; $oldStatus=[string]$s.Status
    if ($result.Status -eq 'OK') {
        if ($oldStatus -ne 'OK' -and $oldStatus -ne 'DESCONHECIDO') {
            Send-Notification -Kind 'RECUPERACAO' -Result $result -Recipients (ConvertTo-StringArray (Get-PropertyValue $target 'ResponsibleEmails' ''))
        }
        $s.Status='OK'; $s.ConsecutiveFailures=0; $s.LastSuccess=(Get-Date).ToString('o')
    } else {
        $s.ConsecutiveFailures=[int]$s.ConsecutiveFailures + 1
        $shouldAlert = $s.ConsecutiveFailures -ge [int]$script:Config.General.FailuresBeforeAlert
        $repeatDue = $false
        if ($s.LastAlert) { $repeatDue = ((Get-Date) - [datetime]$s.LastAlert).TotalMinutes -ge [double]$script:Config.General.RepeatAlertMinutes }
        if ($shouldAlert -and ($oldStatus -eq 'OK' -or $oldStatus -eq 'DESCONHECIDO' -or $oldStatus -ne $result.Status -or $repeatDue)) {
            Send-Notification -Kind 'FALHA' -Result $result -Recipients (ConvertTo-StringArray (Get-PropertyValue $target 'ResponsibleEmails' ''))
            $s.LastAlert=(Get-Date).ToString('o')
        }
        $s.Status=$result.Status; $s.LastFailure=(Get-Date).ToString('o')
    }
    Save-State
}
