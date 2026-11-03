@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================
echo   DBD RANKING - START LOCAL WEBSITE
echo ============================================
echo.
where npm >nul 2>nul
if errorlevel 1 (
  echo [ERROR] Node.js / npm was not found.
  echo Please install the Node.js LTS version from https://nodejs.org/
  echo Then close and reopen this file.
  pause
  exit /b 1
)
if not exist node_modules (
  echo Installing project packages. This may take a few minutes...
  call npm install
  if errorlevel 1 (
    echo.
    echo [ERROR] npm install failed. Check your internet connection and try again.
    pause
    exit /b 1
  )
)
echo.
echo Starting DBD Ranking. Keep this window open while using the website.
echo Your browser should open at http://localhost:5173
call npm run dev -- --open
pause
