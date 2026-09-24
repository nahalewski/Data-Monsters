@echo off
rem Build every console target of the gen1recomp port from Windows.
rem
rem The build scripts are bash.  This wrapper runs them under WSL (preferred)
rem or Git Bash / MSYS2, whichever is installed, and leaves the results in
rem dist\ (dist\gen1recomp-ports.zip has everything that was built).
rem
rem Toolchains (install inside the same bash environment):
rem   PSP:     https://github.com/pspdev/pspdev   (or the pspdev/pspdev Docker image)
rem   PS Vita: https://github.com/vitasdk/vdpm
rem   PS3:     https://github.com/ps3dev/ps3toolchain
rem Missing toolchains are skipped, not failed.
setlocal
cd /d "%~dp0"

where wsl >nul 2>nul
if %errorlevel%==0 (
  echo Building with WSL...
  wsl bash -lc "cd \"$(wslpath -a '%cd%')\" && bash ./build_all.sh %*"
  goto :done
)

if exist "%ProgramFiles%\Git\bin\bash.exe" (
  echo Building with Git Bash...
  "%ProgramFiles%\Git\bin\bash.exe" -lc "cd '%cd:\=/%' && bash ./build_all.sh %*"
  goto :done
)

if exist "C:\msys64\usr\bin\bash.exe" (
  echo Building with MSYS2...
  set MSYSTEM=MINGW64
  "C:\msys64\usr\bin\bash.exe" -lc "cd '%cd:\=/%' && bash ./build_all.sh %*"
  goto :done
)

echo No bash found. Install WSL (wsl --install), Git for Windows, or MSYS2, then run this again.
exit /b 1

:done
echo.
echo Done. Output is in dist\ (dist\gen1recomp-ports.zip).
pause
