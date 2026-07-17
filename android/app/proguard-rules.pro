# QuerySnapshot/Candidate are constructed FROM native code (FindClass/NewObject
# in jd_jni.c), a reference R8 cannot see — keep their names and constructors.
# Everything else JNI-shaped is already covered: methods declared `native` (and
# their classes' names) are kept by proguard-android-optimize.txt, and manifest
# components (JdInputMethodService, the activities) by the manifest keep rules.
-keep class com.hronro.imejd.engine.QuerySnapshot { <init>(...); }
-keep class com.hronro.imejd.engine.Candidate { <init>(...); }
