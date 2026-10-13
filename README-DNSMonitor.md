# Monitor DNS em PowerShell

## Teste local sem alertas
1. Coloque os arquivos na mesma pasta.
2. Edite `DNSMonitor.csv`. Para vários IPs ou e-mails no mesmo campo, separe os valores com `|`.
3. Execute: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor-DNS.ps1 -WhatIfAlerts`
4. Consulte `runtime\history_YYYYMM.csv`, `runtime\monitor_YYYYMMDD.log` e `runtime\state.xml`.

## Teams
Crie no Teams/Workflows um fluxo com o gatilho de webhook e uma ação para publicar no canal. O modo `WorkflowGeneric` envia: `title`, `severity`, `message`, `timestamp`, `source` e `facts`.
Grave a URL sem colocá-la no arquivo:
`[Environment]::SetEnvironmentVariable('DNSMONITOR_TEAMS_WEBHOOK','COLE_A_URL','User')`
Depois altere `Teams.Enabled` para `true`. Para tarefa executada por conta de serviço, crie a variável no escopo `Machine` ou sob a própria conta.

## E-mail
1. Ajuste SMTP, remetente e destinatários no `config.json`.
2. Execute `.\New-SmtpCredential.ps1` sob a mesma conta que executará a tarefa.
3. Altere `Email.Enabled` para `true`.
4. Teste: `.\Monitor-DNS.ps1 -TestNotifications`.

Observação: `Send-MailMessage` é usado pela ampla compatibilidade local. Confirme se o SMTP AUTH está permitido pela política da empresa. Em produção Microsoft 365, prefira OAuth/Microsoft Graph ou relay SMTP aprovado internamente.

## Simular falha e recuperação
- Coloque temporariamente um IP incorreto em `ExpectedIPs`.
- Execute duas vezes, pois `FailuresBeforeAlert=2`.
- Restaure o IP correto e execute novamente para testar a recuperação.
- Use `-WhatIfAlerts` para não enviar mensagens reais.

## Comparação
- `Exact`: o conjunto resolvido deve ser exatamente igual ao esperado.
- `Any`: pelo menos um IP resolvido deve existir no baseline.

## Agendamento
Abra PowerShell como administrador e execute:
`.\Instalar-TarefaAgendada.ps1 -IntervalMinutes 5`
Use uma conta de serviço com acesso mínimo necessário. A credencial CLIXML depende do mesmo usuário e computador.
