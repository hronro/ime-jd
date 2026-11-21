// The user-dictionary editor's parts that need no display: the file format,
// settings.ini, the words of the 状态 column, and the store. The window
// itself is tried in a desktop.

using ImeJd;

/** A directory of a test's own, removed when the test is done. */
class TempDir {
    public string path;

    public TempDir () {
        try {
            path = DirUtils.make_tmp ("imejd-editor-XXXXXX");
        } catch (FileError error) {
            GLib.error ("%s", error.message);
        }
    }

    ~TempDir () {
        remove_tree (path);
    }

    public string file (string name) {
        return Path.build_filename (path, name);
    }

    public void write (string name, string text) {
        try {
            FileUtils.set_contents (file (name), text);
        } catch (FileError error) {
            GLib.error ("%s", error.message);
        }
    }

    public string read (string name) {
        try {
            string text;
            FileUtils.get_contents (file (name), out text);
            return text;
        } catch (FileError error) {
            GLib.error ("%s", error.message);
        }
    }

    private static void remove_tree (string path) {
        if (FileUtils.test (path, FileTest.IS_DIR) && !FileUtils.test (path, FileTest.IS_SYMLINK)) {
            try {
                var dir = Dir.open (path);
                unowned string? name;
                while ((name = dir.read_name ()) != null) {
                    remove_tree (Path.build_filename (path, name));
                }
            } catch (FileError error) {
            }
            DirUtils.remove (path);
        } else {
            FileUtils.remove (path);
        }
    }
}

Store open_store (TempDir dir) {
    return new Store (dir.file (UserDictFile.NAME), dir.file ("settings.ini"));
}

Report build (string text) {
    uint status, line;
    var report = Report.build (text, UserDictFile.hash (text), out status, out line);
    assert_nonnull (report);
    return report;
}

void test_parse () {
    var rows = UserDictFile.parse ("# 注释\n\n 键道 \t jd \r\nno tab\n\t\n #x\tb\n不\tb");
    assert_cmpint (rows.length, CompareOperator.EQ, 4);
    assert_cmpint (rows[0].line, CompareOperator.EQ, 3);
    assert_cmpstr (rows[0].value, CompareOperator.EQ, "键道");
    assert_cmpstr (rows[0].keys, CompareOperator.EQ, "jd");
    // No TAB: the whole line is the value, to be fixed in place.
    assert_cmpint (rows[1].line, CompareOperator.EQ, 4);
    assert_cmpstr (rows[1].value, CompareOperator.EQ, "no tab");
    assert_cmpstr (rows[1].keys, CompareOperator.EQ, "");
    // A TAB alone is a line, not a blank: only spaces and CRs are trimmed.
    assert_cmpint (rows[2].line, CompareOperator.EQ, 5);
    assert_cmpstr (rows[2].value, CompareOperator.EQ, "");
    assert_cmpint (rows[3].line, CompareOperator.EQ, 7);
    assert_cmpstr (rows[3].value, CompareOperator.EQ, "不");
    assert_cmpstr (rows[3].keys, CompareOperator.EQ, "b");
}

void test_serialize () {
    string text = UserDictFile.serialize ({ "键道", "不" }, { "jd", "b" });
    assert_cmpstr (text, CompareOperator.EQ, UserDictFile.HEADER + "\n键道\tjd\n不\tb\n");
    var rows = UserDictFile.parse (text);
    assert_cmpint (rows.length, CompareOperator.EQ, 2);
    assert_cmpint (rows[0].line, CompareOperator.EQ, UserDictFile.line_of_entry (0));
    assert_cmpint (rows[1].line, CompareOperator.EQ, UserDictFile.line_of_entry (1));
    assert_cmpstr (UserDictFile.serialize ({}, {}), CompareOperator.EQ, UserDictFile.HEADER + "\n");
}

void test_decode () {
    string bom = "\xef\xbb\xbf键道\tjd\n";
    try {
        assert_cmpstr (UserDictFile.decode (bom, bom.length), CompareOperator.EQ, "键道\tjd\n");
    } catch (UserDictError error) {
        assert_not_reached ();
    }
    // GBK, and a NUL.
    uint8[] gbk = { 0xc4, 0xe3, '\t', 'a', '\n', 0 };
    uint8[] nul = { 'a', 0, 'b', 0 };
    assert_false (decodes ((string) gbk, 5));
    assert_false (decodes ((string) nul, 3));
}

bool decodes (string text, ssize_t length) {
    try {
        UserDictFile.decode (text, length);
        return true;
    } catch (UserDictError error) {
        assert_true (error is UserDictError.NOT_UTF8);
        return false;
    }
}

void test_read () {
    var dir = new TempDir ();
    try {
        assert_null (UserDictFile.read (dir.file ("missing.txt")));
        dir.write ("a.txt", "键道\tjd\n");
        assert_cmpstr (UserDictFile.read (dir.file ("a.txt")), CompareOperator.EQ, "键道\tjd\n");
    } catch (UserDictError error) {
        assert_not_reached ();
    }
    try {
        UserDictFile.read (dir.path);
        assert_not_reached ();
    } catch (UserDictError error) {
        // read(2)'s own words, not GLib's sentence around a path.
        assert_true (error is UserDictError.UNREADABLE);
        assert_cmpstr (error.message, CompareOperator.EQ, strerror (Posix.EISDIR));
    }
}

void test_write () {
    var dir = new TempDir ();
    string path = Path.build_filename (dir.path, "new", "用户自造词.txt");
    try {
        UserDictFile.write (path, "键道\tjd\n");
    } catch (Error error) {
        assert_not_reached ();
    }
    assert_cmpstr (dir.read ("new/用户自造词.txt"), CompareOperator.EQ, "键道\tjd\n");
    Posix.Stat st;
    Posix.stat (Path.get_dirname (path), out st);
    assert_cmpuint ((uint) (st.st_mode & 0777), CompareOperator.EQ, 0700);
}

void test_trim_and_hash () {
    assert_cmpstr (UserDictFile.trim ("  a b \r", " \r"), CompareOperator.EQ, "a b");
    assert_cmpstr (UserDictFile.trim ("\ta\t", " "), CompareOperator.EQ, "\ta\t");
    assert_cmpstr (UserDictFile.trim ("   ", " "), CompareOperator.EQ, "");
    // The values libjd pins in its own tests.
    assert_true (UserDictFile.hash ("") == 0x0409638ee2bde459);
    assert_true (UserDictFile.hash ("键道\tjd\n") == 0xb5f6c3766f38e694);
}

void test_ini_get () {
    string settings = "# Enabled=true\n[UserDict]\n Enabled = true \n[Other]\nEnabled=false\n";
    assert_cmpstr (Ini.get_value (settings, "UserDict", "Enabled"), CompareOperator.EQ, "true");
    assert_cmpstr (Ini.get_value (settings, "Other", "Enabled"), CompareOperator.EQ, "false");
    assert_null (Ini.get_value (settings, "None", "Enabled"));
    assert_null (Ini.get_value ("", "UserDict", "Enabled"));
}

void test_ini_set () {
    // What the engines write: their tests expect exactly this.
    assert_cmpstr (Ini.set_value ("", "UserDict", "Enabled", "true"), CompareOperator.EQ,
        "[UserDict]\nEnabled=true\n");
    assert_cmpstr (Ini.set_value ("# 注释\n[UserDict]\nEnabled=false\nX=1\n", "UserDict", "Enabled", "true"),
        CompareOperator.EQ, "# 注释\n[UserDict]\nEnabled=true\nX=1\n");
    assert_cmpstr (Ini.set_value ("[UserDictWindow]\nWidth=1\n[UserDict]\n", "UserDict", "Enabled", "true"),
        CompareOperator.EQ, "[UserDictWindow]\nWidth=1\n[UserDict]\nEnabled=true\n");
    assert_cmpstr (Ini.set_value ("[UserDict]\nEnabled=true\n", "UserDictWindow", "Width", "600"),
        CompareOperator.EQ, "[UserDict]\nEnabled=true\n\n[UserDictWindow]\nWidth=600\n");
    // A line it does not understand stays.
    assert_cmpstr (Ini.set_value ("garbage\n", "UserDict", "Enabled", "true"),
        CompareOperator.EQ, "garbage\n\n[UserDict]\nEnabled=true\n");
}

void test_problem_texts () {
    assert_cmpstr (new Problem.invalid (Jd.LINE_MALFORMED).text, CompareOperator.EQ, "缺少制表符（无编码），不生效");
    assert_cmpstr (new Problem.invalid (Jd.LINE_BAD_KEYS).text, CompareOperator.EQ, "编码无效（1 到 6 个 a-z），不生效");
    assert_cmpstr (new Problem.invalid (Jd.LINE_BAD_VALUE).text, CompareOperator.EQ,
        "词无效（不能为空或含控制字符，最长 255 字节），不生效");
    assert_cmpstr (new Problem.duplicate (2).text, CompareOperator.EQ, "与第 3 条重复，不生效");
    assert_cmpstr (new Problem.duplicate (-1).text, CompareOperator.EQ, "与内置词重复，不生效");
    assert_cmpstr (new Problem.shared_code (2, 2, 2).text, CompareOperator.EQ, "与 2 个内置词及第 3 条等 2 条同码");
    assert_cmpstr (new Problem.shared_code (0, 0, 1).text, CompareOperator.EQ, "与第 1 条同码");
    assert_cmpstr (new Problem.shared_code (3, -1, 0).text, CompareOperator.EQ, "与 3 个内置词同码");
}

void test_problems_for_rows () {
    // zzzzzz and zzzzza carry no built-in word; 不 is one on b, and z has
    // some.
    var report = build ("键道\tzzzzzz\n键道\tzzzzzz\n不\tb\nno tab\n键\tz\n甲\tzzzzza\n乙\tzzzzza\n");
    var problems = Problem.for_rows ({ 1, 2, 3, 4, 5, 6, 7, 0 }, report);
    assert_null (problems[0]);
    assert_cmpstr (problems[1].text, CompareOperator.EQ, "与第 1 条重复，不生效");
    assert_cmpstr (problems[2].text, CompareOperator.EQ, "与内置词重复，不生效");
    assert_true (problems[3].kind == ProblemKind.INVALID);
    assert_cmpstr (problems[3].text, CompareOperator.EQ, "缺少制表符（无编码），不生效");
    assert_true (problems[4].kind == ProblemKind.SHARED_CODE);
    assert_true (problems[4].text.has_prefix ("与 ") && problems[4].text.has_suffix (" 个内置词同码"));
    assert_cmpstr (problems[5].text, CompareOperator.EQ, "与第 7 条同码");
    assert_cmpstr (problems[6].text, CompareOperator.EQ, "与第 6 条同码");
    // Not written yet: not in the text the notes are about.
    assert_null (problems[7]);

    // Rows as read — ascending, none new — are walked with the notes rather
    // than looked up, to the same verdicts.
    var walked = Problem.for_rows ({ 1, 2, 3, 4, 5, 6, 7 }, report);
    for (int i = 0; i < 7; i++) {
        assert_true ((walked[i] == null) == (problems[i] == null));
        if (walked[i] != null) {
            assert_cmpstr (walked[i].text, CompareOperator.EQ, problems[i].text);
        }
    }

    // Rows moved since the build: notes follow lines, not positions.
    problems = Problem.for_rows ({ 0, 2, 1 }, report);
    assert_null (problems[0]);
    assert_cmpstr (problems[1].text, CompareOperator.EQ, "与第 3 条重复，不生效");

    // No build, no notes.
    problems = Problem.for_rows ({ 1, 2 }, null);
    assert_null (problems[0]);
    assert_null (problems[1]);
}

void test_default_directory () {
    string? saved = Environment.get_variable ("XDG_CONFIG_HOME");
    Environment.set_variable ("XDG_CONFIG_HOME", "/config", true);
    assert_cmpstr (Store.default_directory (), CompareOperator.EQ, "/config/ime-jd");
    // Relative: ignored, as the engines ignore it.
    Environment.set_variable ("XDG_CONFIG_HOME", "config", true);
    assert_cmpstr (Store.default_directory (), CompareOperator.EQ,
        Path.build_filename (Environment.get_home_dir (), ".config", "ime-jd"));
    if (saved != null) {
        Environment.set_variable ("XDG_CONFIG_HOME", saved, true);
    } else {
        Environment.unset_variable ("XDG_CONFIG_HOME");
    }
}

void test_store_loads_and_saves () {
    var dir = new TempDir ();
    var store = open_store (dir);
    // No file: an empty table, nothing wrong.
    assert_null (store.text);
    assert_null (store.error);
    assert_false (store.read_only);
    assert_false (store.enabled);

    dir.write (UserDictFile.NAME, "键道\tzzzzzz\n不\tb\n");
    store.reload ();
    assert_cmpstr (store.text, CompareOperator.EQ, "键道\tzzzzzz\n不\tb\n");
    assert_cmpuint (store.report.entries, CompareOperator.EQ, 1);
    assert_cmpuint (store.report.dropped, CompareOperator.EQ, 1);

    string text = UserDictFile.serialize ({ "键道" }, { "zzzzzz" });
    try {
        store.save (text);
    } catch (Error error) {
        assert_not_reached ();
    }
    assert_cmpstr (dir.read (UserDictFile.NAME), CompareOperator.EQ, text);
    assert_cmpstr (store.text, CompareOperator.EQ, text);
    assert_cmpuint (store.report.dropped, CompareOperator.EQ, 0);
}

void test_store_reports_what_cannot_be_read () {
    var dir = new TempDir ();
    dir.write (UserDictFile.NAME, (string) new uint8[] { 0xc4, 0xe3, '\t', 'a', '\n', 0 });
    var store = open_store (dir);
    assert_null (store.text);
    assert_true (store.error.kind == LoadError.Kind.NOT_UTF8);
    assert_cmpstr (store.error.message, CompareOperator.EQ, "文件不是 UTF-8 编码");
    // Not shown, so not to be overwritten from the table either.
    assert_true (store.read_only);

    FileUtils.remove (dir.file (UserDictFile.NAME));
    DirUtils.create (dir.file (UserDictFile.NAME), 0700);
    store.reload ();
    assert_true (store.error.kind == LoadError.Kind.UNREADABLE);
    assert_cmpstr (store.error.message, CompareOperator.EQ, "无法读取文件：" + strerror (Posix.EISDIR));
    assert_true (store.read_only);
}

void test_store_reports_a_file_over_the_cap () {
    var dir = new TempDir ();
    var text = new StringBuilder ();
    for (uint i = 0; i <= Jd.USER_DICT_MAX_ENTRIES; i++) {
        text.append_printf ("词%u\tzzzzzz\n", i);
    }
    dir.write (UserDictFile.NAME, text.str);
    var store = open_store (dir);
    assert_true (store.error.kind == LoadError.Kind.BUILD);
    assert_cmpstr (store.error.message, CompareOperator.EQ,
        "第 %u 行起超过 %u 条上限".printf (Jd.USER_DICT_MAX_ENTRIES + 1, Jd.USER_DICT_MAX_ENTRIES));
    // Shown, and editable: deleting rows is how it is fixed.
    assert_nonnull (store.text);
    assert_false (store.read_only);
}

void test_store_switch () {
    var dir = new TempDir ();
    var store = open_store (dir);
    try {
        store.save_switch (true);
    } catch (Error error) {
        assert_not_reached ();
    }
    assert_true (store.enabled);
    assert_cmpstr (dir.read ("settings.ini"), CompareOperator.EQ, "[UserDict]\nEnabled=true\n");

    // The window's size goes beside it, and keeps it.
    store.save_window_size (700, 500, false);
    int width, height;
    bool maximized;
    assert_true (store.window_size (out width, out height, out maximized));
    assert_cmpint (width, CompareOperator.EQ, 700);
    assert_cmpint (height, CompareOperator.EQ, 500);
    assert_false (maximized);
    store.reload ();
    assert_true (store.enabled);

    // Another process's spelling of on.
    dir.write ("settings.ini", "[UserDict]\nEnabled=1\n");
    store.reload ();
    assert_true (store.enabled);
    dir.write ("settings.ini", "[UserDict]\nEnabled=false\n");
    store.reload ();
    assert_false (store.enabled);
}

void test_store_keeps_settings_it_cannot_read () {
    var dir = new TempDir ();
    DirUtils.create (dir.file ("settings.ini"), 0700);
    var store = open_store (dir);
    try {
        store.save_switch (true);
        assert_not_reached ();
    } catch (Error error) {
    }
    assert_false (store.enabled);
    assert_true (FileUtils.test (dir.file ("settings.ini"), FileTest.IS_DIR));
}

// 编码反查's answers, over the real engine: the cases the other clients test
// (windows/userdict/src/lookup/report.rs).

string lookup_body (string query, string? phrases) {
    return new CodeLookup.Report (query, CodeLookup.codes (query, phrases), phrases != null).body;
}

void test_lookup_lists_every_code () {
    var report = new CodeLookup.Report ("着", CodeLookup.codes ("着", null), false);
    assert_cmpstr (report.title, CompareOperator.EQ, "「着」的编码");
    // A later candidate says which it is.
    assert_cmpstr (report.body, CompareOperator.EQ,
        "o（第 2 个候选）\nfe\nqe\nflo\nfzou\nqzou\nfeouia\nflouia\nfzouia\nqeouia\nqzouia");
    // Where the word comes first, the code stands alone.
    assert_cmpstr (lookup_body ("的", null), CompareOperator.EQ, "d\ndeuiua\ndkuiua");
}

void test_lookup_marks_user_phrases () {
    string phrases = "的\tzzzzzz\n测试词\td\n";
    // A user phrase leads its code, and counts toward the word's place.
    assert_cmpstr (lookup_body ("的", phrases), CompareOperator.EQ,
        "d（第 2 个候选）\ndeuiua\ndkuiua\nzzzzzz（自造词）");
    assert_cmpstr (lookup_body ("测试词", phrases), CompareOperator.EQ, "d（自造词）");
    // Phrases that do not build are left out, as the engines leave them.
    assert_cmpint (CodeLookup.codes ("测试词", "测试词\td\n".concat (string.nfill ((int) Jd.USER_DICT_TEXT_MAX, 'x'))).length,
        CompareOperator.EQ, 0);
}

void test_lookup_says_where_it_looked () {
    var enabled = new CodeLookup.Report ("不在词库里的词", {}, true);
    assert_cmpstr (enabled.title, CompareOperator.EQ, "没有找到「不在词库里的词」");
    assert_cmpstr (enabled.body, CompareOperator.EQ, "内置词库和用户自造词中都没有这个词。");
    var disabled = new CodeLookup.Report ("词", {}, false);
    assert_cmpstr (disabled.body, CompareOperator.EQ, "内置词库中没有这个词。用户自造词未启用，不在查询范围内。");
    assert_cmpint (CodeLookup.codes ("不在词库里的词", null).length, CompareOperator.EQ, 0);
    assert_cmpint (CodeLookup.codes ("", null).length, CompareOperator.EQ, 0);
}

void test_lookup_cuts_a_long_query_short () {
    var builder = new StringBuilder ();
    for (int i = 0; i < 30; i++) {
        builder.append ("键");
    }
    string long_query = builder.str;
    string twenty = long_query.substring (0, long_query.index_of_nth_char (20));
    assert_cmpstr (new CodeLookup.Report (long_query, {}, false).title, CompareOperator.EQ,
        "没有找到「%s…」".printf (twenty));
    assert_cmpstr (new CodeLookup.Report (twenty, {}, false).title, CompareOperator.EQ,
        "没有找到「%s」".printf (twenty));
}

void test_lookup_trims_only_spaces_tabs_and_line_breaks () {
    assert_cmpstr (CodeLookup.query (" 键道\r\n"), CompareOperator.EQ, "键道");
    assert_cmpstr (CodeLookup.query ("\t键 道\n"), CompareOperator.EQ, "键 道");
    assert_cmpstr (CodeLookup.query ("键道　"), CompareOperator.EQ, "键道　");
    assert_cmpstr (CodeLookup.query (" \n"), CompareOperator.EQ, "");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/file/parse", test_parse);
    Test.add_func ("/file/serialize", test_serialize);
    Test.add_func ("/file/decode", test_decode);
    Test.add_func ("/file/read", test_read);
    Test.add_func ("/file/write", test_write);
    Test.add_func ("/file/trim-and-hash", test_trim_and_hash);
    Test.add_func ("/ini/get", test_ini_get);
    Test.add_func ("/ini/set", test_ini_set);
    Test.add_func ("/problem/texts", test_problem_texts);
    Test.add_func ("/problem/for-rows", test_problems_for_rows);
    Test.add_func ("/store/default-directory", test_default_directory);
    Test.add_func ("/store/loads-and-saves", test_store_loads_and_saves);
    Test.add_func ("/store/reports-what-cannot-be-read", test_store_reports_what_cannot_be_read);
    Test.add_func ("/store/reports-a-file-over-the-cap", test_store_reports_a_file_over_the_cap);
    Test.add_func ("/store/switch", test_store_switch);
    Test.add_func ("/store/keeps-settings-it-cannot-read", test_store_keeps_settings_it_cannot_read);
    Test.add_func ("/lookup/lists-every-code", test_lookup_lists_every_code);
    Test.add_func ("/lookup/marks-user-phrases", test_lookup_marks_user_phrases);
    Test.add_func ("/lookup/says-where-it-looked", test_lookup_says_where_it_looked);
    Test.add_func ("/lookup/cuts-a-long-query-short", test_lookup_cuts_a_long_query_short);
    Test.add_func ("/lookup/trims-only-spaces-tabs-and-line-breaks", test_lookup_trims_only_spaces_tabs_and_line_breaks);
    return Test.run ();
}
