import java.io.ByteArrayOutputStream
import java.util.Properties
import java.io.FileInputStream

fun getGitVersion(): String {
    val stdout = ByteArrayOutputStream()
    try {
        exec {
            commandLine("git", "describe", "--tags", "--always", "--dirty")
            standardOutput = stdout
        }
        return stdout.toString().trim()
    } catch (e: Exception) {
        return "unknown"
    }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val batikRasterizer by configurations.creating
val generatedLauncherResDir = layout.buildDirectory.dir("generated/res/harmonyLauncher")
val generatedAgreementAssetsDir = layout.buildDirectory.dir("generated/assets/agreements")
val harmonyLauncherSvg = rootDir.resolve("../ohos_app/entry/src/main/resources/base/media/app_icon.svg")
val agreementDocsDir = rootDir.resolve("../docs")
val syncAgreementsScript = rootDir.resolve("../scripts/sync_agreements.py")

android {
    namespace = "com.hengqutiandi.vncviewer"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.hengqutiandi.vncviewer"
        minSdk = 26
        targetSdk = 35
        versionCode = 1740000
        versionName = "1.7.4"
        buildConfigField("String", "BUILD_VERSION", "\"${getGitVersion()}\"")

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }

        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            val keystorePropertiesFile = rootProject.file("local.properties")
            val keystoreProperties = Properties()
            if (keystorePropertiesFile.exists()) {
                keystoreProperties.load(FileInputStream(keystorePropertiesFile))
            }
            
            storeFile = file(keystoreProperties.getProperty("RELEASE_STORE_FILE") ?: System.getenv("RELEASE_STORE_FILE") ?: "../../certs/android/release.jks")
            storePassword = keystoreProperties.getProperty("RELEASE_STORE_PASSWORD") ?: System.getenv("RELEASE_STORE_PASSWORD") ?: ""
            keyAlias = keystoreProperties.getProperty("RELEASE_KEY_ALIAS") ?: System.getenv("RELEASE_KEY_ALIAS") ?: ""
            keyPassword = keystoreProperties.getProperty("RELEASE_KEY_PASSWORD") ?: System.getenv("RELEASE_KEY_PASSWORD") ?: ""
            
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
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
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main").res.srcDir(generatedLauncherResDir)
        getByName("main").assets.srcDir(generatedAgreementAssetsDir)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")

    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.1")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.3")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.google.android.material:material:1.12.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    batikRasterizer("org.apache.xmlgraphics:batik-rasterizer:1.17")
}

val generateLauncherIconsFromHarmonySvg = tasks.register("generateLauncherIconsFromHarmonySvg") {
    inputs.file(harmonyLauncherSvg)
    outputs.dir(generatedLauncherResDir)
    doLast {
        val outputRoot = generatedLauncherResDir.get().asFile
        val sanitizedSvg = layout.buildDirectory.file("intermediates/harmonyLauncher/app_icon_sanitized.svg").get().asFile
        delete(outputRoot)
        delete(sanitizedSvg)
        outputRoot.mkdirs()
        sanitizedSvg.parentFile.mkdirs()
        sanitizedSvg.writeText(
            harmonyLauncherSvg.readText()
                .replace("fill=\"rgba(255,255,255,0.04)\"", "fill=\"#FFFFFF\" fill-opacity=\"0.04\"")
        )
        val densities = listOf(
            "mipmap-mdpi" to 48,
            "mipmap-hdpi" to 72,
            "mipmap-xhdpi" to 96,
            "mipmap-xxhdpi" to 144,
            "mipmap-xxxhdpi" to 192
        )
        densities.forEach { (folderName, sizePx) ->
            val targetDir = outputRoot.resolve(folderName).apply { mkdirs() }
            val targetFiles = listOf("ic_launcher.png", "ic_launcher_round.png")
            targetFiles.forEach { fileName ->
                javaexec {
                    classpath = batikRasterizer
                    mainClass.set("org.apache.batik.apps.rasterizer.Main")
                    args(
                        "-m", "image/png",
                        "-w", sizePx.toString(),
                        "-h", sizePx.toString(),
                        "-d", targetDir.resolve(fileName).absolutePath,
                        sanitizedSvg.absolutePath
                    )
                }
            }
        }
    }
}

val syncAgreementDocs = tasks.register("syncAgreementDocs") {
    inputs.files(
        agreementDocsDir.resolve("privacy-policy.md"),
        agreementDocsDir.resolve("user-agreement.md")
    )
    inputs.file(syncAgreementsScript)
    outputs.dir(generatedAgreementAssetsDir)
    doLast {
        exec {
            commandLine(
                "python3",
                syncAgreementsScript.absolutePath,
                generatedAgreementAssetsDir.get().asFile.absolutePath
            )
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(generateLauncherIconsFromHarmonySvg)
    dependsOn(syncAgreementDocs)
}
