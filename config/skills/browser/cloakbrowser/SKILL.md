---
name: cloakbrowser
description: "Browse bot-protected websites using stealth Chromium — defeats Cloudflare, reCAPTCHA, and 30+ detection systems"
version: 1.0.0
author: local-ai-stack
metadata:
  hermes:
    tags: [browser, web, scraping, automation, stealth]
    category: browser
---

# CloakBrowser

## When to Use
Use this skill when a site blocks `curl` or `requests` with bot detection (Cloudflare Turnstile, reCAPTCHA, BrowserScan, FingerprintJS). CloakBrowser uses a source-patched Chromium that passes 30/30 bot detection tests — patches are compiled into the binary, not injected via JS.

For plain sites without bot detection, prefer `curl` or `requests` — they are faster and cheaper.

## Python Usage

```python
from cloakbrowser import launch

browser = launch(args=["--no-sandbox"])  # --no-sandbox required in Docker
page = browser.new_page()
page.goto("https://protected-site.com")
content = page.content()          # raw HTML
# or use page.inner_text('body')  # cleaner text
browser.close()
```

CloakBrowser is a drop-in for Playwright/Puppeteer — standard Playwright page methods work.

## MCP Server

`cloakbrowsermcp` is installed and can be started as an MCP server, exposing these tools:

| Tool | What it does |
|---|---|
| `cloak_launch()` | Start a stealth session |
| `cloak_navigate(pid, url)` | Navigate to a URL |
| `cloak_snapshot(pid)` | Get interactive elements with `[@eN]` references |
| `cloak_click(pid, ref)` | Click an element |
| `cloak_type(pid, ref, text)` | Type into a field |
| `cloak_read_page(pid)` | Get page content as clean Markdown |

`cloak_snapshot` + `cloak_read_page` use the accessibility tree — far more token-efficient than reading raw HTML.

## Pitfalls

- Always pass `--no-sandbox` in Docker — Chromium requires it when running as root without a user namespace
- On first run, Chromium (~200MB) downloads to `~/.cloakbrowser/` — expect a one-time delay
- For JS-heavy SPAs, prefer `cloak_snapshot()` over reading raw HTML
