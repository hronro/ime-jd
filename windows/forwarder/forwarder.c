/*
 * ime_jd.dll of the ARM64 package: the DLL registered as the IME there, and
 * not the IME itself.
 *
 * ARM64 Windows runs x64 applications too, and the two kinds read one
 * registry: the one path registered for the IME has to load into both. An
 * ARM64 DLL does not load into an x64 application, nor an x64 one into an
 * ARM64 application; what loads into both is an Arm64X DLL, one file with a
 * side for each. This is that file. Each side has the IME's four entry
 * points and passes every call on to the IME built for its architecture,
 * the DLL beside it: ime_jd_arm64.dll in an ARM64 application,
 * ime_jd_x64.dll in an x64 one.
 *
 * It finds that DLL by its own path, which is why it is code at all. A DLL
 * that only forwards its exports, as an Arm64X file usually does, leaves
 * the looking to the loader, and the loader looks in the forwarding DLL's
 * folder only if that DLL was loaded with LOAD_WITH_ALTERED_SEARCH_PATH.
 * COM loads the IME so in a desktop application. In a Store app it passes
 * no such flag, nor does TSF where it loads a text service itself — for its
 * display attributes — and there the IME would not be found.
 *
 * build.bat compiles this file twice, for ARM64 and for ARM64EC, the side
 * x64 applications get, and links the two with no entry point and no C
 * runtime: nothing here runs before the first call.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#if defined(_M_ARM64)
#define IME L"ime_jd_arm64.dll"
#elif defined(_M_X64) /* ARM64EC included: what is x64 to its callers */
#define IME L"ime_jd_x64.dll"
#else
#error "The forwarder is built for ARM64 and for ARM64EC (build.bat)."
#endif

/* This DLL's own header, which is what its module handle points at. */
extern IMAGE_DOS_HEADER __ImageBase;

/* The IME, once loaded. It stays: a text service is never unloaded. */
static HMODULE volatile ime;

static HMODULE load_ime(void)
{
    WCHAR path[1024];
    DWORD length, i;
    HMODULE module = ime;

    if (module != NULL)
        return module;
    length = GetModuleFileNameW((HMODULE)&__ImageBase, path, ARRAYSIZE(path));
    if (length == 0 || length >= ARRAYSIZE(path))
        return NULL;
    while (length > 0 && path[length - 1] != L'\\')
        length--;
    if (length == 0 || length + ARRAYSIZE(IME) > ARRAYSIZE(path))
        return NULL;
    for (i = 0; i < ARRAYSIZE(IME); i++)
        path[length + i] = IME[i];
    /* What the IME imports is looked up from its own folder on, as COM has
       it looked up — and in the usual places where that is not to be had. */
    module = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (module == NULL)
        module = LoadLibraryExW(path, NULL, 0);
    ime = module;
    return module;
}

static FARPROC ime_entry(LPCSTR name)
{
    HMODULE module = load_ime();

    return module != NULL ? GetProcAddress(module, name) : NULL;
}

typedef HRESULT (STDAPICALLTYPE *ClassObjectGetter)(REFCLSID, REFIID, LPVOID *);
typedef HRESULT (STDAPICALLTYPE *Parameterless)(void);

HRESULT STDAPICALLTYPE DllGetClassObject(REFCLSID clsid, REFIID iid, LPVOID *object)
{
    ClassObjectGetter get = (ClassObjectGetter)ime_entry("DllGetClassObject");

    if (get != NULL)
        return get(clsid, iid, object);
    if (object != NULL)
        *object = NULL;
    return CLASS_E_CLASSNOTAVAILABLE;
}

/* Asked of the IME once it is loaded, and it never agrees (src/lib.rs).
   Until then nothing here holds this DLL. */
HRESULT STDAPICALLTYPE DllCanUnloadNow(void)
{
    HMODULE module = ime;
    Parameterless can = module != NULL ? (Parameterless)GetProcAddress(module, "DllCanUnloadNow") : NULL;

    return can != NULL ? can() : S_OK;
}

/* regsvr32 is pointed at this DLL, and the IME registers the path it was
   reached through: this one (src/registration.rs). */
HRESULT STDAPICALLTYPE DllRegisterServer(void)
{
    Parameterless reg = (Parameterless)ime_entry("DllRegisterServer");

    return reg != NULL ? reg() : HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
}

HRESULT STDAPICALLTYPE DllUnregisterServer(void)
{
    Parameterless unregister = (Parameterless)ime_entry("DllUnregisterServer");

    return unregister != NULL ? unregister() : HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
}
