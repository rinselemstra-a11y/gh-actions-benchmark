# bench.ps1 - hardware-benchmark zonder Python, voor Windows (PowerShell 5.1+).
# Start via bench.cmd of:  powershell -NoProfile -ExecutionPolicy Bypass -File bench.ps1
# Zelfde tests en JSON-structuur als bench.py, zodat
#   python bench.py --compare result-a.json result-b.json
# ook met deze resultaten werkt.
#
# Let op: de cpu-test is een PowerShell-loop en is alleen vergelijkbaar met
# andere bench.ps1-resultaten, niet met bench.py of bench.sh.
param(
    [string]$Label = $env:COMPUTERNAME,
    [string]$WorkDir = (Get-Location).Path,
    [string]$Cmd = "",
    [switch]$Worker   # intern: alleen de cpu-klus draaien (kindproces van de multi-test)
)
$ErrorActionPreference = "Stop"

$cpuWork = {
    $s = 0
    for ($i = 0; $i -lt 15000000; $i++) { $s = ($s + $i * $i) % 1000003 }
    $s
}
if ($Worker) { $null = & $cpuWork; exit 0 }

# ---------------------------------------------------------------- systeeminfo
$proc = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs   = Get-CimInstance Win32_ComputerSystem
$osi  = Get-CimInstance Win32_OperatingSystem
$cores = [Environment]::ProcessorCount
$ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$gha = ($env:GITHUB_ACTIONS -eq "true")

Write-Host "Benchmark '$Label' gestart in $WorkDir ..."

# --------------------------------------------------------------------- tests
Write-Host "  cpu single-thread ..."
$sw = [Diagnostics.Stopwatch]::StartNew()
$null = & $cpuWork
$cpuSingle = $sw.Elapsed.TotalSeconds

Write-Host "  cpu multi-thread ..."
# Kindprocessen draaien dit script met -Worker: een loop in een scriptbestand
# wordt door PowerShell gecompileerd, een loop via -Command niet (10x trager).
$sw = [Diagnostics.Stopwatch]::StartNew()
$procs = 1..$cores | ForEach-Object {
    Start-Process -FilePath "powershell" -NoNewWindow -PassThru -ArgumentList `
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-Worker"
}
$procs | ForEach-Object { $_.WaitForExit() }
$cpuMulti = $sw.Elapsed.TotalSeconds
$speedup = $cpuSingle * $cores / $cpuMulti

Write-Host "  geheugen ..."
$buf = New-Object byte[] (512MB)
$sw = [Diagnostics.Stopwatch]::StartNew()
$copy = $buf.Clone()
$memMbS = 1024 / $sw.Elapsed.TotalSeconds
$copy = $null; $buf = $null

Write-Host "  disk sequentieel ..."
$seq = Join-Path $WorkDir "bench_seq.bin"
$chunk = New-Object byte[] (1MB)
(New-Object Random).NextBytes($chunk)
$sw = [Diagnostics.Stopwatch]::StartNew()
$fs = [IO.File]::Create($seq)
for ($i = 0; $i -lt 512; $i++) { $fs.Write($chunk, 0, $chunk.Length) }
$fs.Flush($true)   # fsync
$fs.Close()
$diskW = 512 / $sw.Elapsed.TotalSeconds
$sw = [Diagnostics.Stopwatch]::StartNew()
$fs = [IO.File]::OpenRead($seq)
while ($fs.Read($chunk, 0, $chunk.Length) -gt 0) { }
$fs.Close()
$diskR = 512 / $sw.Elapsed.TotalSeconds
Remove-Item $seq

Write-Host "  disk kleine bestanden ..."
$small = Join-Path $WorkDir "bench_small"
New-Item -ItemType Directory -Force $small | Out-Null
$payload = New-Object byte[] 4096
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 3000; $i++) { [IO.File]::WriteAllBytes("$small\f$i.txt", $payload) }
for ($i = 0; $i -lt 3000; $i++) { $null = [IO.File]::ReadAllBytes("$small\f$i.txt") }
Remove-Item -Recurse -Force $small
$smallS = $sw.Elapsed.TotalSeconds
$smallOps = 3000 / $smallS

$cmdS = $null; $cmdRc = $null
if ($Cmd) {
    Write-Host "  commando: $Cmd ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    cmd /c $Cmd
    $cmdRc = $LASTEXITCODE
    $cmdS = $sw.Elapsed.TotalSeconds
}

# ------------------------------------------------------------------ uitvoer
function Row($name, $value, $note) { "{0,-28}{1,14}  {2}" -f $name, $value, $note }
Write-Host ""
Write-Host "=== $Label ==="
Write-Host ("{0} ({1})  |  {2}  |  {3} cores  |  RAM {4} GB" -f $osi.Caption, $env:PROCESSOR_ARCHITECTURE, $proc.Name, $cores, $ramGb)
if ($gha) { Write-Host "GitHub Actions runner: $env:RUNNER_OS $env:ImageOS" }
Write-Host ""
Write-Host (Row "test" "waarde" "toelichting")
Write-Host ("-" * 72)
Write-Host (Row "cpu single-thread"          ("{0:N2} s" -f $cpuSingle) "lager is beter (PowerShell-loop)")
Write-Host (Row "cpu multi-thread"           ("{0:N2} s" -f $cpuMulti)  ("{0} processen, speedup {1:N1}x (incl. opstarten)" -f $cores, $speedup))
Write-Host (Row "geheugen (kopie)"           ("{0:N0} MB/s" -f $memMbS) "hoger is beter")
Write-Host (Row "disk sequentieel schrijven" ("{0:N0} MB/s" -f $diskW)  "512 MB, met fsync")
Write-Host (Row "disk sequentieel lezen"     ("{0:N0} MB/s" -f $diskR)  "(kan uit cache komen)")
Write-Host (Row "disk kleine bestanden"      ("{0:N2} s" -f $smallS)    ("3000x schrijven+lezen, {0:N0}/s" -f $smallOps))
if ($cmdS -ne $null) { Write-Host (Row "eigen commando" ("{0:N2} s" -f $cmdS) "$Cmd (exit $cmdRc)") }
Write-Host ""

$result = [ordered]@{
    label     = $Label
    timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    tool      = "bench.ps1"
    system    = [ordered]@{
        hostname = $env:COMPUTERNAME
        os = $osi.Caption; os_version = $osi.Version; arch = $env:PROCESSOR_ARCHITECTURE
        cpu = $proc.Name; cores = $cores; ram_gb = $ramGb
        github_actions = $gha; runner = "$env:RUNNER_OS $env:ImageOS".Trim()
    }
    cmd       = $(if ($Cmd) { $Cmd } else { $null })
    metrics   = [ordered]@{
        cpu_single_s = [math]::Round($cpuSingle, 4)
        cpu_multi_s = [math]::Round($cpuMulti, 4)
        cpu_multi_workers = $cores
        cpu_multi_speedup = [math]::Round($speedup, 2)
        mem_mb_s = [math]::Round($memMbS, 2)
        disk_write_mb_s = [math]::Round($diskW, 2)
        disk_read_mb_s = [math]::Round($diskR, 2)
        small_files_s = [math]::Round($smallS, 4)
        small_files_ops_s = [math]::Round($smallOps, 2)
        cmd_s = $(if ($cmdS -ne $null) { [math]::Round($cmdS, 4) } else { $null })
        cmd_rc = $cmdRc
    }
}
$out = "result-$Label.json"
$json = $result | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path (Get-Location).Path $out), $json, (New-Object Text.UTF8Encoding $false))  # zonder BOM
Write-Host "Opgeslagen: $out"
