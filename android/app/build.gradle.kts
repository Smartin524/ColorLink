plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 版本号跟着 git 走：提交数就是 versionCode，每次提交后打的包都比上一个大。
// 有没提交的改动时加 1，名字后面标 dirty。和 mac/build-app.sh 用同一套规则
fun git(vararg args: String): String? = runCatching {
    providers.exec { commandLine("git", *args) }.standardOutput.asText.get().trim()
}.getOrNull()

val commits = git("rev-list", "--count", "HEAD")?.toIntOrNull() ?: 0
val dirty = !git("status", "--porcelain").isNullOrEmpty()
val buildNumber = commits + if (dirty) 1 else 0
val buildName = "0.1.$buildNumber-${git("rev-parse", "--short", "HEAD") ?: "nogit"}${if (dirty) "-dirty" else ""}"

android {
    namespace = "com.colorlink"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.colorlink"
        minSdk = 34 // Android 14：本项目仅面向自用的新版本手机。
        targetSdk = 35
        versionCode = buildNumber.coerceAtLeast(1)
        versionName = buildName
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
