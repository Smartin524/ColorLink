plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.colorlink"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.colorlink"
        minSdk = 34 // Android 14：本项目仅面向自用的新版本手机。
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true // JVM 测试中的 android.util.Log
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// 刻意不引入任何第三方库：HTTP 服务、JSON、界面全部用系统自带能力，APK 小、启动快。

// 仅测试使用，不打入 APK。
dependencies {
    testImplementation("junit:junit:4.13.2")
}
