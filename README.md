# SemPOSIX

> An OS-native semantic filesystem for AI agents — where `cat` is search and `ls` is discovery.

[![CI](https://github.com/Venere-Labs/ragfs/actions/workflows/ci.yml/badge.svg)](https://github.com/Venere-Labs/ragfs/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-1.88%2B-orange.svg)](https://www.rust-lang.org)

SemPOSIX extends the POSIX filesystem with semantic awareness for AI agents. Every file operation — search, discover, organize — goes through a vector embedding layer that understands **meaning**, not just filenames. No APIs, no SDKs. Just `cat`, `echo`, and `ls`.

**Built on [ragfs](https://github.com/Venere-Labs/ragfs)** by Venere-Labs.

---

## The Idea

AI agents already know how to use the filesystem. They run `cat` to read, `ls` to list, `echo` to write. SemPOSIX hijacks these familiar operations and makes them semantically powerful:

```bash
# Agent searches for authentication code
cat .ragfs/.query/authentication    # → ranked results with cosine scores

# Agent discovers related files
cat .ragfs/.similar src/auth.rs    # → files ranked by semantic similarity

# Agent reindexes after edits
echo "src/auth.rs" > .ragfs/.reindex   # → triggers embed + store pipeline
```

Every operation is a standard POSIX call. Any agent, any language, any framework — if it can `cat`, it can do semantic search.

---

## Current Features

| Operation | Command | What it does |
|-----------|---------|-------------|
| **Semantic search** | `cat .ragfs/.query/<intent>` | Vector similarity search ranked by cosine score |
| **Find similar** | `cat .ragfs/.similar/<file>` | Discover files semantically related to a source |
| **Index status** | `cat .ragfs/.index` | Show indexed files, chunks, embeddings |
| **Reindex** | `echo "file" > .ragfs/.reindex` | Trigger extraction→chunk→embed→store pipeline |
| **Config** | `cat .ragfs/.config` | Current system configuration |
| **Help** | `cat .ragfs/.help` | Usage documentation |

### Under the Hood

- **Embeddings**: `gte-small` (384-dim) via Candle — runs 100% locally, no API calls
- **Vector store**: LanceDB (Apache Arrow columnar format)
- **FUSE**: Linux kernel filesystem module — mount appears as real filesystem
- **Chunking**: tree-sitter AST-aware splitting for source code

---

## Quick Start

```bash
# Clone and build
git clone git@github.com:manojtummala/SemPOSIX.git
cd SemPOSIX
cargo build --release

# Mount a project
cargo run --release -- mount --foreground ./my-project ./mount-point

# In another terminal — search it
echo "my-project/src/main.rs" > ./mount-point/.ragfs/.reindex
cat ./mount-point/.ragfs/.query/database connection
cat ./mount-point/.ragfs/.similar src/main.rs
```

---

## Architecture

```
Agent/CLI             FUSE Layer                Pipeline              Storage
    |                    |                        |                     |
    | cat .query/X     → | lookup(QUERY_DIR)     |                     |
    |                    |  execute_query() ----→ | embed query text    |
    |                    |                        | vector_search() ---→| LanceDB
    |                    |                        |←-- ranked results --|
    |←-- JSON response   | cache in content_cache |                     |
    |                    |                        |                     |
    | cat .similar/F   → | lookup(SIMILAR_DIR)   |                     |
    |                    |  find_similar() ------→| embed file content  |
    |                    |                        | vector_search() ---→| LanceDB
    |                    |                        |←-- ranked results --|
    |←-- JSON response   | cache in content_cache |                     |
```

### Workspace Crates

| Crate | Role |
|-------|------|
| `ragfs` | CLI binary (entry point) |
| `ragfs-core` | Traits and types (`VectorStore`, `Embedder`, `Chunker`) |
| `ragfs-fuse` | FUSE filesystem, virtual directory routing, inode management |
| `ragfs-store` | LanceDB vector storage |
| `ragfs-embed` | Local embedding generation (Candle + gte-small) |
| `ragfs-extract` | Content extraction (40+ formats) |
| `ragfs-chunker` | Document chunking (tree-sitter for code) |
| `ragfs-index` | Pipeline orchestration and file watching |
| `ragfs-query` | Query parsing and execution |

---

## Roadmap

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | FUSE mount, virtual dirs, `.query/` semantic search | ✅ Done |
| 2 | `.similar/<file>` — find files by semantic similarity | ✅ Done |
| 3 | TrieHI — scoped vector search (dir metadata in LanceDB) | 🔜 Next |
| 4 | Shadow files — `.L0` (summary), `.L1` (declarations), `.L2` (full) | Planned |
| 5 | AST-aware incremental indexing (tree-sitter diff) | Planned |
| 6 | End-to-end evaluation on real codebases | Planned |

See [SEMPOSIX.md](SEMPOSIX.md) for detailed design documents.
See [DEMO.md](DEMO.md) for a runnable demo with verified outputs.

---

## Requirements

- Rust 1.88+
- Linux with FUSE support (`libfuse-dev`)
- ~500MB disk for the embedding model (downloaded on first run)

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT License](LICENSE-MIT) at your option.

---

*Originally forked from [Venere-Labs/ragfs](https://github.com/Venere-Labs/ragfs).*
