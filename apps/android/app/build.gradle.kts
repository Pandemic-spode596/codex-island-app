import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val repoRoot = rootProject.projectDir.parentFile.parentFile
val generatedJniLibsDir = layout.buildDirectory.dir("generated/jniLibs/main")

val buildRustAndroidFfi by tasks.registering(Exec::class) {
    group = "build"
    description = "Builds the shared Rust FFI library for Android ABIs."

    val outputDir = generatedJniLibsDir.get().asFile
    outputs.dir(outputDir)
    inputs.files(
        fileTree("$repoRoot/engine/crates/island-client-ffi/src"),
        fileTree("$repoRoot/engine/crates/island-core/src"),
        fileTree("$repoRoot/engine/crates/island-proto/src"),
        file("$repoRoot/engine/crates/island-client-ffi/Cargo.toml"),
        file("$repoRoot/engine/crates/island-core/Cargo.toml"),
        file("$repoRoot/engine/crates/island-proto/Cargo.toml"),
        file("$repoRoot/engine/Cargo.lock"),
        file("$repoRoot/engine/Cargo.toml")
    )

    commandLine(
        "$repoRoot/scripts/build-android-ffi.sh",
        "--out-dir",
        outputDir.absolutePath
    )
}

android {
    namespace = "com.codexisland.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.codexisland.android"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }

    sourceSets.getByName("main").jniLibs.srcDir(generatedJniLibsDir)

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    packaging {
        resources {
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
    }
}

tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(buildRustAndroidFfi)
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.hierynomus:sshj:0.39.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.arch.core:core-testing:2.2.0")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("org.robolectric:robolectric:4.14.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:core-ktx:1.6.1")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
}
