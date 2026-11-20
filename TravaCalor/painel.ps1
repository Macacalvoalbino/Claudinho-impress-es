# TravaCalor - painel de controle
# Instala, ajusta e remove a trava de calor por uma janela, sem editar arquivos.
# Abra pelo "ABRIR TRAVACALOR.bat".

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$titulo = 'TravaCalor'
function Aviso([string]$t) { [void][System.Windows.Forms.MessageBox]::Show($t, $titulo, 'OK', 'Information') }
function Erro([string]$t)  { [void][System.Windows.Forms.MessageBox]::Show($t, $titulo, 'OK', 'Error') }
function Confirmar([string]$t) {
    return ([System.Windows.Forms.MessageBox]::Show($t, $titulo, 'YesNo', 'Question') -eq 'Yes')
}

# ---------------------------------------------------------------- administrador
$souAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $souAdmin) {
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    } catch {
        Erro 'O TravaCalor precisa de permissão de administrador para mexer nas impressoras. Abra de novo e clique em "Sim".'
    }
    exit
}

# ---------------------------------------------------------------- constantes
$destino      = 'C:\ProgramData\TravaCalor'
$cfgPath      = Join-Path $destino 'config.json'
$logFile      = Join-Path $destino 'trava-calor.log'
$tarefa       = 'TravaCalor'
$prefixoPorta = 'TRAVA_CALOR_'
$atalho       = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'TravaCalor.lnk'
$arquivos     = 'trava-calor.ps1', 'painel.ps1', 'ABRIR TRAVACALOR.bat', 'LEIA-ME.txt'
$padroes      = @{ zplMaxSD = 15; zplMaxMD = 0; pplaMaxH = 12; pplbMaxD = 8 }

$script:cfg        = $null     # configuração instalada (ou $null se não instalada)
$script:lista      = @()       # impressoras mostradas na caixa de seleção
$script:carregando = $false
$script:ultimoLog  = ''

# ---------------------------------------------------------------- funções de sistema
function Ler-Config {
    if (-not (Test-Path $cfgPath)) { return $null }
    try {
        $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($c.impressoraReal -and $c.impressoraTrava) { return $c }
    } catch { }
    return $null
}

function Gravar-Config($c) {
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $c | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
}

function Existe-Impressora([string]$nome) {
    return [bool](Get-Printer | Where-Object { $_.Name -eq $nome })
}

# Lista as impressoras do Windows, dizendo quais estão conectadas agora.
function Listar-Impressoras {
    $cim = @{}
    try { Get-CimInstance Win32_Printer | ForEach-Object { $cim[$_.Name] = $_ } } catch { }
    $todas = foreach ($p in Get-Printer) {
        if ($p.PortName -like "$prefixoPorta*") { continue }      # a própria impressora com trava
        $c = $cim[$p.Name]
        $desligada = ($c -and $c.WorkOffline) -or ("$($p.PrinterStatus)" -eq 'Offline')
        $virtual = ($p.PortName -match '^(PORTPROMPT:|FILE:|nul:|SHRFAX:|XPSPort:|Microsoft\.Office)') -or
                   ($p.DriverName -match 'Print To PDF|XPS Document|Shared Fax|OneNote|Send to Microsoft')
        [pscustomobject]@{
            Nome      = $p.Name
            Driver    = $p.DriverName
            Porta     = $p.PortName
            Conectada = -not $desligada
            Padrao    = [bool]($c -and $c.Default)
            Virtual   = $virtual
        }
    }
    $todas = @($todas)
    $fisicas = @($todas | Where-Object { -not $_.Virtual })
    if ($fisicas.Count -gt 0) { $todas = $fisicas }
    return @($todas | Sort-Object @{ Expression = { -not $_.Conectada } },
                                  @{ Expression = { -not (($_.Nome + ' ' + $_.Driver) -match 'L42|ELGIN') } },
                                  Nome)
}

function Tornar-Padrao([string]$nome) {
    try {
        $p = Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $nome }
        if ($p) { Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter | Out-Null }
    } catch { }
}

function Eh-Padrao([string]$nome) {
    try { return [bool](Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $nome -and $_.Default }) }
    catch { return $false }
}

function Parar-Filtro {
    Stop-ScheduledTask -TaskName $tarefa -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*trava-calor.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Tarefa que sobe o filtro junto com o Windows (conta SYSTEM, sem janela)
function Registrar-Tarefa {
    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destino\trava-calor.ps1`" -Config `"$cfgPath`""
    $gatilho = New-ScheduledTaskTrigger -AtStartup
    $princ = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $conf = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Unregister-ScheduledTask -TaskName $tarefa -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $tarefa -Action $acao -Trigger $gatilho -Principal $princ -Settings $conf | Out-Null
    Start-ScheduledTask -TaskName $tarefa
}

function Reiniciar-Filtro {
    Parar-Filtro
    if (Get-ScheduledTask -TaskName $tarefa -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName $tarefa }
    else { Registrar-Tarefa }
}

# Verifica se o filtro esta escutando a porta local. Usa so .NET (rapido, sem WMI/CIM),
# para poder ser chamado pelo relogio da tela sem congelar a janela.
function Filtro-Rodando {
    $c = $script:cfg
    if (-not $c) { return $false }
    try {
        $porta = [int]$c.porta
        foreach ($e in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($e.Port -eq $porta) { return $true }
        }
    } catch { }
    return $false
}

# Le a ultima linha do historico sem bloquear o filtro, que escreve nele ao mesmo tempo
function Ultima-Linha-Log {
    if (-not (Test-Path $logFile)) { return '' }
    $fs = New-Object IO.FileStream($logFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $tam = [Math]::Min($fs.Length, 4096)
        [void]$fs.Seek(-$tam, [IO.SeekOrigin]::End)
        $buf = New-Object byte[] $tam
        [void]$fs.Read($buf, 0, $tam)
        $linhas = [Text.Encoding]::UTF8.GetString($buf) -split "`r?`n" | Where-Object { $_.Trim() }
        if ($linhas) { return [string]@($linhas)[-1] }
        return ''
    } finally { $fs.Dispose() }
}

# Copia os arquivos para C:\ProgramData\TravaCalor. Devolve $true se o filtro mudou.
function Copiar-Arquivos {
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    if ($PSScriptRoot -eq $destino) { return $false }            # já rodando da pasta instalada
    $filtroNovo = Join-Path $PSScriptRoot 'trava-calor.ps1'
    if (-not (Test-Path $filtroNovo)) {
        throw "Não achei o arquivo trava-calor.ps1 ao lado do painel. Extraia a pasta TravaCalor inteira antes de abrir."
    }
    $filtroAtual = Join-Path $destino 'trava-calor.ps1'
    $mudou = (-not (Test-Path $filtroAtual)) -or
             ((Get-FileHash $filtroNovo).Hash -ne (Get-FileHash $filtroAtual).Hash)
    foreach ($a in $arquivos) {
        $origem = Join-Path $PSScriptRoot $a
        if (Test-Path $origem) { Copy-Item $origem $destino -Force }
    }
    return $mudou
}

function Criar-Atalho {
    try {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($atalho)
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destino\painel.ps1`""
        $lnk.WorkingDirectory = $destino
        $lnk.IconLocation = 'shell32.dll,16'
        $lnk.Description = 'Ajustar a trava de calor da impressora de etiquetas'
        $lnk.Save()
    } catch { }
}

function Porta-Livre {
    foreach ($n in 9101..9120) {
        try {
            $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $n)
            $l.Start(); $l.Stop()
            return $n
        } catch { }
    }
    throw 'Não encontrei uma porta local livre entre 9101 e 9120.'
}

# ---------------------------------------------------------------- instalar / alterar / remover
function Instalar($sel, [string]$nomeTrava, [string]$nomeDireta, $lim) {
    $real = Get-Printer | Where-Object { $_.Name -eq $sel.Nome }
    if (-not $real) { throw "A impressora '$($sel.Nome)' não existe mais no Windows. Clique em 'Atualizar lista'." }
    $nomeOriginal = $real.Name
    $eraPadrao = Eh-Padrao $nomeOriginal

    Parar-Filtro
    [void](Copiar-Arquivos)
    $porta = Porta-Livre
    $nomePorta = "$prefixoPorta$porta"

    $renomeou = $false
    try {
        if ($nomeDireta -ne $nomeOriginal) {
            Rename-Printer -Name $nomeOriginal -NewName $nomeDireta
            $renomeou = $true
        }
        if (-not (Get-PrinterPort -Name $nomePorta -ErrorAction SilentlyContinue)) {
            Add-PrinterPort -Name $nomePorta -PrinterHostAddress '127.0.0.1' -PortNumber $porta
        }
        Add-Printer -Name $nomeTrava -DriverName $real.DriverName -PortName $nomePorta
    } catch {
        # desfaz o que deu para fazer
        Remove-Printer -Name $nomeTrava -ErrorAction SilentlyContinue
        if ($renomeou) { Rename-Printer -Name $nomeDireta -NewName $nomeOriginal -ErrorAction SilentlyContinue }
        throw
    }

    # Copia tamanho de etiqueta e demais preferências da impressora real
    $avisoPrefs = ''
    try {
        $ticket = (Get-PrintConfiguration -PrinterName $nomeDireta).PrintTicketXML
        Set-PrintConfiguration -PrinterName $nomeTrava -PrintTicketXml $ticket
    } catch {
        $avisoPrefs = "`n`nAtenção: não consegui copiar as preferências. Confira o tamanho da etiqueta em '$nomeTrava'."
    }

    Gravar-Config ([ordered]@{
        impressoraReal  = $nomeDireta
        impressoraTrava = $nomeTrava
        nomeOriginal    = $nomeOriginal
        assumiuNome     = ($nomeTrava -eq $nomeOriginal)
        porta           = $porta
        zplMaxSD        = $lim.zplMaxSD
        zplMaxMD        = $lim.zplMaxMD
        pplaMaxH        = $lim.pplaMaxH
        pplbMaxD        = $lim.pplbMaxD
        salvarJobs      = $lim.salvarJobs
    })
    Registrar-Tarefa
    if ($eraPadrao) { Tornar-Padrao $nomeTrava }
    Criar-Atalho
    return $avisoPrefs
}

function Alterar([string]$nomeTrava, [string]$nomeDireta, $lim) {
    $c = $script:cfg
    $velhaTrava = [string]$c.impressoraTrava
    $velhaReal  = [string]$c.impressoraReal
    foreach ($n in $velhaTrava, $velhaReal) {
        if (-not (Existe-Impressora $n)) {
            throw "Não encontrei a impressora '$n' no Windows (ela foi apagada ou renomeada por fora). Clique em 'Desinstalar' e instale de novo."
        }
    }

    # Renomeia (com nome temporário se os dois nomes estiverem sendo trocados entre si)
    $atualTrava = $velhaTrava
    if ($nomeDireta -ne $velhaReal -and $nomeDireta -eq $velhaTrava) {
        $atualTrava = 'TravaCalor-temp-' + (Get-Random -Maximum 99999)
        Rename-Printer -Name $velhaTrava -NewName $atualTrava
    }
    if ($nomeDireta -ne $velhaReal) { Rename-Printer -Name $velhaReal -NewName $nomeDireta }
    if ($nomeTrava -ne $atualTrava) { Rename-Printer -Name $atualTrava -NewName $nomeTrava }

    $assumiu = [bool]$c.assumiuNome
    if ($nomeTrava -ne $velhaTrava) { $assumiu = $true }   # o programa passa a usar o nome novo
    Gravar-Config ([ordered]@{
        impressoraReal  = $nomeDireta
        impressoraTrava = $nomeTrava
        nomeOriginal    = [string]$c.nomeOriginal
        assumiuNome     = $assumiu
        porta           = [int]$c.porta
        zplMaxSD        = $lim.zplMaxSD
        zplMaxMD        = $lim.zplMaxMD
        pplaMaxH        = $lim.pplaMaxH
        pplbMaxD        = $lim.pplbMaxD
        salvarJobs      = $lim.salvarJobs
    })

    $filtroMudou = Copiar-Arquivos
    if ($filtroMudou -or -not (Filtro-Rodando)) { Reiniciar-Filtro }
    Criar-Atalho
}

# Remove a trava. Com -ManterPasta só desfaz impressoras/tarefa (usado ao trocar de impressora).
function Remover([switch]$ManterPasta) {
    Parar-Filtro
    Unregister-ScheduledTask -TaskName $tarefa -Confirm:$false -ErrorAction SilentlyContinue
    $c = Ler-Config
    if ($c) {
        $travaPadrao = Eh-Padrao ([string]$c.impressoraTrava)
        Remove-Printer -Name $c.impressoraTrava -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
        Remove-PrinterPort -Name "$prefixoPorta$($c.porta)" -ErrorAction SilentlyContinue
        $nomeFinal = [string]$c.impressoraReal
        if ($c.assumiuNome -and (Existe-Impressora $c.impressoraReal) -and -not (Existe-Impressora $c.impressoraTrava)) {
            try {
                Rename-Printer -Name $c.impressoraReal -NewName $c.impressoraTrava
                $nomeFinal = [string]$c.impressoraTrava
            } catch { }
        }
        if ($travaPadrao) { Tornar-Padrao $nomeFinal }
    }
    Remove-Item $cfgPath -Force -ErrorAction SilentlyContinue
    if (-not $ManterPasta) {
        Remove-Item $atalho -Force -ErrorAction SilentlyContinue
        Remove-Item $destino -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:cfg = $null
}

# ---------------------------------------------------------------- janela
$fonte   = New-Object System.Drawing.Font('Segoe UI', 9)
$negrito = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$cinza   = [System.Drawing.Color]::FromArgb(90, 90, 90)
$verde   = [System.Drawing.Color]::FromArgb(30, 130, 60)
$vermelho = [System.Drawing.Color]::FromArgb(190, 40, 40)
$laranja = [System.Drawing.Color]::FromArgb(200, 110, 0)
$neutro  = [System.Drawing.Color]::FromArgb(100, 100, 110)

function Novo-Rotulo($pai, [string]$texto, [int]$x, [int]$y, [int]$w, [int]$h) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $texto
    $l.SetBounds($x, $y, $w, $h)
    $pai.Controls.Add($l)
    return $l
}
function Novo-Grupo([string]$texto, [int]$y, [int]$h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $texto
    $g.Font = $negrito
    $g.SetBounds(12, $y, 596, $h)
    $form.Controls.Add($g)
    return $g
}
function Novo-Botao($pai, [string]$texto, [int]$x, [int]$y, [int]$w, [int]$h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texto
    $b.Font = $fonte
    $b.SetBounds($x, $y, $w, $h)
    $pai.Controls.Add($b)
    return $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'TravaCalor - limite de calor da impressora de etiquetas'
$form.Font = $fonte
$form.ClientSize = New-Object System.Drawing.Size(620, 688)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

# --- situação
$lblStatus = Novo-Rotulo $form '' 12 10 596 40
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::White
$lblStatus.TextAlign = 'MiddleCenter'
$lblUltima = Novo-Rotulo $form '' 12 54 596 36
$lblUltima.TextAlign = 'MiddleCenter'

# --- 1. impressora
$g1 = Novo-Grupo '1. Qual é a impressora de etiquetas?' 94 86
$cmb = New-Object System.Windows.Forms.ComboBox
$cmb.DropDownStyle = 'DropDownList'
$cmb.Font = $fonte
$cmb.SetBounds(12, 24, 440, 24)
$g1.Controls.Add($cmb)
$btnAtualizar = Novo-Botao $g1 'Atualizar lista' 462 22 120 27
$lblDet = Novo-Rotulo $g1 '' 12 54 570 22
$lblDet.Font = $fonte
$lblDet.ForeColor = $cinza

# --- 2. nomes
$g2 = Novo-Grupo '2. Nomes das impressoras (pode alterar)' 186 158
$l = Novo-Rotulo $g2 'Impressora COM trava - é o nome que o programa de realocação usa para imprimir:' 12 22 570 18
$l.Font = $fonte
$txtTrava = New-Object System.Windows.Forms.TextBox
$txtTrava.Font = $fonte
$txtTrava.MaxLength = 200
$txtTrava.SetBounds(12, 42, 570, 24)
$g2.Controls.Add($txtTrava)
$l = Novo-Rotulo $g2 'Impressora direta, SEM trava - a impressora de verdade (para imprimir sem limite):' 12 72 570 18
$l.Font = $fonte
$txtDireta = New-Object System.Windows.Forms.TextBox
$txtDireta.Font = $fonte
$txtDireta.MaxLength = 200
$txtDireta.SetBounds(12, 92, 570, 24)
$g2.Controls.Add($txtDireta)
$l = Novo-Rotulo $g2 'Deixe o nome COM trava igual ao que o programa já usa: assim não precisa mudar nada nele.' 12 122 570 30
$l.Font = $fonte
$l.ForeColor = $cinza

# --- 3. limites
$g3 = Novo-Grupo '3. Calor máximo permitido (quanto menor o número, menos calor)' 350 278

function Nova-Barra([string]$texto, [int]$y, [int]$max) {
    $r = Novo-Rotulo $g3 $texto 12 $y 200 36
    $r.Font = $fonte
    $t = New-Object System.Windows.Forms.TrackBar
    $t.AutoSize = $false
    $t.Minimum = 0
    $t.Maximum = $max
    $t.TickFrequency = [Math]::Max(1, [int]($max / 15))
    $t.LargeChange = 1
    $t.SetBounds(212, $y, 290, 36)
    $g3.Controls.Add($t)
    $v = Novo-Rotulo $g3 '' 508 ($y + 4) 78 22
    $t.Tag = $v
    $t.Add_ValueChanged({ param($s, $e) $s.Tag.Text = "$($s.Value) de $($s.Maximum)" })
    $v.Text = "0 de $max"
    return $t
}
$barSD = Nova-Barra "Linguagem PPLZ (ZPL)`ncomando ~SD, de 0 a 30" 24 30
$barH  = Nova-Barra "Linguagem PPLA`ncomando H, de 0 a 30" 70 30
$barD  = Nova-Barra "Linguagem PPLB (EPL)`ncomando D, de 0 a 15" 116 15

$l = Novo-Rotulo $g3 'PPLZ: ajuste fino ^MD (-30 a 30)' 12 166 200 20
$l.Font = $fonte
$numMD = New-Object System.Windows.Forms.NumericUpDown
$numMD.Font = $fonte
$numMD.Minimum = -30
$numMD.Maximum = 30
$numMD.SetBounds(216, 163, 60, 24)
$g3.Controls.Add($numMD)
$btnPadrao = Novo-Botao $g3 'Voltar aos valores padrão' 412 161 170 27

$l = Novo-Rotulo $g3 ('Não sabe qual linguagem a impressora usa? Imprima uma etiqueta e olhe a linha "Última ' +
    'impressão" lá em cima. Baixe aos poucos até achar o menor valor em que o código de barras ainda é lido.') 12 196 570 34
$l.Font = $fonte
$l.ForeColor = $cinza
$chkJobs = New-Object System.Windows.Forms.CheckBox
$chkJobs.Text = 'Guardar cópia de cada etiqueta para diagnóstico (pasta C:\ProgramData\TravaCalor\jobs)'
$chkJobs.Font = $fonte
$chkJobs.SetBounds(12, 240, 570, 24)
$g3.Controls.Add($chkJobs)

# --- botões
$btnAplicar = Novo-Botao $form 'Instalar trava' 12 638 236 40
$btnAplicar.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnLog       = Novo-Botao $form 'Abrir histórico' 256 638 112 40
$btnReiniciar = Novo-Botao $form 'Reiniciar trava' 376 638 112 40
$btnRemover   = Novo-Botao $form 'Desinstalar' 496 638 112 40

# ---------------------------------------------------------------- lógica da tela
function Limitar-Valor($v, [int]$min, [int]$max, [int]$padrao) {
    if ($null -eq $v) { return $padrao }
    try { $n = [int]$v } catch { return $padrao }
    return [Math]::Min($max, [Math]::Max($min, $n))
}

function Selecionada {
    if ($cmb.SelectedIndex -lt 0 -or $cmb.SelectedIndex -ge $script:lista.Count) { return $null }
    return $script:lista[$cmb.SelectedIndex]
}

# Preenche os campos de nome conforme a impressora escolhida
function Sugerir-Nomes {
    $sel = Selecionada
    if (-not $sel) { $lblDet.Text = ''; return }
    $estado = if ($sel.Conectada) { 'conectada' } else { 'DESCONECTADA ou desligada' }
    $lblDet.Text = "Situação: $estado   |   Porta: $($sel.Porta)   |   Driver: $($sel.Driver)"
    $lblDet.ForeColor = if ($sel.Conectada) { $verde } else { $vermelho }

    $c = $script:cfg
    if ($c -and $sel.Nome -eq $c.impressoraReal) {
        $txtTrava.Text = $c.impressoraTrava
        $txtDireta.Text = $c.impressoraReal
    } elseif ($c) {
        # trocando de impressora: o nome que o programa usa continua o mesmo
        $txtTrava.Text = $c.impressoraTrava
        $txtDireta.Text = if ($sel.Nome -eq $c.impressoraTrava) { "$($sel.Nome) - DIRETA" } else { $sel.Nome }
    } else {
        $txtTrava.Text = $sel.Nome
        $txtDireta.Text = "$($sel.Nome) - DIRETA"
    }
}

function Atualizar-Situacao {
    $c = $script:cfg
    $btnRemover.Enabled = [bool]$c
    $btnReiniciar.Enabled = [bool]$c
    if (-not $c) {
        $lblStatus.Text = 'TRAVA NÃO INSTALADA'
        $lblStatus.BackColor = $neutro
        $btnAplicar.Text = 'Instalar trava'
        $lblUltima.Text = 'Escolha a impressora, confira os nomes e o calor máximo, e clique em "Instalar trava".'
        $lblUltima.ForeColor = $cinza
        return
    }
    $btnAplicar.Text = 'Salvar alterações'
    if (Filtro-Rodando) {
        $lblStatus.Text = "TRAVA ATIVA em '$($c.impressoraTrava)'"
        $lblStatus.BackColor = $verde
    } else {
        $lblStatus.Text = 'TRAVA INSTALADA, MAS PARADA - clique em "Reiniciar trava"'
        $lblStatus.BackColor = $vermelho
    }

    # Última linha do histórico, em linguagem simples
    $linha = ''
    try { $linha = Ultima-Linha-Log } catch { }
    if ($linha -eq $script:ultimoLog -and $lblUltima.Tag -eq 'log') { return }
    $script:ultimoLog = $linha
    $lblUltima.Tag = 'log'
    $hora = if ($linha.Length -ge 19) { $linha.Substring(0, 19) } else { '' }
    if ($linha -match 'LIMITADO: (.+)$') {
        $lblUltima.Text = "Última impressão ($hora): calor REDUZIDO  ->  $($Matches[1])"
        $lblUltima.ForeColor = $verde
    } elseif ($linha -match '\| (.+?) \| ja dentro do limite \((.+)\)') {
        $lblUltima.Text = "Última impressão ($hora): $($Matches[1]), calor já estava dentro do limite ($($Matches[2]))"
        $lblUltima.ForeColor = $verde
    } elseif ($linha -match 'nenhum comando de calor') {
        $lblUltima.Text = "Última impressão ($hora): o programa não mandou comando de calor nesta etiqueta. Veja o LEIA-ME, item `"Se não funcionar`"."
        $lblUltima.ForeColor = $laranja
    } elseif ($linha -match 'ERRO: (.+)$') {
        $lblUltima.Text = "Erro na última impressão ($hora): $($Matches[1])"
        $lblUltima.ForeColor = $vermelho
    } else {
        $lblUltima.Text = 'Nenhuma etiqueta passou pela trava ainda. Imprima uma etiqueta para testar.'
        $lblUltima.ForeColor = $cinza
    }
}

function Carregar-Tela {
    $script:carregando = $true
    try {
        $script:cfg = Ler-Config
        $c = $script:cfg
        $script:lista = @(Listar-Impressoras)
        $cmb.Items.Clear()
        foreach ($p in $script:lista) {
            $marca = if ($p.Conectada) { 'conectada' } else { 'desconectada' }
            [void]$cmb.Items.Add("$($p.Nome)   [$marca]")
        }
        $indice = -1
        if ($c) {
            for ($i = 0; $i -lt $script:lista.Count; $i++) {
                if ($script:lista[$i].Nome -eq $c.impressoraReal) { $indice = $i }
            }
        }
        if ($indice -lt 0 -and $script:lista.Count -gt 0) { $indice = 0 }   # conectadas vêm primeiro
        $cmb.SelectedIndex = $indice

        $fonteLim = if ($c) { $c } else { [pscustomobject]$padroes }
        $barSD.Value = Limitar-Valor $fonteLim.zplMaxSD 0 30 $padroes.zplMaxSD
        $barH.Value  = Limitar-Valor $fonteLim.pplaMaxH 0 30 $padroes.pplaMaxH
        $barD.Value  = Limitar-Valor $fonteLim.pplbMaxD 0 15 $padroes.pplbMaxD
        $numMD.Value = Limitar-Valor $fonteLim.zplMaxMD -30 30 $padroes.zplMaxMD
        $chkJobs.Checked = [bool]($c -and $c.salvarJobs)
    } finally { $script:carregando = $false }
    Sugerir-Nomes
    $lblUltima.Tag = ''
    Atualizar-Situacao
    if ($script:lista.Count -eq 0) {
        $lblDet.Text = 'Nenhuma impressora instalada no Windows. Conecte a impressora, instale o driver e clique em "Atualizar lista".'
        $lblDet.ForeColor = $vermelho
    }
}

function Validar-Nome([string]$nome, [string]$qual) {
    if (-not $nome) { throw "Preencha o nome da impressora $qual." }
    if ($nome -match '[\\,!]') { throw "O nome da impressora $qual não pode ter barra invertida (\), vírgula ou ponto de exclamação." }
}

function Aplicar {
    $sel = Selecionada
    if (-not $sel) { throw 'Escolha a impressora de etiquetas na lista (passo 1).' }
    $nomeTrava = $txtTrava.Text.Trim()
    $nomeDireta = $txtDireta.Text.Trim()
    Validar-Nome $nomeTrava 'COM trava'
    Validar-Nome $nomeDireta 'direta'
    if ($nomeTrava -eq $nomeDireta) { throw 'Os dois nomes precisam ser diferentes: são duas impressoras no Windows.' }

    $c = $script:cfg
    $mesma = ($c -and $sel.Nome -eq $c.impressoraReal)

    # Os nomes não podem bater com outra impressora que já existe
    $proprias = @($sel.Nome)
    if ($c) { $proprias += [string]$c.impressoraTrava }
    $outras = @(Get-Printer | Where-Object { $proprias -notcontains $_.Name } | ForEach-Object { $_.Name })
    foreach ($n in $nomeTrava, $nomeDireta) {
        if ($outras -contains $n) { throw "Já existe outra impressora chamada '$n'. Escolha outro nome." }
    }

    $lim = @{
        zplMaxSD   = [int]$barSD.Value
        zplMaxMD   = [int]$numMD.Value
        pplaMaxH   = [int]$barH.Value
        pplbMaxD   = [int]$barD.Value
        salvarJobs = [bool]$chkJobs.Checked
    }

    if ($mesma) {
        Alterar $nomeTrava $nomeDireta $lim
        Carregar-Tela
        Aviso "Alterações salvas. Já valem para a próxima etiqueta.`n`nO programa de realocação deve imprimir em:`n'$nomeTrava'"
        return
    }

    if ($c) {
        if (-not (Confirmar "A trava hoje está na impressora '$($c.impressoraReal)'.`n`nDeseja passar a trava para '$($sel.Nome)'?")) { return }
        # ao tirar a trava da antiga, ela pode voltar a usar o nome que foi digitado para a nova
        if ($c.assumiuNome -and $nomeTrava -eq $c.impressoraTrava) {
            # a antiga fica com o nome "direto" que já tinha
            $c.assumiuNome = $false
            Gravar-Config $c
        }
        Remover -ManterPasta
    } elseif (-not $sel.Conectada) {
        if (-not (Confirmar "A impressora '$($sel.Nome)' parece estar desconectada ou desligada.`n`nInstalar a trava nela mesmo assim?")) { return }
    }

    $aviso = Instalar $sel $nomeTrava $nomeDireta $lim
    Carregar-Tela
    Aviso ("Trava instalada!`n`nO programa de realocação deve imprimir em:`n'$nomeTrava'`n`n" +
           "Para imprimir sem trava, use:`n'$nomeDireta'`n`n" +
           "Um atalho 'TravaCalor' foi criado na Área de Trabalho para abrir este painel depois.$aviso")
}

# Roda uma ação mostrando o erro numa caixa, em vez de sumir sem avisar
# (o relógio da tela fica pausado durante a ação, para não rodar por cima dela)
function Tentar([scriptblock]$acao) {
    $script:ocupado = $true
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { & $acao }
    catch {
        Erro "Não deu certo:`n`n$($_.Exception.Message)"
        try { Carregar-Tela } catch { }
    }
    finally {
        if (-not $script:fechando) { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        $script:ocupado = $false
    }
}

$cmb.Add_SelectedIndexChanged({ if (-not $script:carregando) { Tentar { Sugerir-Nomes } } })
$btnAtualizar.Add_Click({ Tentar { Carregar-Tela } })
$btnAplicar.Add_Click({ Tentar { Aplicar } })
$btnPadrao.Add_Click({
    $barSD.Value = $padroes.zplMaxSD; $barH.Value = $padroes.pplaMaxH
    $barD.Value = $padroes.pplbMaxD;  $numMD.Value = $padroes.zplMaxMD
})
$btnLog.Add_Click({
    Tentar {
        if (Test-Path $logFile) { Start-Process notepad.exe -ArgumentList "`"$logFile`"" }
        else { Aviso 'Ainda não há histórico. Ele aparece depois da primeira etiqueta impressa com a trava instalada.' }
    }
})
$btnReiniciar.Add_Click({
    Tentar {
        Reiniciar-Filtro
        Start-Sleep -Seconds 4
        $lblUltima.Tag = ''
        Atualizar-Situacao
    }
})
$btnRemover.Add_Click({
    Tentar {
        $c = $script:cfg
        if (-not $c) { return }
        $fim = if ($c.assumiuNome) { "A impressora '$($c.impressoraReal)' passa a se chamar '$($c.impressoraTrava)', então o programa de realocação continua imprimindo, só que SEM limite de calor." }
               else { "A impressora '$($c.impressoraReal)' continua com o mesmo nome." }
        if (-not (Confirmar "Remover a trava de calor?`n`n$fim")) { return }
        Remover
        if ($PSScriptRoot -eq $destino) {
            Aviso 'TravaCalor removido. Para instalar de novo, abra o "ABRIR TRAVACALOR.bat" da pasta original.'
            $form.Close()
            return
        }
        Carregar-Tela
        Aviso 'TravaCalor removido.'
    }
})

# Relógio que atualiza a situação a cada 3 s. Nunca roda duas vezes ao mesmo tempo,
# nem durante uma ação, nem depois que a janela começou a fechar.
$script:ocupado  = $false
$script:fechando = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    if ($script:ocupado -or $script:fechando) { return }
    $script:ocupado = $true
    try { Atualizar-Situacao } catch { }
    finally { $script:ocupado = $false }
})

$form.Add_Shown({ Tentar { Carregar-Tela }; if (-not $script:fechando) { $timer.Start() } })
$form.Add_FormClosing({ $script:fechando = $true; $timer.Stop() })

try { [void]$form.ShowDialog() }
catch { Erro "O painel encontrou um problema e vai fechar:`n`n$($_.Exception.Message)" }
finally {
    $script:fechando = $true
    try { $timer.Stop(); $timer.Dispose(); $form.Dispose() } catch { }
}
# Garante que o processo do painel termine (ele roda escondido, sem janela de console)
[Environment]::Exit(0)
