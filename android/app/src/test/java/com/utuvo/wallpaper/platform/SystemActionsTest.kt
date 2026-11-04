package com.utuvo.wallpaper.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class SystemActionsTest {
    @Test fun acceptsOnlyListedSystemActions() {
        for (a in SystemActions.RESCHEDULE) assertTrue(a, SystemActions.isReschedule(a))
        for (a in listOf(null, "", "com.example.EVIL", "android.intent.action.MAIN", "android.intent.action.BOOT_COMPLETED ",
            "android.intent.action.boot_completed")) assertFalse("$a", SystemActions.isReschedule(a))
    }

    /** 程式接受的 action 要跟 AndroidManifest 的 intent-filter 一模一樣（防止兩邊各改各的）。 */
    @Test fun matchesManifestIntentFilter() {
        val f = listOf(File("src/main/AndroidManifest.xml"), File("app/src/main/AndroidManifest.xml")).first { it.isFile }
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(f)
        val ns = "http://schemas.android.com/apk/res/android"
        val receivers = doc.getElementsByTagName("receiver")
        val actions = mutableSetOf<String>()
        for (i in 0 until receivers.length) {
            val r = receivers.item(i) as org.w3c.dom.Element
            if (r.getAttributeNS(ns, "name") != ".platform.BootReceiver") continue
            val list = r.getElementsByTagName("action")
            for (j in 0 until list.length) actions += (list.item(j) as org.w3c.dom.Element).getAttributeNS(ns, "name")
        }
        assertEquals(SystemActions.RESCHEDULE, actions)
    }
}
