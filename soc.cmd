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
powershell -NoProfile -Command "try{$t=New-Object Net.Sockets.TcpClient;$r=$t.ConnectAsync('127.0.0.1',5000).Wait(2000);$t.Close();if($r){exit 0}else{exit 1}}catch{exit 1}" >nul 2>&1
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

REM ── Check for existing container (running or stopped) for this directory ───
set "EXISTING="
set "EXISTING_STATUS="
for /f "delims=" %%i in ('docker ps -a --filter "label=opencode.managed=true" --format "{{.Names}}" 2^>nul') do (
    for /f "delims=" %%j in ('docker inspect "%%i" --format "{{index .Config.Labels \"opencode.host_path\"}}" 2^>nul') do (
        if "%%j"=="%ROC_DIR%" (
            set "EXISTING=%%i"
            for /f "delims=" %%s in ('docker inspect "%%i" --format "{{.State.Status}}" 2^>nul') do set "EXISTING_STATUS=%%s"
        )
    )
)

if not "!EXISTING!"=="" (
    if "!EXISTING_STATUS!"=="exited" (
        echo [soc] Restarting stopped session: !EXISTING!
        docker start "!EXISTING!" >nul
        if errorlevel 1 (
            echo [soc] ERROR: Failed to restart container.
            pause & exit /b 1
        )
    ) else (
        echo [soc] Reusing existing session: !EXISTING!
    )
    set "CNAME=!EXISTING!"
    echo [soc] Type 'exit' in OpenCode to detach. Container stays running.
    echo.
    start "" "http://localhost:5000"
    docker exec -it -w /workspace "!CNAME!" opencode
    goto :done
)

REM ── Create new session via Flask API (applies global + extra mappings) ─────
set "_SOC_DIR=%ROC_DIR%"
(echo $b = ConvertTo-Json @{path=$env:_SOC_DIR}) > "%TEMP%\_soc_session.ps1"
(echo try {) >> "%TEMP%\_soc_session.ps1"
(echo   $r = Invoke-RestMethod http://localhost:5000/api/sessions -Method POST -ContentType application/json -Body $b) >> "%TEMP%\_soc_session.ps1"
(echo   Write-Output $r.name) >> "%TEMP%\_soc_session.ps1"
(echo } catch { Write-Error $_ }) >> "%TEMP%\_soc_session.ps1"
for /f "delims=" %%r in ('powershell -NoProfile -File "%TEMP%\_soc_session.ps1" 2^>nul') do set "CNAME=%%r"
del "%TEMP%\_soc_session.ps1" >nul 2>&1

if "!CNAME!"=="" (
    echo [soc] ERROR: Failed to create session. Is the management server running?
    pause
    exit /b 1
)

echo [soc] Started session  : !CNAME!
echo [soc] Type 'exit' in OpenCode to detach. Container stays running.
echo.
start "" "http://localhost:5000"
docker exec -it -w /workspace "!CNAME!" opencode

:done
echo.
echo [soc] OpenCode exited. Session container is still running.
echo [soc] Reconnect : docker exec -it -w /workspace !CNAME! opencode
echo [soc] Web UI    : http://localhost:5000
echo.
