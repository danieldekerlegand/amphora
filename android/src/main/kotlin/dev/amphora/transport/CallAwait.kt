package dev.amphora.transport

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Suspend over an OkHttp call.
 *
 * OkHttp has no coroutine adapter of its own, so [TusTransport] referenced a `Call.await()` that
 * had never been written — the first Gradle build of this port (CI run 33038526156) is what
 * surfaced it. Enqueue-and-suspend rather than `execute()` on a dispatcher, so that cancelling
 * the coroutine cancels the HTTP call instead of leaking a socket for the rest of the slice.
 */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response)
        }

        override fun onFailure(call: Call, e: IOException) {
            // Already-cancelled continuations would otherwise surface the cancellation as a
            // TRANSIENT transport error and consume a retry attempt.
            if (continuation.isCancelled) return
            continuation.resumeWithException(e)
        }
    })

    continuation.invokeOnCancellation {
        runCatching { cancel() }
    }
}
