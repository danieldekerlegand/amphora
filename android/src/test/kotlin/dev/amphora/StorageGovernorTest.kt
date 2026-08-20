package dev.amphora

import android.content.Context
import android.content.ContextWrapper
import dev.amphora.governor.SpaceAllocator
import dev.amphora.governor.StorageGovernor
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StorageGovernorTest {
    @Test
    fun reserveDelegatesToAllocatorBeforeReturningReservation() {
        val root = Files.createTempDirectory("amphora-storage-test").toFile()
        var calls = 0
        try {
            val governor = StorageGovernor(
                TestContext(root),
                SpaceAllocator { _, bytes ->
                    calls++
                    assertEquals(123L, bytes)
                },
            )

            val reservation = governor.reserve("job-1", 123L)

            assertEquals(1, calls)
            assertTrue(reservation.file.exists())
            governor.release(reservation)
        } finally {
            root.deleteRecursively()
        }
    }

    private class TestContext(private val files: File) : ContextWrapper(null) {
        override fun getFilesDir(): File = files
    }
}
