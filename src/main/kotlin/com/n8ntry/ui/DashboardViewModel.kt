package com.n8ntry.ui

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.n8ntry.core.ServerManager
import com.n8ntry.core.ServerState
import com.n8ntry.gatekeeper.WhitelistDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.net.Inet4Address
import java.net.NetworkInterface

class DashboardViewModel(application: Application) : AndroidViewModel(application) {

    // Server State
    // Assuming ServerManager is a singleton or accessible via DI. 
    // For this context, we instantiate or retrieve it.
    private val serverManager = ServerManager(application) // In real app, use DI
    val serverState: StateFlow<ServerState> = serverManager.state
    val downloadProgress: StateFlow<Float> = serverManager.downloadProgress

    // Connectivity State
    private val _ipAddress = MutableStateFlow("Determining...")
    val ipAddress: StateFlow<String> = _ipAddress.asStateFlow()

    // Security State (Pending Approvals)
    private val _pendingRequests = MutableStateFlow<List<WhitelistDatabase.Entry>>(emptyList())
    val pendingRequests: StateFlow<List<WhitelistDatabase.Entry>> = _pendingRequests.asStateFlow()

    // Maintenance State
    private val _encryptionKey = MutableStateFlow<String?>(null)
    val encryptionKey: StateFlow<String?> = _encryptionKey.asStateFlow()
    
    // Log State
    private val _logContent = MutableStateFlow("")
    val logContent: StateFlow<String> = _logContent.asStateFlow()
    
    // Reliability State
    private val _isBatteryOptimized = MutableStateFlow(true) // Default to true to avoid initial red flash
    val isBatteryOptimized: StateFlow<Boolean> = _isBatteryOptimized.asStateFlow()

    private var pollJob: Job? = null

    init {
        refreshIp()
        startPolling()
    }

    private fun startPolling() {
        pollJob = viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                // Poll Pending Requests
                val pending = WhitelistDatabase.getAllPending()
                if (_pendingRequests.value != pending) {
                    _pendingRequests.value = pending
                }
                
                // Poll Logs
                readLogs()
                
                // Poll Battery
                checkBatteryOptimization()

                delay(2000) // 2 seconds poll interval
            }
        }
    }

    // Actions
    fun toggleServer() {
        val currentState = serverState.value
        if (currentState == ServerState.RUNNING) {
            serverManager.stopServer()
        } else if (currentState == ServerState.STOPPED || currentState == ServerState.FATAL_ERROR || currentState == ServerState.ERROR_MISSING_RUNTIME) {
            serverManager.startServer()
        }
    }

    /**
     * Checks for runtime in cache and installs if available.
     * Called when user taps "Check for Runtime" button.
     */
    fun checkAndInstallRuntime() {
        viewModelScope.launch(Dispatchers.IO) {
            serverManager.checkAndInstallRuntime()
        }
    }

    fun approveIp(ip: String) {
        viewModelScope.launch(Dispatchers.IO) {
            WhitelistDatabase.allowIp(ip)
            // Trigger immediate refresh or wait for poll
            _pendingRequests.value = WhitelistDatabase.getAllPending()
        }
    }

    fun blockIp(ip: String) {
        viewModelScope.launch(Dispatchers.IO) {
            WhitelistDatabase.blockIp(ip)
            _pendingRequests.value = WhitelistDatabase.getAllPending()
        }
    }

    fun requestBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${getApplication<Application>().packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            getApplication<Application>().startActivity(intent)
        }
    }
    
    fun toggleEncryptionKeyVisibility() {
        if (_encryptionKey.value == null) {
            // Reveal
           // In a real scenario, we might want to prompt auth. For "dumb view", we just read it.
           // We need to read it from the environment or a secure place.
           // ServerManager creates it. We can peek at EncryptedSharedPreferences or reuse ServerManager if it exposed it.
           // Since ServerManager keeps it internal, let's assume we can read it from the same source `AndroidKeyProvider`.
           // Or simplified: We just "show" a placeholder if we can't access it easily, or modify ServerManager to expose it.
           // Spec says: "Read N8N_ENCRYPTION_KEY from EncryptedSharedPreferences".
           // Let's implement helper to read it.
           _encryptionKey.value = com.n8ntry.core.AndroidKeyProvider(getApplication()).getKey() ?: "Key Not Found"
        } else {
            // Hide
            _encryptionKey.value = null
        }
    }

    private fun refreshIp() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val interfaces = NetworkInterface.getNetworkInterfaces()
                while (interfaces.hasMoreElements()) {
                    val iface = interfaces.nextElement()
                    if (iface.isLoopback || !iface.isUp) continue
                    
                    val addresses = iface.inetAddresses
                    while (addresses.hasMoreElements()) {
                        val addr = addresses.nextElement()
                        if (addr is Inet4Address) {
                            _ipAddress.value = addr.hostAddress ?: "Unknown"
                            return@launch
                        }
                    }
                }
                _ipAddress.value = "No Network"
            } catch (e: Exception) {
                _ipAddress.value = "Error"
            }
        }
    }
    
    private fun readLogs() {
        val logFile = java.io.File(getApplication<Application>().filesDir, "userdata/logs/n8n.log")
        if (logFile.exists()) {
            try {
                // Tail last 5KB
                val length = logFile.length()
                val readSize = 5120L // 5KB
                val start = if (length > readSize) length - readSize else 0L
                
                logFile.inputStream().use { stream ->
                    if (start > 0) stream.skip(start)
                    val bytes = stream.readBytes()
                    _logContent.value = String(bytes)
                }
            } catch (e: Exception) {
                // ignore
            }
        } else {
            _logContent.value = "Log file not found."
        }
    }
    
    private fun checkBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
             val pm = getApplication<Application>().getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
             val pkg = getApplication<Application>().packageName
             _isBatteryOptimized.value = pm.isIgnoringBatteryOptimizations(pkg)
        } else {
             _isBatteryOptimized.value = true // Pre-M is safe
        }
    }

    override fun onCleared() {
        super.onCleared()
        pollJob?.cancel()
    }
}
