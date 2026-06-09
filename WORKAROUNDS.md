# Workarounds

Active workarounds for upstream bugs. Each entry links to the issue and notes when it can be removed.

---

## OpenWebUI: web search results not passed to model

**Upstream issue:** [open-webui#25585](https://github.com/open-webui/open-webui/issues/25585)
**Introduced in:** v0.9.6
**Fix PR:** [open-webui#25600](https://github.com/open-webui/open-webui/pull/25600) (open at time of writing)

### Root cause

`get_sources_from_items()` has no dispatch branch for items with `type == "web_search"`. When the retrieval access-control hardening introduced in v0.9.6 is active, these items fall through to a gated fallback and are silently dropped before reaching the model. Web search appears to work (SearXNG returns results, embeddings are generated, documents saved to a vector collection) but the model never sees any of the retrieved content.

### Workaround

Set in `docker/docker-compose.yml` under the `openwebui` service environment:

```yaml
- BYPASS_WEB_SEARCH_WEB_LOADER=true
- BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true
```

`BYPASS_WEB_SEARCH_WEB_LOADER=true` skips full page fetching and uses SearXNG result snippets directly (also avoids failures when result pages block automated scraping).

`BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true` bypasses the broken retrieval path entirely — SearXNG snippets are injected directly into the model context instead of going through embed → store → retrieve.

### When to remove

Once the fix from PR #25600 ships in a released image tag: remove both env vars, pin `image: ghcr.io/open-webui/open-webui:<fixed-version>` in `docker-compose.yml`, and verify web search results appear in chat.
