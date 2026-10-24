@echo off
REM =============================================================================
REM run_stair.bat —— 阶梯压测调度脚本（Windows 批处理版，功能与 run_stair.sh 相同）
REM
REM 用法（CMD 或双击前先改参数）：
REM   scripts\run_stair.bat                          默认打 127.0.0.1:5002（dev 模式）
REM   set PORT=5002 && set MODE=prod && scripts\run_stair.bat
REM
REM 前提：被测服务已启动；JMeter 已解压（默认 C:\Users\37535\tools\apache-jmeter-5.6.3）
REM =============================================================================

REM ---- 可覆盖参数：用 set 变量传参，未设置时取默认值 --------------------------
if "%PORT%"==""      set PORT=5002
if "%HOSTT%"==""     set HOSTT=127.0.0.1
if "%MODE%"==""      set MODE=dev
if "%THREADS%"==""   set THREADS=50 100 150
if "%RAMPUP%"==""    set RAMPUP=10
if "%DURATION%"==""  set DURATION=30
if "%TEST_KEY%"==""  set TEST_KEY=mall-test-key
if "%JMETER_HOME%"=="" set JMETER_HOME=C:\Users\37535\tools\apache-jmeter-5.6.3

REM 临时把 JMeter 加进本会话 PATH（只在当前 CMD 窗口生效，不污染系统环境）
set "PATH=%JMETER_HOME%\bin;%PATH%"

REM 切到工程根目录（本脚本在 scripts\ 下）
cd /d "%~dp0.."

echo == 阶梯压测开始：MODE=%MODE% PORT=%PORT% 档位=[%THREADS%] rampup=%RAMPUP%s duration=%DURATION%s ==

for %%T in (%THREADS%) do call :run_tier %%T

echo == 压测完成，汇总结果 ==
python scripts\analyze_jtl.py results\goods_%MODE%_t*.jtl
echo HTML 报告目录：report\goods_%MODE%_t50 / t100 / t150（浏览器打开 index.html）
goto :eof

:run_tier
set T=%1
set JTL=results\goods_%MODE%_t%T%.jtl
set REPORT=report\goods_%MODE%_t%T%

REM JMeter 生成 HTML 报告要求 -o 目录不存在或为空，先清理旧产物
if exist "%REPORT%" rmdir /s /q "%REPORT%"
if exist "%JTL%"   del /q "%JTL%"

echo -- 档位 T=%T%：reset 数据 -^> 预热 -^> 压测 %DURATION%s --
curl -s -X POST "http://%HOSTT%:%PORT%/api/test/reset" -H "X-Test-Key: %TEST_KEY%" >nul
timeout /t 2 /nobreak >nul
curl -s "http://%HOSTT%:%PORT%/api/health" >nul

jmeter -n -t scenarios\goods_list.jmx ^
       -Jthreads=%T% -Jrampup=%RAMPUP% -Jduration=%DURATION% ^
       -Jhost=%HOSTT% -Jport=%PORT% ^
       -l "%JTL%" -e -o "%REPORT%"

REM 档位之间给服务端喘息时间
timeout /t 3 /nobreak >nul
goto :eof
