# 第三方参考与声明

MarketBar 的 Swift 解析器为独立实现，参考了下列项目公开的协议字段、枚举值和接口用法。本仓库未包含这些项目的 `.proto` 文件、生成代码或运行库。

| 项目 | 参考内容 | 上游许可 |
| --- | --- | --- |
| [yfinance](https://github.com/ranaroussi/yfinance) | WebSocket 端点、订阅格式、protobuf 字段和图表参数 | [Apache License 2.0](https://github.com/ranaroussi/yfinance/blob/main/LICENSE.txt) |
| [open-wallstreet/yahoo-live](https://github.com/open-wallstreet/yahoo-live) | `marketHours` 枚举值 | [GNU GPL v3](https://github.com/open-wallstreet/yahoo-live/blob/master/LICENSE) |

具体参考文件见[协议参考](docs/DATA_SOURCES.md#协议参考)。上游项目的代码仍适用各自的许可。

行情由 Yahoo Finance 提供。MarketBar 与 Yahoo 没有关联或背书关系；Yahoo 名称及相关商标属于其各自权利人。MarketBar 的 MIT 许可覆盖本项目代码，不授予行情数据的使用或再分发权；数据使用受 [Yahoo 条款](https://legal.yahoo.com/us/en/yahoo/terms/otos/index.html)及适用数据许可约束。
