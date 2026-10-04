@echo off
REM ============================================================
REM  OPTIONAL post-install step. NOT a build artifact.
REM
REM  DPAPI machine-key encryption is not portable: a config encrypted
REM  on the development machine CANNOT be decrypted anywhere else, so
REM  baking this into the build would break the application on a
REM  panel-provided or lab machine.
REM
REM  Run this ONLY on the machine that will actually run the demo,
REM  and only after confirming the app starts with a plaintext config.
REM
REM  The primary credential control is NOT this script -- it is the
REM  least-privilege cineflow_app login, which cannot read or write a
REM  single table directly even if the connection string is fully
REM  exposed. See DATA-CONTRACT.md section 8.
REM ============================================================

setlocal
set REGIIS=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe
set TARGET=%~dp0..\CineFlow.UI\bin\Debug

if not exist "%REGIIS%" (
    echo aspnet_regiis.exe not found. Skipping encryption.
    echo The application will run normally with a plaintext config.
    exit /b 0
)

echo Encrypting connectionStrings section for THIS MACHINE ONLY...
"%REGIIS%" -pef "connectionStrings" "%TARGET%" -prov DataProtectionConfigurationProvider

if errorlevel 1 (
    echo.
    echo Encryption failed. This is NOT a blocker -- run with the plaintext
    echo config. Least-privilege database permissions remain in force.
    exit /b 0
)

echo Done. NOTE: this config now works on this machine only.
endlocal
