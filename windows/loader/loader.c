/*
 * ime_jd.dll, and ime_jd_x86.dll for 32-bit applications: the DLL that is
 * registered as the IME, and that is not the IME itself.
 *
 * Windows loads an IME's DLL into every application the user types in, and
 * a DLL, once loaded, stays for as long as the application runs. An IME
 * that is all in its registered DLL is therefore replaced, in an
 * application that is running, only by starting that application again.
 * So the registered DLL is this one, the loader, which has nothing in it
 * that an update needs to replace, and the IME is a DLL beside it, under a
 * name of its own for every installation:
 *
 *     ime_jd.dll, ime_jd_x86.dll    the loader
 *     current                       one line: the id of the installation
 *                                   in use
 *     jd-<id>-<arch>.dll            that installation's IME; <arch> is x64,
 *                                   x86 or arm64
 *
 * register.bat copies the IME it installs under a new id and then rewrites
 * `current`. Where there is no `current` the IME is jd-<arch>.dll, which is
 * how the files lie in a release's package.
 *
 * TSF asks the registered DLL for one object per thread that uses the IME,
 * activates it, and keeps it for as long as the thread lives; it never
 * asks for another. What it gets here is a stand-in (StandIn): an object
 * that passes on to the IME's own object, behind it, whatever it is asked,
 * and that can put another IME's object there. It does so when `current`
 * names another installation than the one its IME is from:
 *
 *   - when TSF activates it — the user switches to 键道 on that thread —
 *     since an IME that is not active has nothing in flight;
 *
 *   - while it is active, when the IME says that it is idle: nothing is
 *     being composed, and no menu of its own is open. The IME says so with
 *     a message to a window of the stand-in's, so that what follows runs
 *     from the application's message loop and not inside a call of TSF's
 *     into the IME. The old IME is deactivated and the new one activated
 *     with what TSF activated the stand-in with, and the input mode, 中 or
 *     英, is put back as it was. TSF is told nothing, and the application
 *     notices nothing.
 *
 * The old IME's DLL stays loaded, as any DLL does, and is not used again
 * by that thread. A new one that does not load, or that cannot be
 * activated, is left alone, and the old one goes on.
 *
 * Besides DllGetClassObject and DllUnregisterServer, the loader calls
 * three functions of an IME's DLL (..\src\lib.rs, ..\src\loader.rs):
 *
 *     HRESULT JdRegisterServer(LPCWSTR server)
 *         Register the IME with `server`, this DLL, as what applications
 *         load for it.
 *     void JdTellWhenIdle(HWND window, UINT message)
 *         From now on, post `message` to `window` whenever the calling
 *         thread's IME may have become idle. Forgotten when that IME is
 *         deactivated.
 *     BOOL JdIsIdle(void)
 *         Whether the calling thread's IME is idle now.
 *
 * The loader in an application is the one that was installed when the
 * application started, and the IMEs it loads are newer than itself: these
 * names, and what they mean, cannot change. An IME without the last two is
 * replaced only when TSF activates the stand-in.
 *
 * On ARM64 this is also what the registered DLL has to be for another
 * reason. ARM64 Windows runs x64 applications too, and the two kinds read
 * one registry: the one path registered for the IME has to load into both,
 * which neither an ARM64 nor an x64 DLL does. What loads into both is an
 * Arm64X DLL, one file with a side for each, and build.bat makes the
 * loader one there: the ARM64 side loads jd-<id>-arm64.dll, the x64 side
 * jd-<id>-x64.dll.
 *
 * The IME is found by this DLL's own path, never by its name alone:
 * Windows looks beside a DLL for what that DLL asks for by name only if
 * the DLL was itself loaded with LOAD_WITH_ALTERED_SEARCH_PATH, as COM
 * loads an IME in a desktop application — and not in a Store app, and not
 * TSF where it loads a text service itself, for its display attributes.
 *
 * build.bat compiles this file with no C runtime and no entry point:
 * nothing here runs before the first call.
 */

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <ole2.h>
/* One of its structures has a member with no name, which C calls an
   extension. */
#pragma warning(push)
#pragma warning(disable : 4201)
#include <msctf.h>
#pragma warning(pop)

#if defined(_M_ARM64EC) || defined(_M_X64) /* ARM64EC: x64 to its callers */
#define ARCH L"x64"
#elif defined(_M_ARM64)
#define ARCH L"arm64"
#elif defined(_M_IX86)
#define ARCH L"x86"
#else
#error "The loader is built for x64, x86, ARM64 and ARM64EC (build.bat)."
#endif

/* This DLL's own header, which is what its module handle points at. */
extern IMAGE_DOS_HEADER __ImageBase;
#define THIS_DLL ((HINSTANCE)&__ImageBase)

#define PATH_LENGTH 1024
/* An id and its end: longer than any register.bat makes. */
#define ID_LENGTH 40

/* The stand-in's window, and what the IME posts to it when it is idle. */
#define WINDOW_CLASS L"JdImeLoader"
#define WM_IME_IDLE (WM_APP + 1)

static const GUID iid_unknown =
    {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID iid_class_factory =
    {0x00000001, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID iid_text_input_processor =
    {0xaa80e7f7, 0x2021, 0x11d2, {0x93, 0xe0, 0x00, 0x60, 0xb0, 0x67, 0xb8, 0x6e}};
static const GUID iid_text_input_processor_ex =
    {0x6e4e2102, 0xf9cd, 0x433d, {0xb4, 0x96, 0x30, 0x3c, 0xe0, 0x3a, 0x65, 0x07}};
static const GUID iid_compartment_mgr =
    {0x7dcf57ac, 0x18ad, 0x438b, {0x82, 0x4d, 0x97, 0x9b, 0xff, 0xb7, 0x4b, 0x7c}};
/* GUID_COMPARTMENT_KEYBOARD_OPENCLOSE: the input mode (..\src\input_mode.rs). */
static const GUID keyboard_openclose =
    {0x58273aad, 0x01bb, 0x4164, {0x95, 0xc6, 0x75, 0x5b, 0xa0, 0xb5, 0x16, 0x2d}};

typedef HRESULT (STDAPICALLTYPE *ClassObjectGetter)(REFCLSID, REFIID, LPVOID *);
typedef HRESULT (STDAPICALLTYPE *Parameterless)(void);
typedef HRESULT (STDAPICALLTYPE *ServerRegistrar)(LPCWSTR);
typedef void (STDAPICALLTYPE *IdleTeller)(HWND, UINT);
typedef BOOL (STDAPICALLTYPE *IdleAsker)(void);

/* ---- What the compiler asks a C runtime for ------------------------------ */

/* It writes a call to these two for a structure it clears or copies, and
   would write one into their own loops if it were let. */
#pragma function(memset, memcpy)
#pragma optimize("", off)
void *memset(void *to, int value, size_t count)
{
    unsigned char *byte = (unsigned char *)to;

    while (count-- > 0)
        *byte++ = (unsigned char)value;
    return to;
}

void *memcpy(void *to, const void *from, size_t count)
{
    unsigned char *byte = (unsigned char *)to;
    const unsigned char *source = (const unsigned char *)from;

    while (count-- > 0)
        *byte++ = *source++;
    return to;
}
#pragma optimize("", on)

static BOOL same_guid(const GUID *a, const GUID *b)
{
    const DWORD *x = (const DWORD *)a, *y = (const DWORD *)b;

    return x[0] == y[0] && x[1] == y[1] && x[2] == y[2] && x[3] == y[3];
}

/* ---- The installation in use, and its IME -------------------------------- */

/* An installation's IME, loaded. It stays: no DLL of the IME's is ever
   unloaded. The id is empty for the IME of a folder without `current`. */
typedef struct Build {
    WCHAR id[ID_LENGTH];
    HMODULE module;
} Build;

static void copy_id(WCHAR *to, const WCHAR *from)
{
    DWORD i;

    for (i = 0; i + 1 < ID_LENGTH && from[i] != 0; i++)
        to[i] = from[i];
    to[i] = 0;
}

static BOOL same_id(const WCHAR *a, const WCHAR *b)
{
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return *a == *b;
}

/* `text` written at `to`, in a buffer that ends at `end`: where the text
   ends, or NULL if it does not fit, or if `to` is NULL already. */
static WCHAR *append(WCHAR *to, const WCHAR *end, const WCHAR *text)
{
    if (to == NULL)
        return NULL;
    for (; *text != 0; text++) {
        if (to + 1 >= end)
            return NULL;
        *to++ = *text;
    }
    *to = 0;
    return to;
}

/* The folder this DLL is in, written to `path` with its last backslash:
   where that ends, for a file's name to follow, or NULL. Everything that
   is installed with the loader is in that folder. */
static WCHAR *own_folder(WCHAR *path)
{
    DWORD length = GetModuleFileNameW(THIS_DLL, path, PATH_LENGTH);

    if (length == 0 || length >= PATH_LENGTH)
        return NULL;
    while (length > 0 && path[length - 1] != L'\\')
        length--;
    if (length == 0)
        return NULL;
    path[length] = 0;
    return path + length;
}

/* Where `current` is. */
static BOOL current_path(WCHAR *path)
{
    return append(own_folder(path), path + PATH_LENGTH, L"current") != NULL;
}

/* Whether `c` may be in an id. An id becomes part of a file's name, and
   nothing that could make that name lead elsewhere is taken for one. */
static BOOL in_an_id(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || c == '.' || c == '_' || c == '-';
}

/* The id `current` gives: its first line. With no such file the id is
   empty, and that is an answer; FALSE if the file is there and cannot be
   read, or does not hold an id. */
static BOOL read_current(WCHAR *id)
{
    WCHAR path[PATH_LENGTH];
    char text[ID_LENGTH + 8];
    DWORD count = 0, at = 0, length = 0;
    HANDLE file;
    BOOL read;

    id[0] = 0;
    if (!current_path(path))
        return FALSE;
    /* Shared with whatever else has it open: register.bat puts a new file
       in its place while applications read it. */
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return GetLastError() == ERROR_FILE_NOT_FOUND;
    read = ReadFile(file, text, sizeof text, &count, NULL);
    CloseHandle(file);
    if (!read)
        return FALSE;
    /* A byte order mark, should whatever wrote the file have put one. */
    if (count >= 3 && text[0] == '\xEF' && text[1] == '\xBB' && text[2] == '\xBF')
        at = 3;
    for (; at < count; at++) {
        char c = text[at];

        if (c == '\r' || c == '\n' || c == ' ' || c == '\t' || c == 0)
            break;
        if (!in_an_id(c) || length + 1 >= ID_LENGTH)
            return FALSE;
        id[length++] = (WCHAR)c;
    }
    id[length] = 0;
    return length > 0;
}

/* The IME of the installation `id`, for applications of this DLL's own
   architecture. */
static BOOL load_build(const WCHAR *id, Build *build)
{
    WCHAR path[PATH_LENGTH];
    const WCHAR *end = path + PATH_LENGTH;
    WCHAR *at = append(own_folder(path), end, L"jd-");
    HMODULE module;

    if (id[0] != 0)
        at = append(append(at, end, id), end, L"-");
    if (append(at, end, ARCH L".dll") == NULL)
        return FALSE;
    /* What the IME imports is looked up from its own folder on, as COM has
       it looked up — and in the usual places where that is not to be had. */
    module = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (module == NULL)
        module = LoadLibraryExW(path, NULL, 0);
    /* Not this DLL, copied there under an IME's name: it would ask itself
       for the IME, and that for ever. */
    if (module == NULL || module == THIS_DLL)
        return FALSE;
    copy_id(build->id, id);
    build->module = module;
    return TRUE;
}

/* The IME of the installation in use. */
static BOOL load_current(Build *build)
{
    WCHAR id[ID_LENGTH], again[ID_LENGTH];

    if (!read_current(id))
        return FALSE;
    if (load_build(id, build))
        return TRUE;
    /* Between the reading and the loading another installation may have
       taken that one's place, and removed its files. */
    return read_current(again) && !same_id(again, id) && load_build(again, build);
}

/* A new object of the IME in `build`. */
static HRESULT create_ime(const Build *build, const CLSID *clsid, ITfTextInputProcessorEx **ime)
{
    ClassObjectGetter get = (ClassObjectGetter)GetProcAddress(build->module, "DllGetClassObject");
    IClassFactory *factory = NULL;
    HRESULT result;

    *ime = NULL;
    if (get == NULL)
        return CLASS_E_CLASSNOTAVAILABLE;
    result = get(clsid, &iid_class_factory, (LPVOID *)&factory);
    if (FAILED(result))
        return result;
    result = IClassFactory_CreateInstance(factory, NULL, &iid_text_input_processor_ex, (void **)ime);
    IClassFactory_Release(factory);
    return result;
}

/* ---- The input mode -------------------------------------------------------- */

/* TSF's keyboard switch on the thread manager's thread, which is the IME's
   input mode: open is 中, closed is 英. */
static ITfCompartment *keyboard_switch(ITfThreadMgr *thread_mgr)
{
    ITfCompartmentMgr *compartments = NULL;
    ITfCompartment *keyboard = NULL;

    if (FAILED(ITfThreadMgr_QueryInterface(thread_mgr, &iid_compartment_mgr, (void **)&compartments)))
        return NULL;
    if (FAILED(ITfCompartmentMgr_GetCompartment(compartments, &keyboard_openclose, &keyboard)))
        keyboard = NULL;
    ITfCompartmentMgr_Release(compartments);
    return keyboard;
}

/* Whether the switch is closed: the mode is 英. A switch that was never
   set, or that cannot be read, is not. */
static BOOL keyboard_is_closed(ITfThreadMgr *thread_mgr)
{
    ITfCompartment *keyboard = keyboard_switch(thread_mgr);
    VARIANT value;
    BOOL closed = FALSE;

    if (keyboard == NULL)
        return FALSE;
    memset(&value, 0, sizeof value);
    if (ITfCompartment_GetValue(keyboard, &value) == S_OK) {
        closed = value.vt == VT_I4 && value.lVal == 0;
        VariantClear(&value);
    }
    ITfCompartment_Release(keyboard);
    return closed;
}

static void close_keyboard(ITfThreadMgr *thread_mgr, TfClientId client)
{
    ITfCompartment *keyboard = keyboard_switch(thread_mgr);
    VARIANT value;

    if (keyboard == NULL)
        return;
    memset(&value, 0, sizeof value);
    value.vt = VT_I4;
    value.lVal = 0;
    ITfCompartment_SetValue(keyboard, client, &value);
    ITfCompartment_Release(keyboard);
}

/* ---- The stand-in ---------------------------------------------------------- */

/* What TSF holds as the IME: ITfTextInputProcessorEx, and through it
   whatever the IME's own object behind it answers to. */
typedef struct StandIn {
    const ITfTextInputProcessorExVtbl *methods;
    LONG references;
    CLSID clsid;
    /* The IME's own object, and the installation it is from. */
    ITfTextInputProcessorEx *ime;
    Build build;
    /* While TSF has this object activated: what it activated it with. */
    ITfThreadMgr *thread_mgr;
    TfClientId client;
    DWORD flags;
    /* Where the IME says that it is idle; made at the first activation.
       Its title is the id of the installation the IME is from, for anyone
       who wants to know what a thread is running. */
    HWND window;
    /* The installation `current` named when it was last read, and that
       file's time and size then. */
    WCHAR wanted[ID_LENGTH];
    FILETIME current_written;
    DWORD current_size;
    /* An installation whose IME could not take over here. It is not tried
       again; the one after it is. */
    WCHAR refused[ID_LENGTH];
    BOOL refused_one;
    BOOL handing_over;
} StandIn;

static void refuse(StandIn *self, const WCHAR *id)
{
    copy_id(self->refused, id);
    self->refused_one = TRUE;
}

/* Whether `current` names an installation other than the one this
   object's IME is from. The file is read only if it has changed since it
   was last read: this is asked at every idle moment of the IME's. */
static BOOL wants_another(StandIn *self)
{
    WCHAR path[PATH_LENGTH];
    WCHAR id[ID_LENGTH];
    WIN32_FILE_ATTRIBUTE_DATA now;

    if (current_path(path) && GetFileAttributesExW(path, GetFileExInfoStandard, &now)
        && (now.ftLastWriteTime.dwLowDateTime != self->current_written.dwLowDateTime
            || now.ftLastWriteTime.dwHighDateTime != self->current_written.dwHighDateTime
            || now.nFileSizeLow != self->current_size)
        && read_current(id)) {
        copy_id(self->wanted, id);
        self->current_written = now.ftLastWriteTime;
        self->current_size = now.nFileSizeLow;
    }
    if (same_id(self->wanted, self->build.id))
        return FALSE;
    return !(self->refused_one && same_id(self->wanted, self->refused));
}

/* The IME of the installation `current` names, as a new object. */
static BOOL create_wanted(StandIn *self, Build *build, ITfTextInputProcessorEx **ime)
{
    if (load_build(self->wanted, build) && SUCCEEDED(create_ime(build, &self->clsid, ime)))
        return TRUE;
    refuse(self, self->wanted);
    return FALSE;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

/* Have the IME behind this object say when it is idle. */
static void listen(StandIn *self)
{
    IdleTeller tell = (IdleTeller)GetProcAddress(self->build.module, "JdTellWhenIdle");

    if (self->window == NULL) {
        WNDCLASSEXW class;

        memset(&class, 0, sizeof class);
        class.cbSize = sizeof class;
        class.lpfnWndProc = window_proc;
        class.hInstance = THIS_DLL;
        class.lpszClassName = WINDOW_CLASS;
        /* Once for the process; again, it fails and changes nothing. */
        RegisterClassExW(&class);
        self->window = CreateWindowExW(0, WINDOW_CLASS, NULL, 0, 0, 0, 0, 0, HWND_MESSAGE, NULL,
                                       THIS_DLL, NULL);
        if (self->window != NULL)
            SetWindowLongPtrW(self->window, GWLP_USERDATA, (LONG_PTR)self);
    }
    if (self->window == NULL)
        return;
    SetWindowTextW(self->window, self->build.id);
    if (tell != NULL)
        tell(self->window, WM_IME_IDLE);
}

/* The IME is idle, and this object active: if another installation is in
   use by now, its IME takes over. */
static void hand_over(StandIn *self)
{
    IdleAsker is_idle;
    Build build;
    ITfTextInputProcessorEx *ime = NULL;
    ITfThreadMgr *thread_mgr = self->thread_mgr;
    BOOL english;

    if (thread_mgr == NULL || self->handing_over || !wants_another(self))
        return;
    /* Idle when it posted the message is not idle now: a key may have come
       first. It will say so again. */
    is_idle = (IdleAsker)GetProcAddress(self->build.module, "JdIsIdle");
    if (is_idle == NULL || !is_idle())
        return;
    if (!create_wanted(self, &build, &ime))
        return;

    /* The thread manager is kept for as long as this takes: should TSF
       deactivate this object from inside one of the calls below, it lets
       go of its own. */
    ITfThreadMgr_AddRef(thread_mgr);
    self->handing_over = TRUE;
    english = keyboard_is_closed(thread_mgr);
    ITfTextInputProcessorEx_Deactivate(self->ime);
    if (SUCCEEDED(ITfTextInputProcessorEx_ActivateEx(ime, thread_mgr, self->client, self->flags))) {
        ITfTextInputProcessorEx_Release(self->ime);
        self->ime = ime;
        self->build = build;
    } else {
        /* It will not run here: undone, as far as it got, and the old one
           is back. */
        ITfTextInputProcessorEx_Deactivate(ime);
        ITfTextInputProcessorEx_Release(ime);
        refuse(self, build.id);
        ITfTextInputProcessorEx_ActivateEx(self->ime, thread_mgr, self->client, self->flags);
    }
    self->handing_over = FALSE;
    if (self->thread_mgr != NULL) {
        listen(self);
        /* An IME starts in 中 when it is activated. */
        if (english)
            close_keyboard(thread_mgr, self->client);
    } else {
        /* Deactivated meanwhile, as far as TSF knows: so it is. */
        ITfTextInputProcessorEx_Deactivate(self->ime);
    }
    ITfThreadMgr_Release(thread_mgr);
}

static HRESULT STDMETHODCALLTYPE stand_in_query(ITfTextInputProcessorEx *this, REFIID iid, void **object)
{
    StandIn *self = (StandIn *)this;

    if (object == NULL)
        return E_POINTER;
    if (same_guid(iid, &iid_unknown) || same_guid(iid, &iid_text_input_processor)
        || same_guid(iid, &iid_text_input_processor_ex)) {
        InterlockedIncrement(&self->references);
        *object = this;
        return S_OK;
    }
    /* Anything else is the IME's own: its display attributes, for one, for
       which TSF makes an object of this class and never activates it. */
    return ITfTextInputProcessorEx_QueryInterface(self->ime, iid, object);
}

static ULONG STDMETHODCALLTYPE stand_in_add_ref(ITfTextInputProcessorEx *this)
{
    return (ULONG)InterlockedIncrement(&((StandIn *)this)->references);
}

static ULONG STDMETHODCALLTYPE stand_in_release(ITfTextInputProcessorEx *this)
{
    StandIn *self = (StandIn *)this;
    LONG references = InterlockedDecrement(&self->references);

    if (references != 0)
        return (ULONG)references;
    if (self->window != NULL) {
        SetWindowLongPtrW(self->window, GWLP_USERDATA, 0);
        DestroyWindow(self->window);
    }
    if (self->thread_mgr != NULL)
        ITfThreadMgr_Release(self->thread_mgr);
    ITfTextInputProcessorEx_Release(self->ime);
    HeapFree(GetProcessHeap(), 0, self);
    return 0;
}

static HRESULT STDMETHODCALLTYPE stand_in_activate_ex(ITfTextInputProcessorEx *this, ITfThreadMgr *thread_mgr,
                                                      TfClientId client, DWORD flags)
{
    StandIn *self = (StandIn *)this;
    Build build;
    ITfTextInputProcessorEx *ime = NULL;
    HRESULT result;

    if (thread_mgr == NULL)
        return E_INVALIDARG;
    /* Not active, the IME has nothing in flight: the one from another
       installation takes its place with nothing to carry over. */
    if (self->thread_mgr == NULL && wants_another(self) && create_wanted(self, &build, &ime)) {
        ITfTextInputProcessorEx_Release(self->ime);
        self->ime = ime;
        self->build = build;
    }
    result = ITfTextInputProcessorEx_ActivateEx(self->ime, thread_mgr, client, flags);
    if (FAILED(result))
        return result;
    ITfThreadMgr_AddRef(thread_mgr);
    if (self->thread_mgr != NULL)
        ITfThreadMgr_Release(self->thread_mgr);
    self->thread_mgr = thread_mgr;
    self->client = client;
    self->flags = flags;
    listen(self);
    return result;
}

static HRESULT STDMETHODCALLTYPE stand_in_activate(ITfTextInputProcessorEx *this, ITfThreadMgr *thread_mgr,
                                                   TfClientId client)
{
    return stand_in_activate_ex(this, thread_mgr, client, 0);
}

static HRESULT STDMETHODCALLTYPE stand_in_deactivate(ITfTextInputProcessorEx *this)
{
    StandIn *self = (StandIn *)this;
    HRESULT result = ITfTextInputProcessorEx_Deactivate(self->ime);

    if (self->thread_mgr != NULL) {
        ITfThreadMgr_Release(self->thread_mgr);
        self->thread_mgr = NULL;
    }
    return result;
}

static const ITfTextInputProcessorExVtbl stand_in_methods = {
    stand_in_query,
    stand_in_add_ref,
    stand_in_release,
    stand_in_activate,
    stand_in_deactivate,
    stand_in_activate_ex,
};

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_IME_IDLE) {
        StandIn *self = (StandIn *)GetWindowLongPtrW(window, GWLP_USERDATA);

        if (self != NULL) {
            /* Kept for as long as this takes, whatever is released on the
               way. */
            stand_in_add_ref((ITfTextInputProcessorEx *)self);
            hand_over(self);
            stand_in_release((ITfTextInputProcessorEx *)self);
        }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

/* A stand-in in front of a new object of the IME in use. */
static HRESULT stand_in_new(const CLSID *clsid, StandIn **created)
{
    StandIn *self = (StandIn *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *self);
    HRESULT result;

    *created = NULL;
    if (self == NULL)
        return E_OUTOFMEMORY;
    self->methods = &stand_in_methods;
    self->references = 1;
    self->clsid = *clsid;
    result = load_current(&self->build) ? create_ime(&self->build, clsid, &self->ime)
                                        : HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
    if (FAILED(result)) {
        HeapFree(GetProcessHeap(), 0, self);
        return result;
    }
    copy_id(self->wanted, self->build.id);
    *created = self;
    return S_OK;
}

/* ---- The class factory ------------------------------------------------------- */

typedef struct Factory {
    const IClassFactoryVtbl *methods;
    LONG references;
    CLSID clsid;
} Factory;

static HRESULT STDMETHODCALLTYPE factory_query(IClassFactory *this, REFIID iid, void **object)
{
    if (object == NULL)
        return E_POINTER;
    if (same_guid(iid, &iid_unknown) || same_guid(iid, &iid_class_factory)) {
        InterlockedIncrement(&((Factory *)this)->references);
        *object = this;
        return S_OK;
    }
    *object = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE factory_add_ref(IClassFactory *this)
{
    return (ULONG)InterlockedIncrement(&((Factory *)this)->references);
}

static ULONG STDMETHODCALLTYPE factory_release(IClassFactory *this)
{
    LONG references = InterlockedDecrement(&((Factory *)this)->references);

    if (references == 0)
        HeapFree(GetProcessHeap(), 0, this);
    return (ULONG)references;
}

static HRESULT STDMETHODCALLTYPE factory_create(IClassFactory *this, IUnknown *outer, REFIID iid, void **object)
{
    StandIn *stand_in;
    HRESULT result;

    if (object == NULL)
        return E_POINTER;
    *object = NULL;
    if (outer != NULL)
        return CLASS_E_NOAGGREGATION;
    result = stand_in_new(&((Factory *)this)->clsid, &stand_in);
    if (FAILED(result))
        return result;
    result = stand_in_query((ITfTextInputProcessorEx *)stand_in, iid, object);
    stand_in_release((ITfTextInputProcessorEx *)stand_in);
    return result;
}

static HRESULT STDMETHODCALLTYPE factory_lock(IClassFactory *this, BOOL lock)
{
    (void)this;
    (void)lock;
    return S_OK;
}

static const IClassFactoryVtbl factory_methods = {
    factory_query,
    factory_add_ref,
    factory_release,
    factory_create,
    factory_lock,
};

/* ---- The entry points ---------------------------------------------------------- */

HRESULT STDAPICALLTYPE DllGetClassObject(REFCLSID clsid, REFIID iid, LPVOID *object)
{
    Build build;
    ClassObjectGetter get;
    IClassFactory *theirs = NULL;
    Factory *factory;
    HRESULT result;

    if (object == NULL)
        return E_POINTER;
    *object = NULL;
    if (clsid == NULL || iid == NULL)
        return E_INVALIDARG;
    /* Which class is the IME's is the IME's to say. */
    if (!load_current(&build))
        return HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
    get = (ClassObjectGetter)GetProcAddress(build.module, "DllGetClassObject");
    if (get == NULL)
        return CLASS_E_CLASSNOTAVAILABLE;
    result = get(clsid, &iid_class_factory, (LPVOID *)&theirs);
    if (FAILED(result))
        return result;
    IClassFactory_Release(theirs);

    factory = (Factory *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *factory);
    if (factory == NULL)
        return E_OUTOFMEMORY;
    factory->methods = &factory_methods;
    factory->references = 1;
    factory->clsid = *clsid;
    result = factory_query((IClassFactory *)factory, iid, object);
    factory_release((IClassFactory *)factory);
    return result;
}

/* A text service is never unloaded, and what has been handed out of here
   is not counted. */
HRESULT STDAPICALLTYPE DllCanUnloadNow(void)
{
    return S_FALSE;
}

/* regsvr32 is pointed at this DLL, and the IME registers it — not itself —
   as what applications load. */
HRESULT STDAPICALLTYPE DllRegisterServer(void)
{
    WCHAR path[PATH_LENGTH];
    DWORD length = GetModuleFileNameW(THIS_DLL, path, PATH_LENGTH);
    Build build;
    ServerRegistrar reg;

    if (length == 0 || length >= PATH_LENGTH)
        return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
    if (!load_current(&build))
        return HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
    reg = (ServerRegistrar)GetProcAddress(build.module, "JdRegisterServer");
    return reg != NULL ? reg(path) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}

HRESULT STDAPICALLTYPE DllUnregisterServer(void)
{
    Build build;
    Parameterless unregister;

    if (!load_current(&build))
        return HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
    unregister = (Parameterless)GetProcAddress(build.module, "DllUnregisterServer");
    return unregister != NULL ? unregister() : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
