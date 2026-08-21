# EngineState/Candidate are constructed FROM native code (FindClass/NewObject
# in jd_jni.c), a reference R8 cannot see — keep their names and constructors.
# Everything else JNI-shaped is already covered: methods declared `native` (and
# their classes' names) are kept by proguard-android-optimize.txt, and manifest
# components (JdInputMethodService, the activities) by the manifest keep rules.
#
# KEEP IN SYNC with the FindClass calls in src/main/cpp/jd_jni.c: R8 silently
# ignores rules that match nothing, so a stale name here still builds — and
# ships an IME that crashes on popup (v0.5.0 shipped a rule for QuerySnapshot
# after the class had been renamed to EngineState; R8 stripped EngineState's
# members and JNI_OnLoad's GetMethodID blew up).
-keep class com.hronro.imejd.engine.EngineState { <init>(...); }
-keep class com.hronro.imejd.engine.Candidate { <init>(...); }
