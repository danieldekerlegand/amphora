package dev.amphora.core

import dev.amphora.UploadRequest
import dev.amphora.governor.NetworkPolicy
import dev.amphora.model.UploadJob
import org.json.JSONObject

/**
 * Per-job policy, stored as JSON on the row rather than as columns.
 *
 * Deliberate: policy grows (bandwidth caps, time windows, per-tenant rules) and a JSON blob adds
 * fields without a migration, whereas `uploadUrl` and `serverOffset` are queried by the reconciler
 * and must stay real columns.
 */
data class JobPolicy(
    val network: NetworkPolicy = NetworkPolicy.ANY,
    val requiresCharging: Boolean = false,
    val maxAttempts: Int = 12,
    val priority: Int = 0,
)

fun encodePolicy(request: UploadRequest): String = JSONObject().apply {
    put("network", request.networkPolicy.name)
    put("requiresCharging", request.requiresCharging)
    put("maxAttempts", request.maxAttempts)
    put("priority", request.priority)
}.toString()

fun decodePolicy(job: UploadJob): JobPolicy = runCatching {
    val o = JSONObject(job.policyJson)
    JobPolicy(
        network = NetworkPolicy.valueOf(o.optString("network", NetworkPolicy.ANY.name)),
        requiresCharging = o.optBoolean("requiresCharging", false),
        maxAttempts = o.optInt("maxAttempts", 12),
        priority = o.optInt("priority", 0),
    )
}.getOrDefault(JobPolicy())   // a malformed blob must not strand a job; defaults are safe

fun encodeMetadata(metadata: Map<String, String>): String =
    JSONObject(metadata as Map<*, *>).toString()

fun decodeMetadata(json: String): Map<String, String> = runCatching {
    val o = JSONObject(json)
    o.keys().asSequence().associateWith { o.getString(it) }
}.getOrDefault(emptyMap())
