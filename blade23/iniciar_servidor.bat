@echo off
setlocal
cd /d "%~dp0"
set "BLADE23_FOLDER=%~dp0"
set "BLADE23_PY=py -3"
py -3 --version >nul 2>&1
if errorlevel 1 (
    python --version >nul 2>&1
    if errorlevel 1 (
        echo Instale Python 3.10 ou superior e marque Add Python to PATH.
        pause
        exit /b 1
    )
    set "BLADE23_PY=python"
)
echo Atualizando o servidor Blade 23...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $target=Join-Path $env:BLADE23_FOLDER 'blade23_server.py'; $temp=$target+'.download'; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri ('https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/blade23_server.py?v='+[DateTime]::UtcNow.Ticks) -OutFile $temp; Move-Item -LiteralPath $temp -Destination $target -Force } catch { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }; exit 1 }"
if errorlevel 1 (
    findstr /c:"--open-browser" "blade23_server.py" >nul 2>&1
    if errorlevel 1 (
        echo Nao consegui baixar o servidor atualizado. Confira a conexao com o GitHub.
        pause
        exit /b 1
    )
    echo Sem atualizacao agora. Usando a versao salva neste PC.
)
%BLADE23_PY% "blade23_server.py" --host 0.0.0.0 --port 8787 --open-browser
pause
