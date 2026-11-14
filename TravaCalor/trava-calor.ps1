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
            Log ("Configuracao recarregada -> '{0}' | ~SD max {1}, ^MD max {2}, H max {3}, D max {4}" -f `
                $novo.impressoraReal, $novo.zplMaxSD, $novo.zplMaxMD, $novo.pplaMaxH, $novo.pplbMaxD)
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

# Troca o valor do grupo "v" por $max quando ele passar do limite
function Limitar([string]$txt, [string]$padrao, [int]$max, [string]$fmt, [string]$nome, $mudancas, $achados) {
    $rx = [regex]$padrao
    $avaliador = [Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $g = $m.Groups['v']
        $v = [int]$g.Value
        $achados.Add("$nome=$v")
        if ($v -le $max) { return $m.Value }
        $mudancas.Add("$nome $v->$max")
        $ini = $g.Index - $m.Index
        return $m.Value.Substring(0, $ini) + $max.ToString($fmt) + $m.Value.Substring($ini + $g.Length)
    }
    return $rx.Replace($txt, $avaliador)
}

function Filtrar([byte[]]$bytes) {
    $txt = $latin1.GetString($bytes)
    $mud = New-Object 'System.Collections.Generic.List[string]'
    $ach = New-Object 'System.Collections.Generic.List[string]'
    $ling = @()

    # PPLZ (compativel ZPL): ~SDnn (0-30) e ^MDn (-30 a 30, relativo)
    if ($txt -match '\^XA') {
        $ling += 'PPLZ/ZPL'
        $txt = Limitar $txt '~SD(?<v>\d{1,2})' $cfg.zplMaxSD '00' '~SD' $mud $ach
        $txt = Limitar $txt '\^MD(?<v>-?\d{1,2})' $cfg.zplMaxMD '0' '^MD' $mud $ach
    }
    # PPLA (compativel DPL/Datamax): linha "Hnn" dentro do formato de etiqueta (STX L)
    if ($txt.Contains([string][char]2 + 'L')) {
        $ling += 'PPLA/DPL'
        $txt = Limitar $txt '(?m)^H(?<v>\d{2})(?=\r?$)' $cfg.pplaMaxH '00' 'H' $mud $ach
    }
    # PPLB (compativel EPL2): linha "Dn" (0-15)
    if ($txt -match '(?m)^N\r?$' -or $txt -match '(?m)^P\d+') {
        $ling += 'PPLB/EPL'
        $txt = Limitar $txt '(?m)^D(?<v>\d{1,2})(?=\r?$)' $cfg.pplbMaxD '0' 'D' $mud $ach
    }

    $resumo = if ($ling.Count) { $ling -join '+' } else { 'linguagem nao reconhecida' }
    if ($ach.Count -eq 0) { $resumo += ' | nenhum comando de calor encontrado' }
    elseif ($mud.Count -eq 0) { $resumo += ' | ja dentro do limite (' + (($ach | Select-Object -Unique) -join ',') + ')' }
    else { $resumo += ' | LIMITADO: ' + (($mud | Select-Object -Unique) -join ', ') }

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
