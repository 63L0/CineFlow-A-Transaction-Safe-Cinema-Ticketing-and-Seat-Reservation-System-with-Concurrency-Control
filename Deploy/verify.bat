@echo off
REM ============================================================
REM  CineFlow verification gate  (VG-01)
REM  Runs daily from Day 3. No day's work is done until green.
REM
REM  Each gate runs in its OWN sqlcmd connection with -b so that
REM  a leaked security context (EXECUTE AS) or a doomed transaction
REM  cannot affect the next gate. -b makes sqlcmd return a nonzero
REM  exit code on error, so failures actually stop the build
REM  instead of scrolling past.
REM ============================================================

setlocal
if "%SRV%"=="" set SRV=.\SQLEXPRESS
if "%DB%"==""  set DB=CineFlow
set ROOT=%~dp0..

echo.
echo ===== CineFlow verification gate =====
echo Server : %SRV%
echo Database: %DB%
echo.

echo [1/6] IS-01 static SQL scan (heuristic)...
sqlcmd -S %SRV% -d %DB% -b -I -i "%ROOT%\Tests\01_static_sql_scan.sql" || goto :fail

echo [2/6] IS-05 ownership, trusted constraints, contract drift...
sqlcmd -S %SRV% -d %DB% -b -I -i "%ROOT%\Tests\02_ownership_and_constraints.sql" || goto :fail

echo [3/6] IS-01 runtime proof - execute all procs as cineflow_app...
sqlcmd -S %SRV% -d %DB% -b -I -i "%ROOT%\Tests\03_smoke_as_app.sql" || goto :fail

echo [4/6] IS-02 security denials...
sqlcmd -S %SRV% -d %DB% -b -I -i "%ROOT%\Tests\04_security_denials.sql" || goto :fail

echo [5/6] Invariant tests - cancel, purge, payment, PC-01...
sqlcmd -S %SRV% -d %DB% -b -I -i "%ROOT%\Tests\05_invariants.sql" || goto :fail

echo [6/6] Concurrency suite (TC-CONC, TC-CANCEL-02, TC-PAY-06)...
REM Skipped automatically until the test project exists (Day 5+).
if exist "%ROOT%\CineFlow.Tests\bin\Debug\CineFlow.Tests.dll" (
    dotnet test "%ROOT%\CineFlow.Tests\CineFlow.Tests.csproj" --filter Category=Concurrency --nologo || goto :fail
) else (
    echo       - test project not built yet, skipping
)

echo.
echo ===== ALL GATES GREEN =====
endlocal
exit /b 0

:fail
echo.
echo ***** VERIFICATION FAILED - gate above did not pass *****
echo ***** Do not mark today's work complete.            *****
endlocal
exit /b 1
