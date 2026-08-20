package dev.amphora

import android.content.Context
import androidx.room.Room
import dev.amphora.core.DefaultUploadEngine
import dev.amphora.core.EventEmitter
import dev.amphora.core.Reconciler
import dev.amphora.core.SourceResolver
import dev.amphora.governor.NetworkGovernor
import dev.amphora.governor.StorageGovernor
import dev.amphora.model.UploadJob
import dev.amphora.store.UploadDao
import dev.amphora.store.UploadDatabase
import dev.amphora.transport.TusTransport
import dev.amphora.work.UploadNotifications
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/** The process-wide object graph shared by the public API and WorkManager workers. */
class AmphoraGraph private constructor(context: Context) {
    private val appContext = context.applicationContext
    val clock = Clock()
    val database: UploadDatabase = Room.databaseBuilder(
        appContext, UploadDatabase::class.java, "amphora.db",
    ).build()
    val dao: UploadDao = database.uploads()
    val notifications = UploadNotifications(appContext)

    private val network = NetworkGovernor(appContext).also { it.start() }
    private val storage = StorageGovernor(appContext)
    private val transport = TusTransport(OkHttpClient())
    private val sources = SourceResolver(appContext)
    private val emitter = object : EventEmitter {
        override fun stateChanged(job: UploadJob) = Unit
        override fun progress(jobId: String, bytesTransferred: Long, total: Long) = Unit
        override fun flush(jobId: String) = Unit
    }

    val engine = DefaultUploadEngine(
        context = appContext,
        dao = dao,
        transport = transport,
        storage = storage,
        network = network,
        sources = sources,
        emitter = emitter,
        now = clock::now,
    )
    private val reconciler = Reconciler(
        context = appContext,
        dao = dao,
        transport = transport,
        engine = engine,
        storage = storage,
        now = clock::now,
    )
    val uploader = AmphoraUploader(appContext, dao, engine, reconciler)

    init {
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            engine.completeReady(reconciler.reconcile())
        }
    }

    class Clock { fun now(): Long = System.currentTimeMillis() }

    companion object {
        fun of(context: Context): AmphoraGraph = AmphoraGraph(context)
    }
}
