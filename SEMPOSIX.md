# SemPOSIX: OS-Native Semantic Filesystem for AI Agents

> **Reference Document** - Last updated: 2026-07-16
> Foundation: ragfs v0.2.0 (Forked from Venere-Labs/ragfs)

---

## Table of Contents

1. [Dev Environment Setup](#1-dev-environment-setup)
2. [Quick Reference Commands](#2-quick-reference-commands)
3. [Current Codebase Map](#3-current-codebase-map)
4. [Phase 1: Bootstrap & FUSE Verification ✅](#4-phase-1-bootstrap--fuse-verification--completed)
5. [Phase 2: Virtual Query Directory Mapping (.similarity)](#5-phase-2-virtual-query-directory-mapping-similarity)
6. [Phase 3: TrieHI Integration in LanceDB ✅](#6-phase-3-triehi-integration-in-lancedb-)
7. [Phase 4: Multi-Tiered Shadow Files (.L0, .L1, .L2)](#7-phase-4-multi-tiered-shadow-files-l0-l1-l2)
8. [Phase 5: AST-Aware Incremental Indexing](#8-phase-5-ast-aware-incremental-indexing)
9. [Phase 6: End-to-End Evaluation](#9-phase-6-end-to-end-evaluation)
10. [Build Commands Quick Reference](#10-build-commands-quick-reference)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Dev Environment Setup

### 1.1 VM Specs (Current Working Config)

| Resource | Value | Notes |
|----------|-------|-------|
| RAM | 3.8 GB | Using 8GB swap to avoid OOM |
| CPU | 2 cores | Build uses `-j2` |
| Disk | 20 GB | 92% used — clean up `/tmp/ragfs-build` if tight |
| OS | Ubuntu 24.04 LTS | via Multipass |
| Rust | 1.97.0 | via rustup (not system rustc 1.75) |
| VM Name | `semposix-dev` | |

### 1.2 Create VM (macOS Host)

```bash
brew install --cask multipass

multipass launch --name semposix-dev \
  --ram 4G \
  --disk 20G \
  --cpus 2 \
  24.04

# Add swap (required for 4GB RAM)
multipass exec semposix-dev -- sudo fallocate -l 8G /swapfile
multipass exec semposix-dev -- sudo chmod 600 /swapfile
multipass exec semposix-dev -- sudo mkswap /swapfile
multipass exec semposix-dev -- sudo swapon /swapfile

# Verify
multipass exec semposix-dev -- free -h
```

### 1.3 Install All Dependencies (One-Shot)

```bash
multipass exec semposix-dev -- bash -c '
  sudo apt-get update && sudo apt-get install -y \
    build-essential g++ pkg-config libssl-dev \
    libfuse-dev protobuf-compiler cmake curl fuse3

  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source ~/.cargo/env
  rustc --version
'
```

### 1.4 Clone & Build (One-Shot)

```bash
multipass exec semposix-dev -- bash -c '
  source ~/.cargo/env
  git clone https://github.com/<your-fork>/SemPOSIX.git ~/SemPOSIX
  echo "export CARGO_TARGET_DIR=/tmp/ragfs-build" >> ~/.bashrc
  source ~/.bashrc
  cd ~/SemPOSIX
  cargo build --release -p ragfs -j2
'
```

### 1.5 FUSE Config

```bash
multipass exec semposix-dev -- sudo sed -i "s/#user_allow_other/user_allow_other/" /etc/fuse.conf
```

### 1.6 Mount & Test

```bash
multipass exec semposix-dev -- bash -c '
  source ~/.cargo/env
  mkdir -p ~/test-src ~/test-mount
  echo "fn main() { println!(\"hello\"); }" > ~/test-src/main.rs
  echo "pub fn authenticate(token: &str) -> bool { todo!() }" > ~/test-src/auth.rs
  /tmp/ragfs-build/release/ragfs -v mount ~/test-src ~/test-mount --foreground &
  sleep 2
  ls -a ~/test-mount/.ragfs/
'
```

---

## 2. Quick Reference Commands

### VM Management

```bash
# Shell into VM
multipass shell semposix-dev

# Run single command on VM
multipass exec semposix-dev -- <command>

# Stop/start VM
multipass stop semposix-dev
multipass start semposix-dev

# Check VM resources
multipass exec semposix-dev -- free -h
multipass exec semposix-dev -- df -h /
```

### Build

```bash
# Build ragfs binary (use -j2 for 4GB RAM + swap)
source ~/.cargo/env
cd ~/SemPOSIX
cargo build --release -p ragfs -j2

# Binary location
/tmp/ragfs-build/release/ragfs
```

### Mount/Unmount

```bash
# Mount (foreground, verbose, background)
/tmp/ragfs-build/release/ragfs -v mount ~/test-src ~/test-mount --foreground &
/tmp/ragfs-build/release/ragfs mount ~/test-src ~/test-mount &

# Unmount
fusermount -u ~/test-mount

# Check if mounted
mount | grep ragfs
```

### FUSE Operations (via virtual files)

```bash
# Query (READ - filename is the query)
cat ~/test-mount/.ragfs/.query/hello
cat ~/test-mount/.ragfs/.query/authenticate

# Reindex (WRITE - path to file)
echo "main.rs" > ~/test-mount/.ragfs/.reindex
echo "src/auth.rs" > ~/test-mount/.ragfs/.reindex

# Index stats
cat ~/test-mount/.ragfs/.index

# Config
cat ~/test-mount/.ragfs/.config

# Help
cat ~/test-mount/.ragfs/.help
```

### Debug

```bash
# Mount with verbose logging to file
/tmp/ragfs-build/release/ragfs -v mount ~/test-src ~/test-mount --foreground > /tmp/ragfs-debug.log 2>&1 &

# Watch logs
tail -f /tmp/ragfs-debug.log

# Check specific callbacks
grep -E "readdir|lookup|write|setattr" /tmp/ragfs-debug.log
```

### Common FUSE Callback Flow

```
echo "file" > .ragfs/.reindex
  → lookup(.ragfs)        → RAGFS_DIR_INO
  → lookup(.reindex)      → REINDEX_FILE_INO
  → open(REINDEX_FILE_INO, O_WRONLY|O_CREAT)
  → setattr(size=0)       → truncate before write
  → write(REINDEX_FILE_INO, "file")
  → release

cat .ragfs/.query/hello
  → lookup(.ragfs)        → RAGFS_DIR_INO
  → lookup(.query)        → QUERY_DIR_INO
  → lookup(hello)         → executes query, returns result
  → open(result)
  → read(result)
```

---

## 3. Current Codebase Map

### 2.1 Architecture Overview

```
File on disk
    |
    v
[ragfs-extract]  -- ContentExtractor trait -> ExtractedContent
    |
    v
[ragfs-chunker]  -- Chunker trait -> Vec<ChunkOutput> (tree-sitter for code)
    |
    v
[ragfs-embed]    -- Embedder trait -> Vec<f32> (gte-small, 384-dim, Candle)
    |
    v
[ragfs-store]    -- VectorStore trait -> LanceDB (arrow schema with embeddings)
    |
    v
[ragfs-query]    -- SearchQuery -> Vec<SearchResult>
    |
    v
[ragfs-fuse]     -- FUSE mount with virtual dirs (.ragfs/.query, .similar, etc.)
```

### 2.2 Key Crate Responsibilities

| Crate | Location | Key Files | What It Does |
|-------|----------|-----------|--------------|
| `ragfs-core` | `crates/ragfs-core/src/` | `traits.rs`, `types.rs`, `error.rs` | All shared types: `Chunk`, `FileRecord`, `SearchQuery`, `SearchResult`, `Embedder`/`VectorStore`/`Chunker` traits |
| `ragfs-extract` | `crates/ragfs-extract/src/` | `text.rs`, `pdf.rs`, `registry.rs` | Content extraction by MIME type (text, PDF, markdown, code) |
| `ragfs-chunker` | `crates/ragfs-chunker/src/` | `fixed.rs`, `code.rs`, `semantic.rs`, `registry.rs` | Chunking strategies; `code.rs` uses tree-sitter for AST-aware splits |
| `ragfs-embed` | `crates/ragfs-embed/src/` | `candle.rs`, `cache.rs`, `pool.rs` | Local embeddings via gte-small (384-dim), LRU cache, thread pool |
| `ragfs-store` | `crates/ragfs-store/src/` | `lancedb.rs`, `schema.rs` | LanceDB vector store; arrow schema with embedding, path, language, symbol fields |
| `ragfs-index` | `crates/ragfs-index/src/` | `indexer.rs`, `watcher.rs` | Pipeline orchestrator; file watching via `notify` crate |
| `ragfs-query` | `crates/ragfs-query/src/` | `executor.rs`, `parser.rs` | Query DSL parsing and execution |
| `ragfs-fuse` | `crates/ragfs-fuse/src/` | `filesystem.rs`, `inode.rs`, `ops.rs`, `safety.rs`, `semantic.rs` | FUSE handler with virtual directories, agent ops, safety layer |

### 2.3 Existing Virtual Directory Layout

```
/mnt/semfs/                    # FUSE mount point
├── (real files from source)   # Passthrough to source directory
└── .ragfs/                    # Virtual control plane (ROOT_INO=1 -> RAGFS_DIR_INO=2)
    ├── .query/<text>          # Write query -> returns JSON results (QUERY_DIR_INO=3)
    ├── .search/<text>         # Search results as symlinks (SEARCH_DIR_INO=4)
    ├── .similar/<path>        # Find similar files (SIMILAR_DIR_INO=8)
    ├── .index                 # Index statistics JSON (INDEX_FILE_INO=5)
    ├── .config                # Current config JSON (CONFIG_FILE_INO=6)
    ├── .reindex               # Write path to trigger reindex (REINDEX_FILE_INO=7)
    ├── .help                  # Usage docs (HELP_FILE_INO=9)
    ├── .ops/                  # Agent file operations (OPS_DIR_INO=10)
    │   ├── .create            # Write "path\ncontent"
    │   ├── .delete            # Write "path"
    │   ├── .move              # Write "src\ndst"
    │   ├── .batch             # Write JSON BatchRequest
    │   └── .result            # Read JSON OperationResult
    ├── .safety/               # Protection layer (SAFETY_DIR_INO=20)
    │   ├── .trash/            # Soft-deleted files
    │   ├── .history           # Audit log (JSONL)
    │   └── .undo              # Write operation_id to undo
    └── .semantic/             # AI-powered operations (SEMANTIC_DIR_INO=30)
        ├── .organize          # Write OrganizeRequest JSON
        ├── .similar           # Write path -> find similar
        ├── .cleanup           # Read CleanupAnalysis JSON
        ├── .dedupe            # Read DuplicateGroups JSON
        ├── .pending/          # Proposed plans directory
        ├── .approve           # Write plan_id to execute
        └── .reject            # Write plan_id to cancel
```

### 2.4 LanceDB Schema (Current)

**Chunks table** (`crates/ragfs-store/src/schema.rs`):

```
Fields:
  chunk_id: Utf8 (UUID)
  file_id: Utf8 (UUID)
  file_path: Utf8              <-- path on disk
  content: Utf8                <-- text content of chunk
  content_type: Utf8           <-- "text" | "code" | "markdown" etc.
  chunk_index: UInt32
  start_byte / end_byte: UInt64
  start_line / end_line: UInt32 (nullable)
  parent_chunk_id: Utf8 (nullable)  <-- hierarchy support exists
  depth: UInt8
  embedding: FixedSizeList<Float32, 384>  <-- gte-small output
  embedding_model: Utf8 (nullable)
  indexed_at: Timestamp
  file_mime_type: Utf8 (nullable)
  file_size_bytes: UInt64 (nullable)
  language: Utf8 (nullable)           <-- programming language
  symbol_type: Utf8 (nullable)        <-- Function, Struct, etc.
  symbol_name: Utf8 (nullable)        <-- symbol identifier
```

**What's missing for SemPOSIX:**
- No `dir_prefix` or trie-path fields for hierarchical scoping
- No `tier_level` field for shadow file generation
- No `ast_node_type` for granular AST indexing

### 2.5 Embedding Model

| Property | Value |
|----------|-------|
| Model | `thenlper/gte-small` |
| Dimension | 384 |
| Max tokens | 512 |
| Framework | Candle (local, offline) |
| Cache | LRU, 10k entries default |
| Location | `~/.local/share/ragfs/models/` |

---

## 4. Phase 1: Bootstrap & FUSE Verification ✅ COMPLETED

**Goal:** Verify ragfs compiles, FUSE mounts correctly, basic indexing works.

### 4.1 Checklist

- [x] VM created with 4GB RAM + 8GB swap
- [x] System deps installed (build-essential, g++, pkg-config, libssl-dev, libfuse-dev, protobuf-compiler, cmake)
- [x] `cargo build --release -p ragfs -j2` succeeds
- [x] FUSE mount works with real files + virtual dirs
- [x] Reindex works: `echo "file" > .ragfs/.reindex`
- [x] Semantic query works: `cat .ragfs/.query/hello` returns JSON
- [x] Index stats work: `cat .ragfs/.index`

### 4.2 Bugs Fixed During Phase 1

| Bug | Error | Root Cause | Fix |
|-----|-------|------------|-----|
| Shared mount corruption | `invalid metadata files for crate arrow` | Building on macOS↔Linux shared mount corrupts `.rmeta` files | Use `CARGO_TARGET_DIR=/tmp/ragfs-build` to build on native VM disk |
| ethnum transmute | `cannot transmute between types of different sizes` | ethnum v1.5.2 incompatible with Rust 1.88+ | `cargo update -p ethnum` |
| Missing protoc | `Could not find protoc` | protobuf-compiler not installed | `sudo apt install protobuf-compiler` |
| Missing C++ compiler | `failed to find tool "c++"` | g++ not installed | `sudo apt install g++ build-essential` |
| FUSE allow_other | `option allow_other only allowed if 'user_allow_other' is set` | /etc/fuse.conf not configured | Uncomment `user_allow_other` in `/etc/fuse.conf` |
| OOM during link | `ld terminated with signal 9` | 4GB RAM insufficient for linking | Added 8GB swap |
| **FUSE panic** | `Cannot start a runtime from within a runtime` | `block_on` called inside tokio runtime context | Spawn FUSE on dedicated OS thread via `std::thread::scope` |
| **Reindex EPERM** | `Operation not permitted` on `echo > .reindex` | `setattr` handler blocked all virtual file operations | Allow `setattr(size=0)` on writable virtual files |
| **Reindex EINVAL** | `Invalid argument` after setattr fix | setattr fell through to `InodeKind::Real` check | Return early for virtual file truncate |

### 4.3 Verified Working

```
FUSE mount:       ~/test-src → ~/test-mount (real files + .ragfs/)
ls -a .ragfs/:    .query .search .index .config .reindex .help .similar .ops .safety .semantic
echo > .reindex:  indexes file, stores chunks in LanceDB
cat .query/hello: returns {"query":"hello","results":[{"score":0.97,"content":"fn main()..."}]}
cat .index:       {"total_chunks":2,"total_files":2}
```

---

## 5. Phase 2: Virtual Query Directory Mapping (.similarity) ✅ COMPLETE

**Goal:** Make `.similarity/<path>` return files ranked by cosine similarity to the semantic content of `<path>`.

**Status:** ✅ Implemented and verified. `cat .ragfs/.similar/main.rs` → returns `auth.rs` with score 0.96. `cat .ragfs/.similar/auth.rs` → returns `main.rs` with score 0.96. Bidirectional similarity works. Zero panics in foreground mode.

### 4.1 Changes Made

**`crates/ragfs-fuse/src/inode.rs`:**
- Added `similar_to_ino: HashMap<PathBuf, u64>` field to `InodeTable`
- Added `get_or_create_similar_lookup(parent, source_path)` method using the existing `InodeKind::SimilarLookup` variant

**`crates/ragfs-fuse/src/filesystem.rs`:**
- Added `parent == SIMILAR_DIR_INO` handler in `lookup()` (after `.query` handler)
- Resolves path to absolute, calls `SemanticManager::find_similar()` via `block_on`
- Formats results as JSON with source, file, score, preview
- Creates dynamic inode, caches content in `content_cache`
- `readdir`, `getattr`, `read` handlers unchanged (already work via content_cache)

### 4.2 Build Note

- Daemon mode (`fusermount` background) panics on `block_on` due to forked tokio runtime
- Foreground mode (`--foreground`) works correctly
- This is a known limitation inherited from Phase 1; not a Phase 2 regression

### 4.3 Future Enhancements (optional)

- `ls .ragfs/.similar/<path>/` could list similar files as directory entries (currently returns empty readdir)
- Subpath traversal: `ls .ragfs/.similar/src/auth/` could find similar to all files under `src/auth/`

---

## 6. Phase 3: TrieHI Integration in LanceDB ✅ (Verified 2026-07-13)

**Goal:** Restrict vector searches to directory subscopes using a prefix-tree key in LanceDB metadata, avoiding expensive post-filtering.

### 5.1 Motivation

Current search is global across all indexed files. When an agent works in `src/auth/`, searching the entire project is wasteful and noisy. TrieHI enables:

```
/mnt/semfs/src/auth/.similarity/login.rs
    -> Only searches chunks whose path starts with "src/auth/"
    -> Uses LanceDB metadata filter on dir_path field
```

### 5.2 Schema Extension ✅

Added to `chunks_schema()` in `crates/ragfs-store/src/schema.rs`:

```rust
// Hierarchical path components for TrieHI
Field::new("dir_path", DataType::Utf8, false),      // "src" (relative to root)
Field::new("dir_depth", DataType::UInt16, false),    // depth in tree
Field::new("path_components", DataType::Utf8, false), // comma-separated: "src,auth.rs"
```

### 5.3 Index-time: Building the Trie Keys ✅

In `crates/ragfs-index/src/indexer.rs`, `build_chunk()` now computes relative paths:

```
file_path = /project/src/auth.rs, root = /project
dir_path = "src"                  (parent of rel_path)
dir_depth = 1                     (component count - 1)
path_components = "src,auth.rs"   (comma-separated)
```

### 5.4 Query-time: Scoped Search ✅

Added `scope_prefix: Option<String>` to `SearchQuery` struct. When set, LanceDB applies:
```
dir_path = '{scope}' OR dir_path LIKE '{scope}/%'
```

Implemented in both `search()` and `hybrid_search()` via `only_if()` predicate pushdown.

CLI access: `ragfs query <path> "query" --scope src/`

### 5.5 Verified Results

```
TEST: Global query "authentication" → 6 results (all dirs)
TEST: --scope src/                   → 3 results (src only)
TEST: --scope docs/                  → 2 results (docs only)
TEST: --scope tests/                 → 1 result  (tests only)
TEST: --scope src (no slash)         → 3 results (works same)
TEST: --scope src/ + "database"      → 3 results (src only, database query)
```

### 5.6 Files Modified

- `crates/ragfs-core/src/types.rs` - Added `dir_path`, `dir_depth`, `path_components` to `Chunk`; `scope_prefix` to `SearchQuery`
- `crates/ragfs-store/src/schema.rs` - Added 3 Arrow fields
- `crates/ragfs-store/src/lancedb.rs` - Updated schema, `chunks_to_batch()`, `batch_to_chunks()`, `search()`, `hybrid_search()` with scope filter
- `crates/ragfs-index/src/indexer.rs` - `build_chunk()` populates relative TrieHI fields
- `crates/ragfs-query/src/executor.rs` - `scope_prefix` support via `with_scope()`
- `crates/ragfs/src/main.rs` - `--scope` CLI flag for `query` command

---

## 7. Phase 4: Multi-Tiered Shadow Files (.L0, .L1, .L2)

**Goal:** Expose hierarchical abstractions of source files to save agent context window costs.

### 6.1 Tier Definitions

| Tier | Suffix | Content | Generation Method |
|------|--------|---------|-------------------|
| L0 | `.L0` | Compressed abstract summary (1-2 sentences) | Regex/token extraction or lightweight local model |
| L1 | `.L1` | Struct/function/enum declarations only | tree-sitter AST walk, extract declaration nodes |
| L2 | (original) | Full raw file content | Direct passthrough |

### 6.2 Example

Given `database.rs`:
```rust
pub struct DatabasePool { max_size: usize, connections: Vec<Connection> }
impl DatabasePool {
    pub async fn new(config: DbConfig) -> Result<Self> { ... }
    pub async fn get_connection(&self) -> Result<Connection> { ... }
    pub async fn execute(&self, query: &str) -> Result<Row> { ... }
}
```

Virtual files exposed:
- `database.rs.L0` -> `"Database connection pool managing connections with configurable max size"`
- `database.rs.L1` -> `"pub struct DatabasePool; impl DatabasePool { pub async fn new(); pub async fn get_connection(); pub async fn execute(); }"`
- `database.rs` -> full content

### 6.3 FUSE Implementation

**New InodeKind variants** in `inode.rs`:

```rust
/// Shadow file tier L0 (abstract summary)
ShadowL0 { source_path: PathBuf },
/// Shadow file tier L1 (declarations only)
ShadowL1 { source_path: PathBuf },
```

**New inode numbers** (starting from 200):

```rust
pub const SHADOW_BASE_INO: u64 = 200;
```

Dynamic allocation for shadow files since there can be many.

**lookup handler** in `filesystem.rs`:

When resolving `foo.rs.L0` or `foo.rs.L1`:
1. Strip the `.L0`/`.L1` suffix to get real filename
2. Check if real file exists in source
3. Generate L0/L1 content on-demand (cache in `content_cache`)
4. Return virtual inode with generated content

**read handler** in `filesystem.rs`:

When reading a shadow file inode:
1. Look up source path from `InodeKind::ShadowL0/L1`
2. Check `content_cache` for pre-generated content
3. If miss, generate via tree-sitter AST walk
4. Return cached/generated content

### 6.4 Content Generation

**L1 generation** (`crates/ragfs-chunker/src/code.rs` extend existing tree-sitter logic):

```rust
fn generate_declarations(source: &str, language: &str) -> String {
    // Use tree-sitter to walk AST
    // Extract: function definitions, struct definitions,
    //          enum definitions, impl blocks, trait definitions
    // Return concatenated declarations without bodies
}
```

**L0 generation** (new module `crates/ragfs-chunker/src/summary.rs`):

For Phase 4, use a fast heuristic approach:
1. Extract file-level doc comments (`///` or `//!`)
2. Extract struct/enum doc comments
3. Concatenate first N sentences as summary
4. (Future: plug in a local summarization model)

### 6.5 Caching Strategy

- L0/L1 content cached in `content_cache: HashMap<u64, String>` (already exists in `RagFs` struct)
- Cache invalidation: on file modification detected by `notify` watcher
- TTL: invalidate when source file `mtime` changes

---

## 8. Phase 5: AST-Aware Incremental Indexing

**Goal:** When files change, only re-index modified AST nodes (functions, structs) instead of entire files.

### 7.1 Current State

- `ragfs-index/src/watcher.rs` uses `notify` crate to detect file changes
- On change, triggers full re-index of the file
- `ragfs-chunker/src/code.rs` already has tree-sitter based code chunking

### 7.2 Incremental Strategy

```
File modified on disk
    |
    v
[notify watcher detects change]
    |
    v
[Parse old version vs new version with tree-sitter]
    |
    v
[Diff AST nodes: identify added/modified/removed functions/structs]
    |
    v
[Only re-embed changed nodes]
    |
    v
[Update LanceDB: delete old chunks for changed nodes, insert new ones]
```

### 7.3 Implementation

**New module: `crates/ragfs-chunker/src/diff.rs`**

```rust
pub struct AstDiff {
    pub added: Vec<AstNode>,
    pub modified: Vec<AstNode>,
    pub removed: Vec<AstNode>,
}

pub fn diff_ast(old_source: &str, new_source: &str, language: &str) -> AstDiff {
    // Parse both versions with tree-sitter
    // Walk AST, compare node types + names + content
    // Return diff
}
```

**Modify `ragfs-index/src/indexer.rs`**:

```rust
async fn incremental_index(&self, path: &Path) -> Result<()> {
    let old_chunks = self.store.get_chunks_for_file(path).await?;
    let new_content = fs::read_to_string(path)?;
    let old_content = /* retrieve from cache or chunk content */;

    let diff = diff_ast(&old_content, &new_content, language);

    // Remove chunks for deleted/modified nodes
    for node in &diff.removed {
        self.store.delete_chunks_by_symbol(path, &node.name).await?;
    }
    for node in &diff.modified {
        self.store.delete_chunks_by_symbol(path, &node.name).await?;
    }

    // Embed and insert only changed nodes
    for node in diff.added.iter().chain(diff.modified.iter()) {
        let embedding = self.embedder.embed_text(&node.content, &config).await?;
        self.store.upsert_chunks(&[chunk_with_embedding]).await?;
    }

    // Cache new content for future diffs
    self.content_cache.insert(path, new_content);
}
```

### 7.4 LanceDB Schema Addition

Add to chunks schema:

```rust
Field::new("ast_node_type", DataType::Utf8, true),  // "function", "struct", "impl"
Field::new("ast_node_name", DataType::Utf8, true),   // "DatabasePool::new"
```

This enables targeted deletion: `DELETE FROM chunks WHERE file_path = ? AND ast_node_name = ?`

---

## 9. Phase 6: End-to-End Evaluation

### 8.1 Test Scenarios

| Scenario | Command | Expected Result |
|----------|---------|-----------------|
| Mount | `ragfs mount ~/project ~/mnt --foreground` | FUSE mount succeeds |
| Virtual dirs | `ls ~/mnt/.ragfs/` | Shows .query, .search, .similar, .ops, .safety, .semantic |
| Index | `echo ~/project > ~/mnt/.ragfs/.reindex` | Index builds without error |
| Query | `echo "auth middleware" > ~/mnt/.ragfs/.query/auth` | Returns JSON with ranked results |
| Similarity | `cat ~/mnt/.ragfs/.similar/src/auth/login.rs` | Returns files similar to login.rs |
| Shadow L0 | `cat ~/mnt/.ragfs/src/database.rs.L0` | Returns 1-2 sentence summary |
| Shadow L1 | `cat ~/mnt/.ragfs/src/database.rs.L1` | Returns declarations only |
| Agent ops | `echo -e "src/test.rs\nfn test() {}" > ~/mnt/.ragfs/.ops/.create` | File created, .result shows success |
| Safety | Read `.safety/.history` | Shows operation audit trail |
| Scoped search | `ls ~/mnt/.similarity/src/auth/` | Only files from src/auth/ ranked |

### 8.2 Agent Validation Script

```bash
#!/bin/bash
# test_agent.sh - Run inside mounted directory
MOUNT=/mnt/semfs

# 1. Can agent discover files?
ls $MOUNT/src/

# 2. Can agent query semantically?
echo "database connection" > $MOUNT/.ragfs/.query/db

# 3. Can agent find similar files?
cat $MOUNT/.ragfs/.similar/src/main.rs

# 4. Can agent read shadow abstractions?
head -5 $MOUNT/src/main.rs.L0
head -20 $MOUNT/src/main.rs.L1

# 5. Can agent create files via ops?
echo -e "src/new_module.rs\npub mod utils;" > $MOUNT/.ragfs/.ops/.create
cat $MOUNT/.ragfs/.ops/.result

# 6. Can agent undo?
echo "<operation_id>" > $MOUNT/.ragfs/.safety/.undo

# 7. Verify no kernel panics or hangs
echo "All tests passed"
```

---

## 10. Build Commands Quick Reference

```bash
# Full release build (use -j2 on 8GB RAM)
cargo build --release -j2

# Build only ragfs binary
cargo build --release -p ragfs

# Build Python bindings
cargo build --release -p ragfs-python

# Run all tests
cargo test --all

# Run specific crate tests
cargo test -p ragfs-fuse

# Format
cargo fmt --all

# Lint
cargo clippy --all-targets -- -D warnings

# Clean
cargo clean

# Set target dir (avoid shared mount issues)
export CARGO_TARGET_DIR=/tmp/ragfs-build
```

---

## 11. Troubleshooting

### Build Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `invalid metadata files for crate arrow` | Shared mount corruption | Build on native disk, not shared mount |
| `cannot transmute between types of different sizes` (ethnum) | Rust version incompatibility | `cargo update -p ethnum` |
| `Could not find protoc` | Missing protobuf compiler | `sudo apt install protobuf-compiler` |
| `failed to find tool "c++"` | Missing C++ compiler | `sudo apt install g++ build-essential` |
| `ld terminated with signal 9` (OOM) | Insufficient RAM | Add swap or increase VM RAM to 12GB |
| OpenSSL not found | Missing dev packages | `sudo apt install libssl-dev pkg-config` |

### Runtime Errors

| Error | Fix |
|-------|-----|
| `Cannot start a runtime from within a runtime` | FUSE must run on dedicated OS thread, not inside tokio runtime. Fix in `main.rs`: use `std::thread::scope` for `fuser::mount2` |
| `Operation not permitted` on `echo > .reindex` | `setattr` handler blocks virtual files. Allow `setattr(size=0)` on writable virtual inodes |
| `Invalid argument` after setattr fix | setattr falls through to `InodeKind::Real` check. Return early for virtual file truncate |
| FUSE `allow_other` error | `sudo sed -i "s/#user_allow_other/user_allow_other/" /etc/fuse.conf` |
| FUSE mount permission denied | `sudo usermod -aG fuse $USER` then re-login |
| Model download fails | Check network; models cache at `~/.local/share/ragfs/models/` |
| Mount hangs | `fusermount -u <mountpoint>` or `kill -9 $(pgrep ragfs)` |

### Multipass Commands

```bash
# List VMs
multipass list

# Shell into VM
multipass shell semposix-dev

# Stop VM
multipass stop semposix-dev

# Delete VM
multipass delete semposix-dev

# Recreate with more RAM
multipass launch --name semposix-dev --ram 12G --disk 40G --cpus 4 24.04

# Share directory (read-only from VM)
multipass mount /Users/manoj/SemPOSIX semposix-dev:/media/ubuntu/SemPOSIX
```

---

## File Change Summary by Phase

| Phase | Files Modified | New Files |
|-------|---------------|-----------|
| Phase 1 | `main.rs` (FUSE thread fix), `filesystem.rs` (setattr/create handlers) | `setup-ubuntu.sh`, `SEMPOSIX.md` |
| Phase 2 | `filesystem.rs`, `inode.rs`, `lancedb.rs` | None |
| Phase 3 | `schema.rs`, `lancedb.rs`, `types.rs`, `indexer.rs`, `main.rs`, `executor.rs` | None |
| Phase 4 | `filesystem.rs`, `inode.rs`, `code.rs` | `crates/ragfs-chunker/src/summary.rs` |
| Phase 5 | `indexer.rs`, `watcher.rs`, `schema.rs`, `types.rs` | `crates/ragfs-chunker/src/diff.rs` |
| Phase 6 | None (evaluation only) | `test_agent.sh` |
