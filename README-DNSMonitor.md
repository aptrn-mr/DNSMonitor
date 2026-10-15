# Monitor DNS em PowerShell

## Configuração (`config.json`)

O arquivo `config.json` deve ficar na mesma pasta que `Monitor-DNS.ps1`. Por padrão, o script carrega esse arquivo automaticamente. Para usar outro caminho, passe `-ConfigPath`, por exemplo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor-DNS.ps1 -ConfigPath "C:\Monitor\config-producao.json"
```

O arquivo deve ser JSON válido: mantenha aspas duplas em nomes e textos, vírgulas entre propriedades e não deixe vírgula após a última propriedade de um objeto. Propriedades booleanas aceitam `true` ou `false`; números não devem ser colocados entre aspas.

### `General`

Opções gerais do monitor:

| Propriedade | O que é e para que serve | Como configurar |
|---|---|---|
| `CsvDelimiter` | Delimitador de coluna do arquivo de alvos `DNSMonitor.csv`. | Use `";"` para CSV separado por ponto e vírgula ou `","` para vírgula. Deve corresponder ao formato do CSV. |
| `RetryCount` | Número de novas tentativas de consulta DNS após a primeira falha. | Inteiro igual ou maior que `0`. Por exemplo, `2` significa até três consultas no total. |
| `RetryDelaySeconds` | Intervalo entre as tentativas DNS. | Inteiro em segundos; por exemplo, `2`. Só é usado quando ainda há uma tentativa a fazer. |
| `FailuresBeforeAlert` | Quantas execuções com falha consecutivas são necessárias antes de enviar o alerta. | Inteiro igual ou maior que `1`. Por exemplo, `1` alerta na primeira execução com falha; `2` aguarda duas execuções consecutivas. |
| `RepeatAlertMinutes` | Intervalo mínimo antes de repetir um alerta enquanto o mesmo problema persiste. | Número de minutos, por exemplo `60`. |
| `LatencyWarningMilliseconds` | Limite padrão de latência usado para classificar DNS lento (`DNS_LENTO`) e conexão TCP lenta (`TCP_LENTO`) quando o alvo não define seu próprio limite no CSV. | Número não negativo em milissegundos, por exemplo `1000`. Pode ser substituído por alvo usando a coluna `LatencyWarningMilliseconds` do `DNSMonitor.csv`. |
| `TcpTimeoutMilliseconds` | Tempo máximo para estabelecer uma conexão TCP e limite de tempo usado na requisição HTTP(S). | Inteiro positivo em milissegundos, por exemplo `3000`. |
| `NotificationTimeoutSeconds` | Tempo máximo de espera ao enviar a notificação ao Teams. | Inteiro positivo em segundos, por exemplo `15`. |

### `Teams`

Configura as notificações para Teams/Workflows:

| Propriedade | O que é e para que serve | Como configurar |
|---|---|---|
| `Enabled` | Liga ou desliga o envio para Teams. | Use `true` para habilitar ou `false` para desabilitar. |
| `PayloadMode` | Formato JSON enviado ao webhook. | Use `AdaptiveCard` para enviar um cartão Adaptive Card pronto para a ação “Post card in a chat or channel”; `WorkflowGeneric` para enviar os campos `title`, `severity`, `message`, `timestamp`, `source` e `facts`; ou `Text` para enviar uma mensagem de texto simples. |
| `WebhookEnvironmentVariable` | Nome da variável de ambiente que contém a URL secreta do webhook. | Informe o nome da variável, não a URL. O padrão é `DNSMONITOR_TEAMS_WEBHOOK`. Defina a URL no escopo `User` ou `Machine`; não a grave no JSON nem no repositório. |

### `Email`

Configura as notificações por e-mail:

| Propriedade | O que é e para que serve | Como configurar |
|---|---|---|
| `Enabled` | Liga ou desliga o envio de e-mail. | Use `true` para habilitar ou `false` para desabilitar. |
| `SmtpServer` | Nome ou endereço do servidor SMTP de saída. | Use o hostname ou endereço fornecido pelo administrador de e-mail. |
| `Port` | Porta de conexão SMTP. | Número inteiro, por exemplo `587`. Use a porta exigida pelo servidor SMTP; confirme que ela é compatível com `UseSsl`. |
| `UseSsl` | Solicita conexão SMTP protegida por TLS/SSL ao `Send-MailMessage`. | Use `true` se exigido pelo servidor, caso contrário `false`; confirme a compatibilidade com a porta e política do SMTP. |
| `From` | Endereço remetente usado nas mensagens. | Informe um endereço autorizado pelo servidor SMTP. |
| `DefaultRecipients` | Lista de destinatários incluídos em todos os alertas, além dos endereços configurados por alvo no CSV. | Use uma lista JSON de endereços, por exemplo `["operacao@exemplo.com","plantao@exemplo.com"]`. |
| `CredentialFile` | Arquivo CLIXML com a credencial SMTP. | Informe o nome ou caminho relativo à pasta do script. Gere o arquivo com `.\New-SmtpCredential.ps1` usando a mesma conta do Windows que executará o monitor; a credencial CLIXML é protegida para essa conta e computador. Não compartilhe nem versiona esse arquivo. |

## Teste local sem alertas
1. Coloque os arquivos na mesma pasta.
2. Edite `DNSMonitor.csv`. Para vários IPs ou e-mails no mesmo campo, separe os valores com `|`.
3. Execute: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Monitor-DNS.ps1 -WhatIfAlerts`
4. Consulte `runtime\history_YYYYMM.csv`, `runtime\monitor_YYYYMMDD.log` e `runtime\state.xml`.

## Teams
Crie no Teams/Workflows um fluxo com o gatilho de webhook e uma ação **Post card in a chat or channel** como o modelo `Enviar alertas de webhook para um canal`. Configure `Teams.PayloadMode` como `AdaptiveCard` para o script enviar diretamente um objeto Adaptive Card com `type: "AdaptiveCard"`, versão `1.4`, título, mensagem, severidade, origem, horário e os fatos do monitor. Na ação do Teams, use o corpo recebido pelo gatilho como conteúdo do cartão; não envolva novamente o objeto em uma propriedade `text` ou em outra estrutura.

Os modos `WorkflowGeneric` (campos `title`, `severity`, `message`, `timestamp`, `source` e `facts`) e `Text` (mensagem simples) continuam disponíveis para fluxos configurados para esses formatos.
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
- Execute o número de vezes definido em `General.FailuresBeforeAlert` (atualmente `1`).
- Restaure o IP correto e execute novamente para testar a recuperação.
- Use `-WhatIfAlerts` para não enviar mensagens reais.

## Comparação
- `Exact`: o conjunto resolvido deve ser exatamente igual ao esperado.
- `Any`: pelo menos um IP resolvido deve existir no baseline.

## Verificação HTTP opcional
Adicione a coluna `http` ao cabeçalho do `DNSMonitor.csv` e informe `true` ou `false` em cada alvo. Com `true`, o monitor faz uma requisição GET para a raiz (`/`) na porta configurada: tenta HTTPS primeiro e, se não obtiver resposta 2xx, tenta HTTP na mesma porta. Respostas entre 200 e 299 são consideradas sucesso. O resultado, URL e detalhes das tentativas são registrados no histórico e no log, e a falha de ambos os protocolos participa do alerta.

## Latência TCP
Adicione a coluna `LatencyWarningMilliseconds` ao cabeçalho do `DNSMonitor.csv` para definir o limite de latência de cada alvo, em milissegundos. Por exemplo:

```csv
Enabled;Hostname;ExpectedIPs;DnsServer;ComparisonMode;Port;ResponsibleEmails;Team;http;LatencyWarningMilliseconds
true;api.exemplo.com;192.0.2.10;;Exact;443;operacao@exemplo.com;Infraestrutura;true;250
true;mail.exemplo.com;192.0.2.20;;Exact;587;operacao@exemplo.com;Infraestrutura;false;1500
```

Um valor informado na linha é usado para classificar tanto o tempo de resolução DNS (`DNS_LENTO`) quanto o estabelecimento TCP (`TCP_LENTO`). Se a coluna não existir ou o campo estiver vazio, o monitor usa `General.LatencyWarningMilliseconds` do `config.json`. O limite deve ser um número não negativo em milissegundos; valores inválidos interrompem o processamento com erro. O valor efetivamente aplicado fica registrado no histórico e no log.

O tempo TCP registrado é o intervalo medido pela aplicação desde o início de `ConnectAsync` até a conclusão ou timeout da conexão. A medição usa um cronômetro de alta resolução e não inclui a criação do cliente TCP nem a execução anterior do script; ainda pode incluir uma pequena latência de agendamento do sistema operacional, portanto não representa uma medição de pacotes em nível de rede.

## Agendamento
Abra PowerShell como administrador e execute:
`.\Instalar-TarefaAgendada.ps1 -IntervalMinutes 5`
Use uma conta de serviço com acesso mínimo necessário. A credencial CLIXML depende do mesmo usuário e computador.
