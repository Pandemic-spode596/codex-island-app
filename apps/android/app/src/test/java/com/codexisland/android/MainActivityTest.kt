package com.codexisland.android

import android.view.ViewGroup
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class MainActivityTest {
    @Test
    fun showsBootstrapMessage() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup().get()
        val content = activity.findViewById<ViewGroup>(android.R.id.content)
        val textView = content.getChildAt(0) as TextView

        assertEquals(
            ApplicationProvider.getApplicationContext<android.content.Context>()
                .getString(R.string.bootstrap_message),
            textView.text.toString()
        )
    }
}
