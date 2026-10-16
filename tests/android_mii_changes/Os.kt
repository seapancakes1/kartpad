package android.system

import java.io.FileDescriptor
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.FileTime
import java.util.IdentityHashMap
import java.util.concurrent.TimeUnit

object OsConstants { const val O_RDONLY = 0 }

class StructTimespec(@JvmField val tv_sec: Long, @JvmField val tv_nsec: Long)

class StructStat(
    @JvmField val st_dev: Long, @JvmField val st_ino: Long, @JvmField val st_size: Long,
    @JvmField val st_mtim: StructTimespec, @JvmField val st_ctim: StructTimespec,
)

/** tests/android_identity/Os.kt's checked sync seam, plus stat for the Mii queue's file stamps. */
object Os {
    var failSyncSuffix: String? = null
    var failSyncSkip = 0
    private val paths = IdentityHashMap<FileDescriptor, String>()
    private val directories = IdentityHashMap<FileDescriptor, FileChannel>()
    fun register(fd: FileDescriptor, path: String) { paths[fd] = path }
    fun open(path: String, flags: Int, mode: Int): FileDescriptor {
        check(flags == OsConstants.O_RDONLY && mode == 0)
        val fd = FileDescriptor()
        paths[fd] = path
        directories[fd] = FileChannel.open(Path.of(path), StandardOpenOption.READ)
        return fd
    }
    fun fsync(fd: FileDescriptor) {
        if (failSyncSuffix?.let { paths[fd]?.endsWith(it) } == true) {
            if (failSyncSkip > 0) failSyncSkip-- else throw IOException("injected sync failure")
        }
        directories[fd]?.force(true) ?: fd.sync()
    }
    fun close(fd: FileDescriptor) { directories.remove(fd)?.close(); paths.remove(fd) }
    fun stat(path: String): StructStat {
        val info = Files.readAttributes(Path.of(path), "unix:dev,ino,size,lastModifiedTime,ctime")
        fun time(value: Any?): StructTimespec {
            val nanos = (value as FileTime).to(TimeUnit.NANOSECONDS)
            return StructTimespec(nanos / 1_000_000_000, nanos % 1_000_000_000)
        }
        return StructStat((info["dev"] as Number).toLong(), (info["ino"] as Number).toLong(),
            (info["size"] as Number).toLong(), time(info["lastModifiedTime"]), time(info["ctime"]))
    }
}
