@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

REM =======================================================================
REM Path Configuration
REM =======================================================================
set ROOT_PATH=%~dp0..
for %%i in ("%ROOT_PATH%") do set ROOT_PATH=%%~fi

REM =======================================================================
REM Project
REM =======================================================================
set PROJECT=KraftonEngine

set BUILD_PATH=%ROOT_PATH%\%PROJECT%\Bin\Debug
set EXE=%BUILD_PATH%\%PROJECT%.exe
set PDB=%BUILD_PATH%\%PROJECT%.pdb
set SRCINFO=%BUILD_PATH%\srcsrv.txt
set TEMP_RAW_LIST=%BUILD_PATH%\raw_files.txt
set PS1=%~dp0gen_srcsrv.ps1

REM =======================================================================
REM Servers
REM =======================================================================
set SOURCE_SERVER=\\172.21.10.44\sources
set SYMBOL_SERVER=\\172.21.10.44\symbols

REM =======================================================================
REM Tools
REM =======================================================================
set SDK_TOOLS=C:\Program Files (x86)\Windows Kits\10\Debuggers\x64
set SRCSRV_TOOLS=%SDK_TOOLS%\srcsrv

echo =========================================
echo 0. Check files
echo =========================================

if not exist "%PDB%" (
    echo [ERROR] PDB not found: %PDB%
    exit /b 1
)
if not exist "%PS1%" (
    echo [ERROR] gen_srcsrv.ps1 not found: %PS1%
    exit /b 1
)
if not exist "%EXE%" (
    echo [ERROR] EXE not found: %EXE%
    echo [ERROR] EXE is required to extract GUID.
    exit /b 1
)

REM =======================================================================
REM 0-1. Extract PDB GUID via PowerShell (cv info 방식)
REM =======================================================================
echo =========================================
echo 0-1. Extract PDB GUID
echo =========================================

REM PowerShell에서 PDB 바이너리를 직접 읽어 GUID 추출
REM PDB7.0 포맷: offset 32부터 슈퍼블록, GUID는 고정 위치에 존재
REM 실패 시 타임스탬프(wmic 없이 Get-Date) 사용
for /f "usebackq delims=" %%G in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try {" ^
    "  $b = [IO.File]::ReadAllBytes('%PDB%');" ^
    "  $magic = [Text.Encoding]::ASCII.GetString($b[0..28]);" ^
    "  if ($magic -notlike 'Microsoft C/C++*') { throw 'bad magic' }" ^
    "  $pageSize  = [BitConverter]::ToInt32($b, 32);" ^
    "  $rootPage  = [BitConverter]::ToInt32($b, 40);" ^
    "  $rootOff   = $rootPage * $pageSize;" ^
    "  $numStream = [BitConverter]::ToInt32($b, $rootOff);" ^
    "  $pdbOff    = $rootOff + 4 + $numStream * 4 + 4;" ^
    "  $guidBytes = $b[$pdbOff..($pdbOff+15)];" ^
    "  $guid = [guid]$guidBytes;" ^
    "  Write-Output $guid.ToString('N').ToUpper()" ^
    "} catch {" ^
    "  Write-Output (Get-Date -Format 'yyyyMMdd_HHmmss')" ^
    "}"`) do set BUILD_GUID=%%G

echo [INFO] Build GUID / Key: !BUILD_GUID!

if "!BUILD_GUID!"=="" (
    echo [ERROR] Failed to generate GUID key.
    exit /b 1
)

REM =======================================================================
REM 1. Copy Source Files to Versioned Folder
REM =======================================================================
echo =========================================
echo 1. Copy Source to Source Server [!BUILD_GUID!]
echo =========================================

set VERSIONED_SRC=%SOURCE_SERVER%\%PROJECT%\!BUILD_GUID!

REM EXE/PDB 복사
xcopy "%EXE%" "!VERSIONED_SRC!\Bin\" /Y /I
xcopy "%PDB%" "!VERSIONED_SRC!\Bin\" /Y /I

REM 소스 복사
xcopy "%ROOT_PATH%\%PROJECT%\*.cpp"        "!VERSIONED_SRC!\"              /Y /D /I
xcopy "%ROOT_PATH%\%PROJECT%\*.h"          "!VERSIONED_SRC!\"              /Y /D /I
xcopy "%ROOT_PATH%\%PROJECT%\Source\*"     "!VERSIONED_SRC!\Source\"       /E /I /Y /D
xcopy "%ROOT_PATH%\%PROJECT%\Shaders\*"    "!VERSIONED_SRC!\Shaders\"      /E /I /Y /D
xcopy "%ROOT_PATH%\%PROJECT%\ThirdParty\*" "!VERSIONED_SRC!\ThirdParty\"   /E /I /Y /D

if errorlevel 1 (echo [ERROR] xcopy failed & exit /b 1)

REM =======================================================================
REM 2. Generate srcsrv.txt pointing to versioned folder
REM =======================================================================
echo =========================================
echo 2. Generating Source Index (GUID: !BUILD_GUID!)
echo =========================================

"%SRCSRV_TOOLS%\srctool.exe" -r "%PDB%" > "%TEMP_RAW_LIST%"

echo [DEBUG] raw_files.txt 앞 5줄:
for /f "tokens=*" %%a in ('type "%TEMP_RAW_LIST%" ^| findstr /n "." ^| findstr /b "[1-5]:"') do echo %%a

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" ^
    -Project      "%PROJECT%"         ^
    -SourceServer "%SOURCE_SERVER%"   ^
    -BuildGuid    "!BUILD_GUID!"      ^
    -RawList      "%TEMP_RAW_LIST%"   ^
    -SrcInfo      "%SRCINFO%"

if errorlevel 1 (
    echo [ERROR] No source files indexed or PowerShell failed.
    exit /b 1
)

if exist "%TEMP_RAW_LIST%" del "%TEMP_RAW_LIST%"

REM PDB에 소스 인덱스 주입
echo [INFO] Running pdbstr...
"%SRCSRV_TOOLS%\pdbstr.exe" -w -p:"%PDB%" -s:srcsrv -i:"%SRCINFO%"
if errorlevel 1 (echo [ERROR] pdbstr injection failed & exit /b 1)

REM =======================================================================
REM 3. Upload Indexed PDB and EXE to Symbol Server
REM =======================================================================
echo =========================================
echo 3. Upload to Symbol Server
echo =========================================

set NEED_PDB_UPLOAD=1
if exist "%SYMBOL_SERVER%\000Admin\history.txt" (
    findstr /I /C:"\"%PROJECT%.pdb\"" "%SYMBOL_SERVER%\000Admin\history.txt" >nul 2>&1
    if !errorlevel! equ 0 (set NEED_PDB_UPLOAD=0)
)

if !NEED_PDB_UPLOAD! equ 0 (
    echo [SKIP] PDB already in Symbol Server.
) else (
    echo [UPLOAD] Uploading Indexed PDB...
    "%SDK_TOOLS%\symstore.exe" add /f "%PDB%" /s "%SYMBOL_SERVER%" /t "%PROJECT%"
    if !errorlevel! geq 1 (echo [ERROR] symstore PDB failed & exit /b 1)
)

if exist "%EXE%" (
    set NEED_EXE_UPLOAD=1
    if exist "%SYMBOL_SERVER%\000Admin\history.txt" (
        findstr /I /C:"\"%PROJECT%.exe\"" "%SYMBOL_SERVER%\000Admin\history.txt" >nul 2>&1
        if !errorlevel! equ 0 (set NEED_EXE_UPLOAD=0)
    )
    if !NEED_EXE_UPLOAD! equ 0 (
        echo [SKIP] EXE already in Symbol Server.
    ) else (
        echo [UPLOAD] Uploading EXE...
        "%SDK_TOOLS%\symstore.exe" add /f "%EXE%" /s "%SYMBOL_SERVER%" /t "%PROJECT%"
        if !errorlevel! geq 1 (echo [ERROR] symstore EXE failed & exit /b 1)
    )
)

REM =======================================================================
REM 4. Verify
REM =======================================================================
echo =========================================
echo 4. Verify PDB Indexing
echo =========================================

"%SRCSRV_TOOLS%\srctool.exe" "%PDB%"
"%SRCSRV_TOOLS%\pdbstr.exe" -r -p:"%PDB%" -s:srcsrv

echo =========================================
echo DONE  [GUID: !BUILD_GUID!]
echo =========================================
pause
endlocal