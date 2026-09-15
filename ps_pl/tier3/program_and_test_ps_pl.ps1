# scripts/program_and_test_ps_pl.ps1
#
# End-to-end HIL automation for the PS+PL target: generates the BSP,
# compiles the Tier 3 software, programs the board, runs the test suite,
# and checks the UART output for OVERALL PASS/FAIL. Exits 1 on any
# failure, matching the exit-code discipline used by the PL-only Tcl
# scripts (see README: "explicitly exit 1 on failure").
#
# Run from the repository root:
#   powershell -File scripts/program_and_test_ps_pl.ps1

$ErrorActionPreference = "Stop"

$XSCT = "C:\AMDDesignTools\2025.2\Vitis\bin\xsct.bat"
$GCC  = "C:\AMDDesignTools\2025.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe"
# NOTE: these two use forward slashes on purpose -- they get embedded in
# generated .tcl script content below, and Tcl treats backslash as an
# escape character, silently eating "\g", "\w", etc. from Windows paths.
$XSA  = "./gemm_ps_pl.xsa"
$WORKSPACE = "./workspace"
$SERIAL_PORT_NAME = $null  # auto-detected below
$SERIAL_TIMEOUT_SEC = 30

function Fail($msg) {
    Write-Error $msg
    exit 1
}

# --- 1. Generate BSP (xsct) ---------------------------------------------
# Start from a clean workspace every time -- xsct's "platform create" fails
# if a platform with the same name already exists in the target directory,
# and this way the script is repeatable (important for CI, where the
# previous run's leftovers shouldn't matter).
if (Test-Path $WORKSPACE) {
    Remove-Item -Recurse -Force $WORKSPACE
}

$bspScript = @"
platform create -name gemm_ps_pl_platform -hw $XSA -os standalone -proc ps7_cortexa9_0 -out $WORKSPACE
setws $WORKSPACE
platform active gemm_ps_pl_platform
domain active standalone_domain
bsp config stdin ps7_uart_0
bsp config stdout ps7_uart_0
platform generate
exit
"@
$bspScriptPath = ".\_bsp_gen.tcl"
Set-Content -Path $bspScriptPath -Value $bspScript
& $XSCT $bspScriptPath

$bspInclude = "$WORKSPACE\gemm_ps_pl_platform\ps7_cortexa9_0\standalone_domain\bsp\ps7_cortexa9_0\include"
$bspLib     = "$WORKSPACE\gemm_ps_pl_platform\ps7_cortexa9_0\standalone_domain\bsp\ps7_cortexa9_0\lib"

# xsct's own exit code doesn't reliably reflect internal Tcl errors, so
# verify the actual BSP output exists instead of trusting $LASTEXITCODE.
if (-not (Test-Path "$bspLib\libxil.a")) {
    Fail "BSP generation failed: $bspLib\libxil.a was not created. Check the xsct output above for the real error."
}

# --- 2. Compile software (arm-none-eabi-gcc) ----------------------------
$commonFlags = "-mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard"

& $GCC -c $commonFlags.Split(" ") -I $bspInclude .\ps_pl\tier3\main.c -o .\ps_pl\tier3\main.o
if ($LASTEXITCODE -ne 0) { Fail "Compiling main.c failed" }

& $GCC -c $commonFlags.Split(" ") -I $bspInclude .\ps_pl\tier3\gemm.c -o .\ps_pl\tier3\gemm.o
if ($LASTEXITCODE -ne 0) { Fail "Compiling gemm.c failed" }

$linkArgs = @(
    "-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-nostartfiles",
    "-Wl,-T", "-Wl,.\ps_pl\tier3\lscript.ld",
    "-L", $bspLib,
    "-o", ".\ps_pl\tier3\main.elf",
    ".\ps_pl\tier3\main.o", ".\ps_pl\tier3\gemm.o",
    "-Wl,--start-group", "-lxil", "-lgcc", "-lc", "-Wl,--end-group"
)
& $GCC @linkArgs
if ($LASTEXITCODE -ne 0) { Fail "Linking main.elf failed" }

# --- 3. Auto-detect and open the serial port BEFORE programming, so no --
#        output is lost. The Pynq-Z1's FTDI chip shows up as "USB Serial
#        Port (COMx)" -- COM number differs per machine/USB port, so we
#        look it up instead of hardcoding it.
$comDevice = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match "USB Serial Port \((COM\d+)\)" } | Select-Object -First 1
if (-not $comDevice) {
    Fail "No 'USB Serial Port (COMx)' device found -- is the Pynq-Z1 connected and powered on?"
}
$SERIAL_PORT_NAME = $matches[1]
Write-Host "[INFO] Using serial port: $SERIAL_PORT_NAME"

$port = New-Object System.IO.Ports.SerialPort $SERIAL_PORT_NAME, 115200, "None", 8, "One"
try {
    $port.Open()
} catch {
    Fail "Could not open serial port $SERIAL_PORT_NAME : $_"
}

# --- 4. Program the board and run (xsct, background process) -----------
$bitFile = Get-ChildItem -Path .\vivado_prj -Recurse -Filter "*.bit" | Select-Object -First 1 -ExpandProperty FullName
$ps7Init = Get-ChildItem -Path $WORKSPACE -Recurse -Filter "ps7_init.tcl" | Select-Object -First 1 -ExpandProperty FullName
if (-not $bitFile) { Fail "No .bit file found under vivado_prj" }
if (-not $ps7Init) { Fail "ps7_init.tcl not found under $WORKSPACE" }

# Same Tcl-escape issue as above: convert to forward slashes before
# embedding in the generated .tcl script (e.g. "\v" in "\vivado_prj" would
# otherwise be silently swallowed as a Tcl vertical-tab escape).
$bitFileTcl = $bitFile -replace '\\', '/'
$ps7InitTcl = $ps7Init -replace '\\', '/'

$runScript = @"
connect
targets -set -filter {name =~ "APU*"}
rst -system
fpga $bitFileTcl
source $ps7InitTcl
ps7_init
ps7_post_config
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
dow ./ps_pl/tier3/main.elf
con
exit
"@
$runScriptPath = ".\_run.tcl"
Set-Content -Path $runScriptPath -Value $runScript
$xsctProc = Start-Process -FilePath $XSCT -ArgumentList $runScriptPath -PassThru -NoNewWindow

# --- 5. Capture UART output for a fixed window --------------------------
$output = ""
$deadline = (Get-Date).AddSeconds($SERIAL_TIMEOUT_SEC)
while ((Get-Date) -lt $deadline) {
    $chunk = $port.ReadExisting()
    if ($chunk) { $output += $chunk; Write-Host -NoNewline $chunk }
    if ($output -match "OVERALL (PASS|FAIL)") { break }
    Start-Sleep -Milliseconds 200
}

$port.Close()
if (-not $xsctProc.HasExited) { Stop-Process -Id $xsctProc.Id -Force }
Remove-Item $bspScriptPath, $runScriptPath -ErrorAction SilentlyContinue

# --- 6. Check the result --------------------------------------------------
if ($output -match "OVERALL PASS") {
    Write-Host "[TEST] OVERALL PASS"
    exit 0
} elseif ($output -match "OVERALL FAIL") {
    Write-Host "[TEST] OVERALL FAIL"
    exit 1
} else {
    Fail "No OVERALL PASS/FAIL found in UART output within ${SERIAL_TIMEOUT_SEC}s -- test suite likely hung or serial port/wiring issue"
}
