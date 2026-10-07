@echo off
rem Пересборка БД superbd и прогон тестов (Windows). Запуск: двойной щелчок или из cmd.
rem Нужен psql (PostgreSQL 18) и пароль postgres в %APPDATA%\postgresql\pgpass.conf (иначе psql спросит его сам).
rem Полный вывод — в build_and_test.log рядом со скриптом; в окне — результаты тестов.
rem Скрипты подаются на вход psql (а не -f), чтобы в сообщениях не было префикса «psql:файл:строка:».
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set PGCLIENTENCODING=UTF8
set "PSQL=psql"
where psql >nul 2>&1 || set "PSQL=%ProgramFiles%\PostgreSQL\18\bin\psql.exe"
set "LOG=%~dp0build_and_test.log"

echo == Сборка БД superbd (build.sql) ...
"%PSQL%" -U postgres -h localhost -d superbd -q -v ON_ERROR_STOP=1 < build.sql > "%LOG%" 2>&1
if errorlevel 1 (
  echo ОШИБКА СБОРКИ:
  type "%LOG%"
  goto :end
)
echo    готово
echo == Тесты (tests\run_all.sql) ...
pushd tests
"%PSQL%" -U postgres -h localhost -d superbd -q -v ON_ERROR_STOP=1 < run_all.sql >> "%LOG%" 2>&1
set RC=%errorlevel%
popd
findstr /C:"PASS" /C:"FAIL" /C:"== " "%LOG%"
echo.
for /f %%n in ('findstr /C:" PASS " "%LOG%" ^| find /c /v ""') do set NPASS=%%n
for /f %%n in ('findstr /C:" FAIL " "%LOG%" ^| find /c /v ""') do set NFAIL=%%n
if "%RC%"=="0" (echo ИТОГ: все тесты пройдены — PASS %NPASS%, FAIL %NFAIL%) else (echo ИТОГ: есть ошибки — PASS %NPASS%, FAIL %NFAIL%, подробности в build_and_test.log)
:end
echo.
pause
