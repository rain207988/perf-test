# JMeter 脚本详解（perf-test · 文档02）

> 一句话：逐个组件讲透两个 jmx——线程组怎么参数化、断言为什么必须加、关联（token/order_id）怎么做、CSV 数据集怎么配。

## 1. 在整个工程中的位置

```mermaid
flowchart LR
    A["run_stair.sh / 命令行<br/>-Jthreads=100 -Jport=5002"] -->|__P() 属性| B["goods_list.jmx"]
    A -->|__P() 属性| C["order_flow.jmx"]
    B --> D["results/*.jtl"]
    C --> D
    E["data/users.csv"] -.被引用(演示).-> B
    F["demo-mall API"] <-.HTTP.-> B
    F <-.HTTP.-> C
```

jmx 是 XML 文本文件，GUI 里拖的每个组件对应一段 XML。下面按"组件 → XML 关键片段 → 逐行解释"讲。

## 2. 涉及文件

| 文件 | 职责 |
|---|---|
| `scenarios/goods_list.jmx` | 查询场景：线程组、HTTP 默认值、取样器、JSON 断言、CSV 数据集、监听器 |
| `scenarios/order_flow.jmx` | 业务场景：Once Only、信息头管理器、JSON 提取器、JSR223 断言、定时器 |
| `data/users.csv` | CSV 数据集的数据文件 |

## 3. 如何实现（逐组件讲解）

### 3.1 线程组（Thread Group）——负载的发动机

```xml
<ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="线程组-商品列表查询" enabled="true">
  <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
  <elementProp name="ThreadGroup.main_controller" elementType="LoopController" ...>
    <boolProp name="LoopController.continue_forever">false</boolProp>
    <intProp name="LoopController.loops">-1</intProp>
  </elementProp>
  <stringProp name="ThreadGroup.num_threads">${__P(threads,50)}</stringProp>
  <stringProp name="ThreadGroup.ramp_time">${__P(rampup,10)}</stringProp>
  <boolProp name="ThreadGroup.scheduler">true</boolProp>
  <stringProp name="ThreadGroup.duration">${__P(duration,60)}</stringProp>
  <stringProp name="ThreadGroup.delay">0</stringProp>
</ThreadGroup>
```

逐项解释：
- `num_threads=${__P(threads,50)}`：虚拟用户数。`${__P(name, default)}` 是**属性函数**：取 JMeter 属性 `threads`，没有就用默认 50。命令行 `-Jthreads=100` 即改，**脚本文件一行不动**。
- `ramp_time=${__P(rampup,10)}`：10 秒内把线程匀速拉满。避免 50 个线程同一毫秒砸向服务器（那是 DoS 不是压测），也让"到达速率"可控。
- `loops=-1` + `scheduler=true` + `duration`：**不按圈数停，按墙钟时间停**。压测口径（TPS）只有在固定时长下才可比。
- `on_sample_error=continue`：单请求失败不断压。压测要的是"统计意义上的错误率"，一个错误就停跑会把整个档位报废。

order_flow 的线程组正好相反：`scheduler=false`，`loops=${__P(loops,15)}`——因为下单消耗库存，**圈数必须与种子库存匹配**（10 线程 × 15 圈 = 150 单 < 保温杯库存 200）。固定时长无限循环会把库存打穿，之后的"错误"全是 2002 库存不足，把真实性能数据淹没。**按圈数还是按时长，取决于被测接口是否消耗不可再生资源**——这是场景设计的第一个分叉点。

### 3.2 HTTP 请求默认值（ConfigTestElement）——环境配置集中营

```xml
<ConfigTestElement guiclass="HttpDefaultsGui" testclass="ConfigTestElement" testname="HTTP请求默认值" enabled="true">
  <stringProp name="HTTPSampler.domain">${__P(host,127.0.0.1)}</stringProp>
  <stringProp name="HTTPSampler.port">${__P(port,5002)}</stringProp>
  <stringProp name="HTTPSampler.protocol">http</stringProp>
  <stringProp name="HTTPSampler.connect_timeout">5000</stringProp>
  <stringProp name="HTTPSampler.response_timeout"></stringProp>
</ConfigTestElement>
```

- 作用域：同层级之后的所有取样器。取样器里只写相对路径 `/api/goods`，环境信息只在这一处维护。
- `connect_timeout=5000`：5 秒连不上按错误计（服务端 accept 队列打满时这是真实信号）。
- `response_timeout` **故意留空**（0=不限制）：不设人为超时，让过载时的真实等待时间如实进报告——超时上限是压测人员的假设，设了会把"慢"变成"错"，丢掉长尾证据。
- 换环境：`-Jhost=10.0.0.5 -Jport=8080`，或接 properties 文件，脚本零改动。

### 3.3 取样器（HTTPSamplerProxy）——一次请求的完整定义

```xml
<HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="GET /api/goods 商品列表" enabled="true">
  <elementProp name="HTTPsampler.Arguments" elementType="Arguments" ...>
    <collectionProp name="Arguments.arguments">
      <elementProp name="page" elementType="HTTPArgument">
        <boolProp name="HTTPArgument.always_encode">false</boolProp>
        <stringProp name="Argument.value">1</stringProp>
        <stringProp name="Argument.metadata">=</stringProp>
        <boolProp name="HTTPArgument.use_equals">true</boolProp>
        <stringProp name="Argument.name">page</stringProp>
      </elementProp>
      <!-- page_size=5 同构 -->
    </collectionProp>
  </elementProp>
  <stringProp name="HTTPSampler.path">/api/goods</stringProp>
  <stringProp name="HTTPSampler.method">GET</stringProp>
  <boolProp name="HTTPSampler.use_keepalive">true</boolProp>
</HTTPSamplerProxy>
```

- GET 参数放 `Arguments` 集合而不是拼在 path 里：GUI 可视、可参数化、可被录制器替换。
- `use_keepalive=true`：请求 `Connection: keep-alive`。**注意它只是"请求"复用，能不能复用由服务端决定**——实测 Werkzeug dev server 每响应都回 `Connection: close`，keep-alive 无效，这也是 dev 模式端口耗尽事故的根源（docs/04）。
- POST + JSON 体（order_flow 的登录取样器）：

```xml
<elementProp name="" elementType="HTTPArgument">
  <boolProp name="HTTPArgument.always_encode">false</boolProp>
  <stringProp name="Argument.value">{"username":"perf_${__threadNum}","password":"123456"}</stringProp>
  <stringProp name="Argument.metadata">=</stringProp>
</elementProp>
...
<boolProp name="HTTPSampler.postBodyRaw">true</boolProp>
```

`postBodyRaw=true` 表示整段 JSON 是原始 body；配合子节点信息头管理器设置 `Content-Type: application/json`。

### 3.4 断言——"压测 ≠ 打流量"的分水岭

JSON 断言（每个取样器都有）：

```xml
<JSONPathAssertion guiclass="JSONPathAssertionGui" testclass="JSONPathAssertion" testname="JSON断言：$.code == 0" enabled="true">
  <stringProp name="JSON_PATH">$.code</stringProp>
  <stringProp name="EXPECTED_VALUE">0</stringProp>
  <boolProp name="JSONVALIDATION">true</boolProp>
  <boolProp name="EXPECT_NULL">false</boolProp>
  <boolProp name="INVERT">false</boolProp>
  <boolProp name="ISREGEX">false</boolProp>
</JSONPathAssertion>
```

- demo-mall 的约定是**业务失败也返回 HTTP 200**（`{"code":1004,...}`），只看响应码错误率永远是 0。`$.code==0` 断言把业务失败变成采样失败，错误率才真实。
- `ISREGEX=false`：按"完全相等"比较。默认 true 会把期望值当正则（数字 0 恰好也能匹配意外内容，显式关掉最稳）。
- **踩过的坑（重要）**：JMeter 文档说"期望值留空 + 勾选校验 = 校验路径存在"，但 5.6.3 实测它会把路径值与空串做等值比较——`$.data.token` 返回正常 JWT 时**断言反而失败，且 failureMessage 为空**。所以工程里不做"存在性断言"，改用两层兜底：① 提取器设默认哨兵值 `TOKEN_NOT_FOUND`，② 下游步骤的 `$.code==0` 断言——token 没提取到，下一步必然 401，错误立刻暴露。

JSR223 断言（注册步骤的宽断言，保证脚本可重复执行）：

```groovy
// 注册可重复执行：首次 code=0；重复跑撞已存在 code=1003；其余都算失败
import groovy.json.JsonSlurper
def json = new JsonSlurper().parseText(prev.getResponseDataAsString())
if (!(json.code == 0 || json.code == 1003)) {
    AssertionResult.setFailure(true)
    AssertionResult.setFailureMessage('注册返回异常: ' + prev.getResponseDataAsString())
}
```

断言逻辑是"业务幂等"：reset 过的库注册成功（0），没 reset 的库返回已存在（1003），两者都放行，其余一律失败。这就是"脚本可重跑"的工程实现。

### 3.5 关联（Correlation）——token 与 order_id 两级传递

```xml
<JSONPostProcessor guiclass="JSONPostProcessorGui" testclass="JSONPostProcessor" testname="JSON提取器-data.token→${token}" enabled="true">
  <stringProp name="JSONPostProcessor.referenceNames">token</stringProp>
  <stringProp name="JSONPostProcessor.jsonPathExprs">$.data.token</stringProp>
  <stringProp name="JSONPostProcessor.match_numbers">1</stringProp>
  <stringProp name="JSONPostProcessor.defaultValues">TOKEN_NOT_FOUND</stringProp>
</JSONPostProcessor>
```

- `referenceNames`：提取结果存进线程局部变量 `token`，本线程后续请求用 `${token}` 引用——**线程间互不串号**（JMeter 变量天然线程隔离）。
- `defaultValues=TOKEN_NOT_FOUND`：提取失败时的哨兵值。没有它，变量为空会导致 `Authorization: Bearer `（带尾随空格）这种难排查的请求；有了它，下游 401 + 断言失败会明确暴露。
- 第二级关联：下单响应提取 `$.data.order_id` → `order_id`，支付取样器路径写 `/api/orders/${order_id}/pay`，完成"创建→引用"闭环。这就是**变量替换**式关联；如果要从响应里提取**一组**值逐个使用（比如批量下单），才轮到 ForEach 控制器 + `match_numbers=-1`（全部匹配）的组合。
- **踩过的坑**：JMeter 5.6 的 JSON 提取器 XML 属性名是**复数** `referenceNames`/`jsonPathExprs`（手写 JMX 用了单数时，JMeter 读不到值、提取器空转、`${token}` 全空、后续全 401，且日志几乎无提示）。从 GUI 录一份标准 jmx 对照属性名，是手写 JMX 的保命习惯。

### 3.6 Once Only 控制器 + 线程专属账号

```xml
<OnceOnlyController guiclass="OnceOnlyControllerGui" testclass="OnceOnlyController" testname="Once Only-注册线程专属账号（仅第1圈执行）" enabled="true"/>
```

- 语义：**每个线程只在第 1 圈执行其子节点一次**，后续圈跳过。
- 设计意图：10 个线程若共用 lemon 账号，10 份加购写进同一张购物车，A 线程 `from_cart` 下单会连 B 线程刚加的商品一起买走并清空购物车 → B 线程下单 3001。**这是脚本级数据竞争，不是被测系统 bug**。每线程注册 `perf_${__threadNum}` 专属账号，购物车天然隔离。
- 注册放 Once Only 而不是每圈执行：注册是幂等的资源准备，重复注册只会白白增加 1003 噪音。

### 3.7 思考时间（Constant Timer）

```xml
<ConstantTimer guiclass="ConstantTimerGui" testclass="ConstantTimer" testname="思考时间-模拟真实操作间隔" enabled="true">
  <stringProp name="ConstantTimer.delay">${__P(think_time,200)}</stringProp>
</ConstantTimer>
```

放在线程组层级，作用域内每个取样器前停顿指定毫秒。真实用户在"看到页面→点加购→点下单"之间有停顿；零思考时间的压测等于全肉搏机器人。order_flow 验证档用 `-Jthink_time=800`：既更接近真实节奏，又把"同一秒内的下单密度"降下来（避开被测系统 order_no 秒级碰撞缺陷的干扰，见 docs/04）。

### 3.8 CSV 数据集（演示配置，goods_list 中未启用）

```xml
<CSVDataSet guiclass="TestBeanGUI" testclass="CSVDataSet" testname="CSV数据集-测试账号（演示，未启用）" enabled="false">
  <stringProp name="filename">../data/users.csv</stringProp>
  <stringProp name="fileEncoding">UTF-8</stringProp>
  <stringProp name="variableNames">username,password</stringProp>
  <boolProp name="ignoreFirstLine">true</boolProp>
  <stringProp name="delimiter">,</stringProp>
  <boolProp name="recycle">true</boolProp>
  <boolProp name="stopThread">false</boolProp>
  <stringProp name="shareMode">shareMode.all</stringProp>
</CSVDataSet>
```

- `variableNames`：列名→变量名映射，启用后脚本里直接 `${username}` `${password}`。
- `recycle=true, stopThread=false`：读到文件尾从头再来（压测账号循环用）；若希望"账号用尽就停"则 stopThread=true。
- `shareMode.all`：所有线程**共享一个文件指针**——100 个线程各拿一行往下走，保证每个账号同一时刻只被一个线程使用。
- 相对路径**相对于 jmx 文件所在目录**解析（`scenarios/` 的上级找 `data/`，所以写 `../data/users.csv`）。
- 何时需要它：登录接口压测、需要"每虚拟用户一个账号"的场景。本工程 order_flow 用"注册线程专属账号"方案替代了 CSV（注册比预置几百个账号更自愈），goods_list 免登录用不上——保留配置只为教学。

### 3.9 监听器：聚合报告 / 查看结果树

```xml
<ResultCollector guiclass="StatVisualizer" testclass="ResultCollector" testname="聚合报告" enabled="true">
  <boolProp name="ResultCollector.error_logging">false</boolProp>
  <objProp><name>saveConfig</name><value class="SampleSaveConfiguration">...</value></objProp>
  <stringProp name="filename"></stringProp>
</ResultCollector>
```

- 聚合报告（StatVisualizer）：GUI 里实时看每标签的均值/中位数/P90/吞吐。
- 查看结果树（ViewResultsFullVisualizer）：调试时逐笔看请求/响应，**正式压测必须禁用**（enabled=false）——它把响应体留在内存里，几十万请求会撑爆压测机。
- `filename` 留空：非 GUI 运行时结果由 `-l results/xxx.jtl` 统一落盘，监听器只服务 GUI 模式。
- `saveConfig` 里的字段（time/elapsed/success/bytes...）就是 jtl 的列集合；注意字段名是 `assertions` 不是 `assertionResults`——手写 XML 用错字段名会在加载时抛 XStream ConversionException。

### 3.10 `${__P()}` 属性参数化机制总结

```
命令行/脚本            JMeter 属性空间            脚本内引用
-Jthreads=100    →    P(threads)="100"     →    ${__P(threads,50)} 取到 "100"
(未传)                P(threads) 不存在          ${__P(threads,50)} 落到默认 "50"
```

- `-Jkey=value` 只影响本次运行；`-q props文件` 可成套切换（如 dev.properties / prod.properties）；
- 属性是 **JMeter 全局**的（所有线程看到同一个值），变量是**线程局部**的（每个线程各有一套）——全局配置用属性，运行时数据用变量，这条边界决定参数化方案怎么选。

## 4. 为什么这样设计

| 决策 | 备选方案 | 理由 |
|---|---|---|
| JSON 断言做业务校验 | 只看 HTTP 200 / Response Assertion 匹配文本 | demo-mall 业务失败也是 200；JSONPath 直取 code 字段最语义化，且不受 JSON 键序影响 |
| 默认值哨兵 TOKEN_NOT_FOUND | 不设默认值 | 空变量产生的 `Bearer ` 尾随空格问题极难排查；哨兵值让失败在下游 401 处显式爆出来 |
| 线程专属账号 + 注册宽断言 | CSV 预置账号池 | 自愈：不用维护几百行账号文件；宽断言容忍 1003，脚本 reset 前后都能跑 |
| 按 `${__P()}` 属性参数化 | 每个环境复制一份 jmx | 复制品必然失同步；属性是 JMeter 原生机制，脚本单源 |
| 查询场景按 duration、业务场景按 loops | 两边都用 duration | 下单扣库存，固定时长必打穿库存；圈数与库存匹配才是正确姿势 |
| 手写 jmx（文本） | GUI 拖拽生成 | 文本可 review、可进 git、可精确注释；GUI 生成的 XML 无注释。代价是要吃透属性名（踩过两个：assertions、referenceNames 复数） |

## 5. 怎么运行/验证

```bash
# 改属性不改脚本：同一份 jmx 三种压法
jmeter -n -t scenarios/goods_list.jmx -Jthreads=10 -Jrampup=5 -Jduration=20 -Jport=5002 -l results/a.jtl
jmeter -n -t scenarios/goods_list.jmx -Jthreads=50 -Jrampup=10 -Jduration=30 -Jport=5002 -l results/b.jtl
jmeter -n -t scenarios/goods_list.jmx -Jthreads=150 -Jrampup=10 -Jduration=30 -Jhost=127.0.0.1 -Jport=5003 -l results/c.jtl

# 验证断言生效：故意把 -Jport 指向不存在的服务
jmeter -n -t scenarios/goods_list.jmx -Jthreads=2 -Jduration=5 -Jport=5999 -l results/fail.jtl
# 期望：错误率 100%，错误码 Non HTTP response code: HttpHostConnectException

# 验证关联生效（真实输出，2026-10-25）：
$ jmeter -n -t scenarios/order_flow.jmx -Jthreads=10 -Jrampup=5 -Jloops=6 -Jthink_time=800 -Jport=5002 \
         -l results/order_flow.jtl -e -o report/order_flow
summary =    310 in 00:00:30 =   10.4/s Avg:     6 Min:     1 Max:    26 Err:     0 (0.00%)
```

## 6. 常见坑

1. **JSON 提取器属性名是复数**：手写 jmx 用 `referenceName`/`jsonPathExpr`（单数）时静默失效，`${token}` 全空、后续全 401，jmeter.log 几乎无提示。属性名以 `JSONPostProcessor.class` 里的常量为准（`referenceNames`、`jsonPathExprs`、`match_numbers`、`defaultValues`）。
2. **saveConfig 字段名 `assertions`**：写 JMX 时想当然写 `assertionResults` 会得到 XStream ConversionException，整个 jmx 加载失败。以 JMeter 自带 `bin/templates/*.jmx` 为模板。
3. **"期望值留空=存在性校验"在 5.6.3 失真**：实测会把存在的值判失败且 failureMessage 为空（文档说可以，代码实现是空串等值比较）。存在性用"哨兵默认值 + 下游断言"兜底。
4. **CSV 相对路径**：相对的是 jmx 所在目录不是启动目录；路径错时表现为"线程启动即失败、全部采样报错"。先用 enabled=false 的空场景或绝对路径验证一次。
5. **共用账号的购物车竞态**：多线程共用一个账号做"加购→下单 from_cart"，会互相买走对方加购的商品（3001）。表现像被测系统 bug，实为脚本数据竞争。

## 7. 面试怎么讲

**30 秒版本**：
"我的 JMeter 脚本有三个设计点：第一，线程数/RampUp/时长/目标地址全部用 `${__P()}` 属性参数化，同一份 jmx 打任何环境和档位；第二，每个取样器都挂 JSON 断言校验业务码，因为这套系统业务失败也返回 200，不断言的话错误率是假的；第三，业务链路做了两级关联——登录响应提取 token 放进 Bearer 头，下单响应提取 order_id 拼进支付路径，提取器设了哨兵默认值，提取失败会在下游 401 显式暴露。过程中还踩了两个真实的坑：5.6 的 JSON 提取器 XML 属性名是复数，手写脚本用单数会静默失效；以及多线程共用账号会导致购物车竞态，我用每线程注册专属账号解决。"

**高频追问**：
1. *"属性和变量有什么区别？"* —— 属性是 JMeter 进程全局（-J 传入、${__P()} 读取，所有线程共享），变量是线程局部（JSON 提取器产出的 token 只有本线程可见）。全局配置用属性、运行时数据用变量；跨线程传数据要么用属性（JMeter Properties 组件）要么重新设计线程模型。
2. *"为什么不用 ForEach 做关联？"* —— ForEach 适合"提取多个匹配值逐个使用"（如把列表页 10 个 goods_id 逐个下单），配 match_numbers=-1。本场景每次迭代只需要一个 order_id，变量替换更直接；教班里两种都演示过。
3. *"断言加在 JMeter 层还是后处理脚本层？"* —— 压测必须在 JMeter 层断言：错误率要计入采样结果，才能进 TPS/错误率统计和 HTML dashboard；事后脚本层只能做事后核对，发现问题时压测早跑完了。JSR223 断言是两者折中——在 JMeter 内写代码级断言（本工程的注册宽断言就是）。

## 8. 复现任务清单

| # | 任务 | 验收标准 |
|---|---|---|
| 1 | GUI 打开 goods_list.jmx，对照本文逐组件找到 XML | 组件树与 3.1~3.9 一一对应 |
| 2 | 改 `-Jthreads` 跑三组，观察 jmeter.log 属性生效 | summary 的 Active 数随 threads 变化 |
| 3 | 把 -Jport 指到 5999 跑 5 秒 | 错误率 100%，responseCode 为 HttpHostConnectException |
| 4 | 手动把提取器属性改回单数跑一次 | 复现"全 401"事故，加深印象 |
| 5 | 启用 CSV 数据集（enabled=true）+ 在登录取样器引用 ${username} | 两个种子账号交替登录成功 |
| 6 | reset 后跑 order_flow 默认参数 10×15 圈 | 观察 order_no 碰撞 500（可复现的被测系统缺陷） |
