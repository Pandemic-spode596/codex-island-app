package com.codexisland.android

import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityInstrumentedTest {
    @Test
    fun bootstrapMessageIsVisible() {
        ActivityScenario.launch(MainActivity::class.java).use {
            onView(withText(R.string.bootstrap_message)).check(matches(isDisplayed()))
        }
    }
}
