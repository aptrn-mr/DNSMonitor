[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TargetsPath,
    [switch]$TestNotifications,
    [switch]$WhatIfAlerts,
    [switch]$ResetState
)

Set-StrictMode -Version Latest

$logValues = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$logValues.Add('Info', 'INFO')
$logValues.Add('Warn', 'WARN')
$logValues.Add('Error', 'ERROR')
$script:Log = [Collections.ObjectModel.ReadOnlyDictionary[string,string]]::new($logValues)
Set-Variable -Name Log -Scope Script -Option ReadOnly

$severityValues = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$severityValues.Add('Ok', 'OK')
$severityValues.Add('Critical', 'CRITICO')
$script:Severity = [Collections.ObjectModel.ReadOnlyDictionary[string,string]]::new($severityValues)
Set-Variable -Name Severity -Scope Script -Option ReadOnly

$kindValues = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$kindValues.Add('Recovery', 'RECUPERACAO')
$kindValues.Add('Failure', 'FALHA')
$script:Kind = [Collections.ObjectModel.ReadOnlyDictionary[string,string]]::new($kindValues)
Set-Variable -Name Kind -Scope Script -Option ReadOnly

$statusValues = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$statusValues.Add('Ok', 'OK')
$statusValues.Add('Unknown', 'DESCONHECIDO')
$statusValues.Add('DnsFailure', 'DNS_FALHA')
$statusValues.Add('IpMismatch', 'IP_DIVERGENTE')
$statusValues.Add('TcpFailure', 'TCP_FALHA')
$statusValues.Add('TcpSlow', 'TCP_LENTO')
$statusValues.Add('HttpFailure', 'HTTP_FALHA')
$statusValues.Add('DnsSlow', 'DNS_LENTO')
$statusValues.Add('Untested', 'NAO_TESTADO')
$statusValues.Add('Failure', 'FALHA')
$statusValues.Add('Slow', 'LENTO')
$statusValues.Add('Test', 'TESTE')
$script:Status = [Collections.ObjectModel.ReadOnlyDictionary[string,string]]::new($statusValues)
Set-Variable -Name Status -Scope Script -Option ReadOnly

function Write-Log {
    param([string]$Message, [string]$Level)

    if ([string]::IsNullOrWhiteSpace($Level)) {
        $Level = $script:Log['Info']
    }
    if ($script:Log.Values -notcontains $Level) {
        throw "Nivel de log invalido: $Level"
    }

    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:TextLogPath -Value $line -Encoding UTF8
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name, $Default=$null)

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { 
        return $Object.$Name 
    }

    return $Default
}

function ConvertTo-Bool {
    param($Value, [bool]$Default=$false)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { 
        return $Default 
    }

    return ([string]$Value).Trim() -match '^(1|true|sim|yes)$'
}

function ConvertTo-StringArray {
    param($Value, [string]$Separator='|')

    if ($null -eq $Value) { return @() }

    return @(([string]$Value -split [regex]::Escape($Separator)) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-CollectionCount {
    param($Value)

    if ($null -eq $Value) { return 0 }

    return @($Value).Count
}

function Get-TargetLatencyWarningMilliseconds {
    param([object]$Target)

    $value = [string](Get-PropertyValue $Target 'LatencyWarningMilliseconds' '')

    if ([string]::IsNullOrWhiteSpace($value)) {
        return [double]$script:Config.General.LatencyWarningMilliseconds
    }

    $latencyLimit = 0.0
    $valid = [double]::TryParse(
        $value.Trim(),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$latencyLimit
    )

    if (-not $valid -or $latencyLimit -lt 0 -or [double]::IsNaN($latencyLimit) -or [double]::IsInfinity($latencyLimit)) {
        throw "LatencyWarningMilliseconds invalido para '$($Target.Hostname)': '$value'. Informe um numero nao negativo em milissegundos."
    }

    return $latencyLimit
}

function Save-State {
    $script:State | Export-Clixml -LiteralPath $script:StatePath
}

function Get-SmtpCredential {
    if (-not $script:Config.Email.Enabled) { return $null }

    $path = Join-Path $scriptRoot $script:Config.Email.CredentialFile
    
    if (-not (Test-Path -LiteralPath $path)) { 
        throw "Credencial SMTP ausente: $path. Execute .\New-SmtpCredential.ps1" 
    }

    return Import-Clixml -LiteralPath $path
}

function Send-TeamsAlert {
    param([string]$Title,[string]$Severity,[string]$Message,[hashtable]$Facts)

    if (-not $script:Config.Teams.Enabled) { return }

    if ($WhatIfAlerts) { 
        Write-Log "SIMULACAO Teams: $Title | $Message"
        return 
    }

    $uri = [Environment]::GetEnvironmentVariable($script:Config.Teams.WebhookEnvironmentVariable, 'Machine')

    if ([string]::IsNullOrWhiteSpace($uri)) {
        $uri = [Environment]::GetEnvironmentVariable($script:Config.Teams.WebhookEnvironmentVariable, 'User')
    }

    if ([string]::IsNullOrWhiteSpace($uri)) { 
        throw "Variavel de ambiente $($script:Config.Teams.WebhookEnvironmentVariable) nao definida." 
    }

    switch ($script:Config.Teams.PayloadMode) {
        'AdaptiveCard' {
            $cardFacts = @(
                [ordered]@{ title='Severidade'; value=$Severity }
                [ordered]@{ title='Origem'; value=$env:COMPUTERNAME }
                [ordered]@{ title='Executado em'; value=(Get-Date).ToString('o') }
            )
            $cardFacts += @(
                $Facts.GetEnumerator() |
                    Sort-Object Name |
                    ForEach-Object {
                        [ordered]@{
                            title=[string]$_.Name
                            value=if ($null -eq $_.Value -or [string]::IsNullOrWhiteSpace([string]$_.Value)) { '-' } else { [string]$_.Value }
                        }
                    }
            )
            $severityColor = if ($Severity -eq $script:Severity['Critical']) { 'Attention' } else { 'Good' }
            $payload = [ordered]@{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type = 'AdaptiveCard'
                version = '1.4'
                body = @(
                    [ordered]@{
                        type = 'TextBlock'
                        text = $Title
                        weight = 'Bolder'
                        size = 'Large'
                        color = $severityColor
                        wrap = $true
                    }
                    [ordered]@{
                        type = 'TextBlock'
                        text = $Message
                        wrap = $true
                    }
                    [ordered]@{
                        type = 'FactSet'
                        facts = $cardFacts
                    }
                )
            }
        }
        'WorkflowGeneric' {
            $payload = [ordered]@{
                title=$Title
                severity=$Severity
                message=$Message
                timestamp=(Get-Date).ToString('o')
                source=$env:COMPUTERNAME
                facts=$Facts
            }
        }
        'Text' {
            $factText = ($Facts.GetEnumerator() | Sort-Object Name | ForEach-Object { "**$($_.Name):** $($_.Value)" }) -join "`n`n"
            $payload = @{ text = "**$Title**`n`n$Message`n`n$factText" }
        }
        default {
            throw "PayloadMode do Teams invalido: '$($script:Config.Teams.PayloadMode)'. Use AdaptiveCard, WorkflowGeneric ou Text."
        }
    }

    $json = $payload | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $json -TimeoutSec $script:Config.General.NotificationTimeoutSeconds | Out-Null
}

function Send-EmailAlert {
    param([string]$Subject,[string]$HtmlBody,[string[]]$To)

    if (-not $script:Config.Email.Enabled) { return }

    $recipients = @($To + $script:Config.Email.DefaultRecipients | Where-Object { $_ } | Sort-Object -Unique)

    if ((Get-CollectionCount $recipients) -eq 0) { 
        Write-Log 'Alerta sem destinatario de e-mail.' $script:Log['Warn']; 
        return 
    }

    if ($WhatIfAlerts) { 
        Write-Log "SIMULACAO Email para $($recipients -join ', '): $Subject"; 
        return 
    }

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

    $isRecovery = $Kind -eq $script:Kind['Recovery']
    $severity = if ($isRecovery) { $script:Severity['Ok'] } else { $script:Severity['Critical'] }
    $title = if ($isRecovery) { "DNS RECUPERADO: $($Result.Hostname)" } else { "ALERTA DNS: $($Result.Hostname)" }
    $message = if ($isRecovery) { 'O alvo voltou ao estado normal.' } else { $Result.Details }

    $facts = [ordered]@{
        Hostname=$Result.Hostname;
        Equipe=$Result.Team;
        DNSServer=$Result.DnsServer
        IPsEsperados=$Result.ExpectedIPs;
        IPsObtidos=$Result.ResolvedIPs
        TempoDNSms=$Result.DnsTimeMs;
        Porta=$Result.Port;
        TCP=$Result.TcpStatus;
        TempoTCPms=$Result.TcpTimeMs
        LimiteLatenciaMs=$Result.LatencyWarningMilliseconds
        HTTP=$Result.HttpStatus;
        URL=$Result.HttpUrl;
        DetalhesHTTP=$Result.HttpDetails
        Estado=$Result.Status;
        ExecutadoEm=$Result.Timestamp
    }

    $html = @"
<html><body style='font-family:Segoe UI,Arial'><h2>$title</h2><p>$message</p>
<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse'>
$(( $facts.GetEnumerator() | ForEach-Object { "<tr><th align='left'>$($_.Name)</th><td>$([System.Net.WebUtility]::HtmlEncode([string]$_.Value))</td></tr>" } ) -join "`n")
</table><p>Origem: $env:COMPUTERNAME</p></body></html>
"@

    $errors = @()

    try { 
        Send-TeamsAlert -Title $title -Severity $severity -Message $message -Facts $facts 
    } catch { 
        $errors += "Teams: $($_.Exception.Message)" 
    }

    try { 
        Send-EmailAlert -Subject "[$severity] $title" -HtmlBody $html -To $Recipients 
    } catch { 
        $errors += "Email: $($_.Exception.Message)" 
    }

    if ((Get-CollectionCount $errors) -gt 0) { 
        Write-Log ($errors -join ' | ') $script:Log['Error'] 
    } else { 
        Write-Log "Notificacao enviada: $title" 
    }
}

function Send-TestNotification {
    $sample = [pscustomobject]@{
        Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Hostname='teste.local'
        Team='Teste'
        DnsServer='PADRAO_DO_SISTEMA'
        ExpectedIPs='192.0.2.10'
        ResolvedIPs='192.0.2.99'
        DnsTimeMs=25
        Port=443
        TcpStatus=$script:Status['Failure']
        TcpTimeMs=$null
        LatencyWarningMilliseconds=[double]$script:Config.General.LatencyWarningMilliseconds
        HttpStatus=$script:Status['Untested']
        HttpUrl=''
        HttpDetails='Teste HTTP nao executado.'
        Status=$script:Status['Test']
        Details='Mensagem de teste. Nenhuma falha real foi detectada.'
    }

    Send-Notification -Kind $script:Kind['Failure'] -Result $sample -Recipients @($script:Config.Email.DefaultRecipients)
}

function Test-DnsTarget {
    param([string]$Hostname,[string]$DnsServer)

    $sw = [Diagnostics.Stopwatch]::new()
    $records = @()
    $dnsError = ''

    try {
        $parameters = @{ 
            Name=$Hostname; 
            Type='A'; 
            DnsOnly=$true; 
            ErrorAction='Stop' 
        }

        if ($DnsServer) { 
            $parameters.Server = $DnsServer 
        }

        $sw.Start()
        $records = @(Resolve-DnsName @parameters | Where-Object { $_.Type -eq 'A' -and $_.IPAddress })
        $sw.Stop()

        if ((Get-CollectionCount $records) -eq 0) { 
            $dnsError = 'A consulta nao retornou registro A.' 
        }

    } catch {
        $dnsError = $_.Exception.Message
    } finally {
        if ( $sw.IsRunning) { $sw.Stop() }
    }    

    $resolved = @()
    $ttl = ''

    if ((Get-CollectionCount $records) -gt 0) {
        $resolved = @($records | ForEach-Object { $_.IPAddress } | Sort-Object -Unique)
        $ttl = @($records | ForEach-Object { $_.TTL } | Sort-Object -Unique) -join ';'
    }

    [pscustomobject]@{
        ResolvedAddresses=$resolved
        Ttl=$ttl
        DnsTimeMs=[math]::Round($sw.Elapsed.TotalMilliseconds,2)
        DnsError=$dnsError
    }
}

function Test-TcpPort {
    param([string]$Hostname,[int]$Port,[bool]$DnsResolved,[double]$LatencyWarningMilliseconds)

    $status = $script:Status['Untested']
    $success = $true
    $elapsedMilliseconds = $null
    $details = 'Teste TCP nao executado.'

    if ($Port -gt 0 -and $DnsResolved) {
        $client = $null
        $stopwatch = [Diagnostics.Stopwatch]::new()

        try {
            $client = [Net.Sockets.TcpClient]::new()

            $stopwatch.Start()
            $task = $client.ConnectAsync($Hostname,$Port)
            $success = $task.Wait([int]$script:Config.General.TcpTimeoutMilliseconds) -and $client.Connected
            $stopwatch.Stop()

            $status = if ($success) { $script:Status['Ok'] } else { $script:Status['Failure'] }
            $details = if ($success) { 'Conexao TCP estabelecida.' } else { 'Tempo limite excedido ou conexao recusada.' }
        } catch {
            $success = $false
            $status = $script:Status['Failure']
            $details = $_.Exception.Message
        } finally {
            if ($stopwatch.IsRunning) { $stopwatch.Stop() }

            $elapsedMilliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds,2)

            if ($null -ne $client) { $client.Dispose() }
        }
        if ($success -and $elapsedMilliseconds -gt $LatencyWarningMilliseconds) {
            $success = $false
            $status = $script:Status['Slow']
            $details = "Latencia TCP de $elapsedMilliseconds ms excede o limite de $LatencyWarningMilliseconds ms."
        }
    }

    [pscustomobject]@{ 
        Status=$status; 
        Success=$success; 
        TimeMs=$elapsedMilliseconds; 
        Details=$details 
    }
}

function Test-HttpService {
    param([string]$Hostname,[int]$Port,[bool]$Enabled,[bool]$DnsResolved)

    $status = $script:Status['Untested']
    $details = if ($Enabled) { 'Requisicao HTTP nao executada porque nao houve resposta DNS.' } else { 'Teste HTTP desabilitado.' }
    $url = ''
    $success = $true

    if ($Enabled -and $DnsResolved) {
        $portPart = if ($Port -gt 0) { ":$Port" } else { '' }
        $timeoutSeconds = [int][math]::Max(1, [math]::Ceiling([double]$script:Config.General.TcpTimeoutMilliseconds / 1000))
        $attemptDetails = @()
        $success = $false

        foreach ($scheme in @('https','http')) {
            $attemptUrl = "{0}://{1}{2}/" -f $scheme, $Hostname, $portPart

            try {
                $response = Invoke-WebRequest -Uri $attemptUrl -Method Get -TimeoutSec $timeoutSeconds -UseBasicParsing -ErrorAction Stop
                $statusCode = [int]$response.StatusCode
                $attemptDetails += "${scheme}: HTTP $statusCode"

                if ($statusCode -ge 200 -and $statusCode -lt 300) {
                    $url = $attemptUrl
                    $status = [string]$statusCode
                    $details = "Resposta bem-sucedida em ${scheme}: HTTP $statusCode."
                    $success = $true
                    break
                }

            } catch {
                $response = Get-PropertyValue $_.Exception 'Response'
                $responseStatusCode = Get-PropertyValue $response 'StatusCode'

                if ($null -ne $responseStatusCode) {
                    $statusCode = [int]$responseStatusCode
                    $attemptDetails += "${scheme}: HTTP $statusCode"
                    $status = [string]$statusCode
                } else {
                    $attemptDetails += "${scheme}: $($_.Exception.Message)"
                    $status = $script:Status['Failure']
                }
            }

            $url = $attemptUrl
        }

        if (-not $success) {
            $details = "Falharam as tentativas HTTPS e HTTP na porta $Port. " + ($attemptDetails -join '; ')
        }
    }

    [pscustomobject]@{ 
        Status=$status; 
        Details=$details; 
        Url=$url; 
        Success=$success 
    }
}

function New-TargetResult {
    param([object]$Target,[object]$DnsResult,[int]$Port,[bool]$IpOk,[object]$TcpResult,[bool]$HttpEnabled,[object]$HttpResult,[double]$LatencyWarningMilliseconds)

    $hostName = ([string]$Target.Hostname).Trim()
    $expected = ConvertTo-StringArray $Target.ExpectedIPs
    $dnsServer = ([string](Get-PropertyValue $Target 'DnsServer' '')).Trim()
    $status=$script:Status['Ok']; 
    $details='Resolucao e validacoes realizadas com sucesso.'

    if ((Get-CollectionCount $DnsResult.ResolvedAddresses) -eq 0) { 
        $status=$script:Status['DnsFailure']; 
        $details="Falha de resolucao: $($DnsResult.DnsError)" 
    }
    elseif (-not $IpOk) { 
        $status=$script:Status['IpMismatch']; 
        $details='O conjunto de IPs obtido diverge do baseline.' 
    }
    elseif ($TcpResult.Status -eq $script:Status['Slow']) { 
        $status=$script:Status['TcpSlow']; 
        $details=$TcpResult.Details 
    }
    elseif (-not $TcpResult.Success) { 
        $status=$script:Status['TcpFailure']; 
        $details="O DNS esta correto, mas a conexao TCP na porta $Port falhou. $($TcpResult.Details)" 
    }
    elseif (-not $HttpResult.Success) { 
        $status=$script:Status['HttpFailure']; 
        $details="O servico HTTP nao respondeu corretamente: $($HttpResult.Details)" 
    }
    elseif ($DnsResult.DnsTimeMs -gt $LatencyWarningMilliseconds) { 
        $status=$script:Status['DnsSlow']; 
        $details="Resolucao acima do limite de $LatencyWarningMilliseconds ms." 
    }

    [pscustomobject][ordered]@{
        Timestamp=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Hostname=$hostName
        Team=(Get-PropertyValue $Target 'Team' ''); DnsServer=if($dnsServer){$dnsServer}else{'PADRAO_DO_SISTEMA'}
        ExpectedIPs=($expected -join ';'); ResolvedIPs=if((Get-CollectionCount $DnsResult.ResolvedAddresses)){ $DnsResult.ResolvedAddresses -join ';'}else{'SEM_RESPOSTA'}
        TTL=$DnsResult.Ttl; DnsTimeMs=$DnsResult.DnsTimeMs; Port=$Port; TcpStatus=$TcpResult.Status; TcpTimeMs=$TcpResult.TimeMs
        LatencyWarningMilliseconds=$LatencyWarningMilliseconds
        HttpEnabled=$HttpEnabled; HttpUrl=$HttpResult.Url; HttpStatus=$HttpResult.Status; HttpDetails=$HttpResult.Details
        Status=$status; Details=$details
    }
}

$ErrorActionPreference = 'Stop'
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($ConfigPath)) { 
    $ConfigPath = Join-Path $scriptRoot 'config.json'
}
if ([string]::IsNullOrWhiteSpace($TargetsPath)) { 
    $TargetsPath = Join-Path $scriptRoot 'DNSMonitor.csv'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config nao encontrado: $ConfigPath" }
if (-not (Test-Path -LiteralPath $TargetsPath)) { throw "CSV nao encontrado: $TargetsPath" }

$script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$runtime = Join-Path $scriptRoot 'runtime';
New-Item -ItemType Directory -Path $runtime -Force | Out-Null

$script:StatePath = Join-Path $runtime 'state.xml'
$script:TextLogPath = Join-Path $runtime ("monitor_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$historyPath = Join-Path $runtime ("history_{0}.csv" -f (Get-Date -Format 'yyyyMM'))

if ($ResetState -and (Test-Path $script:StatePath)) { 
    Remove-Item $script:StatePath -Force 
}

$script:State = if (Test-Path $script:StatePath) { Import-Clixml -LiteralPath $script:StatePath } else { @{} }

if ($null -eq $script:State) { $script:State = @{} }

if ($TestNotifications) {
    Send-TestNotification
    exit 0
}

$targets = @(Import-Csv -LiteralPath $TargetsPath -Delimiter $script:Config.General.CsvDelimiter -Encoding UTF8)

if ((Get-CollectionCount $targets) -eq 0) { throw 'O CSV nao possui alvos.' }

foreach ($target in $targets) {
    if (-not (ConvertTo-Bool (Get-PropertyValue $target 'Enabled' 'true') $true)) { continue }

    $hostName = ([string]$target.Hostname).Trim()
    $dnsServer = ([string](Get-PropertyValue $target 'DnsServer' '')).Trim()
    $expected = ConvertTo-StringArray $target.ExpectedIPs
    $retryCount = [int]$script:Config.General.RetryCount
    $dnsResult = $null

    for ($attempt=1; $attempt -le ($retryCount + 1); $attempt++) {
        $dnsResult = Test-DnsTarget -Hostname $hostName -DnsServer $dnsServer
        if ((Get-CollectionCount $dnsResult.ResolvedAddresses) -gt 0) { break }
        if ($attempt -le $retryCount) { 
            Start-Sleep -Seconds ([int]$script:Config.General.RetryDelaySeconds) 
        }
    }

    $comparison = ([string](Get-PropertyValue $target 'ComparisonMode' 'Exact')).Trim()
    $ipOk = $false

    if ((Get-CollectionCount $dnsResult.ResolvedAddresses) -gt 0 -and (Get-CollectionCount $expected) -gt 0) {
        if ($comparison -eq 'Any') { 
            $ipOk = (Get-CollectionCount ($dnsResult.ResolvedAddresses | Where-Object { $expected -contains $_ })) -gt 0 }
        else { 
            $ipOk = (Get-CollectionCount ($dnsResult.ResolvedAddresses | Where-Object { $expected -notcontains $_ })) -eq 0 -and (Get-CollectionCount ($expected | Where-Object { $dnsResult.ResolvedAddresses -notcontains $_ })) -eq 0 
        }
    }

    $portText = ([string](Get-PropertyValue $target 'Port' '')).Trim()
    $port = if ($portText) { [int]$portText } else { 0 }
    $latencyWarningMilliseconds = Get-TargetLatencyWarningMilliseconds $target
    $httpEnabled = ConvertTo-Bool (Get-PropertyValue $target 'http' 'false')
    $dnsResolved = (Get-CollectionCount $dnsResult.ResolvedAddresses) -gt 0
    $tcpResult = Test-TcpPort -Hostname $hostName -Port $port -DnsResolved $dnsResolved -LatencyWarningMilliseconds $latencyWarningMilliseconds
    $httpResult = Test-HttpService -Hostname $hostName -Port $port -Enabled $httpEnabled -DnsResolved $dnsResolved
    $result = New-TargetResult -Target $target -DnsResult $dnsResult -Port $port -IpOk $ipOk -TcpResult $tcpResult -HttpEnabled $httpEnabled -HttpResult $httpResult -LatencyWarningMilliseconds $latencyWarningMilliseconds
    $result | Export-Csv -LiteralPath $historyPath -Delimiter $script:Config.General.CsvDelimiter -NoTypeInformation -Append -Encoding UTF8

    Write-Log "$($result.Hostname): $($result.Status); obtido=$($result.ResolvedIPs); esperado=$($result.ExpectedIPs); DNS=$($result.DnsTimeMs)ms; TCP=$($result.TcpStatus) $($result.TcpTimeMs)ms; limiteLatencia=$($result.LatencyWarningMilliseconds)ms; HTTP=$($result.HttpStatus) $($result.HttpDetails)"

    $key = $result.Hostname.ToLowerInvariant()

    if (-not $script:State.ContainsKey($key)) { 
        $script:State[$key] = @{ 
            Status=$script:Status['Unknown']; 
            ConsecutiveFailures=0; 
            LastAlert=$null 
        } 
    }

    $s = $script:State[$key]; $oldStatus=[string]$s.Status

    if ($result.Status -eq $script:Status['Ok']) {
        if ($oldStatus -ne $script:Status['Ok'] -and $oldStatus -ne $script:Status['Unknown']) {
            Send-Notification -Kind $script:Kind['Recovery'] -Result $result -Recipients (ConvertTo-StringArray (Get-PropertyValue $target 'ResponsibleEmails' ''))
        }

        $s.Status=$script:Status['Ok']; 
        $s.ConsecutiveFailures=0; 
        $s.LastSuccess=(Get-Date).ToString('o')

    } else {
        $s.ConsecutiveFailures=[int]$s.ConsecutiveFailures + 1
        $shouldAlert = $s.ConsecutiveFailures -ge [int]$script:Config.General.FailuresBeforeAlert
        $repeatDue = $false

        if ($s.LastAlert) { 
            $repeatDue = ((Get-Date) - [datetime]$s.LastAlert).TotalMinutes -ge [double]$script:Config.General.RepeatAlertMinutes 
        }

        if ($shouldAlert -and ($oldStatus -eq $script:Status['Ok'] -or $oldStatus -eq $script:Status['Unknown'] -or $oldStatus -ne $result.Status -or $repeatDue)) {
            Send-Notification -Kind $script:Kind['Failure'] -Result $result -Recipients (ConvertTo-StringArray (Get-PropertyValue $target 'ResponsibleEmails' ''))

            $s.LastAlert=(Get-Date).ToString('o')
        }

        $s.Status=$result.Status; $s.LastFailure=(Get-Date).ToString('o')
    }
    
    Save-State
}
