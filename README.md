# MarketBar

在 Mac 菜单栏看美股价格，点开就能查看盘前、盘中和盘后的分钟走势。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/marketbar-dark.png">
  <img src="docs/images/marketbar.png" alt="MarketBar 自选列表与盘前图表">
</picture>

界面示例，价格为演示数据。

- 自选股票价格常驻菜单栏，默认 AMD、NVDA；支持最多 12 只，菜单栏显示其中 1–3 只。
- 分时线与 1 分钟 K 线，按纽约日期和交易时段查看；十字线显示价格及相对昨收的涨跌幅。
- 自动保存分钟数据和昨收基准，离线可查看缓存；图中保留缺失分钟的空白。
- 原生 Swift、AppKit、SwiftUI，无第三方运行时或 Swift 包依赖，无需账号。

## 安装

从 [Releases](https://github.com/ZAIQuQ/marketbar/releases/latest) 下载 Apple Silicon 版本，解压后将 `MarketBar.app` 放入「应用程序」并打开。需要 macOS 13+；应用尚未经过 Apple 公证。

也可以从源码构建，需要 Swift 5.9+ 和 Xcode Command Line Tools。尚未安装命令行工具时，先运行 `xcode-select --install`。CI 同时检查 Apple Silicon 和 Intel 构建。

```sh
git clone https://github.com/ZAIQuQ/marketbar.git
cd marketbar
bash scripts/install.sh
```

脚本会构建应用、安装到 `~/Applications/MarketBar.app` 并打开。已有版本会备份；更新前请从应用菜单正常退出。只想构建可运行 `bash scripts/build-app.sh`，产物位于 `dist/MarketBar.app`。

## 使用

点击菜单栏价格打开面板，在右上角设置自选股。列表顺序就是菜单栏顺序。点击股票卡片进入图表，鼠标悬停可查看该分钟的价格和涨跌幅。

| 标记 | 含义 |
| --- | --- |
| 前 / 中 / 后 | 这笔报价所属的盘前 / 盘中 / 盘后时段 |
| ≈ | 分钟快照 |
| 旧 | 报价时间距当前超过 60 秒 |
| ◌ | 推送未连接 |

若需登录时启动，将应用添加到 macOS「系统设置 → 通用 → 登录项」。

## 行情与缓存

行情来自 Yahoo Finance 推送和分钟接口。接口为非官方接入，没有延迟或可用性保证，可能限流或变更。图表区分线上分钟数据、本机采样和混合数据；本机样本不代表完整分钟成交，也不推算成交量。详细说明见[数据说明](docs/DATA_SOURCES.md)。

缓存位于 `~/Library/Application Support/MarketBar/Candles/`，按股票和纽约日期保存。启动时加载最近 10 个已保存日期，旧文件仍保留。缺少对应日期的昨收基准时，涨跌幅显示「—」。

## 开发

```sh
bash scripts/check.sh
```

用 `swift run MarketBar --diagnose` 观察 20 秒网络行情并输出 JSON。该命令不写入行情缓存；没有收到推送时退出码为 2，休市或断网都可能导致这一结果。

`Sources/TickerCore` 负责行情解析和分钟数据合并，`Sources/MarketBar` 负责界面、网络连接及本地保存。问题反馈请附 macOS 版本、股票代码和出现问题的时间。

用 `swift run MarketBar --preview docs/images` 生成浅色、深色界面截图，数据固定且不联网。

## 许可

[MIT](LICENSE) · [第三方参考与声明](THIRD_PARTY_NOTICES.md)
