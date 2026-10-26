# Shrinker rules for apps that ship the jd binding. R8 reads them from this
# jar on its own (META-INF/proguard/), so an app keeps none of its own.
#
# EngineState and Candidate are built FROM native code (FindClass + NewObject
# in jd_jni.c), references R8 cannot see: keep their names and constructors.
#
# KEEP IN SYNC with the FindClass calls in src/main/c/jd_jni.c. R8 silently
# ignores a rule that matches nothing, so a stale name here still builds, and
# ships an app whose library fails to load. (v0.5.0 of the Android app shipped
# a rule for a renamed class, and its keyboard crashed on first popup.)
-keep class com.hronro.jd.EngineState { <init>(...); }
-keep class com.hronro.jd.Candidate { <init>(...); }

# Jni's native methods are found by name: keep them, and the class's name.
# (Android's stock proguard-android-optimize.txt says the same for every
# class; this keeps the jar right under any configuration.)
-keepclasseswithmembernames,includedescriptorclasses class com.hronro.jd.Jni {
    native <methods>;
}
