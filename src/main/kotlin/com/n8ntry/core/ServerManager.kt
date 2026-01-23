package com.n8ntry.core

import android.content.Context
import android.util.Log
// import androidx.security.crypto.EncryptedSharedPreferences
// import androidx.security.crypto.MasterKey
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.UUID

enum class ServerState {
    STOPPED, STARTING, RUNNING, RETRYING, FATAL_ERROR, STOPPING, ERROR_MISSING_RUNTIME
}

class ServerManager(
    private val context: Context,
    private val processRunner: ProcessRunner = RealProcessRunner(),
    private val keyProvider: KeyProvider = AndroidKeyProvider(context)
) {
    private val _state = MutableStateFlow(ServerState.STOPPED)
    val state: StateFlow<ServerState> = _state.asStateFlow()

    private var currentProcess: RunningProcess? = null
    private var processJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // File Paths
    private val rootDir = context.filesDir
    private val runtimeRoot = File(rootDir, "runtime")
    private val nodeBin = File(runtimeRoot, "bin/node")
    private val userDataDir = File(rootDir, "userdata/n8n")
    private val logDir = File(rootDir, "userdata/logs")
    private val logFile = File(logDir, "n8n.log")
    private val pidFile = File(userDataDir, "n8n.pid")

    companion object {
        private const val TAG = "ServerManager"
        private const val PORT = "5679"
    }

    fun startServer() {
        if (_state.value == ServerState.RUNNING || _state.value == ServerState.STARTING) return
        
        processJob = scope.launch {
            try {
                _state.value = ServerState.STARTING
                println("DEBUG: ServerState set to STARTING")
                
                // 1. Pre-Flight Checks
                println("DEBUG: Checking nodeBin at: " + nodeBin.absolutePath)
                if (!ensureBinariesExist()) {
                    _state.value = ServerState.ERROR_MISSING_RUNTIME
                    Log.e(TAG, "Runtime binaries missing. Use side-load to install.")
                    println("DEBUG: Binaries missing - ERROR_MISSING_RUNTIME")
                    return@launch
                }
                
                // 2. Prepare Environment
                val encryptionKey = getOrGenerateEncryptionKey()
                if (encryptionKey == null) {
                    _state.value = ServerState.FATAL_ERROR
                    Log.e(TAG, "Encryption Key issue. Aborting.")
                    println("DEBUG: Key missing!")
                    return@launch
                }
                
                val env = buildEnvironment(encryptionKey)
                
                // 3. Command construction
                // We run 'node n8n/bin/n8n start' directly or via a wrapper?
                // Spec says we use the Universal Contract paths.
                val n8nEntry = File(runtimeRoot, "lib/node_modules/n8n/bin/n8n")
                // Note: In a real shell script we might use a wrapper, but here we exec directly to control PID.
                // However, the bootstrap script 'n8n-start.sh' is mentioned in the Spec.
                // If we use 'n8n-start.sh', it handles setting env vars. But the spec says ServerManager injects them.
                // Let's invoke the bootstrap script if it exists, otherwise invoke node directly.
                // Re-reading Spec: "Inputs: Module A (n8n-start.sh), Universal Contract (Env Vars)."
                // And "The ProcessBuilder MUST be injected with the full map...".
                
                val bootstrapScript = File(runtimeRoot, "bin/n8n-start.sh")
                val command = if (bootstrapScript.exists()) {
                    // Explicitly use sh to avoid Shebang execution issues on some Android ROMs
                    listOf("/system/bin/sh", bootstrapScript.absolutePath)
                } else {
                     // Fallback: If node is a binary, run directly. If it's a script (mock), this might fail without sh.
                     // But we should prioritize having n8n-start.sh present.
                     // For the mock scenario where node IS a script, we might need sh too, but let's assume
                     // we fix the environment to have n8n-start.sh.
                    listOf(nodeBin.absolutePath, n8nEntry.absolutePath, "start")
                }

                // 4. Start Process
                Log.i(TAG, "Starting n8n process: $command")
                currentProcess = processRunner.start(command, env, userDataDir)
                
                // 5. Stream Consumption (Critical)
                launch(Dispatchers.IO) { consumeStream(currentProcess!!.inputStream, "STDOUT") }
                launch(Dispatchers.IO) { consumeStream(currentProcess!!.errorStream, "STDERR") }
                
                // 6. PID Tracking
                val pid = currentProcess!!.pid()
                if (pid > 0) {
                   pidFile.parentFile?.mkdirs()
                   pidFile.writeText(pid.toString())
                }
                
                _state.value = ServerState.RUNNING
                
                // 7. Wait for exit
                val exitCode = currentProcess!!.waitFor()
                handleExit(exitCode)

            } catch (e: Exception) {
                Log.e(TAG, "Error starting server", e)
                _state.value = ServerState.FATAL_ERROR
                 // Trigger Resilience/Backoff here (handled by Resilience component usually, but we notify state)
            }
        }
    }
    
    fun stopServer() {
        scope.launch {
            _state.value = ServerState.STOPPING
            currentProcess?.let { proc ->
                // Graceful kill
                // In Android executing 'kill -15' requires finding the PID.
                // Since we have the process object, java.lang.Process.destroy() sends SIGTERM usually.
                proc.destroy() 
                
                // Wait 5s
                delay(5000)
                
                if (proc.isAlive()) {
                    Log.w(TAG, "Process ignored SIGTERM. Sending SIGKILL.")
                    proc.destroyForcibly()
                }
            }
            currentProcess = null
            _state.value = ServerState.STOPPED
        }
    }
    
    fun performHardRestart() {
        scope.launch {
            Log.w(TAG, "Performing Hard Restart...")
            stopServer()
            // Wait for stop to complete? stopServer uses launch, so it returns immediately.
            // We should suspend stopServer or use join.
            // For now, simple delay or just calling startServer (which checks state) might race.
            // Let's rely on stopServer setting state.
            delay(6000) // 5s wait in stop + buffer
            startServer()
        }
    }
    
    fun isAlive(): Boolean {
        return currentProcess?.isAlive() == true
    }

    /**
     * Attempts to install runtime from cache and updates state accordingly.
     * @return true if runtime is now available
     */
    private val _downloadProgress = MutableStateFlow(0f)
    val downloadProgress: StateFlow<Float> = _downloadProgress.asStateFlow()

    /**
     * Attempts to check, download, and install runtime.
     * @return true if runtime is now available
     */
    suspend fun checkAndInstallRuntime(): Boolean {
        if (RuntimeInstaller.isRuntimeAvailable(context)) {
            if (_state.value == ServerState.ERROR_MISSING_RUNTIME) {
                _state.value = ServerState.STOPPED
            }
            return true
        }

        // 1. Fetch Metadata
        val metadata = RuntimeDownloader.getLatestMetadata()
        if (metadata == null) {
            Log.e(TAG, "Failed to fetch metadata")
            return false
        }
        
        // 2. Download
        val cacheDir = context.externalCacheDir ?: context.cacheDir
        val archiveFile = File(cacheDir, "n8n-android-arm64.tar.gz")
        
        try {
            _downloadProgress.value = 0.01f // Started
            val downloaded = RuntimeDownloader.downloadRuntime(
                metadata.downloadUrl,
                archiveFile,
                metadata.sha256
            ) { progress ->
                _downloadProgress.value = progress
            }
            
            if (!downloaded) {
                Log.e(TAG, "Download failed or checksum mismatch")
                _downloadProgress.value = 0f
                return false
            } else {
                _downloadProgress.value = 1.0f 
            }
            
            // 3. Extract
            val installed = RuntimeInstaller.installFromArchive(context, archiveFile)
            if (installed) {
                _state.value = ServerState.STOPPED
            }
            return installed
            
        } catch (e: Exception) {
            Log.e(TAG, "Install failed", e)
            _downloadProgress.value = 0f
            return false
        }
    }

    private suspend fun ensureBinariesExist(): Boolean {
        // Check and attempt install from cache if missing
        return checkAndInstallRuntime() // This might try to download which is good
    }
    
    private suspend fun consumeStream(stream: java.io.InputStream, type: String) {
        try {
            logDir.mkdirs()
            stream.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    // Log to Logcat
                    if (type == "STDERR") Log.e("n8n-proc", line) else Log.i("n8n-proc", line)
                    // Append to file (simple synchronous append for now, can be optimized)
                    try {
                        logFile.appendText("$line\n")
                    } catch (e: Exception) {
                        // ignore file write errors to keep process alive
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Stream consumer failed for $type", e)
        }
    }

    private fun getOrGenerateEncryptionKey(): String? {
        return keyProvider.getKey()
    }

    private fun buildEnvironment(encryptionKey: String): Map<String, String> {
        val env = HashMap<String, String>()
        
        // Universal Contract v1.5
        env["HOME"] = userDataDir.absolutePath
        env["N8N_USER_FOLDER"] = userDataDir.absolutePath
        env["LD_LIBRARY_PATH"] = File(runtimeRoot, "lib").absolutePath
        env["PATH"] = "${File(runtimeRoot, "bin").absolutePath}:${System.getenv("PATH")}"
        env["N8N_PORT"] = PORT
        env["N8N_HOST"] = "127.0.0.1"
        env["N8N_LISTEN_ADDRESS"] = "127.0.0.1"
        env["N8N_ENCRYPTION_KEY"] = encryptionKey
        env["DB_TYPE"] = "sqlite"
        env["NODE_OPTIONS"] = "--max-old-space-size=512" // Default legacy profile
        
        return env
    }
    
    private fun handleExit(exitCode: Int) {
        Log.w(TAG, "Process exited with code $exitCode")
        
        if (exitCode == 101) { // Binary Mismatch
             _state.value = ServerState.FATAL_ERROR
             return
        }
        
        if (exitCode == 0 || exitCode == 143) { // 143 = SIGTERM
             _state.value = ServerState.STOPPED
             return
        }
        
        // Crash
        _state.value = ServerState.RETRYING
        // Resilience logic (Exponential backoff) should be triggered here or observed from outside
        // N8nForegroundService observes state and triggers Resilience.scheduleRestart()
    }
}
