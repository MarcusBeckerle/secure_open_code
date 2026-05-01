@echo off
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PORT=5000"

echo.
echo   SecureOpenCode Management Server
echo   ==================================
echo.

REM Resolve Python: prefer py launcher (3.10+), fall back to bare python
set "PY="
where py >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%i in ('py -3 -c "import sys;print(sys.executable)" 2^>nul') do set "PY=%%i"
)
if "%PY%"=="" (
    for /f "delims=" %%i in ('where python 2^>nul') do (
        if "%PY%"=="" set "PY=%%i"
    )
)
if "%PY%"=="" (
    echo [ERROR] Python 3.10+ not found. Install from https://python.org
    pause
    exit /b 1
)
echo [+] Using Python: %PY%

REM Create virtual environment if missing
if not exist "%SCRIPT_DIR%\.venv\Scripts\activate.bat" (
    echo [+] Creating virtual environment...
    "%PY%" -m venv "%SCRIPT_DIR%\.venv"
)

echo [+] Activating virtual environment...
call "%SCRIPT_DIR%\.venv\Scripts\activate.bat"

echo [+] Installing dependencies...
python -m pip install -q --upgrade pip
pip install -q --upgrade -r "%SCRIPT_DIR%\requirements.txt"

REM Build Docker image if not present
docker image inspect secure-opencode >nul 2>&1
if errorlevel 1 (
    echo [+] Building Docker image secure-opencode...
    docker build -t secure-opencode "%SCRIPT_DIR%\docker"
    if errorlevel 1 (
        echo [WARN] Docker image build failed. Build it later from the web UI.
    ) else (
        echo [+] Image built.
    )
)

REM Open browser after short delay
start "" /b cmd /c "timeout /t 2 >nul 2>&1 && start http://localhost:%PORT%"

echo [+] Starting server at http://localhost:%PORT%
echo     Press Ctrl+C to stop.
echo.

set PORT=%PORT%
python "%SCRIPT_DIR%\app.py"
