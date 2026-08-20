package dev.amphora.store

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import dev.amphora.model.UploadJob

/**
 * Migrations must move rows in place. Dropping this table silently orphans every in-flight
 * server-side resource, because `uploadUrl` lives nowhere else on the device and tusd offers
 * no enumeration endpoint. See docs/reference/persistence-and-recovery.md §7.
 */
@Database(entities = [UploadJob::class], version = UploadJob.SCHEMA_VERSION, exportSchema = true)
@TypeConverters(EnumConverters::class)
abstract class UploadDatabase : RoomDatabase() {
    abstract fun uploads(): UploadDao
}
