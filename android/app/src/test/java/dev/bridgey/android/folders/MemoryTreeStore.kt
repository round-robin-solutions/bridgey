package dev.bridgey.android.folders

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** A [TreeStore] in memory, for the folder session tests. Names keep their case; lookups are the session's. */
class MemoryTreeStore(override val supportsCreateFolder: Boolean = true) : TreeStore {
    class Node(val id: String, var name: String, val isDirectory: Boolean, var parent: String?) {
        var content: ByteArray = ByteArray(0)
        var published = true
    }

    val nodes = LinkedHashMap<String, Node>()
    private var nextId = 1
    override val rootId: String = "root"

    /** Throws [PlaceUnavailableException] on every call, like a revoked grant. */
    var revoked = false

    /** File creations that fail with an I/O error, by name. */
    val failCreate = HashSet<String>()
    var free: Long? = null
    var childrenCalls = 0

    /** Runs on every children() call: tests advance a fake clock here to make listing slow. */
    var onChildren: () -> Unit = {}

    init {
        nodes[rootId] = Node(rootId, "", true, null)
    }

    private fun check() {
        if (revoked) throw PlaceUnavailableException()
    }

    override fun children(dirId: String): List<TreeNode> {
        check()
        childrenCalls++
        onChildren()
        val dir = nodes[dirId] ?: throw IOException("missing")
        require(dir.isDirectory)
        return nodes.values.filter { it.parent == dirId }.map { TreeNode(it.id, it.name, it.isDirectory) }
    }

    /** Modified times by node ID (tests set them); unset ones are 0. */
    val modified = HashMap<String, Long>()
    var openInputCalls = 0

    override fun entries(dirId: String): List<TreeEntry> = children(dirId).map { node ->
        val stored = nodes.getValue(node.id)
        TreeEntry(
            id = node.id, name = node.name, isDirectory = node.isDirectory,
            size = if (node.isDirectory) null else stored.content.size.toLong(),
            modifiedMillis = modified[node.id],
            mimeType = if (node.isDirectory) null else mimeOf(node.name),
            providerThumbnail = !node.isDirectory && mimeOf(node.name)?.startsWith("image/") == true,
        )
    }

    override fun openInput(fileId: String): InputStream {
        check()
        openInputCalls++
        val node = nodes[fileId]?.takeIf { !it.isDirectory } ?: throw IOException("missing")
        return ByteArrayInputStream(node.content)
    }

    private fun mimeOf(name: String): String? = when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "mp4" -> "video/mp4"
        "pdf" -> "application/pdf"
        "txt" -> "text/plain"
        else -> null
    }

    private fun add(parentId: String, name: String, isDirectory: Boolean): String {
        check()
        val parent = nodes[parentId] ?: throw IOException("missing parent")
        require(parent.isDirectory)
        // Like a real provider, never two children with the same name: a test would see the clash.
        require(nodes.values.none { it.parent == parentId && it.name.equals(name, ignoreCase = true) }) { "duplicate $name" }
        val id = "n${nextId++}"
        nodes[id] = Node(id, name, isDirectory, parentId)
        return id
    }

    override fun createDirectory(parentId: String, name: String): String = add(parentId, name, true)

    override fun createFile(parentId: String, name: String): String {
        if (name in failCreate) throw IOException("create failed")
        return add(parentId, name, false).also { nodes[it]!!.published = false }
    }

    override fun openOutput(fileId: String): OutputStream {
        check()
        val node = nodes[fileId] ?: throw IOException("missing")
        return object : ByteArrayOutputStream() {
            override fun write(b: ByteArray, off: Int, len: Int) {
                if (revoked) throw PlaceUnavailableException()
                super.write(b, off, len)
            }

            override fun close() {
                node.content = toByteArray()
            }
        }
    }

    override fun rename(id: String, name: String): String {
        check()
        val node = nodes[id] ?: throw IOException("missing")
        require(nodes.values.none { it !== node && it.parent == node.parent && it.name.equals(name, ignoreCase = true) }) { "duplicate $name" }
        node.name = name
        return id
    }

    override fun delete(id: String) {
        check()
        val node = nodes.remove(id) ?: throw IOException("missing")
        if (node.isDirectory) nodes.values.filter { it.parent == id }.map { it.id }.forEach { runCatching { delete(it) } }
    }

    override fun publish(fileId: String) {
        nodes[fileId]?.published = true
    }

    override fun freeBytes(): Long? = free

    // Test helpers.

    fun mkdirs(path: String): String {
        var current = rootId
        path.split('/').filter { it.isNotEmpty() }.forEach { part ->
            current = nodes.values.firstOrNull { it.parent == current && it.name == part }?.id ?: add(current, part, true)
        }
        return current
    }

    fun put(path: String, content: ByteArray): String {
        val parent = mkdirs(path.substringBeforeLast('/', ""))
        return add(parent, path.substringAfterLast('/'), false).also { nodes[it]!!.content = content }
    }

    fun find(path: String): Node? {
        var current: Node = nodes[rootId]!!
        path.split('/').filter { it.isNotEmpty() }.forEach { part ->
            current = nodes.values.firstOrNull { it.parent == current.id && it.name == part } ?: return null
        }
        return current
    }

    /** Every path below the root, sorted, folders with a trailing slash. */
    fun tree(): List<String> = nodes.values.filter { it.id != rootId }.map { node ->
        var path = node.name
        var parent = node.parent
        while (parent != null && parent != rootId) {
            val p = nodes[parent]!!
            path = p.name + "/" + path
            parent = p.parent
        }
        if (node.isDirectory) "$path/" else path
    }.sorted()
}
