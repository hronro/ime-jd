// A dictionary of the host's own in place of the embedded one: the Java
// counterpart of bindings/rust/tests/dict.rs.
package com.hronro.jd;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class DictTest {
    private static List<String> firstValues(Engine e, String keys, int count) {
        e.reset();
        for (char key : keys.toCharArray()) {
            e.pressKey((byte) key);
        }
        return e.readRange(0, count).stream().map(Candidate::value).toList();
    }

    @Test
    void aHostDictionaryReplacesTheBuiltInOne() throws UserDictException {
        Dict.Built built = Dict.build("你\tn\n你好\tnh\n；\t;\n：\t;;\n坏\tn;\n你\tn\n", 7);
        UserDictReport report = built.report();
        assertEquals(List.of(4, 1, 1, 0), List.of(report.entries(), report.invalid(), report.dropped(), report.shared()));
        assertEquals(2, report.notes().size());
        Dict dict = built.dict();
        assertEquals(4, dict.getEntries());
        assertEquals(7, dict.getSourceTag());

        Dict copy = Dict.fromBlob(dict.getBlob());
        assertEquals(4, copy.getEntries());
        assertEquals(7, copy.getSourceTag());
        byte[] cut = java.util.Arrays.copyOf(dict.getBlob(), dict.getBlob().length - 1);
        assertEquals(UserDictException.Status.CORRUPT, assertThrows(UserDictException.class, () -> Dict.fromBlob(cut)).getStatus());

        try (Engine e = new Engine(copy, null)) {
            assertEquals(List.of("你"), firstValues(e, "n", 1));
            assertEquals(List.of("："), firstValues(e, ";;", 1));
            assertEquals(List.of(), firstValues(e, "b", 1));
            assertEquals(List.of("nh"), e.lookupCodes("你好").stream().map(Code::keys).toList());
        }
    }

    @Test
    void aUserDictionarySitsOnTheDictionaryItWasBuiltOn() throws UserDictException {
        Dict dict = Dict.build("你\tn\n拟\tn\n").dict();
        UserDict.Built built = UserDict.build(dict, "你\tn\n泥\tn\n", 0);
        assertEquals(List.of(1, 1, 1), List.of(built.report().entries(), built.report().dropped(), built.report().shared()));
        UserDict user = built.dict();
        try (Engine e = new Engine(dict, user)) {
            assertEquals(List.of("泥", "你", "拟"), firstValues(e, "n", 3));
        }

        Dict other = Dict.build("你\tn\n").dict();
        assertEquals(
                UserDictException.Status.STALE,
                assertThrows(UserDictException.class, () -> UserDict.fromBlob(other, user.getBlob())).getStatus());
        IllegalStateException refused = assertThrows(IllegalStateException.class, () -> new Engine(other, user));
        assertTrue(refused.getMessage().contains("another dictionary"), refused.getMessage());
        if (Dict.builtinEntries() > 0) {
            assertEquals(
                    UserDictException.Status.STALE,
                    assertThrows(UserDictException.class, () -> UserDict.fromBlob(user.getBlob())).getStatus());
        }
    }

    @Test
    void anEmptyDictionaryLeavesOnlyTheUserDictionary() throws UserDictException {
        Dict empty = Dict.empty();
        assertEquals(0, empty.getEntries());
        // Every empty dictionary is the same one.
        UserDict user = UserDict.build(Dict.empty(), "不\tb\n测试\tb\n：\t;;\n", 0).dict();
        try (Engine e = new Engine(empty, user)) {
            assertEquals(List.of("不", "测试"), firstValues(e, "b", 3));
            assertEquals(List.of("："), firstValues(e, ";;", 1));
            assertEquals(List.of(), firstValues(e, "n", 1));
        }
    }

    @Test
    void aMappedDictionaryIsReadInPlace(@TempDir Path dir) throws IOException, UserDictException {
        Dict built = Dict.build("你\tn\n").dict();
        Path file = dir.resolve("dict.bin");
        Files.write(file, built.getBlob());
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ)) {
            ByteBuffer map = channel.map(FileChannel.MapMode.READ_ONLY, 0, channel.size());
            Dict mapped = Dict.fromBuffer(map);
            UserDict user = UserDict.build(mapped, "泥\tn\n", 0).dict();
            UserDict userMapped = UserDict.fromBuffer(mapped, ByteBuffer.allocateDirect(user.getBlob().length).put(user.getBlob()).flip());
            try (Engine e = new Engine(mapped, userMapped)) {
                assertEquals(List.of("泥", "你"), firstValues(e, "n", 2));
            }
        }
    }

    @Test
    void theBuiltInDictionaryIsThereUnlessThisIsLibjdEngine() {
        if (Dict.builtinEntries() == 0) {
            assertThrows(IllegalStateException.class, Engine::new);
        } else {
            assertTrue(Dict.builtinEntries() > 100_000);
            new Engine().close();
        }
    }
}
