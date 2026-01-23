package com.n8ntry.core

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Handles extraction and installation of the n8n runtime.
 * Now uses native shell commands (tar) to preserve symlinks and permissions.
 */
object RuntimeInstaller {
    private const val TAG = "RuntimeInstaller"

    /**
     * Extracts the given archive to the context's files dir (runtime/ folder).
     * @param archiveFile The tar.gz file to extract.
     * @param context App Context.
     * @return true if successful.
     */
    fun installFromArchive(context: Context, archiveFile: File): Boolean {
        val runtimeDir = File(context.filesDir, "runtime")
        
        // Ensure runtime dir exists (or clean it first?)
        // Safer to clean if we rely on overwrite
        if (runtimeDir.exists()) {
            runtimeDir.deleteRecursively()
        }
        runtimeDir.mkdirs()
        
        Log.i(TAG, "Extracting ${archiveFile.absolutePath} to ${runtimeDir.absolutePath} using tar...")
        
        // 1. Extract using tar (preserves symlinks)
        // Note: Android's tar might behave differently. We assume 'tar -xzf <archive> -C <dest>' works.
        // We use plain ProcessBuilder / Runtime.exec
        try {
            val command = listOf("tar", "-xzf", archiveFile.absolutePath, "-C", runtimeDir.absolutePath)
            val process = Runtime.getRuntime().exec(command.toTypedArray())
            val exitCode = process.waitFor()
            
            if (exitCode != 0) {
                // Read stderr
                val error = process.errorStream.bufferedReader().readText()
                Log.e(TAG, "Tar extraction failed. Code: $exitCode, Error: $error")
                return false
            }
            
            Log.i(TAG, "Extraction successful.")
            
        } catch (e: Exception) {
            Log.e(TAG, "Shell execution failed", e)
            return false
        }
        
        // 2. Set Permissions (Recursive chmod 755)
        Log.i(TAG, "Setting permissions...")
        try {
            // chmod -R 755 runtimeDir
            val chmodCmd = listOf("chmod", "-R", "755", runtimeDir.absolutePath)
            val chmodProc = Runtime.getRuntime().exec(chmodCmd.toTypedArray())
            if (chmodProc.waitFor() != 0) {
                 Log.w(TAG, "chmod failed, strictly not fatal if tar preserved modes, but recommended.")
            }
        } catch (e: Exception) {
            Log.e(TAG, "chmod failed", e)
        }

        // 3. Verify
        val nodeBin = File(runtimeDir, "bin/node")
        if (nodeBin.exists()) { // Executable check might fail if mounted noexec, but filesDir should be okay.
             Log.i(TAG, "Runtime verified.")
             // 4. Clean up archive
             if (archiveFile.exists()) {
                 archiveFile.delete()
                 Log.i(TAG, "Deleted archive.")
             }
             return true
        } else {
             Log.e(TAG, "Node binary not found after extraction.")
             return false
        }
    }

    /**
     * Checks if the runtime is currently installed.
     */
    fun isRuntimeAvailable(context: Context): Boolean {
        val nodeBin = File(context.filesDir, "runtime/bin/node")
        // Basic check. We could check symlinks too but existence is good proxy.
        // We can also check if it's executable using canExecute(), though that depends on file system mount flags.
        return nodeBin.exists()
    }
}
