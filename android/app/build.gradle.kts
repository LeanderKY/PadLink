plugins {
    id("com.android.application")
}

android {
    namespace = "app.padlink.pad"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.padlink.pad"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with the debug key so it installs straight from the Mac (sideload).
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
