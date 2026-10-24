#!/usr/bin/env bash
# =============================================================================
# run_stair.sh —— 阶梯压测（Staircase Load Test）调度脚本
#
# 作用：把 goods_list.jmx 按三档并发（50/100/150）顺序压一遍，
#       每档独立产出 jtl 结果文件与 HTML 报告目录，最后调 analyze_jtl.py 汇总。
#
# 用法（Git Bash）：
#   bash scripts/run_stair.sh                          # 默认打 127.0.0.1:5002（dev 模式）
#   PORT=5002 MODE=prod bash scripts/run_stair.sh      # 指定端口/档位标记
#   THREADS="30 60 90" DURATION=20 bash scripts/run_stair.sh   # 自定义阶梯
#
# 前提：
#   1. 被测服务已按对应模式启动（dev: python run.py --port 5002
#      / prod: python run.py --port 5002 --mode prod）
#   2. JMETER_HOME 已设或使用默认安装路径
# =============================================================================
set -euo pipefail

# ---- 可覆盖参数（环境变量传参，见上方用法） --------------------------------
PORT="${PORT:-5002}"                                  # 被测服务端口
HOSTT="${HOSTT:-127.0.0.1}"                           # 被测服务地址
MODE="${MODE:-dev}"                                   # 档位标记：dev / prod，用于命名产物
THREADS="${THREADS:-50 100 150}"                      # 阶梯档位（空格分隔）
RAMPUP="${RAMPUP:-10}"                                # 每档 RampUp 秒数
DURATION="${DURATION:-30}"                            # 每档持续秒数
TEST_KEY="${TEST_KEY:-mall-test-key}"                 # /api/test/reset 的钥匙
JMETER_HOME="${JMETER_HOME:-/c/Users/37535/tools/apache-jmeter-5.6.3}"

# JMeter 不在 PATH 里时临时补上（不写进 ~/.bashrc，不污染全局环境）
export PATH="$JMETER_HOME/bin:$PATH"

# 切到工程根目录（脚本位于 scripts/ 下），保证 jmx/jtl/report 的相对路径一致
cd "$(dirname "$0")/.."

echo "== 阶梯压测开始：MODE=$MODE PORT=$PORT 档位=[$THREADS] rampup=${RAMPUP}s duration=${DURATION}s =="

for T in $THREADS; do
  JTL="results/goods_${MODE}_t${T}.jtl"
  REPORT="report/goods_${MODE}_t${T}"

  # JMeter 生成 HTML 报告要求 -o 指向"不存在或为空"的目录，先清理旧产物
  rm -rf "$REPORT"
  rm -f  "$JTL"

  # 每档之前 reset 种子数据 + 稍等端口空闲：
  # 查询场景虽然只读，但统一 reset 能保证"每档从同一世界状态出发"，对比才公平
  echo "-- 档位 T=$T：reset 数据 -> 预热 -> 压测 ${DURATION}s --"
  curl -s -X POST "http://${HOSTT}:${PORT}/api/test/reset" -H "X-Test-Key: ${TEST_KEY}" > /dev/null
  sleep 2
  curl -s "http://${HOSTT}:${PORT}/api/health" > /dev/null   # 预热一次，避免首请求冷启动计入

  jmeter -n -t scenarios/goods_list.jmx \
         -Jthreads="$T" -Jrampup="$RAMPUP" -Jduration="$DURATION" \
         -Jhost="$HOSTT" -Jport="$PORT" \
         -l "$JTL" -e -o "$REPORT"

  # 档位之间给服务端喘息时间，让连接队列排空，避免上一档余压污染下一档
  sleep 3
done

echo "== 压测完成，汇总结果 =="
python scripts/analyze_jtl.py results/goods_${MODE}_t*.jtl
echo "HTML 报告目录：report/goods_${MODE}_t50 / t100 / t150（浏览器打开 index.html）"
