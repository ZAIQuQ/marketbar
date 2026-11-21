<p align="center"><img src="Resources/AppIcon.svg" width="64" height="64" alt=""></p>
<h1 align="center">MarketBar</h1>
<p align="center"><a href="README.md" lang="zh-CN">简体中文</a> · <strong>English</strong></p>

Follow US stocks, bitcoin spot and SOXL perpetuals from your Mac’s menu bar. Click a price to see how it moved over the last few minutes.

**[Download for Mac ↗](https://github.com/ZAIQuQ/marketbar/releases/latest)**　Apple Silicon · macOS 13 or later · No market data account required

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/marketbar-dark.png">
  <img src="docs/images/marketbar.png" width="760" alt="Demo showing BTC spot and SOXL perpetual prices in the menu bar. The crosshair on the SOXL one-minute chart shows the selected minute’s price and percentage change.">
</picture>

## Put your first prices in the menu bar

1. Download the file ending in `macos-arm64.zip` from the release page. Unzip it, drag `MarketBar.app` into Applications and open it. The release build is not notarized by Apple. Intel Mac users can build from source using the instructions below.
2. Click a price in the menu bar. Your watchlist starts with AMD and NVDA. Click the sliders at the top right, enter `AMD, NVDA, BTCUSDT, SOXLUSDT`, then click **完成** (Done). The app’s controls are in Simplified Chinese.
3. Click the rectangle beside the bell and check the prices you want in the menu bar. Select just BTC and SOXL, for example, and the other instruments stay in the watchlist. Clear every checkmark and you can still open the panel from `MarketBar` in the menu bar.

| Enter | Market |
| --- | --- |
| `AMD`, `NVDA` | US stocks with premarket, regular and after-hours quotes |
| `BTCUSDT` or `BTC-USDT` | Bitcoin spot on OKX, quoted in USDT |
| `SOXLUSDT` or `SOXL-USDT-SWAP` | SOXL perpetual swap on OKX, quoted in USDT |
| `BTC`, `SOXL` | The corresponding US-listed ETFs |

Follow up to 12 instruments. When US trading closes, those symbols are hidden from the menu bar by default and return when trading resumes. Open the watchlist to see their last quotes.

## Read a one-minute chart

Click a watchlist entry to switch between a line chart and one-minute candles. Hover to see a minute’s closing price and percentage change. The current minute updates as quotes arrive.

- **US stocks** use New York trading dates. Pick premarket, regular trading or after-hours. The chart measures change from the previous close.
- **OKX** charts cover the last 30 minutes, 1, 2, 3, 6 or 12 hours, or a full UTC day. Rolling windows use your Mac’s time zone. The chart shows change from the UTC day’s open. Watchlist entries show the rolling 24-hour change.

US quotes come from an unofficial Yahoo Finance feed. Coverage and latency vary by session. OKX quotes use the exchange’s public market data. In the menu bar, `≈` marks a snapshot and `旧` marks a quote older than 60 seconds. Saved candles are available offline. [Data sources and local storage (Chinese)](docs/DATA_SOURCES.md)

## Get an alert when SOXL moves on volume

Click the bell and choose **启用提醒** (Enable alerts) to watch the SOXL perpetual for sharp moves in either direction. By default, a move must reach 0.6% in the current minute or 1.0% across two minutes, with at least three times the baseline volume and five seconds of confirmation. The price threshold rises when recent volatility is high.

Confirmed moves leave a mark in the menu bar and can trigger a silent macOS notification. You can adjust the price thresholds, volume multiple and confirmation time. Monitoring runs on your Mac and pauses when it sleeps, the lid closes or the connection drops. [Alert rules and settings (Chinese)](docs/ALERTS.md)

<details>
<summary><strong>Build from source and development commands</strong></summary>

Requires macOS 13 or later and Swift 5.9 or later. Install the Xcode Command Line Tools with `xcode-select --install` if needed.

```sh
git clone https://github.com/ZAIQuQ/marketbar.git
cd marketbar
bash scripts/install.sh
```

The script backs up the previous app, installs to `~/Applications/MarketBar.app` and opens it. To build without installing, run `bash scripts/build-app.sh`.

- Offline checks: `bash scripts/check.sh`
- Live feed diagnostics: `swift run MarketBar --diagnose --symbols 'BTCUSDT,SOXLUSDT'`. Add `--monitor --seconds 240` to inspect the SOXL monitor.
- Render the app preview: `swift run MarketBar --preview docs/images`

</details>

## Star History

<a href="https://www.star-history.com/#ZAIQuQ/marketbar&amp;Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ZAIQuQ/marketbar&amp;type=date&amp;legend=top-left&amp;theme=dark">
    <img src="https://api.star-history.com/chart?repos=ZAIQuQ/marketbar&amp;type=date&amp;legend=top-left" width="680" alt="GitHub star history for MarketBar">
  </picture>
</a>

[Report an issue](https://github.com/ZAIQuQ/marketbar/issues) · [MIT license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
