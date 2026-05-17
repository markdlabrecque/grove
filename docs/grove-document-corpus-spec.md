# Grove — Document corpus integration spec

**Status:** Draft, pending review
**Author:** mark@affinitybridge.com (with Claude)
**Date:** 2026-05-17

## 1. Summary

Extend Grove to ingest and index a corpus of markdown documents (typically an Obsidian vault stored in a git repository) alongside the existing memories store. The corpus participates in retrieval at ask-time so the LLM has access to both raw captured memories and intentionally-written notes when answering questions.

**Scope is server-side only.** No capture-path changes. No new client surfaces. This integration affects Grove's data model, ingestion pipeline, and ask flow — nothing else.

## 2. Goals & non-goals

### Goals

- Index an external git-tracked markdown corpus (Obsidian vault or equivalent) into Grove's Postgres database.
- Make documents queryable via the existing ask flow, with results merged alongside memory hits.
- Preserve document structure (headers, frontmatter, file paths) for retrieval context and citation.
- Keep the index in sync as the corpus changes via a defined sync mechanism.
- Reuse Grove's existing embedding pipeline — same model, same vector dimension, same retrieval infrastructure.

### Non-goals

- **Replacing memories with documents.** Memories remain Grove's primary store; documents are additive reference material.
- **Writing back to the markdown files.** Documents are read-only from Grove's perspective in V1. Enrichment outputs (if any) go to Postgres-only sidecar tables, never to the user's vault.
- **Wiki-link graph traversal.** Wiki-links are preserved in chunk text but not extracted into a graph structure in V1.
- **Bidirectional sync.** Grove never modifies the source markdown.
- **Generic file-format support.** Markdown only. Skip PDFs, images, audio, code files.
- **Obsidian-specific UI integration.** Grove does not become an Obsidian plugin. The vault is just a directory of markdown files.

Acronym key:
- **LLM** — Large Language Model
- **HNSW** — Hierarchical Navigable Small World (a vector-index structure)
- **ANN** — Approximate Nearest Neighbor (the class of algorithms HNSW belongs to)
- **FK** — Foreign Key
- **PK** — Primary Key
- **RAG** — Retrieval-Augmented Generation

## 3. Data model

Two new tables, parent-child:

```sql
CREATE TABLE documents (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  repo_path       TEXT UNIQUE NOT NULL,         -- relative path inside the git repo
  title           TEXT NOT NULL,                -- from H1 or filename
  frontmatter     JSONB,                        -- parsed YAML frontmatter (tags, dates, etc.)
  body_hash       TEXT NOT NULL,                -- SHA-256 of file body, for change detection
  content_length  INT,                          -- characters in body
  last_modified   TIMESTAMPTZ,                  -- file mtime at last index
  last_indexed_at TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX documents_frontmatter_gin ON documents USING GIN (frontmatter);

CREATE TABLE document_chunks (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id    UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  chunk_index    INT  NOT NULL,                 -- 0-based ordinal within document
  text           TEXT NOT NULL,                 -- the chunk's content
  embedding      VECTOR(1536),                  -- pgvector; matches Grove's existing embedding model
  token_count    INT,
  start_char     INT,                           -- offset in original document body
  end_char       INT,
  headers        TEXT[],                        -- breadcrumb path: ["Architecture", "Database"]
  UNIQUE (document_id, chunk_index)
);

CREATE INDEX ON document_chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON document_chunks (document_id);
```

### 3.1 Schema notes

- **Embedding dimension** matches Grove's existing model (currently `text-embedding-3-small` at 1536 dims). If the embedding model changes, both the `memories` and `document_chunks` tables need reindexing in lockstep.
- **`body_hash`** is the load-bearing field for incremental sync: compare against the source file's hash; only re-chunk + re-embed if it changed.
- **`headers` as `TEXT[]`** preserves the markdown header path. Stored as an ordered array rather than denormalized columns because depth varies per chunk.
- **`frontmatter` as `JSONB`** with a GIN index lets us filter on tags / dates / custom fields without per-field columns. Trades a small query-complexity cost for schema flexibility.
- **`ON DELETE CASCADE`** on the chunks FK is critical — when a file is removed from the repo, the sync job deletes the parent row and all chunks vanish automatically.

## 4. Chunking strategy

V1 uses **header-aware chunking with a sliding-window fallback** for long sections.

### 4.1 Algorithm

1. Parse the markdown body into a tree of (header, content) sections.
2. For each leaf section:
   - If the section fits in the chunk budget (default: 400 tokens), emit it as a single chunk.
   - If it exceeds the budget, split via sliding window (400 tokens, 80-token overlap).
3. For each emitted chunk:
   - Prepend the parent header path to the embedding text (improves semantic match without polluting display text).
   - Record the `headers` array, `chunk_index`, `start_char`, `end_char`, `token_count`.
4. Embed each chunk via the existing pipeline.

### 4.2 Chunk budget rationale

- 400 tokens is a sweet spot for retrieval quality: long enough to carry context, short enough that an embedding represents a single semantic unit.
- 80-token overlap (20%) ensures that a query targeting the boundary of two chunks still matches at least one of them.

### 4.3 Skipped content

- YAML frontmatter is parsed into the `frontmatter` column, not chunked.
- Code blocks are preserved in chunks (their syntax matters for the LLM).
- Image embeds (`![[image]]`) are stripped from chunk text; the alt-text is preserved.
- Obsidian's `.obsidian/` config directory and any `.trash/` or `_attachments/` are excluded at the file-walker level.

## 5. Sync model

V1: **periodic full-tree walk with hash-based incremental indexing.**

### 5.1 Sync flow

The sync job runs on a schedule (default: hourly via the existing `grove-enrichment` LaunchAgent — same cadence as memory enrichment, no new system service):

1. `git pull` in the local clone of the documents repo.
2. Walk the file tree, hashing each `.md` file's body.
3. For each file:
   - **New file** (`repo_path` not in `documents`): insert document row, chunk, embed, insert chunks.
   - **Changed file** (`body_hash` differs): delete existing chunks, re-chunk, re-embed, update document row.
   - **Unchanged file**: skip.
4. **Deleted files** (in `documents` but not in the file tree): delete document rows (chunks cascade).

### 5.2 Why this approach

- **No webhook infrastructure required.** Reuses Grove's existing scheduled-job pattern.
- **Idempotent.** Running the sync twice produces the same result.
- **Cheap when nothing changed.** Hash compare is fast; nothing else runs.
- **Survives partial failures.** A crash mid-sync leaves the database in a consistent state; the next run picks up where it left off.

### 5.3 Future sync upgrades (out of scope for V1)

- Git webhook from GitHub for near-real-time indexing.
- Filesystem watcher (`watchdog`) for sub-second indexing when editing locally on the Mac Mini.
- Diff-based partial chunking (don't re-chunk a 5,000-word file when one paragraph changed).

## 6. Retrieval integration

The ask flow gains a second retrieval branch alongside the existing memory retrieval.

### 6.1 Modified ask pipeline

```
1. Embed the query (existing)
2. Vector search memories     → top-K memory hits
3. Vector search documents    → top-K chunk hits        ← NEW
4. (Optional) Expand chunk hits with adjacent chunks    ← NEW
5. Merge + rerank              → unified context        ← MODIFIED
6. Build LLM prompt with source attribution metadata
7. Call LLM
```

### 6.2 Source attribution

Both memory hits and document chunks are passed to the LLM with metadata distinguishing their source:

```
[MEMORY 2026-04-12]
<memory text>

[NOTE: architecture/grove.md > Database choices > Why pgvector]
<chunk text>
```

This lets the LLM cite specific notes in answers ("Per your note on Database choices…") and prevents hallucination of which source said what.

### 6.3 Merge / rerank strategy

V1: simple cosine-distance threshold merge. Memory hits and chunk hits are pooled; the union is sorted by distance and truncated to a fixed token budget.

V2 (future): weight document hits slightly higher (curated content is higher-signal per item), or expose a `source` filter to the user ("ask only my notes," "ask only my memories").

### 6.4 Chunk-neighbor expansion

For the top-N chunk hits, optionally fetch chunks at `chunk_index - 1` and `chunk_index + 1` of the same document. This dramatically improves answer quality when the hit chunk references something defined in an adjacent chunk. V1 default: expand the top 3 chunk hits with one neighbor on each side.

## 7. V1 scope and explicit limitations

### In scope for V1

- Documents + document_chunks tables with the schema above.
- Hourly sync job extending the existing LaunchAgent.
- Header-aware chunking with sliding-window fallback.
- Retrieval merge in the ask pipeline.
- Source attribution in LLM context.
- Chunk-neighbor expansion for top hits.

### Out of scope for V1 — explicitly

- **Wiki-link graph extraction.** Wiki-link syntax is preserved as text but not modeled as edges. The LLM can mention `[[Foo]]` references in answers but cannot expand them.
- **Backlink traversal.** Same reasoning.
- **Multiple corpora.** V1 supports exactly one configured documents repo. Multi-corpus support is future work.
- **Writeback to markdown.** Grove never modifies files in the source vault.
- **User-configurable chunking parameters.** Chunk size, overlap, and strategy are constants in V1.
- **Hybrid keyword + vector search (BM25 + embeddings).** Pure vector retrieval only in V1.
- **Document-level summaries.** No per-document summary or "table of contents" embedding; only chunk-level.
- **Hierarchical retrieval** (document-level first, then chunk-level drill-down). All retrieval is flat chunk-level in V1.
- **Per-document access control.** All documents in the configured repo are queryable; no per-file permissions.
- **Source filtering at query time.** No "ask only notes" or "ask only memories" mode in V1 — both are always pooled.

### Known limitations users should expect

- **Sync latency is up to one hour.** A note edited 5 minutes ago may not surface in answers until the next sync run. Mitigatable by running the sync job manually (a CLI command).
- **First sync of a large corpus is slow.** Embedding 10,000 chunks takes ~10–30 minutes wall-clock and costs ~$5 in API fees. Subsequent syncs are seconds when little has changed.
- **Long sections produce many chunks.** A 5,000-word note becomes ~15–20 chunks, all of which compete in retrieval. Heavy use of long-form notes may benefit from V2's hierarchical retrieval.

## 8. Hardware impact

For a personal-scale corpus (up to ~100K notes / ~1M chunks), **no hardware tier change is required**. Concrete numbers:

| Corpus size | Chunks | Raw text | Embeddings | Working set | Search latency on base Mac Mini |
|---|---|---|---|---|---|
| 1K notes | ~7.5K | ~5 MB | ~45 MB | ~50 MB | <10 ms |
| 10K notes | ~75K | ~50 MB | ~450 MB | ~500 MB | <50 ms |
| 100K notes | ~750K | ~500 MB | ~4.5 GB | ~6–8 GB | <100 ms |

The base 16 GB Mac Mini handles up to ~100K notes comfortably alongside Grove's other services. Past that scale, see §11 (future considerations) for tuning levers.

## 9. Cost estimate

### One-time

- **Initial indexing pass:** ~$0.50 per 10K notes (assuming `text-embedding-3-small` at $0.02/M tokens, ~500 tokens per chunk average, ~7.5 chunks per note).

### Ongoing

- **Reindex on file changes:** trivial. Editing 50 notes a day = fractions of a cent.
- **Ask-time cost increase:** modest. Retrieved context grows by ~30–50% (memories + chunks vs. memories alone), so per-ask cost grows proportionally. At personal use, this is ~$1–3/month additional cloud spend.

## 10. Build effort

Breakdown into approximate tickets:

| Ticket | Description | Estimate |
|---|---|---|
| 1 | Alembic migration: `documents` + `document_chunks` tables, indexes | 1–2 hrs |
| 2 | Markdown parser + frontmatter extraction | 2–3 hrs |
| 3 | Header-aware chunker with sliding-window fallback | 3–5 hrs |
| 4 | Sync job: git pull, file walk, hash compare, dispatch reindex | 4–6 hrs |
| 5 | Embedding pipeline integration (reuse existing) | 1–2 hrs |
| 6 | Ask flow: retrieval merge + neighbor expansion + source attribution | 3–5 hrs |
| 7 | Configuration (repo path, sync schedule, chunk parameters) | 1–2 hrs |
| 8 | Tests (chunker, sync diff logic, retrieval merge) | 4–6 hrs |
| **Total** | | **~19–31 hours** |

Roughly **4–6 PR-sized tickets**, ideally a long weekend or two of focused work.

## 11. Considered alternatives

### 11.1 Markdown-as-source-of-truth (rejected for V1)

A more committed version of this design makes the markdown vault the canonical store for *all* of Grove's data — both intentionally-written notes and raw voice captures. Grove writes captures as markdown files, the file watcher reindexes into pgvector, and Postgres becomes a rebuildable index rather than a source of truth.

**Why rejected for V1:** Adds significant complexity around enrichment write-back (the existing pipeline writes summaries and embeddings back to memory rows; with markdown-as-source, that requires sidecar files or risks clobbering user edits), introduces concurrency hazards between Grove's writes and user edits in Obsidian, and slows the capture path from milliseconds to seconds due to file I/O and sync.

**When to revisit:** If the user's primary workflow shifts toward writing in Obsidian as the main authoring surface, with Grove as an enhancement layer rather than a capture surface, this design becomes more attractive. Tracked as a future-architecture decision, not a near-term option.

### 11.2 Separate Model Context Protocol (MCP) resource (rejected for V1)

Instead of mirroring the corpus into Grove's Postgres, expose it as a separate MCP server that Grove's ask flow (or any MCP-aware client) queries. Clean separation, lets Claude Desktop also query the corpus.

**Why rejected for V1:** Adds an extra service and a network hop for the most common code path. The pgvector-in-same-DB approach is simpler, faster, and gets us the same retrieval result. MCP exposure can be added later as a thin shim over the same tables.

### 11.3 Mirror documents into the existing `memories` table (rejected)

Treat each markdown file (or chunk) as just another memory row, bypassing the new tables entirely. Simpler schema, single retrieval path.

**Why rejected:** Loses the conceptual distinction between captured thoughts and curated documents. Both have different shapes (memories are short, atomic; documents are long, hierarchical) and different sources of truth (memories live in Grove; documents live in the git repo). Conflating them costs us source attribution and makes the eventual "source filter" feature harder.

## 12. Future considerations

Out of V1 scope but worth keeping the architecture friendly to:

- **Wiki-link graph extraction** into a `document_links(source_id, target_id, link_text)` table. Enables graph-aware retrieval expansion.
- **Hybrid search (BM25 + vector).** BM25 (Best Matching 25, a classic keyword-ranking algorithm) complements vector search for queries with rare or specific terms.
- **Hierarchical retrieval.** Embed document-level summaries first; use them to narrow the chunk-level search space. Useful past ~100K notes.
- **Multiple corpora.** Different repos for different content types (e.g., personal notes, work notes, research notes) with per-corpus weighting.
- **Per-corpus source filter.** "Ask only my work notes." Requires a `source_corpus` column on documents.
- **Read-only writeback.** If the user wants Grove-derived metadata (tags, summaries) to surface in Obsidian, write to a sidecar `.grove.json` per document, never the markdown itself.
- **Half-precision (`float16`) embeddings** to halve storage and memory footprint at minor recall cost — relevant past ~1M chunks.

## 13. Open questions

1. **Which repo, and how is it configured?** Path to the local git clone needs to live somewhere — env var, settings table, or YAML config. Default proposal: env var `GROVE_DOCUMENTS_REPO_PATH`.
2. **What's the sync schedule?** Hourly (matching enrichment) is the proposal; could be more or less frequent. Worth deciding once we know the user's edit cadence.
3. **What happens when the embedding model changes in the future?** Memories and documents need to reindex in lockstep — should we track an `embedding_version` column to support gradual migration, or always require a full reindex? Defer until it actually matters.
4. **Should the chunker handle code blocks specially?** Long code blocks chunked by token count can split mid-function. Probably tolerable for V1; revisit if it hurts retrieval quality.
5. **Does this affect Grove's existing memory enrichment pipeline?** It shouldn't — they're parallel data paths. But worth verifying that running both jobs in the same hourly LaunchAgent doesn't create contention. Likely fine; both are mostly I/O-bound.

## 14. Phased rollout suggestion

Ticketing order, smallest to largest, each independently mergeable:

1. **#XXX — Schema migration.** `documents` + `document_chunks` tables, no code change. Establishes the foundation.
2. **#XXX — Markdown parser + chunker.** Pure logic, unit-tested with fixtures. No DB or sync wiring yet.
3. **#XXX — Sync job (skeleton).** Wired into the LaunchAgent, configurable repo path, parses + chunks + embeds + persists. Manual-run-only initially.
4. **#XXX — Ask-flow retrieval merge.** Modify ask pipeline to query chunks alongside memories, with source attribution. Manually-curated corpus for testing.
5. **#XXX — Chunk-neighbor expansion + reranking.** Quality polish on retrieval.
6. **#XXX — Sync scheduling + manual-trigger CLI.** Hourly run + a `grove sync-documents` command for on-demand reindex.

Each ticket lands a working slice. The corpus is queryable end-to-end after ticket 4; the rest is polish.

## 15. Success criteria

V1 ships when:

- A markdown corpus of ≥100 files can be indexed end-to-end via the sync job.
- An ask query returns merged memory + chunk hits with correct source attribution.
- Re-running the sync job on an unchanged corpus is a no-op (no re-embedding).
- Modifying a file and re-running the sync re-embeds only that file's chunks.
- The hourly LaunchAgent picks up new/changed files without manual intervention.
- All operations stay well under 30 seconds of wall-clock time at the 1,000-note corpus scale.

---

**Next action:** review this spec, decide whether to file the §14 tickets and in what cadence, and resolve any §13 open questions that block the first ticket.
