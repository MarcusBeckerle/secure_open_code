@echo off
setlocal EnableDelayedExpansion

set "IMAGE=secure-opencode"
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

REM Directory: first argument or current directory
set "ROC_DIR=%~f1"
if "%ROC_DIR%"=="" set "ROC_DIR=%CD%"

REM Validate directory
if not exist "%ROC_DIR%\" (
    echo [soc] ERROR: Directory not found: %ROC_DIR%
    pause
    exit /b 1
)

echo.
echo [soc] Directory : %ROC_DIR%
echo [soc] Image     : %IMAGE%
echo.

REM ── Ensure Flask management server is running ─────────────────────────────
powershell -NoProfile -Command "try{(Invoke-WebRequest 'http://localhost:5000/' -UseBasicParsing -TimeoutSec 2)|Out-Null; exit 0}catch{exit 1}" >nul 2>&1
if errorlevel 1 (
    echo [soc] Management server not running. Starting it...
    if exist "%SCRIPT_DIR%\.venv\Scripts\python.exe" (
        start "SecureOpenCode Manager" /min "%SCRIPT_DIR%\.venv\Scripts\python.exe" "%SCRIPT_DIR%\app.py"
    ) else (
        echo [soc] No virtualenv found. Running full setup ^(this may take a minute^)...
        start "SecureOpenCode Manager" cmd /c "call \"%SCRIPT_DIR%\start-server.cmd\""
    )
    echo [soc] Waiting for server to be ready...
    powershell -NoProfile -Command "$i=0; while($i -lt 60){Start-Sleep -Milliseconds 500; $i++; try{$t=New-Object System.Net.Sockets.TcpClient; if($t.ConnectAsync('127.0.0.1',5000).Wait(300)){$t.Close(); Write-Host '[soc] Server ready.'; exit 0} $t.Close()}catch{}}; Write-Host '[soc] WARN: server timeout, continuing anyway.'"
)

REM ── Build Docker image if missing ─────────────────────────────────────────
docker image inspect %IMAGE% >nul 2>&1
if errorlevel 1 (
    echo [soc] Image not found. Building %IMAGE%...
    docker build -t %IMAGE% "%SCRIPT_DIR%\docker"
    if errorlevel 1 (
        echo [soc] ERROR: Image build failed.
        pause
        exit /b 1
    )
    echo.
)

REM ── Check for existing running container mapped to this directory ──────────
set "EXISTING="
for /f "delims=" %%i in ('docker ps --filter "label=opencode.managed=true" --format "{{.Names}}" 2^>nul') do (
    for /f "delims=" %%j in ('docker inspect "%%i" --format "{{index .Config.Labels \"opencode.host_path\"}}" 2^>nul') do (
        if "%%j"=="%ROC_DIR%" set "EXISTING=%%i"
    )
)

if not "!EXISTING!"=="" (
    echo [soc] Reusing existing session: !EXISTING!
    echo [soc] Type 'exit' in OpenCode to detach. Container stays running.
    echo.
    start "" "http://localhost:5000"
    docker exec -it -w /workspace "!EXISTING!" opencode
    set "CNAME=!EXISTING!"
    goto :done
)

REM ── Start new container ───────────────────────────────────────────────────
set "CNAME=soc-%RANDOM%%RANDOM%"

echo [soc] Starting session : !CNAME!
echo [soc] Type 'exit' in OpenCode to detach. Container stays running.
echo.

docker run -d ^
    -v "%ROC_DIR%:/workspace" ^
    --label opencode.managed=true ^
    --label "opencode.host_path=%ROC_DIR%" ^
    --name "!CNAME!" ^
    %IMAGE% sleep infinity >nul
if errorlevel 1 (
    echo [soc] ERROR: Failed to start container.
    pause
    exit /b 1
)

start "" "http://localhost:5000"
docker exec -it -w /workspace "!CNAME!" opencode

:done
echo.
echo [soc] OpenCode exited. Session container is still running.
echo [soc] Reconnect : docker exec -it -w /workspace !CNAME! opencode
echo [soc] Stop      : docker stop !CNAME! ^&^& docker rm !CNAME!
echo [soc] Web UI    : http://localhost:5000
echo.
