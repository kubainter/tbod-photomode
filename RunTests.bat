@echo off
setlocal
set "PATH=%LOCALAPPDATA%\Programs\Lua\bin;%ProgramFiles%\Lua;%PATH%"
cd /d "%~dp0"
lua Tests\run_all.lua
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Tests FAILED!
    exit /b %ERRORLEVEL%
)
echo.
echo All tests PASSED!
