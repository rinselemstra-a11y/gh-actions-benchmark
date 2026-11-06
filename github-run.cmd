@echo off
rem github-run.cmd - draait de benchmark op GitHub Actions zonder dat je iets
rem van GitHub Actions hoeft te weten. Doet achter elkaar:
rem   1. GitHub CLI (gh) installeren als die ontbreekt (via winget)
rem   2. inloggen bij GitHub (eenmalig, via de browser)
rem   3. deze map als prive-repository naar GitHub pushen (eerste keer aanmaken)
rem   4. de workflow starten en wachten tot de Mac-runners klaar zijn
rem   5. de resultaten downloaden naar .\results en vergelijken met jouw lokale
rem      result-*.json (als er een is en Python aanwezig is)
rem
rem Gebruik:  github-run.cmd ["eigen commando"]
rem   github-run.cmd
rem   github-run.cmd "mvn -q package"      (alleen zinvol als de repo dat kan bouwen)
rem
rem Repositorynaam aanpassen: zie REPO hieronder.
setlocal EnableDelayedExpansion
set "REPO=gh-actions-benchmark"
set "CMDARG=%~1"
cd /d "%~dp0"

echo.
echo === 1. GitHub CLI ===
where gh >nul 2>&1
if errorlevel 1 (
    echo gh is niet gevonden. Installeren via winget?
    choice /c JN /m "J=installeren, N=stoppen"
    if errorlevel 2 exit /b 1
    winget install --id GitHub.cli -e --source winget --accept-source-agreements --accept-package-agreements
    if errorlevel 1 (
        echo Installatie mislukt. Installeer handmatig: https://cli.github.com
        exit /b 1
    )
    echo.
    echo gh is geinstalleerd. Sluit dit venster, open een nieuw venster en start
    echo github-run.cmd opnieuw, zodat gh in het PATH zit.
    exit /b 0
)
gh --version | findstr /i "gh version"

echo.
echo === 2. Inloggen bij GitHub ===
gh auth status >nul 2>&1
if errorlevel 1 (
    echo Nog niet ingelogd. Er opent een browser; volg de stappen daar.
    gh auth login --web --git-protocol https
    if errorlevel 1 exit /b 1
)
for /f "tokens=*" %%u in ('gh api user -q .login') do set "GHUSER=%%u"
echo Ingelogd als %GHUSER%

echo.
echo === 3. Repository %GHUSER%/%REPO% ===
if not exist ".git" (
    git init -b main >nul
)
git add bench.py bench.sh bench.cmd bench.ps1 README.md .github github-run.cmd .gitignore
git diff --cached --quiet || git commit -q -m "benchmark bijgewerkt"
git remote get-url origin >nul 2>&1
if errorlevel 1 (
    echo Repository bestaat nog niet, aanmaken als prive-repository...
    gh repo create "%REPO%" --private --source . --remote origin --push
    if errorlevel 1 exit /b 1
) else (
    git push -q -u origin main
    if errorlevel 1 exit /b 1
)

echo.
echo === 4. Workflow starten ===
if "%CMDARG%"=="" (
    gh workflow run benchmark.yml --ref main
) else (
    gh workflow run benchmark.yml --ref main -f "cmd=%CMDARG%"
)
if errorlevel 1 (
    echo Starten mislukt. Bij een nieuwe repository duurt het soms even voordat
    echo GitHub de workflow kent; wacht een halve minuut en probeer opnieuw.
    exit /b 1
)
echo Wachten tot GitHub de run heeft aangemaakt...
timeout /t 10 /nobreak >nul
for /f "tokens=*" %%i in ('gh run list --workflow benchmark.yml --limit 1 --json databaseId -q ".[0].databaseId"') do set "RUNID=%%i"
if "%RUNID%"=="" (
    echo Geen run gevonden. Kijk op https://github.com/%GHUSER%/%REPO%/actions
    exit /b 1
)
echo Run %RUNID% gestart: https://github.com/%GHUSER%/%REPO%/actions/runs/%RUNID%
echo Dit duurt meestal 2 tot 5 minuten. Een macOS-runner kan lang in de wachtrij staan;
echo na 15 minuten zonder runner annuleert GitHub de job zelf. Dan later opnieuw proberen.
gh run watch %RUNID% --exit-status
set "RUNRC=%errorlevel%"

echo.
echo === 5. Resultaten ophalen ===
if exist results rmdir /s /q results
gh run download %RUNID% -D results
if errorlevel 1 (
    rem geen haakjes in deze tekst: een ) sluit het if-blok voortijdig ("was unexpected at this time")
    echo Downloaden mislukt, run status %RUNRC%.
    exit /b 1
)
set "FILES="
for /f "delims=" %%f in ('dir /b /s results\result-*.json') do set "FILES=!FILES! "%%f""
echo Gedownload:!FILES!

set "LOCAL="
for %%f in (result-*.json) do if "!LOCAL!"=="" set "LOCAL=%%f"
where python >nul 2>&1
if errorlevel 1 (
    echo Python niet gevonden; de JSON-bestanden staan in .\results
    exit /b 0
)
if "%LOCAL%"=="" (
    echo Geen lokaal result-*.json gevonden; draai eerst bench.cmd of bench.py.
    python bench.py --compare !FILES!
) else (
    echo Vergelijking met lokaal resultaat %LOCAL%:
    python bench.py --compare "%LOCAL%" !FILES!
)
endlocal
