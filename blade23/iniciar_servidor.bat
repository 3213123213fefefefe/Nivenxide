@echo off
cd /d "%~dp0"
py -3 --version >nul 2>&1
if errorlevel 1 (
    python --version >nul 2>&1
    if errorlevel 1 (
        echo Instale Python 3.10 ou superior e marque a opcao Add Python to PATH.
        pause
        exit /b 1
    )
    python blade23_server.py --host 0.0.0.0 --port 8787
) else (
    py -3 blade23_server.py --host 0.0.0.0 --port 8787
)
pause
