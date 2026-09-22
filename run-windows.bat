@echo off
setlocal
cd /d "%~dp0"

if "%~1"=="" goto usage
set "SONG=%~1"
set "PLAY_CALL=music:play(%SONG%)"
if "%~2"=="" goto selection_done
if /i "%~2"=="tracks" (
  set "PLAY_CALL=begin io:write(music:tracks(%SONG%)), io:nl(), ok end"
  goto selection_done
)
if /i "%~2"=="solo" (
  if "%~3"=="" goto usage
  set "PLAY_CALL=music:play(%SONG%, {solo, %~3})"
  goto selection_done
)
if /i "%~2"=="mute" (
  if "%~3"=="" goto usage
  set "PLAY_CALL=music:play(%SONG%, {mute, [%~3]})"
  goto selection_done
)
goto usage

:selection_done

set "REBAR=%CD%\rebar3"
if not exist "%REBAR%" (
  call "%CD%\bootstrap-rebar3-windows.bat"
  if errorlevel 1 exit /b 1
)

where escript.exe >nul 2>nul || (
  echo Error: escript.exe is not available on PATH.
  exit /b 1
)
where erl.exe >nul 2>nul || (
  echo Error: erl.exe is not available on PATH.
  exit /b 1
)

escript.exe "%REBAR%" compile
if errorlevel 1 exit /b 1

erl.exe -noshell -pa "%CD%\_build\default\lib\music\ebin" -eval "case %PLAY_CALL% of ok -> init:stop(0); Error -> io:format(standard_error, '~p~n', [Error]), init:stop(1) end."
exit /b %errorlevel%

:usage
echo Usage: %~nx0 SONG [tracks ^| solo TRACK ^| mute TRACK,TRACK,...]
exit /b 1
