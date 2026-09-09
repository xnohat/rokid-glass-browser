package com.rokid.rokid_browser_glasses

import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File

/**
 * Coordinates run_node requests from the Flutter/main process.
 *
 * Each call to [run] starts [NodeService] (which runs in the `:node` Android
 * process), waits for it to write a "done" sentinel file, reads the captured
 * stdout/stderr, enforces a wall-clock timeout, and cleans up temp files.
 *
 * Limits (enforced here; not in the JNI layer):
 *   - Wall-clock timeout: [timeoutMs] (default 30 s, max 120 s)
 *   - Output cap: [maxOutputBytes] per stream (default 64 KB)
 *   - Workspace disk quota: [maxWorkspaceBytes] total (default 100 MB)
 *
 * npm / npx: not bundled; see docs/NODE_RUNTIME.md.  If the caller asks for
 * "npm" or "npx" the script path is rewritten to go through a stub that
 * prepends --ignore-scripts (set via NPM_CONFIG_IGNORE_SCRIPTS env var in
 * the Node script itself).  The caller is responsible for ensuring a copy of
 * npm's JS is present in the workspace.
 */
object NodeRunner {

    data class NodeResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean,
        val diskQuotaExceeded: Boolean = false,
    )

    private const val TAG = "NodeRunner"
    private const val POLL_INTERVAL_MS = 100L
    private const val DEFAULT_TIMEOUT_MS = 30_000L
    private const val MAX_TIMEOUT_MS = 120_000L
    private const val DEFAULT_MAX_OUTPUT = 64 * 1024       // 64 KB per stream
    private const val DEFAULT_MAX_WORKSPACE = 100L * 1024 * 1024  // 100 MB

    /**
     * Run a Node.js script synchronously (from a worker thread – blocks until
     * completion or timeout).
     *
     * @param context        Android context (for startService / cacheDir).
     * @param workspaceDir   The agent workspace directory (disk-quota checked).
     * @param scriptPath     Absolute path to the .js file to execute.
     * @param nodeArgs       Extra Node.js flags (e.g. "--max-old-space-size=64").
     * @param timeoutMs      Wall-clock timeout in ms; clamped to MAX_TIMEOUT_MS.
     * @param maxOutputBytes Max bytes per stdout/stderr stream returned.
     */
    fun run(
        context: Context,
        workspaceDir: File,
        scriptPath: String,
        nodeArgs: Array<String> = emptyArray(),
        scriptArgs: Array<String> = emptyArray(),
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        maxOutputBytes: Int = DEFAULT_MAX_OUTPUT,
    ): NodeResult {

        // Disk quota check before spending a process on it.
        val workspaceSizeBytes = workspaceDir.walkTopDown().sumOf {
            if (it.isFile) it.length() else 0L
        }
        if (workspaceSizeBytes > DEFAULT_MAX_WORKSPACE) {
            return NodeResult(
                exitCode = -1,
                stdout = "",
                stderr = "Workspace disk quota exceeded (${workspaceSizeBytes / 1024 / 1024} MB " +
                         "> ${DEFAULT_MAX_WORKSPACE / 1024 / 1024} MB); " +
                         "delete files before running Node.",
                timedOut = false,
                diskQuotaExceeded = true,
            )
        }

        val id = System.currentTimeMillis()
        val tmpDir = context.cacheDir
        val stdoutFile = File(tmpDir, "node_stdout_$id.txt")
        val stderrFile = File(tmpDir, "node_stderr_$id.txt")
        val doneFile   = File(tmpDir, "node_done_$id.txt")

        // Ensure temp files are absent so polling is reliable.
        doneFile.delete(); stdoutFile.delete(); stderrFile.delete()

        val clampedTimeout = timeoutMs.coerceIn(1_000L, MAX_TIMEOUT_MS)
        val deadline = System.currentTimeMillis() + clampedTimeout

        val intent = Intent(context, NodeService::class.java).apply {
            putExtra(NodeService.EXTRA_SCRIPT_PATH,  scriptPath)
            putExtra(NodeService.EXTRA_STDOUT_PATH,  stdoutFile.absolutePath)
            putExtra(NodeService.EXTRA_STDERR_PATH,  stderrFile.absolutePath)
            putExtra(NodeService.EXTRA_DONE_PATH,    doneFile.absolutePath)
            putExtra(NodeService.EXTRA_NODE_ARGS,    nodeArgs)
            putExtra(NodeService.EXTRA_SCRIPT_ARGS,  scriptArgs)
        }

        try {
            context.startService(intent)
        } catch (e: Exception) {
            return NodeResult(-1, "", "Failed to start NodeService: ${e.message}", false)
        }

        Log.i(TAG, "NodeService started for script=$scriptPath timeout=${clampedTimeout}ms")

        // Poll for the done sentinel written by NodeService before it exits.
        while (!doneFile.exists() && System.currentTimeMillis() < deadline) {
            Thread.sleep(POLL_INTERVAL_MS)
        }

        val timedOut = !doneFile.exists()
        if (timedOut) {
            Log.w(TAG, "Node script timed out after ${clampedTimeout}ms – stopping service")
            try { context.stopService(Intent(context, NodeService::class.java)) } catch (_: Exception) {}
        }

        val exitCode = if (!timedOut) {
            doneFile.readText().trim().toIntOrNull() ?: -1
        } else {
            -1
        }

        val stdoutRaw = safeRead(stdoutFile, maxOutputBytes)
        val stderrRaw = safeRead(stderrFile, maxOutputBytes)

        // Append truncation notice if needed.
        val stdout = if (stdoutFile.exists() && stdoutFile.length() > maxOutputBytes)
            "$stdoutRaw\n[stdout truncated at ${maxOutputBytes / 1024} KB]" else stdoutRaw
        val stderr = if (stderrFile.exists() && stderrFile.length() > maxOutputBytes)
            "$stderrRaw\n[stderr truncated at ${maxOutputBytes / 1024} KB]" else stderrRaw

        // Cleanup temp files.
        doneFile.delete(); stdoutFile.delete(); stderrFile.delete()

        return NodeResult(exitCode, stdout, stderr, timedOut)
    }

    private fun safeRead(file: File, maxBytes: Int): String {
        if (!file.exists()) return ""
        return try {
            val bytes = file.readBytes()
            val slice = if (bytes.size > maxBytes) bytes.copyOf(maxBytes) else bytes
            String(slice, Charsets.UTF_8)
        } catch (_: Exception) {
            ""
        }
    }
}
