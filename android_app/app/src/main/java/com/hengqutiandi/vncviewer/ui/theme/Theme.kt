package com.hengqutiandi.vncviewer.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val LightColors: ColorScheme = lightColorScheme(
    primary = TigerPrimary,
    onPrimary = TigerOnPrimary,
    primaryContainer = TigerPrimaryContainer,
    surface = TigerSurface,
    onSurface = TigerOnSurface,
    outline = TigerOutline,
    secondary = TigerSecondary,
    error = TigerError
)

private val DarkColors: ColorScheme = darkColorScheme(
    primary = TigerPrimaryContainer,
    onPrimary = TigerOnSurface,
    primaryContainer = TigerPrimary,
    surface = TigerOnSurface,
    onSurface = TigerSurface,
    outline = TigerOutline,
    secondary = TigerPrimaryContainer,
    error = TigerError
)

@Composable
fun GreenTigerTheme(
    darkTheme: Boolean = false,
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = AppTypography,
        content = content
    )
}
