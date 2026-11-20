param([Parameter(Mandatory=$true)][ValidateSet('CreatePlatform','BuildPlatform','CreateApp','BuildApp')][string]$Stage)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$previousStage=$env:FH_VITIS_STAGE
$previousResult=$env:FH_VITIS_RESULT
$previousJavaOptions=$env:JAVA_TOOL_OPTIONS
$statusDir=Join-Path $root 'software/status'
New-Item -ItemType Directory -Force $statusDir | Out-Null
$marker=Join-Path $statusDir ($Stage+'-'+[guid]::NewGuid().ToString()+'.ok')
$logDir=Join-Path $root 'software/logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log=Join-Path $logDir ($Stage+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
try {
    # Java 21 AF_UNIX socket setup fails with some Windows short TEMP paths.
    # Use a normal project-local directory for this process only.
    $javaSocketDir=Join-Path $root 'software/java_tmp'
    New-Item -ItemType Directory -Force $javaSocketDir | Out-Null
    $env:JAVA_TOOL_OPTIONS=($previousJavaOptions+' -Djdk.net.unixdomain.tmpdir="'+$javaSocketDir.Replace('\','/')+'"').Trim()
    Write-Host "Saving full Vitis output to $log"
    $env:FH_VITIS_STAGE=$Stage
    $env:FH_VITIS_RESULT=$marker
    # Native child output can bypass Start-Transcript in Windows PowerShell 5.1.
    # Pipe both streams explicitly; stderr is diagnostic text, not a PS exception.
    $ErrorActionPreference='Continue'
    & 'C:\AMDDesignTools\2025.2\Vitis\bin\vitis.bat' -s "$root/scripts/vitis_project.py" 2>&1 | Tee-Object -FilePath $log
    $ErrorActionPreference='Stop'
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $marker)) {
        throw "Vitis $Stage did not complete. The launcher can return zero after Python fails; inspect its output."
    }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $Stage) {throw 'Vitis completion marker mismatch'}
} finally {
    $env:FH_VITIS_STAGE=$previousStage
    $env:FH_VITIS_RESULT=$previousResult
    $env:JAVA_TOOL_OPTIONS=$previousJavaOptions
}
