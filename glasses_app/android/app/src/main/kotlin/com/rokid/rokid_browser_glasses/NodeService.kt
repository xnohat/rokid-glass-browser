package com.rokid.rokid_browser_glasses

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.Process
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Disposable Node process. Manifest assigns android:process=":node"; after one
 * node::Start this process exits because V8 cannot safely be re-entered.
 * Same-UID risk is explicitly accepted by the owner.
 */
class NodeService : Service() {
    companion object {
        const val EXTRA_SCRIPT_PATH = "script_path"
        const val EXTRA_WORKSPACE_PATH = "workspace_path"
        const val EXTRA_STDOUT_PATH = "stdout_path"
        const val EXTRA_STDERR_PATH = "stderr_path"
        const val EXTRA_DONE_PATH = "done_path"
        const val EXTRA_PID_PATH = "pid_path"
        const val EXTRA_NODE_ARGS = "node_args"
        const val EXTRA_SCRIPT_ARGS = "script_args"

        init { System.loadLibrary("node_runner") }
        @JvmStatic external fun startNode(
            args: Array<String>, cwd: String, stdoutPath: String, stderrPath: String
        ): Int
    }

    private val started = AtomicBoolean(false)
    private var lockFile: RandomAccessFile? = null
    private var lock: FileLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!started.compareAndSet(false, true)) {
            writeDone(intent?.getStringExtra(EXTRA_DONE_PATH), -2)
            return START_NOT_STICKY
        }
        val script = intent?.getStringExtra(EXTRA_SCRIPT_PATH)
        val workspace = intent?.getStringExtra(EXTRA_WORKSPACE_PATH)
        val stdout = intent?.getStringExtra(EXTRA_STDOUT_PATH)
        val stderr = intent?.getStringExtra(EXTRA_STDERR_PATH)
        val done = intent?.getStringExtra(EXTRA_DONE_PATH)
        val pidPath = intent?.getStringExtra(EXTRA_PID_PATH)
        if (script == null || workspace == null || stdout == null || stderr == null || done == null || pidPath == null) {
            writeDone(done, -2); stopSelf(); return START_NOT_STICKY
        }

        Thread({
            var exit = -2
            try {
                // Cross-process single-job lock: survives Activity recreation.
                val lf = RandomAccessFile(File(filesDir, "node-runner.lock"), "rw")
                val lk = lf.channel.tryLock()
                if (lk == null) {
                    lf.close(); writeDone(done, -3); return@Thread
                }
                lockFile = lf; lock = lk
                File(pidPath).writeText(Process.myPid().toString())
                val nodeArgs = intent.getStringArrayExtra(EXTRA_NODE_ARGS) ?: emptyArray()
                val scriptArgs = intent.getStringArrayExtra(EXTRA_SCRIPT_ARGS) ?: emptyArray()
                val args = arrayOf("node", *nodeArgs, script, *scriptArgs)
                exit = startNode(args, workspace, stdout, stderr)
            } catch (t: Throwable) {
                try { File(stderr).appendText("Node runner error: ${t.message}\n") } catch (_: Exception) {}
            } finally {
                writeDone(done, exit)
                try { lock?.release() } catch (_: Exception) {}
                try { lockFile?.close() } catch (_: Exception) {}
                try { File(pidPath).delete() } catch (_: Exception) {}
                stopSelf()
                // Node/V8 is one-shot per process.
                Process.killProcess(Process.myPid())
            }
        }, "node-main").start()
        return START_NOT_STICKY
    }

    private fun writeDone(path: String?, code: Int) {
        if (path == null) return
        try {
            val target = File(path)
            val tmp = File(target.parentFile, target.name + ".tmp")
            tmp.writeText(code.toString())
            if (!tmp.renameTo(target)) { target.writeText(code.toString()); tmp.delete() }
        } catch (_: Exception) {}
    }
}
