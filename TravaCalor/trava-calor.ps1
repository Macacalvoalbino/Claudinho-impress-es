# TravaCalor - filtro de temperatura para impressoras de etiquetas (ELGIN L42 PRO / L42 PRO FULL)
# Recebe os trabalhos da impressora "com trava" em 127.0.0.1, limita os comandos
# de calor/darkness e repassa o trabalho para a impressora real.
# Os limites e o nome da impressora sao relidos do config.json a cada etiqueta,
# entao mudancas feitas pelo painel valem na hora, sem reiniciar nada.
param(
    [string]$Config = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
$pasta = Split-Path $Config -Parent
$logFile = Join-Path $pasta 'trava-calor.log'
$latin1 = [Text.Encoding]::GetEncoding(28591)   # preserva todos os bytes
$cfg = $null
$cfgData = [datetime]::MinValue

function Log([string]$msg) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
            Move-Item $logFile "$logFile.old" -Force
        }
        Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg)
    } catch { }
}

# Le o config.json de novo sempre que ele for alterado. Se estiver invalido
# (por exemplo, no meio de uma gravacao), continua com a configuracao anterior.
function CarregarConfig {
    try {
        $data = (Get-Item $Config).LastWriteTimeUtc
        if ($data -eq $script:cfgData) { return }
        $novo = Get-Content $Config -Raw | ConvertFrom-Json
        if (-not $novo.impressoraReal) { throw 'impressoraReal vazio' }
        $primeira = ($null -eq $script:cfg)
        $script:cfg = $novo
        $script:cfgData = $data
        if (-not $primeira) {
            Log ("Configuracao recarregada -> '{0}' | ~SD max {1}, ^MD max {2}, H max {3}, D max {4}, velocidade max {5}" -f `
                $novo.impressoraReal, $novo.zplMaxSD, $novo.zplMaxMD, $novo.pplaMaxH, $novo.pplbMaxD, $novo.velocidadeMax)
        }
    } catch {
        if ($null -eq $script:cfg) { throw }
        Log "AVISO: nao consegui ler o config.json ($($_.Exception.Message)); mantendo a configuracao anterior"
    }
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RawPrinter {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class DOCINFO { public string pDocName; public string pOutputFile; public string pDataType; }
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool OpenPrinter(string name, out IntPtr h, IntPtr def);
    [DllImport("winspool.drv", SetLastError = true)] public static extern bool ClosePrinter(IntPtr h);
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int StartDocPrinter(IntPtr h, int level, [In] DOCINFO di);
    [DllImport("winspool.drv", SetLastError = true)] public static extern bool EndDocPrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)] public static extern bool StartPagePrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)] public static extern bool EndPagePrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool WritePrinter(IntPtr h, byte[] buf, int count, out int written);

    public static void Send(string printer, byte[] data, string docName) {
        IntPtr h;
        if (!OpenPrinter(printer, out h, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
        try {
            DOCINFO di = new DOCINFO();
            di.pDocName = docName; di.pDataType = "RAW";
            if (StartDocPrinter(h, 1, di) == 0) throw new System.ComponentModel.Win32Exception();
            StartPagePrinter(h);
            int written;
            if (!WritePrinter(h, data, data.Length, out written)) throw new System.ComponentModel.Win32Exception();
            EndPagePrinter(h);
            EndDocPrinter(h);
        } finally { ClosePrinter(h); }
    }
}
"@

# Inicio e fim de linha. Aceita CR, LF ou CRLF: o PPLA costuma usar so CR,
# e com "(?m)^...$" do .NET (que so entende LF) o comando passava sem ser visto.
$IL = '(?:^|(?<=[\r\n]))'
$FL = '(?=[\r\n]|$)'

# Troca o valor do grupo "v" pelo limite quando ele passar do limite.
# $ler converte o texto achado em numero; $escrever converte o limite em texto.
function Limitar([string]$txt, [string]$padrao, [double]$max, [scriptblock]$ler, [scriptblock]$escrever,
                 [string]$nome, $mudancas, $achados) {
    $rx = [regex]$padrao
    $novoTxt = & $escrever $max
    $avaliador = [Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $g = $m.Groups['v']
        $v = & $ler $g.Value
        $achados.Add("$nome=$($g.Value)")
        if ($v -le $max) { return $m.Value }
        $mudancas.Add("$nome $($g.Value)->$novoTxt")
        $ini = $g.Index - $m.Index
        return $m.Value.Substring(0, $ini) + $novoTxt + $m.Value.Substring($ini + $g.Length)
    }
    return $rx.Replace($txt, $avaliador)
}

$lerInt = { param($t) [int]$t }
function Fmt([string]$f) { return { param($n) ([int]$n).ToString($f) }.GetNewClosure() }

# Velocidade PPLZ/ZPL (^PR): numero em pol/s ou letra A=2 B=3 C=4 D=6 E=8
$lerVelZpl = { param($t)
    switch -casesensitive ($t.ToUpper()) { 'A' { 2 } 'B' { 3 } 'C' { 4 } 'D' { 6 } 'E' { 8 } default { [int]$t } } }
# Velocidade PPLA/DPL (Pa): letra A=1,0 pol/s, B=1,5, C=2,0 ... (meio pol/s por letra)
$letrasPpla = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
$lerVelPpla = { param($t) 1 + $letrasPpla.IndexOf([string]$t) * 0.5 }
$escVelPpla = { param($n) [string]$letrasPpla[[int][Math]::Max(0, [Math]::Floor(($n - 1) * 2))] }

function Filtrar([byte[]]$bytes) {
    $txt = $latin1.GetString($bytes)
    $mud = New-Object 'System.Collections.Generic.List[string]'
    $ach = New-Object 'System.Collections.Generic.List[string]'
    $ling = @()
    $vel = 0
    if ($cfg.velocidadeMax) { $vel = [double]$cfg.velocidadeMax }
    $ppla = $txt.Contains([string][char]2 + 'L')
    $zpl = $txt -match '\^XA'

    # PPLZ (compativel ZPL): ~SDnn (0-30) e ^MDn (-30 a 30, relativo ao ~SD guardado na impressora)
    if ($zpl) {
        $ling += 'PPLZ/ZPL'
        $antes = $ach.Count
        $txt = Limitar $txt '~SD(?<v>\d{1,2})' $cfg.zplMaxSD $lerInt (Fmt '00') '~SD' $mud $ach
        $temSD = $ach.Count -gt $antes
        $txt = Limitar $txt '\^MD(?<v>-?\d{1,2})' $cfg.zplMaxMD $lerInt (Fmt '0') '^MD' $mud $ach
        if (-not $temSD) {
            # Sem ~SD o ^MD soma em cima do calor guardado na impressora (que pode estar no maximo).
            # Manda o calor absoluto antes da etiqueta.
            $sd = ([int]$cfg.zplMaxSD).ToString('00')
            $i = $txt.IndexOf('^XA')
            $txt = $txt.Substring(0, $i) + "~SD$sd" + $txt.Substring($i)
            $mud.Add("~SD inserido=$sd")
        }
        if ($vel -gt 0) {
            $txt = Limitar $txt '\^PR(?<v>[A-Ea-e]|\d{1,2})' $vel $lerVelZpl (Fmt '0') 'velocidade ^PR' $mud $ach
        }
    }
    # PPLA (compativel DPL/Datamax): linha "Hnn" dentro do formato de etiqueta (STX L)
    if ($ppla) {
        $ling += 'PPLA/DPL'
        $antes = $ach.Count
        $txt = Limitar $txt "$($IL)H(?<v>\d{2})$FL" $cfg.pplaMaxH $lerInt (Fmt '00') 'H' $mud $ach
        if ($ach.Count -eq $antes) {
            # Sem "H" a impressora usa o calor guardado nela. Coloca o limite em cada etiqueta.
            $h = ([int]$cfg.pplaMaxH).ToString('00')
            $rxL = [regex]'\x02L(?<t>\r\n|\r|\n)'
            if ($rxL.IsMatch($txt)) {
                $txt = $rxL.Replace($txt, [Text.RegularExpressions.MatchEvaluator]{
                    param($m) $m.Value + "H$h" + $m.Groups['t'].Value })
                $mud.Add("H inserido=$h")
            }
        }
        if ($vel -gt 0) {
            $txt = Limitar $txt "$($IL)P(?<v>[A-Za-z])$FL" $vel $lerVelPpla $escVelPpla 'velocidade P' $mud $ach
        }
    }
    # PPLB (compativel EPL2): linha "Dn" (0-15). So se nao for PPLA/PPLZ, para nao
    # confundir a linha "D11" (tamanho do ponto) do PPLA com calor.
    if (-not $ppla -and -not $zpl -and ($txt -match "$($IL)N$FL" -or $txt -match "$($IL)P\d+")) {
        $ling += 'PPLB/EPL'
        $antes = $ach.Count
        $txt = Limitar $txt "$($IL)D(?<v>\d{1,2})$FL" $cfg.pplbMaxD $lerInt (Fmt '0') 'D' $mud $ach
        if ($ach.Count -eq $antes) {
            $d = [int]$cfg.pplbMaxD
            $n = [regex]::Match($txt, "$($IL)N(?<t>\r\n|\n|\r)")
            if ($n.Success) {
                $pos = $n.Index + $n.Length
                $txt = $txt.Substring(0, $pos) + "D$d" + $n.Groups['t'].Value + $txt.Substring($pos)
            } else {
                $txt = "`nD$d`n" + $txt
            }
            $mud.Add("D inserido=$d")
        }
        if ($vel -gt 0) {
            $txt = Limitar $txt "$($IL)S(?<v>\d{1,2})$FL" $vel $lerInt (Fmt '0') 'velocidade S' $mud $ach
        }
    }

    $resumo = if ($ling.Count) { $ling -join '+' } else { 'linguagem nao reconhecida' }
    if ($mud.Count -gt 0) { $resumo += ' | CONTROLADO: ' + (($mud | Select-Object -Unique) -join ', ') }
    elseif ($ach.Count -gt 0) { $resumo += ' | ja dentro do limite (' + (($ach | Select-Object -Unique) -join ',') + ')' }
    else { $resumo += ' | nenhum comando de calor encontrado' }

    return @{ Bytes = $latin1.GetBytes($txt); Resumo = $resumo }
}

CarregarConfig
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int]$cfg.porta)
$listener.Start()
Log "Iniciado. Porta $($cfg.porta) -> '$($cfg.impressoraReal)'"

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $ms = New-Object IO.MemoryStream
        $client.GetStream().CopyTo($ms)
        $original = $ms.ToArray()
        if ($original.Length -eq 0) { continue }

        CarregarConfig
        $r = Filtrar $original
        if ($cfg.salvarJobs) {
            $dir = Join-Path $pasta 'jobs'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $carimbo = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
            [IO.File]::WriteAllBytes((Join-Path $dir "$carimbo-original.prn"), $original)
            [IO.File]::WriteAllBytes((Join-Path $dir "$carimbo-enviado.prn"), $r.Bytes)
        }
        [RawPrinter]::Send($cfg.impressoraReal, $r.Bytes, 'Etiqueta (TravaCalor)')
        Log ("Job {0:N0} bytes | {1}" -f $original.Length, $r.Resumo)
    } catch {
        Log "ERRO: $($_.Exception.Message)"
    } finally {
        $client.Close()
    }
}
