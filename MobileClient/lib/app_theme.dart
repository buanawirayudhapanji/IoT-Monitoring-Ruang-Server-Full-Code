import 'package:flutter/material.dart';

const ink = Color(0xff171715);
const accent = Color(0xffffd64d);
const paper = Color(0xfff5f5f2);
const muted = Color(0xff5c5c55);
const line = Color(0xffdeded8);
const warning = Color(0xfffff3c4);
const pageInset = 20.0;
const panelInset = 16.0;
const panelRadius = 16.0;

ThemeData buildAppTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: ink).copyWith(
    primary: ink,
    onPrimary: Colors.white,
    secondary: accent,
    onSecondary: ink,
    surface: Colors.white,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: line,
    outlineVariant: line,
    error: const Color(0xff705100),
  ),
  scaffoldBackgroundColor: paper,
  fontFamily: 'Roboto',
  cardTheme: const CardThemeData(
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: BorderRadius.all(Radius.circular(panelRadius)),
    ),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: accent,
    elevation: 0,
    height: 68,
  ),
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
);
