@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM ============================================================
REM Загрузка основной конфигурации из файла .cf в базу с обновлением БД
REM ВНИМАНИЕ: полностью перезаписывает конфигурацию базы
REM
REM Параметры:
REM   %1 - путь к файлу .cf
REM   %2 - (опционально) "skipdbupdate" для пропуска обновления БД
REM
REM По умолчанию после загрузки выполняется обновление конфигурации БД.
REM
REM Требует: .1c-devbase.bat в текущем каталоге
REM ============================================================

REM Загружаем настройки
if not exist ".1c-devbase.bat" (
    echo Ошибка: не найден .1c-devbase.bat в текущем каталоге
    echo Скопируйте .1c-devbase.bat.example в корень проекта как .1c-devbase.bat
    exit /b 1
)
call .\.1c-devbase.bat

if "%~1"=="" (
    echo Использование: load-cf.bat ^<CF_FILE^> [skipdbupdate]
    echo.
    echo Примеры:
    echo   Загрузка + обновление БД:      load-cf.bat "build\МояКонфигурация.cf"
    echo   Загрузка БЕЗ обновления БД:    load-cf.bat "build\МояКонфигурация.cf" skipdbupdate
    exit /b 1
)

set "CF_FILE=%~1"
set "SKIP_UPDATE=0"

if /i "%~2"=="skipdbupdate" (
    set "SKIP_UPDATE=1"
)

REM Определяем тип подключения: сервер или файловая база
if not "%ONEC_SERVER%"=="" (
    set "IB_PARAMS=/S "%ONEC_SERVER%\%ONEC_BASE%""
) else if not "%ONEC_FILEBASE_PATH%"=="" (
    set "IB_PARAMS=/F "%ONEC_FILEBASE_PATH%""
) else (
    echo Ошибка: не указан ни сервер ^(ONEC_SERVER^), ни путь к файловой базе ^(ONEC_FILEBASE_PATH^)
    exit /b 1
)

REM Формируем параметры авторизации
set "AUTH_PARAMS="
if not "%ONEC_USER%"=="" set AUTH_PARAMS=/N"%ONEC_USER%"
if not "%ONEC_PASSWORD%"=="" set AUTH_PARAMS=!AUTH_PARAMS! /P"%ONEC_PASSWORD%"

echo Загрузка конфигурации из файла...
echo   Источник: %CF_FILE%

REM Добавляем обновление БД если не указан skipdbupdate
set "UPDATE_PARAMS="
if "%SKIP_UPDATE%"=="0" (
    set "UPDATE_PARAMS=/UpdateDBCfg"
    echo   Обновление БД: да
) else (
    echo   Обновление БД: нет
)

"%ONEC_PATH%" DESIGNER !IB_PARAMS! !AUTH_PARAMS! /DisableStartupDialogs /LoadCfg "%CF_FILE%" !UPDATE_PARAMS!

if %ERRORLEVEL% equ 0 (
    echo Загрузка завершена успешно
) else (
    echo Ошибка загрузки
    exit /b 1
)

exit /b 0
