# 行情与数据说明

MarketBar 通过 Yahoo Finance 的公开网页行情接口获取美股报价，无需账号或 API key。这些接口不是面向本项目提供保证的开发者 API，可能限流、停更或调整格式。Yahoo 官方说明部分市场提供盘前盘后实时行情，但覆盖范围随市场而异。[Yahoo 行情说明](https://help.yahoo.com/kb/SLN2321.html)

## 报价更新

| 路径 | 用途 | 更新方式 |
| --- | --- | --- |
| WebSocket | 最新价格、本机分钟采样 | 收到推送即更新；每 15 秒维护订阅和心跳，断开后退避重连 |
| 图表接口 | 启动回填、分钟 OHLC、备用报价 | 请求 `interval=1m&includePrePost=true`，启动及约每 60 秒刷新 |

价格按行情时间合并，较旧的快照不会覆盖较新的推送。图表接口的 `regularMarketPrice` 只表示常规时段报价；盘前盘后会结合更晚的图表数据选择价格。

「行情时间」来自数据源，「到达差值」是本机收取时间与行情时间之差，包含上游处理、时间戳精度及本机时钟误差，不等于单纯网络延迟。超过 60 秒的报价标为「旧」。价格不变也可能只是没有新的成交。

## 时段与涨跌幅

美股使用 `America/New_York` 时区，随夏令时切换。报价时段优先采用推送标记或数据源给出的交易区间；无法确定的时段显示未知。标签描述报价本身，不预测节假日是否开市。

十字线百分比统一相对**所选纽约交易日的前一交易日常规收盘价**，计算为 `(价格 / 昨收 - 1) × 100%`。基准与日期一同缓存；缺少可靠基准时显示「—」，不借用其他日期的昨收或当天首笔价格。

## 分钟数据来源

| 来源 | 含义 |
| --- | --- |
| 线上分钟数据 | Yahoo 图表接口提供的开、高、低、收及可用成交量 |
| 本机采样 | 应用收到的推送价格按分钟聚合，不代表完整市场成交 |
| 线上数据加实时补充 | 线上分钟数据与较新的本机样本合并 |

当前分钟尚未结束时，OHLC 会继续变化。睡眠、断网、应用未运行或上游缺失的分钟保留空白，分时线不会跨缺口连接。本机采样及混合数据不提供推算成交量。

## 本地保存

文件保存在 `~/Library/Application Support/MarketBar/Candles/<品种>/<日期>.json`，包含分钟数据、来源和涨跌基准。美股按纽约日期、OKX 现货与合约按 UTC 日期保存。

- 约每 10 秒保存变更，正常退出时再保存；强制结束可能丢失尚未保存的样本。
- 每日文件原子替换。损坏文件会报告错误并保留，不被新数据静默覆盖。
- 启动时加载每只股票最近 10 个已保存日期；旧文件不会自动删除。
- 混合数据保留来源标记；重新联网后，更新的完整线上分钟数据可替代缓存中的混合记录。

## OKX USDT 现货与永续

`BTCUSDT` 规范化为 `BTC-USDT` 现货，裸 `BTC` 保持美股代码；`SOXLUSDT` 规范化为 `SOXL-USDT-SWAP`；`SOXL` 仍指美股。现货与合约数据使用 `wss://ws.okx.com/ws/v5/public` 的 `tickers` 和 `trades` 频道，不登录、不访问账户接口。

- `tickers.last` 为最新成交价，`ts` 是行情消息生成时间。盘口变化也可能触发消息，因此 ticker 不生成本地成交 K 线。
- `trades.px/ts` 用于本地分钟采样。REST `market/candles` 回填最近 300 根分钟 K 线，`confirm` 区分未结束和已结束的分钟。
- 列表涨跌幅使用 `last/open24h-1`；图表按 UTC 日期组织，以 `sodUtc0` 为当日开盘基准。二者均在界面注明。
- 现货与永续价格均为 USDT。现货 `sz`／`vol` 按基础币数量保存（BTC-USDT 为 BTC），永续按合约张数保存；两种单位分开，也不混用为股票股数。现货不会进入 SOXL 永续提醒策略。
- 行情连接独立于 Yahoo。WebSocket 空闲时以 `ping/pong` 保活，断开后退避重连；不会每隔几秒重复提交订阅。

接口字段及频率以 [OKX 官方 API 文档](https://www.okx.com/docs-v5/en/)为准。

## 协议参考

Swift 解析器参考以下公开资料中的端点与字段定义，未引入第三方运行库：

- [yfinance WebSocket 实现](https://github.com/ranaroussi/yfinance/blob/main/yfinance/live.py)：`version=2` 连接、订阅格式、JSON 包裹的 base64 protobuf。
- [yfinance pricing.proto](https://github.com/ranaroussi/yfinance/blob/main/yfinance/pricing.proto)：字段编号与类型；时间字段为以毫秒计的 ZigZag `sint64`。
- [yahoo-live yaticker.proto](https://github.com/open-wallstreet/yahoo-live/blob/master/proto/yaticker.proto)：`marketHours` 枚举，0 为盘前、1 为常规、2 为盘后、3 为未细分的延长时段。
- [yfinance 图表实现](https://github.com/ranaroussi/yfinance/blob/main/yfinance/scrapers/history.py)：图表参数与盘前盘后数据获取。

这些资料描述公开接口的使用方式，不构成 Yahoo 的稳定协议承诺。代码许可与行情数据的使用权限分别适用，参见[第三方声明](../THIRD_PARTY_NOTICES.md)。
