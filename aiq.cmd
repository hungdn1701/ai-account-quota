@echo off
rem aiq launcher for cmd.exe and PowerShell on Windows.
rem `aiq` itself is a bash script with no extension, which Windows cannot run
rem directly - it offers an "open with" dialog instead. This shim finds Git Bash
rem and hands the script to it.
rem
rem Note: it deliberately does NOT use `where bash`. On most Windows machines
rem that resolves to C:\Windows\System32\bash.exe, which is WSL - a different
rem filesystem, where the user's real ~/.claude and ~/.codex are not visible.
setlocal

set "AIQ_SCRIPT=%~dp0aiq"
if not exist "%AIQ_SCRIPT%" set "AIQ_SCRIPT=%~dp0aiq.sh"
if not exist "%AIQ_SCRIPT%" (
    echo aiq: cannot find the aiq script next to this launcher.>&2
    exit /b 1
)

if defined AIQ_BASH if exist "%AIQ_BASH%" goto :run

rem Git for Windows ships bash.exe next to its cmd\git.exe
for /f "delims=" %%G in ('where git 2^>nul') do (
    if exist "%%~dpG..\bin\bash.exe" (
        set "AIQ_BASH=%%~dpG..\bin\bash.exe"
        goto :run
    )
)

set "AIQ_BASH=%ProgramFiles%\Git\bin\bash.exe"
if exist "%AIQ_BASH%" goto :run

set "AIQ_BASH=%ProgramW6432%\Git\bin\bash.exe"
if exist "%AIQ_BASH%" goto :run

set "AIQ_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if exist "%AIQ_BASH%" goto :run

set "AIQ_BASH=%USERPROFILE%\scoop\apps\git\current\bin\bash.exe"
if exist "%AIQ_BASH%" goto :run

echo aiq: Git Bash not found.>&2
echo Install Git for Windows, or point AIQ_BASH at a bash.exe:>&2
echo   setx AIQ_BASH "C:\Program Files\Git\bin\bash.exe">&2
exit /b 1

:run
"%AIQ_BASH%" "%AIQ_SCRIPT%" %*
exit /b %ERRORLEVEL%
