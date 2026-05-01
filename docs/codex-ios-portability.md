# Codex iOS 12 Portability Notes

This document records the local Codex Rust portability edits used to build the
`codex` binary that CodexMobile bundles locally.

## Known-Good Baseline

- Upstream repository: `https://github.com/openai/codex`
- Local checkout path used during validation: `/Users/angad/workspace/codex`
- Baseline commit: `f5497f4d65bdcf3105b7d2f97b19c95209f040e6`
- Target: `aarch64-apple-ios`
- Minimum OS: iOS `12.0`
- Verified binary: `codex-rs/target/aarch64-apple-ios/release/codex`
- Verified SHA256: `6b615930d00d2e5cd98381a345f5d51fb916f843cf5e481d09a55fa3909d2184`
- Verified Mach-O load command: `LC_BUILD_VERSION minos 12.0`

The Codex checkout was the official upstream repo plus the local portability
edits below. A pristine upstream checkout may fail until equivalent changes are
applied upstream or locally.

## Why Edits Were Needed

The iOS build failed on desktop-oriented dependencies and integrations that are
not usable inside the jailbroken iPhone 6 CodexMobile environment:

- `codex-code-mode` pulls in the v8-backed runtime and `deno_core_icudata`.
  That path is not needed for the current mobile app-builder workflow and is
  not portable to the iOS target as-is.
- TUI clipboard code uses `arboard`, which does not support iOS.
- Process hardening cfg gates needed to include iOS in the Unix core-limit
  constant gate used by shared code.

The edits intentionally make the iOS build compile by disabling unsupported
desktop integrations, not by pretending they work on-device.

## Changed Files

In the Codex checkout:

- `codex-rs/code-mode/Cargo.toml`
- `codex-rs/code-mode/src/lib.rs`
- `codex-rs/code-mode/src/runtime_stub.rs`
- `codex-rs/code-mode/src/service_stub.rs`
- `codex-rs/process-hardening/src/lib.rs`
- `codex-rs/tui/Cargo.toml`
- `codex-rs/tui/src/clipboard_copy.rs`
- `codex-rs/tui/src/clipboard_paste.rs`

## Edit Summary

### `codex-rs/code-mode/Cargo.toml`

Move `deno_core_icudata` behind a non-iOS target dependency:

```toml
[target.'cfg(not(target_os = "ios"))'.dependencies]
deno_core_icudata = { workspace = true }
```

`v8` remained in the checked-out file during the known-good build, but the
runtime/service module gates are what kept the v8-backed code path out of the
iOS build.

### `codex-rs/code-mode/src/lib.rs`

Gate the real runtime/service off for iOS and export stubs instead:

```rust
#[cfg(not(target_os = "ios"))]
mod runtime;
#[cfg(target_os = "ios")]
mod runtime_stub;
#[cfg(not(target_os = "ios"))]
mod service;
#[cfg(target_os = "ios")]
mod service_stub;
```

The public exports are similarly split so other Codex crates keep compiling
against the same type names on iOS.

### `codex-rs/code-mode/src/runtime_stub.rs`

The stub preserves the public request/response types needed by downstream
crates:

```rust
use std::collections::HashMap;

use codex_protocol::ToolName;
use serde::Serialize;
use serde_json::Value as JsonValue;

use crate::description::ToolDefinition;
use crate::response::FunctionCallOutputContentItem;

pub const DEFAULT_EXEC_YIELD_TIME_MS: u64 = 10_000;
pub const DEFAULT_WAIT_YIELD_TIME_MS: u64 = 10_000;
pub const DEFAULT_MAX_OUTPUT_TOKENS_PER_EXEC_CALL: usize = 10_000;

#[derive(Clone, Debug)]
pub struct ExecuteRequest {
    pub cell_id: String,
    pub tool_call_id: String,
    pub enabled_tools: Vec<ToolDefinition>,
    pub source: String,
    pub stored_values: HashMap<String, JsonValue>,
    pub yield_time_ms: Option<u64>,
    pub max_output_tokens: Option<usize>,
}

#[derive(Clone, Debug)]
pub struct WaitRequest {
    pub cell_id: String,
    pub yield_time_ms: u64,
    pub terminate: bool,
}

#[derive(Debug, PartialEq)]
pub enum WaitOutcome {
    LiveCell(RuntimeResponse),
    MissingCell(RuntimeResponse),
}

impl From<WaitOutcome> for RuntimeResponse {
    fn from(outcome: WaitOutcome) -> Self {
        match outcome {
            WaitOutcome::LiveCell(response) | WaitOutcome::MissingCell(response) => response,
        }
    }
}

#[derive(Debug, PartialEq, Serialize)]
pub enum RuntimeResponse {
    Yielded {
        cell_id: String,
        content_items: Vec<FunctionCallOutputContentItem>,
    },
    Terminated {
        cell_id: String,
        content_items: Vec<FunctionCallOutputContentItem>,
    },
    Result {
        cell_id: String,
        content_items: Vec<FunctionCallOutputContentItem>,
        stored_values: HashMap<String, JsonValue>,
        error_text: Option<String>,
    },
}

#[derive(Debug)]
pub struct CodeModeNestedToolCall {
    pub cell_id: String,
    pub runtime_tool_call_id: String,
    pub tool_name: ToolName,
    pub input: Option<JsonValue>,
}
```

### `codex-rs/code-mode/src/service_stub.rs`

The stub service returns a clear unsupported response instead of trying to run
the desktop code-mode runtime:

```rust
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;

use async_trait::async_trait;
use serde_json::Value as JsonValue;
use tokio_util::sync::CancellationToken;

use crate::runtime_stub::CodeModeNestedToolCall;
use crate::runtime_stub::ExecuteRequest;
use crate::runtime_stub::RuntimeResponse;
use crate::runtime_stub::WaitOutcome;
use crate::runtime_stub::WaitRequest;

#[async_trait]
pub trait CodeModeTurnHost: Send + Sync {
    async fn invoke_tool(
        &self,
        invocation: CodeModeNestedToolCall,
        cancellation_token: CancellationToken,
    ) -> Result<JsonValue, String>;

    async fn notify(&self, call_id: String, cell_id: String, text: String) -> Result<(), String>;
}

pub struct CodeModeService {
    stored_values: tokio::sync::Mutex<HashMap<String, JsonValue>>,
    next_cell_id: AtomicU64,
}

impl CodeModeService {
    pub fn new() -> Self {
        Self {
            stored_values: tokio::sync::Mutex::new(HashMap::new()),
            next_cell_id: AtomicU64::new(1),
        }
    }

    pub async fn stored_values(&self) -> HashMap<String, JsonValue> {
        self.stored_values.lock().await.clone()
    }

    pub async fn replace_stored_values(&self, values: HashMap<String, JsonValue>) {
        *self.stored_values.lock().await = values;
    }

    pub fn allocate_cell_id(&self) -> String {
        self.next_cell_id
            .fetch_add(1, Ordering::Relaxed)
            .to_string()
    }

    pub async fn execute(&self, request: ExecuteRequest) -> Result<RuntimeResponse, String> {
        Ok(unsupported_response(request.cell_id))
    }

    pub async fn wait(&self, request: WaitRequest) -> Result<WaitOutcome, String> {
        Ok(WaitOutcome::MissingCell(unsupported_response(
            request.cell_id,
        )))
    }

    pub fn start_turn_worker(&self, _host: Arc<dyn CodeModeTurnHost>) -> CodeModeTurnWorker {
        CodeModeTurnWorker {}
    }
}

impl Default for CodeModeService {
    fn default() -> Self {
        Self::new()
    }
}

pub struct CodeModeTurnWorker {}

fn unsupported_response(cell_id: String) -> RuntimeResponse {
    RuntimeResponse::Result {
        cell_id,
        content_items: Vec::new(),
        stored_values: HashMap::new(),
        error_text: Some("code mode is unavailable in the iOS build".to_string()),
    }
}
```

### `codex-rs/tui/Cargo.toml`

Exclude `arboard` on iOS:

```toml
[target.'cfg(not(any(target_os = "android", target_os = "ios")))'.dependencies]
arboard = { workspace = true }
```

### `codex-rs/tui/src/clipboard_copy.rs`

Treat iOS like Android for native clipboard unavailability:

```rust
#[cfg(any(target_os = "android", target_os = "ios"))]
fn arboard_copy(_text: &str) -> Result<Option<ClipboardLease>, String> {
    Err("native clipboard unavailable on this platform".to_string())
}
```

The non-Linux native clipboard function is gated with:

```rust
#[cfg(all(
    not(any(target_os = "android", target_os = "ios")),
    not(target_os = "linux")
))]
```

### `codex-rs/tui/src/clipboard_paste.rs`

Treat iOS like Android for image paste:

```rust
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn paste_image_as_png() -> Result<(Vec<u8>, PastedImageInfo), PasteImageError> {
    ...
}

#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn paste_image_as_png() -> Result<(Vec<u8>, PastedImageInfo), PasteImageError> {
    Err(PasteImageError::ClipboardUnavailable(
        "clipboard image paste is unsupported on this platform".into(),
    ))
}
```

`paste_image_to_temp_png` uses the same `not(any(target_os = "android",
target_os = "ios"))` / `any(target_os = "android", target_os = "ios")` split.

### `codex-rs/process-hardening/src/lib.rs`

Include iOS in the cfg around `SET_RLIMIT_CORE_FAILED_EXIT_CODE`:

```rust
#[cfg(any(
    target_os = "linux",
    target_os = "android",
    target_os = "ios",
    target_os = "macos",
    target_os = "freebsd",
    target_os = "netbsd",
    target_os = "openbsd"
))]
const SET_RLIMIT_CORE_FAILED_EXIT_CODE: i32 = 7;
```

## Build Command

After applying equivalent portability edits in the Codex checkout, run from this
workspace:

```sh
scripts/build_codex_ios12.sh --codex-repo /path/to/codex
```

For a fast verification of an already-built artifact:

```sh
scripts/build_codex_ios12.sh --codex-repo /path/to/codex --skip-build --no-copy
```

The script verifies:

- target artifact exists at `codex-rs/target/aarch64-apple-ios/release/codex`
- `file` reports `Mach-O 64-bit executable arm64`
- `otool -l` reports `LC_BUILD_VERSION minos 12.0`

## Current Limitation

The current mobile build disables Code Mode on iOS. That is acceptable for
CodexMobile's current app-builder path because CodexMobile drives the CLI as a
local agent and maps command/file activity in the native UI. If a future
CodexMobile version needs full nested Code Mode runtime support on-device, the
stub should be replaced with a real iOS-compatible implementation rather than
silently expanding this patch.
