[CmdletBinding()]
param([string]$OutputPath = "$PSScriptRoot\smtp-credential.xml")
$credential = Get-Credential -Message 'Informe a conta SMTP usada pelo monitor DNS'
$credential | Export-Clixml -LiteralPath $OutputPath
Write-Host "Credencial protegida criada em: $OutputPath"
Write-Host 'Ela so pode ser descriptografada pelo mesmo usuario no mesmo computador.'
