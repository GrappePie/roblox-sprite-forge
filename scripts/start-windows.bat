@echo off
setlocal
cd /d "%~dp0\.."
if not exist .env copy .env.example .env >nul
if not exist node_modules (
  echo Instalando dependencias...
  call npm ci || goto :error
)
call npm run doctor
if errorlevel 1 (
  echo.
  echo Corrige el diagnostico anterior y vuelve a ejecutar este archivo.
  pause
  exit /b 1
)
call npm start
goto :eof
:error
echo La instalacion fallo.
pause
exit /b 1
