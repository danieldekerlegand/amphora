package dev.amphora.governor

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Network state as a policy input, not an error source.
 *
 * The critical behaviour: a Wi-Fi → cellular handover kills the in-flight socket. That is a
 * TRANSIENT transport error followed by HEAD-and-resume, never a job failure. Treating it as a
 * failure is the bug that made the original AWS-SDK implementation feel broken on trains.
 */
class NetworkGovernor(context: Context) {

    private val cm = context.getSystemService(ConnectivityManager::class.java)

    private val _status = MutableStateFlow(NetworkStatus.UNAVAILABLE)
    val status: StateFlow<NetworkStatus> = _status

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            _status.value = classify(cm.getNetworkCapabilities(network))
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
            // Fires on metered↔unmetered flips (including TEMPORARILY_NOT_METERED) without the
            // network going away, so policy must be re-evaluated here too.
            _status.value = classify(caps)
        }

        override fun onLost(network: Network) {
            _status.value = NetworkStatus.UNAVAILABLE
        }
    }

    fun start() = cm.registerNetworkCallback(
        NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(),
        callback,
    )

    fun stop() = cm.unregisterNetworkCallback(callback)

    private fun classify(caps: NetworkCapabilities?): NetworkStatus = when {
        caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ->
            NetworkStatus.UNAVAILABLE
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED) ->
            NetworkStatus.UNMETERED
        else -> NetworkStatus.METERED
    }

    fun permits(policy: NetworkPolicy): Boolean = when (policy) {
        NetworkPolicy.ANY -> _status.value != NetworkStatus.UNAVAILABLE
        NetworkPolicy.UNMETERED_ONLY -> _status.value == NetworkStatus.UNMETERED
    }
}

enum class NetworkStatus { UNAVAILABLE, METERED, UNMETERED }
enum class NetworkPolicy { ANY, UNMETERED_ONLY }
