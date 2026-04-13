package com.hengqutiandi.vncviewer.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.hengqutiandi.vncviewer.model.ConnectionItem
import com.hengqutiandi.vncviewer.model.connectionFromJson
import com.hengqutiandi.vncviewer.model.generateConnectionId
import com.hengqutiandi.vncviewer.model.toJson
import org.json.JSONArray

class ConnectionsRepository(context: Context) {
    private val prefs = context.getSharedPreferences("vnc_store", Context.MODE_PRIVATE)
    private val securePrefs = runCatching {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "vnc_store_secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }.getOrElse { prefs }

    fun loadConnections(): List<ConnectionItem> {
        val raw = prefs.getString(KEY_CONNECTIONS, "").orEmpty()
        val migrated = migrateLegacyConnection()
        if (raw.isBlank()) {
            return migrated.sortedByDescending { it.lastUsedAt }
        }

        return try {
            val array = JSONArray(raw)
            val needsSecureMigration = arrayNeedsSecureMigration(array)
            val connections = buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    connectionFromJson(item)?.let { connection ->
                        val securePassword = securePrefs.getString(passwordKey(connection.id), null)
                        val fallbackPassword = item.optString("password")
                        val resolvedPassword = if (connection.storePassword) {
                            securePassword ?: fallbackPassword
                        } else {
                            ""
                        }
                        add(
                            connection.copy(
                                password = resolvedPassword.orEmpty(),
                                storePassword = connection.storePassword && resolvedPassword.orEmpty().isNotEmpty()
                            )
                        )
                    }
                }
            }.sortedByDescending { it.lastUsedAt }
            if (needsSecureMigration) {
                saveConnections(
                    connections = connections,
                    selectedId = loadSelectedConnectionId(),
                    address = prefs.getString(KEY_ADDRESS, "").orEmpty(),
                    user = prefs.getString(KEY_USER, "").orEmpty(),
                    password = ""
                )
            }
            connections
        } catch (_: Throwable) {
            migrated.sortedByDescending { it.lastUsedAt }
        }
    }

    fun loadSelectedConnectionId(): String = prefs.getString(KEY_SELECTED_CONNECTION_ID, "").orEmpty()

    fun saveConnections(connections: List<ConnectionItem>, selectedId: String, address: String, user: String, password: String) {
        val array = JSONArray()
        val secureEditor = securePrefs.edit()
        val activePasswordKeys = mutableSetOf<String>()
        connections.forEach { connection ->
            array.put(connection.toJson(includePassword = false))
            val key = passwordKey(connection.id)
            activePasswordKeys += key
            if (connection.storePassword && connection.password.isNotEmpty()) {
                secureEditor.putString(key, connection.password)
            } else {
                secureEditor.remove(key)
            }
        }
        securePrefs.all.keys
            .filter { it.startsWith(PASSWORD_PREFIX) && it !in activePasswordKeys }
            .forEach(secureEditor::remove)
        if (password.isNotEmpty()) {
            secureEditor.putString(KEY_LEGACY_PASSWORD, password)
        } else {
            secureEditor.remove(KEY_LEGACY_PASSWORD)
        }
        secureEditor.apply()
        prefs.edit()
            .putString(KEY_CONNECTIONS, array.toString())
            .putString(KEY_SELECTED_CONNECTION_ID, selectedId)
            .putString(KEY_ADDRESS, address)
            .putString(KEY_USER, user)
            .remove(KEY_PASSWORD)
            .apply()
    }

    private fun migrateLegacyConnection(): List<ConnectionItem> {
        val oldAddress = prefs.getString(KEY_ADDRESS, "").orEmpty().trim()
        if (oldAddress.isEmpty()) {
            return emptyList()
        }
        return listOf(
            ConnectionItem(
                id = generateConnectionId(),
                name = "",
                address = oldAddress,
                user = prefs.getString(KEY_USER, "").orEmpty().trim(),
                password = loadLegacyPassword(),
                storePassword = loadLegacyPassword().isNotEmpty(),
                touchScrollStep = 0,
                lastUsedAt = System.currentTimeMillis()
            )
        )
    }

    private fun arrayNeedsSecureMigration(array: JSONArray): Boolean {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val id = item.optString("id")
            val password = item.optString("password")
            if (password.isNotEmpty()) {
                return true
            }
            if (item.optBoolean("storePassword", password.isNotEmpty()) && securePrefs.getString(passwordKey(id), null) == null) {
                return true
            }
        }
        return prefs.contains(KEY_PASSWORD)
    }

    private fun loadLegacyPassword(): String = securePrefs.getString(KEY_LEGACY_PASSWORD, null)
        ?: prefs.getString(KEY_PASSWORD, "").orEmpty()

    private fun passwordKey(connectionId: String): String = "$PASSWORD_PREFIX$connectionId"

    fun loadMonitorLayout(connectionId: String, fbW: Int, fbH: Int): List<android.graphics.Rect>? {
        if (connectionId.isBlank() || fbW <= 0 || fbH <= 0) return null
        val key = "monitor_layout_${connectionId}_${fbW}_${fbH}"
        val raw = prefs.getString(key, null) ?: return null
        return try {
            val array = JSONArray(raw)
            val rects = mutableListOf<android.graphics.Rect>()
            for (i in 0 until array.length()) {
                val parts = array.getString(i).split(",")
                if (parts.size == 4) {
                    val x = parts[0].toInt()
                    val y = parts[1].toInt()
                    val w = parts[2].toInt()
                    val h = parts[3].toInt()
                    rects.add(android.graphics.Rect(x, y, x + w, y + h))
                }
            }
            if (rects.isNotEmpty()) rects else null
        } catch (_: Exception) {
            null
        }
    }

    fun saveMonitorLayout(connectionId: String, fbW: Int, fbH: Int, rects: List<android.graphics.Rect>) {
        if (connectionId.isBlank() || fbW <= 0 || fbH <= 0) return
        val key = "monitor_layout_${connectionId}_${fbW}_${fbH}"
        val array = JSONArray()
        for (rect in rects) {
            array.put("${rect.left},${rect.top},${rect.width()},${rect.height()}")
        }
        prefs.edit().putString(key, array.toString()).apply()
    }

    fun clearMonitorLayout(connectionId: String, fbW: Int, fbH: Int) {
        if (connectionId.isBlank() || fbW <= 0 || fbH <= 0) return
        val key = "monitor_layout_${connectionId}_${fbW}_${fbH}"
        prefs.edit().remove(key).apply()
    }

    fun hasAcceptedLaunchAgreements(): Boolean = prefs.getBoolean(KEY_LAUNCH_AGREEMENTS_ACCEPTED, false)

    fun setLaunchAgreementsAccepted(accepted: Boolean) {
        prefs.edit().putBoolean(KEY_LAUNCH_AGREEMENTS_ACCEPTED, accepted).apply()
    }

    private companion object {
        const val KEY_CONNECTIONS = "connections_v1"
        const val KEY_SELECTED_CONNECTION_ID = "selected_conn_id"
        const val KEY_ADDRESS = "address"
        const val KEY_USER = "user"
        const val KEY_PASSWORD = "password"
        const val KEY_LEGACY_PASSWORD = "legacy_password"
        const val PASSWORD_PREFIX = "connection_password_"
        const val KEY_LAUNCH_AGREEMENTS_ACCEPTED = "launch_agreements_accepted_v1"
    }
}
