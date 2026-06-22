---
name: searxng
description: "Search the web via the local SearXNG instance — structured JSON results, no API key required"
version: 1.0.0
author: local-ai-stack
metadata:
  hermes:
    tags: [search, web, research]
    category: infrastructure
---

# SearXNG Web Search

## When to Use
Use this skill to search the web. The local SearXNG instance is always available on the Docker network — no external API key needed.

## Search

```bash
curl -s 'http://searxng:8080/search?q=your+query+here&format=json'
```

URL-encode the query: replace spaces with `+`.

## Response

```json
{
  "results": [
    { "title": "...", "url": "...", "content": "..." }
  ]
}
```

Extract key fields:

```bash
curl -s 'http://searxng:8080/search?q=your+query&format=json' \
  | jq '.results[] | {title, url, content}'
```

## Pitfalls

- Check multiple results before drawing conclusions — result quality varies by query
