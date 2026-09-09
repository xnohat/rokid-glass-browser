# Node.js Runtime Integration

This Rokid browser app now supports Node.js script execution via the `run_node` LLM tool.

## Architecture

### Design
- **Approach**: Disposable service process (`:node_runner`)
- **Process Model**: Each `run_node` call starts a new service, executes one script, then kills itself
- **Security**: Same-UID process (accepted risk per owner); runs in isolated `agent_workspace`
- **Never repeated**: `node::Start` is never re-invoked in the browser process

### Components

#### Android (`NodeRunnerService.kt`)
- Isolated service running the Node.js runtime
- Executes scripts in `$filesDir/agent_workspace`
- Bounded timeout (default 30s, max ~90s)
- Captures output (max 16 MB)
- Auto-terminates after execution

#### Kotlin Native Integration (`MainActivity.kt`)
- `runNode` method channel: validates script path, starts service
- Sandbox check: enforces scripts stay in `agent_workspace`
- Returns start status immediately (service runs async)

#### Dart Tool (`browser_agent.dart` + `browser_screen.dart`)
- `run_node` LLM tool with detailed schema
- Parameters: `script`, `args`, `timeout_ms`, `npm` (flag)
- Extended timeout (120s agent timeout) for long-running operations
- Resolves relative paths to workspace

## Node.js Runtime Details

### Version
- **Node 12.19 (EOL)** bundled from official `nodejs-mobile-v0.3.3`
- Source: ARM64 libnode.so from https://github.com/JonathanChoong/nodejs-mobile
- Placed in: `android/app/src/main/jniLibs/arm64-v8a/libnode.so` (~44 MB)

### Known Limitations

#### npm CLI Status
**NOT BUNDLED** — npm is a separate binary and Node 12 npm is severely outdated.

To use npm:
1. Write a `.js` script that programmatically calls `require('npm')`
2. Or download a Node 12-compatible npm binary separately
3. Or use `write_file` to create `package.json`, then invoke `npm install` via `run_shell`

#### Node 12 Limitations
- No native ES modules (require CommonJS)
- No top-level await
- Limited TypeScript support
- Some modern npm packages won't work

**Recommendation**: Use Node 12 for data processing, JSON parsing, file operations, and bash-like scripting. For modern JS, write to disk and use shell tools.

## LLM Tool Usage

```json
{
  "name": "run_node",
  "description": "Execute a Node.js script (v12.19) in a disposable isolated process...",
  "parameters": {
    "type": "object",
    "properties": {
      "script": {
        "type": "string",
        "description": "Path to Node.js script file (relative to agent_workspace, or absolute within it)"
      },
      "args": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Command-line arguments passed to the script"
      },
      "timeout_ms": {
        "type": "integer",
        "description": "Max execution time in milliseconds (default 30000, max ~90000)"
      },
      "npm": {
        "type": "boolean",
        "description": "If true, enable npm CLI commands. Requires npm to be bundled (NOT currently bundled)"
      }
    },
    "required": ["script"]
  }
}
```

## Usage Example

Combine with file tools:

```
Agent command: "Process this CSV and save a JSON summary"

1. read_file("data.csv") → get CSV content
2. write_file("processor.js", "const csv = process.argv[1]; ...") → create Node script
3. run_node(script="processor.js", args=["data.csv"]) → execute
4. read_file("output.json") → get results
5. done("Summary saved to output.json")
```

## Security Notes

- **Same UID**: Both browser and Node processes run as the same system user
  - Secrets/cookies in `filesDir` are accessible to Node
  - Owner accepts this risk for convenience
  - Keep `agent_workspace` free of sensitive data

- **Filesystem Sandbox**: Script paths are validated to stay within `agent_workspace`
  - No `..` traversal outside workspace
  - `run_node` rejects scripts outside workspace

- **Resource Limits**:
  - Output capped at 16 MB
  - Timeout enforced (max ~90s)
  - Process killed if timeout exceeded

## Building

The Node.js runtime is included in all APK builds:

```bash
flutter build apk --release
flutter build aab --release
```

The libnode.so is automatically included via jniLibs/arm64-v8a/ during the Gradle build.

## Troubleshooting

### "Script not found"
- Ensure script exists in `agent_workspace`
- Use absolute paths or paths relative to workspace

### "Timeout after Xms"
- Script ran longer than specified `timeout_ms`
- Increase timeout or optimize script

### Exit code != 0
- Check script syntax and Node 12 compatibility
- Use `console.error()` for debugging (captured in output)

### Missing modules
- Node 12 has limited package support
- Stick to built-in modules: fs, path, util, crypto, etc.
- Pure-JS packages (no native bindings) generally work

## Future Enhancements

1. Bundle npm CLI (requires separate binary or Node 18+)
2. Upgrade to Node 18+ LTS (requires recompiling nodejs-mobile)
3. Add worker pool for parallel script execution
4. Support npm package.json-based workflows
5. Add Node module cache/persistence across runs
