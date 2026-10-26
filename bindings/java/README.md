# jd (Java bindings)

Java wrapper for the libjd core engine over JNI: a plain Java library, `com.hronro:jd`, whose native half is one C file, `src/main/c/jd_jni.c`. The `android/` app compiles it from source as an included Gradle build:

```kotlin
// android/settings.gradle.kts
includeBuild("../bindings/java") {
    name = "jd"
    dependencySubstitution {
        substitute(module("com.hronro:jd")).using(project(":"))
    }
}

// android/app/build.gradle.kts
dependencies {
    implementation("com.hronro:jd")
}
```

It is written in Java so that every JVM language uses it as it is, with no runtime of another language to ship. Kotlin reads it like Kotlin: the records read as data classes (`state.commit`), the getters as properties (`engine.state`), and the package is `@NullMarked` with [JSpecify](https://jspecify.dev) annotations, so Kotlin types a value `String?` exactly where it can be null (with `-Xjspecify-annotations=strict` on Kotlin 2.0, as `android/` sets it).

## Usage

```java
/** Candidates drawn at once — a frontend choice. The engine has no page concept. */
static final int PAGE = 9;

static void draw(List<Candidate> window) {
    for (int i = 0; i < window.size(); i++) {
        Candidate c = window.get(i);
        System.out.println((i + 1) + ". " + c.value() + (c.hint() != null ? " 〔" + c.hint() + "〕" : ""));
    }
}

try (Engine engine = new Engine()) {
    StringBuilder typed = new StringBuilder();

    // Feed one ASCII byte at a time. A keystroke may commit text, may open or
    // extend a candidate list, or both (when the key restarts from the root).
    for (byte key : "nk".getBytes(StandardCharsets.US_ASCII)) {
        EngineState state = engine.pressKey(key);
        if (state.hasCommit()) typed.append(state.commit());
    }
    System.out.println(engine.getState().optionsCount());   // 331

    // Read the window you actually draw. Reads are pure — they never change
    // what the engine's own commits resolve to — so prefetch freely.
    int start = 0;
    draw(engine.readRange(start, PAGE));                     // 1. 泥   2. 尼 〔a〕   …

    // Turning a page: point the anchor at the first visible candidate, so that
    // space — and every other commit the engine makes on its own — picks
    // something that is on screen.
    if (start + PAGE < engine.getState().optionsCount()) {
        start += PAGE;
        engine.setAnchor(start);
        draw(engine.readRange(start, PAGE));                 // 1. 南柯梦 〔m〕   …
    }

    // Space commits the anchor candidate and ends the composition.
    String commit = engine.pressKey((byte) ' ').commit();
    if (commit != null) typed.append(commit);
    System.out.println(typed);                               // 南柯梦
}
```

Committing a candidate the user tapped needs no engine call: insert `c.value()`, then `engine.reset()`. For an append-only candidate strip, keep your own list and read `[loaded, loaded + window)` as it scrolls; `android/`'s `InputSession` does exactly this.

An `Engine` holds native memory until it is closed: use try-with-resources, or `close()` it when its session ends. Closing twice is harmless; any other call on a closed engine throws `IllegalStateException`. Like the libjd context it wraps, one engine must not be used from two threads at once; distinct engines are independent.

### User dictionary

The user's own phrases are compiled once into a blob that every engine created with it merges into its candidate lists — same ordering as the built-in words, with a user phrase first on a code it shares with one. The text stays the source of truth; a rebuild takes a few milliseconds for thousands of phrases.

```java
String text = "键道\tzzzzzz\n不\tb\n";       // value<TAB>keys, the table files' line format
UserDict.Built built = UserDict.build(text, contentHash);
UserDictReport report = built.report();
// entries 1, dropped 1, shared 0, invalid 0: 不/b repeats a built-in word, so it is dropped
for (UserDictNote note : report.notes()) {
    System.out.println(note);              // UserDictNote[line=2, flags=2, other=0, builtIn=2, peers=0]
}

try (Engine engine = new Engine(built.dict())) {   // null (or new Engine()) = the built-in dictionary alone
    // …
}
```

A line that does not parse never fails the build: the engine skips it, counts it in `invalid` and notes it (`MALFORMED`, `BAD_KEYS`, `BAD_VALUE`). The notes also say which lines were dropped as duplicates and what they repeat (`REPEATS_LINE`, `REPEATS_BUILT_IN`, the line in `other`), and which kept phrases sit on a code a built-in word or another phrase already uses (`CODE_IN_BUILT_IN`, `CODE_IN_LINE`, with the counts in `builtIn` and `peers`): the phrase works, listed first, but the code is shared (重码). `UserDictException`, a checked exception, is for the call as a whole: too many phrases (`getLine()` names the first one past the cap) or too much text. An engine's dictionary is fixed for its lifetime; to adopt an edited one, create a new `Engine`.

`getBlob()` gives the bytes to cache, and `UserDict.fromBlob` takes them back, validated as `jd_init` would. A blob from another build of libjd throws `STALE`, which just means "build it again":

```java
UserDict dict;
try {
    dict = UserDict.fromBlob(Files.readAllBytes(cache));
    if (dict.getSourceTag() != contentHash) dict = UserDict.build(text, contentHash).dict(); // another text's cache
} catch (UserDictException | IOException e) {
    dict = UserDict.build(text, contentHash).dict(); // no cache, STALE after a library update, or CORRUPT
}
```

## The native library

Two shared libraries make up the native half: `libjd`, the engine, and `libjdjni`, the shim. `System.loadLibrary("jdjni")` loads the shim, whose `DT_NEEDED` pulls in `libjd`, so both must sit where the runtime looks for native libraries. Both are built per platform by whoever ships them:

- **Android**: `android/scripts/build-libjd.sh`, per ABI, into the app's `jniLibs/` (with the NDK clang for the shim).
- **The machine running the tests**: `scripts/build-host.sh`, into `build/host/` (zig builds libjd; `zig cc` compiles the shim against a JDK's `jni.h`). A desktop app would ship these two on `java.library.path`.

The shim links the *dynamic* libjd: the static archive uses local-exec TLS relocations that a linker refuses in a shared object.

## Design

- **The native methods are all in one class.** `Jni` declares every one of them, package-private, and `javac -h` writes their C declarations into `build/generated/jni/`. Both native builds compile the shim against them with `-Werror=missing-prototypes`, so a C function whose name or types no longer match fails the build instead of the first call. At load time, `JNI_OnLoad` checks libjd's struct layout and limits against `jd.h` and finds the two classes it builds; anything amiss fails the load with an `UnsatisfiedLinkError` that says why.
- **JNI has to copy, so it copies only what is asked for.** The Rust and Swift bindings hand out pointers into libjd's dictionary; JNI has to build JVM objects. `readRange` builds Strings for exactly the window requested, in chunks of 64 per native call, so a strip that has fetched 900 candidates but shows 9 pays for 9. A user dictionary crosses as plain arrays (the blob a `byte[]`, the report an `int[]`), and each `Engine` copies the blob into native memory of its own, because `jd_init` reads it in place for the context's whole lifetime and a JVM array can move. `UserDict` keeps its bytes to itself: `fromBlob` copies the array it is given and `getBlob` hands out a copy.
- **Shrinking needs no rules from the app.** `EngineState` and `Candidate` are constructed from C, a reference R8 cannot see. `META-INF/proguard/jd.pro` in the jar keeps their names and constructors, and the names of `Jni`'s natives, and R8 reads it from the dependency on its own. It must stay in step with the `FindClass` calls in `jd_jni.c`.
- **Java 17's language, Android 7's library.** Records compile down to Android's minimum (D8 desugars them), but the JDK *classes* the binding calls must exist on API 24: no `List.of` (API 30), no `java.lang.ref.Cleaner` (API 33). That is also why an `Engine` is closed explicitly rather than cleaned up behind your back.
- **Errors are values or one checked exception.** What the build says about individual lines comes back in the report; `UserDictException` is only for a call that failed as a whole.

## Tests

```sh
./gradlew test
```

The tests run on the JVM running Gradle, under HotSpot's JNI checker (`-Xcheck:jni`), against libjd and the shim built for this machine; no emulator. They cover the engine wrapper (use after close, chunked reads, the anchor's independence from reads, literal appends, hints, results as values) and the user dictionary (merge order, user-only codes, notes, the caps, cached blobs). The build needs [`zig`](https://ziglang.org) 0.17.0, and a JDK that Gradle 8.11 runs on (17 to 23). The shim compiles against the `jni.h` of `JAVA_HOME`, or of the `java` on PATH; set `JNI_INCLUDE` to a JDK's `include/` directory if neither has one (Android Studio's bundled JBR does not).
