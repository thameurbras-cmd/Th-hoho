#!/usr/bin/env python3
"""يعدّل مجلد android/ المولَّد بـ flutter create. يفشل بصوت عالٍ إن تغيّر القالب."""
import re, sys, pathlib

root = pathlib.Path("android/app")
man = root / "src/main/AndroidManifest.xml"
t = man.read_text(encoding="utf-8")
if "android.permission.INTERNET" not in t:
    t, n = re.subn(r"(\s*)<application", r'\1<uses-permission android:name="android.permission.INTERNET"/>\1<application', t, count=1)
    if n != 1:
        sys.exit("AndroidManifest: لم أجد <application>")
if "usesCleartextTraffic" not in t:
    t, n = re.subn(r"<application", '<application\n        android:usesCleartextTraffic="true"', t, count=1)
    if n != 1:
        sys.exit("AndroidManifest: تعذّر إضافة usesCleartextTraffic")
man.write_text(t, encoding="utf-8")

# Gradle: تعطيل التصغير صراحةً في نمط release
kts, groovy = root / "build.gradle.kts", root / "build.gradle"
if kts.exists():
    g = kts.read_text(encoding="utf-8")
    if "isMinifyEnabled" not in g:
        g, n = re.subn(r"(release\s*\{)", r"\1\n            isMinifyEnabled = false\n            isShrinkResources = false", g, count=1)
        if n != 1:
            sys.exit("build.gradle.kts: لم أجد كتلة release")
    kts.write_text(g, encoding="utf-8")
elif groovy.exists():
    g = groovy.read_text(encoding="utf-8")
    if "minifyEnabled" not in g:
        g, n = re.subn(r"(release\s*\{)", r"\1\n            minifyEnabled false\n            shrinkResources false", g, count=1)
        if n != 1:
            sys.exit("build.gradle: لم أجد كتلة release")
    groovy.write_text(g, encoding="utf-8")
else:
    sys.exit("لا يوجد build.gradle(.kts) في android/app")
print("android patched")
