@echo off
rem bench.cmd - start de Windows-benchmark zonder Python.
rem Gebruik:  bench.cmd [label] [workdir] ["eigen commando"]
rem   bench.cmd                      label = computernaam
rem   bench.cmd ws1
rem   bench.cmd ws1 D:\werk "mvn -q package"
setlocal
set "ARGS="
if not "%~1"=="" set "ARGS=-Label "%~1""
if not "%~2"=="" set "ARGS=%ARGS% -WorkDir "%~2""
if not "%~3"=="" set "ARGS=%ARGS% -Cmd "%~3""
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bench.ps1" %ARGS%
endlocal
