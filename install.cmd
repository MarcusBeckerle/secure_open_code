@echo off
setlocal EnableDelayedExpansion

set "INSTALL_DIR=%~dp0"
if "!INSTALL_DIR:~-1!"=="\" set "INSTALL_DIR=!INSTALL_DIR:~0,-1!"

echo.
echo   SecureOpenCode - Install
echo   ==========================
echo.
echo   Install dir : !INSTALL_DIR!
echo.

REM ── Prerequisites ────────────────────────────────────────────────────────────
where docker >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker not found. Install Docker Desktop: https://docker.com
    pause & exit /b 1
)
for /f "delims=" %%v in ('docker --version 2^>nul') do echo [+] %%v

REM Resolve Python 3.10+ via py launcher, skip non-dev pythons
set "PY="
where py >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do set "PY=%%i"
)
REM Fallback: walk PATH entries; skip Inkscape/system pythons
if "!PY!"=="" (
    for /f "delims=" %%i in ('where python 2^>nul') do (
        if "!PY!"=="" (
            echo %%i | findstr /i "inkscape windowsapps" >nul 2>&1
            if errorlevel 1 set "PY=%%i"
        )
    )
)
if "!PY!"=="" (
    echo [ERROR] Python 3.10+ not found. Install from https://python.org
    pause & exit /b 1
)
for /f "delims=" %%v in ('"!PY!" --version 2^>nul') do echo [+] %%v ^(%%PY%%^)

REM ── Add project directory to user PATH (no admin required) ────────────────────
echo.
echo [+] Adding to user PATH...
set "PSDIR=!INSTALL_DIR!"
powershell -NoProfile -Command ^
    "$dir=$env:PSDIR; $p=[Environment]::GetEnvironmentVariable('PATH','User'); if(-not $p){$p=''}; $parts=$p -split ';' | Where-Object{$_ -ne ''}; if($parts -contains $dir){ Write-Host '[=] Already in user PATH.' } else { [Environment]::SetEnvironmentVariable('PATH',($parts+$dir -join ';'),'User'); Write-Host '[+] Added to user PATH.' }"

REM Activate in current session immediately
set "PATH=!PATH!;!INSTALL_DIR!"
echo [+] Active in this session.

REM ── Python virtual environment ────────────────────────────────────────────────
echo.
echo [+] Setting up Python environment...
REM Stop any running server that might be locking venv files
taskkill /f /im python.exe >nul 2>&1
taskkill /f /im python3.exe >nul 2>&1
REM Remove broken/stale venv if it exists
if exist "!INSTALL_DIR!\.venv" (
    rmdir /s /q "!INSTALL_DIR!\.venv" >nul 2>&1
)
"!PY!" -m venv "!INSTALL_DIR!\.venv"
if errorlevel 1 (
    echo [ERROR] Failed to create virtual environment.
    pause & exit /b 1
)
call "!INSTALL_DIR!\.venv\Scripts\activate.bat"
python -m pip install -q --upgrade pip
pip install -q --upgrade -r "!INSTALL_DIR!\requirements.txt"
if errorlevel 1 (
    echo [ERROR] Failed to install Python dependencies.
    pause & exit /b 1
)
echo [+] Python dependencies installed.

REM ── Build Docker image ────────────────────────────────────────────────────────
echo.
docker image inspect secure-opencode >nul 2>&1
if errorlevel 1 (
    echo [+] Building Docker image secure-opencode ^(first time, takes ~1 min^)...
    docker build -t secure-opencode "!INSTALL_DIR!\docker"
    if errorlevel 1 (
        echo [WARN] Image build failed. Open the web UI later and click "Build Image".
    ) else (
        echo [+] Docker image built.
    )
) else (
    echo [=] Docker image already built.
)

REM ── Done ──────────────────────────────────────────────────────────────────────
echo.
echo   Done! Open a new terminal window, then:
echo.
echo     soc                        Run OpenCode in current directory
echo     soc C:\path\to\project     Run OpenCode in a specific directory
echo     start-server.cmd           Open the management web UI only
echo.
echo   NOTE: New terminal required for PATH changes to apply.
echo.
pause
