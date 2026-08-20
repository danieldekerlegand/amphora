package dev.amphora

import dev.amphora.core.UploadStateMachine
import dev.amphora.model.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import java.io.File

class ConformanceVectorsTest {
    @Test
    fun sharedVectorsMatchAndroidPort() {
        val root = JSONObject(File("Tests/Conformance/vectors.json").readText())
        val entries = root.getJSONArray("vectors")
        for (index in 0 until entries.length()) {
            val vector = entries.getJSONObject(index)
            val eventJson = vector.getJSONObject("event")
            if (eventJson.getString("type") == "Enqueue") continue
            val transition = UploadStateMachine.reduce(job(vector.getJSONObject("given")), event(eventJson), 10L)
            val expect = vector.getJSONObject("expect")
            val id = vector.getString("id")
            assertEquals(UploadState.valueOf(expect.getString("state")), transition.job.state, id)
            if (expect.has("serverOffset")) assertEquals(expect.getLong("serverOffset"), transition.job.serverOffset, id)
            if (expect.has("bytesTransferred")) assertEquals(expect.getLong("bytesTransferred"), transition.job.bytesTransferred, id)
            if (expect.has("attemptCount")) assertEquals(expect.getInt("attemptCount"), transition.job.attemptCount, id)
            if (expect.optBoolean("terminateRemote")) assertTrue(transition.effects.any { it is Effect.TerminateRemote }, id)
            if (expect.optJSONArray("requiredEffects")?.toString()?.contains("HEAD_BEFORE_RESUME") == true) assertTrue(transition.effects.contains(Effect.HeadBeforeResume), id)
        }
        assertEquals(40, entries.length())
    }

    private fun job(given: JSONObject): UploadJob = UploadJob(
        id = "vector", sourceKind = SourceKind.FILE, sourceUri = "vector", sizeBytes = given.optLong("sizeBytes", 1000),
        contentType = "application/octet-stream", fingerprint = "vector", endpoint = "https://example.test",
        uploadUrl = given.optString("uploadUrl", null), state = UploadState.valueOf(given.optString("state", "PENDING")),
        blockReason = given.optString("blockReason", "").takeIf { it.isNotEmpty() }?.let { BlockReason.valueOf(it) },
        serverOffset = given.optLong("serverOffset", 0), attemptCount = given.optInt("attemptCount", 0),
        remoteTerminated = given.optBoolean("remoteTerminated", true), createdAt = 1, updatedAt = 1,
    )

    private fun event(value: JSONObject): UploadEvent = when (value.getString("type")) {
        "Schedule" -> UploadEvent.Schedule
        "SourceResolved" -> UploadEvent.SourceResolved(value.getLong("sizeBytes"), value.getString("fingerprint"), value.optString("stagedPath", null))
        "SourceMissing" -> UploadEvent.SourceMissing
        "SpaceDenied" -> UploadEvent.SpaceDenied(value.getLong("needed"))
        "RemoteCreated" -> UploadEvent.RemoteCreated(value.getString("uploadUrl"), value.optLong("expiresAt").takeIf { value.has("expiresAt") && !value.isNull("expiresAt") })
        "OffsetAdvanced" -> UploadEvent.OffsetAdvanced(value.getLong("serverOffset"))
        "TransportComplete" -> UploadEvent.TransportComplete
        "ServerAck" -> UploadEvent.ServerAck
        "TransportError" -> UploadEvent.TransportError(ErrorClass.valueOf(value.getString("errorClass")), value.optString("detail", null))
        "Blocked" -> UploadEvent.Blocked(BlockReason.valueOf(value.getString("blockReason")))
        "Pause" -> UploadEvent.Pause
        "Gone" -> UploadEvent.Gone
        "OffsetDiverged" -> UploadEvent.OffsetDiverged(value.getLong("serverOffset"))
        "DeadlineReached" -> UploadEvent.DeadlineReached
        "AttemptsExhausted" -> UploadEvent.AttemptsExhausted
        "GateCleared" -> UploadEvent.GateCleared
        "Resume" -> UploadEvent.Resume
        "Retry" -> UploadEvent.Retry
        "Cancel" -> UploadEvent.Cancel
        "ProcessStart" -> UploadEvent.ProcessStart
        else -> error("unknown vector event")
    }
}
