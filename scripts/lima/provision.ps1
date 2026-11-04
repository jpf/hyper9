# Minimal Windows guest setup for h9 testing. Idempotent; run by
# `scripts/lima/vm up windows` (as the Lima admin user over ssh).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Step($msg) { Write-Output "== $msg" }

function PSStartup {
	$t = Measure-Command { powershell -NoProfile -NonInteractive -Command 'exit' }
	[math]::Round($t.TotalSeconds, 1)
}

Step 'quieting the guest'
# Background Windows Update work slows the guest to a crawl.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Force $au | Out-Null
Set-ItemProperty $au NoAutoUpdate 1 -Type DWord
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service wuauserv -StartupType Disabled
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /hibernate off

# Real-time scanning of freshly copied test binaries slows every run.
$h9 = Join-Path $env:USERPROFILE 'h9'
New-Item -ItemType Directory -Force $h9 | Out-Null
Add-MpPreference -ExclusionPath $h9 -ErrorAction SilentlyContinue

Step 'precompiling .NET Framework (ngen)'
# Without native images PowerShell takes ~20s to start in this guest.
$before = PSStartup
$rt = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory().TrimEnd('\')
$dirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$null = $dirs.Add($rt)
(Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework*\v4.0.30319" -Directory).FullName | ForEach-Object { $null = $dirs.Add($_) }
foreach ($d in $dirs) {
	$ngen = Join-Path $d 'ngen.exe'
	if (-not (Test-Path $ngen)) { continue }
	if ($d -ieq $rt) {
		Import-Module Microsoft.PowerShell.Utility, Microsoft.PowerShell.Management, Microsoft.PowerShell.Security -ErrorAction SilentlyContinue
		foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
			if ($a.Location) { & $ngen install $a.Location /nologo /silent | Out-Null }
		}
	}
	& $ngen update /nologo /silent | Out-Null
	& $ngen executeQueuedItems /nologo /silent | Out-Null
}
Write-Output "powershell startup: ${before}s before, $(PSStartup)s after"

Step 'done'
