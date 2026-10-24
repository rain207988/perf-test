# perf-test —— demo-mall 性能压测工程

> 一句话：用 JMeter 对 demo-mall 做基准/负载/压力三段式压测，量化 Flask dev server 与 waitress 的真实差距，并沉淀一套"脚本-调度-解析"的可复用压测工程。

## 目录结构

```
perf-test/
├── README.md                  # 本文件：怎么装、怎么跑、怎么读结果
├── .gitignore                 # results/ report/ 等运行产物不入库
├── scenarios/
│   ├── goods_list.jmx         # 核心查询接口压测（${__P()} 全参数化）
│   └── order_flow.jmx         # 混合业务链路：注册→登录→加购→下单→支付（token/order_id 关联）
├── data/
│   └── users.csv              # CSV 数据集示例（lemon/test 两个种子账号）
├── scripts/
│   ├── run_stair.sh           # 阶梯压测调度（Git Bash）
│   ├── run_stair.bat          # 阶梯压测调度（Windows CMD）
│   └── analyze_jtl.py         # jtl 解析：TPS/P50/P90/P95/P99/错误率 markdown 表格
├── docs/
│   ├── 00-项目总览.md
│   ├── 01-压测场景设计.md
│   ├── 02-JMeter脚本详解.md
│   ├── 03-执行与报告解读.md
│   ├── 04-压测实测报告.md     # ★ 本机实测数据（2026-10-25）
│   └── 05-常见坑与面试.md
├── results/                   # 运行产物：*.jtl（.gitignore）
└── report/                    # 运行产物：HTML dashboard（.gitignore）
```

## 环境准备（一次性）

JMeter 不需要安装器，解压即用。**不要**把它加进系统 PATH（避免污染全局环境），用的时候临时加：

```bash
# 1. 下载 apache-jmeter-5.6.3.zip（需要代理时加 -x http://127.0.0.1:7897）
#    https://dlcdn.apache.org/jmeter/binaries/apache-jmeter-5.6.3.zip
#    （若该版本已从 dlcdn 下架，用 https://archive.apache.org/dist/jmeter/binaries/）
# 2. 解压到 C:\Users\37535\tools\apache-jmeter-5.6.3
# 3. 临时加 PATH（只对当前 Git Bash 会话生效）
export PATH="/c/Users/37535/tools/apache-jmeter-5.6.3/bin:$PATH"
jmeter --version    # 应打印 "Apache JMeter 5.6.3"
```

Windows CMD 下临时加 PATH：`set PATH=C:\Users\37535\tools\apache-jmeter-5.6.3\bin;%PATH%`

要求：JDK 17（本机已装 java 17.0.12）、Python 3.8+（analyze_jtl.py 用）。

## 快速开始

```bash
# 0. 起被测系统（另一个终端）
cd /d/软件测试/demo-mall && python run.py --port 5002            # dev 模式
# 或 python run.py --port 5002 --mode prod                        # waitress 8 线程

# 1. 冒烟：10 并发压 20 秒，先确认脚本和服务都正常
cd /d/软件测试/perf-test
jmeter -n -t scenarios/goods_list.jmx -Jthreads=10 -Jrampup=5 -Jduration=20 \
       -Jport=5002 -l results/smoke.jtl -e -o report/smoke

# 2. 阶梯压测：50/100/150 三档自动跑（MODE=prod 换打 prod 模式）
bash scripts/run_stair.sh                 # dev
MODE=prod bash scripts/run_stair.sh       # prod

# 3. 汇总解析 jtl（纯标准库）
python scripts/analyze_jtl.py results/goods_dev_t*.jtl

# 4. 混合业务链路（先 reset 数据！下单扣库存、注册写用户）
curl -X POST http://127.0.0.1:5002/api/test/reset -H "X-Test-Key: mall-test-key"
jmeter -n -t scenarios/order_flow.jmx -Jthreads=10 -Jrampup=5 -Jloops=6 -Jthink_time=800 \
       -Jport=5002 -l results/order_flow.jtl -e -o report/order_flow
```

看报告：浏览器打开 `report/smoke/index.html`（JMeter HTML dashboard）。

## 关键约定

- **端口只用 5002**：5000/5001 是其他工程的被测实例。且注意：三个端口的 mall 共享同一个 `demo_mall.db` 文件，任何一方调 `/api/test/reset` 都会清掉全部实例的数据（踩过的真实坑，见 docs/05）。
- **非 GUI 运行**：`-n -t -l -e -o` 四件套，GUI 只用来编辑脚本。
- **压测前后 reset**：`curl -X POST http://127.0.0.1:5002/api/test/reset -H "X-Test-Key: mall-test-key"`。
- **实测结论速览**（详见 docs/04-压测实测报告.md，2026-10-25 实测）：
  - dev 模式 10 并发冒烟：TPS 601.8、P95 23ms、错误率 0；
  - dev 模式 ≥50 并发：被测端每请求 `Connection: close` 触发压测机临时端口耗尽，错误率 64%~99%，数据不可信；
  - prod 模式（waitress keep-alive）：50 并发 TPS 1100.4 / P95 62ms，100 并发 958.0 / 144ms，150 并发 931.6 / 142ms，全程 0 错误；
  - order_flow 混合链路：310 请求 0 错误，并顺带发现被测系统 order_no 高并发碰撞缺陷（详见 docs/04 第 4 节）。

## 进一步阅读

按顺序读 docs/00 → 01 → 02 → 03 → 04 → 05，每篇都带"怎么实现、为什么这样设计、怎么验证、常见坑、面试怎么讲"。
