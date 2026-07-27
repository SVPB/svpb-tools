import CeolKitParser
import XCTest
@testable import App

/// Covers the mapping from a CeolKit `Score` onto catalogue `Tune`/`Part` fields.
///
/// These cases are the ones the deleted hand-rolled `ABCParser` used to handle,
/// plus the ones it got wrong: `nm=` as an alternative spelling of `name=`, and
/// files containing more than one tune.
final class CatalogueExtractorTests: XCTestCase {

    private func extract(_ source: String) -> CatalogueExtractor.Entry {
        CatalogueExtractor.extract(from: CeolKitParser().parse(source, options: .default))
    }

    // MARK: - Title

    func testTitleComesFromFirstTitleField() {
        let entry = extract("""
        X:1
        T:Archie Beag
        M:6/8
        L:1/8
        K:D
        A2 B c2 d |]
        """)

        XCTAssertEqual(entry.title, "Archie Beag")
    }

    func testTitleIsNilWhenAbsent() {
        let entry = extract("""
        X:1
        M:6/8
        L:1/8
        K:D
        A2 B c2 d |]
        """)

        XCTAssertNil(entry.title)
    }

    /// A medley is a single ABC file holding several `X:` blocks. One PDF is
    /// built per file, so the first tune's title names the catalogue entry.
    func testTitleOfMultiTuneFileIsTheFirstTune() {
        let entry = extract("""
        X:1
        T:First Tune
        M:4/4
        L:1/8
        K:D
        A2 d2 |]

        X:2
        T:Second Tune
        M:6/8
        L:1/8
        K:A
        A2 B c2 d |]
        """)

        XCTAssertEqual(entry.title, "First Tune")
    }

    // MARK: - Parts

    func testFileWithNoVoiceFieldsIsAFullScore() {
        let entry = extract("""
        X:1
        T:No Voices
        M:4/4
        L:1/8
        K:D
        A2 d2 |]
        """)

        XCTAssertEqual(entry.parts, ["Full Score"])
    }

    /// CeolKit synthesises a voice with ID "1" when no `V:` field is present, so
    /// a bare `V:1` is indistinguishable from no voices at all — both mean the
    /// musician has a whole score rather than a choice of parts.
    func testLoneUnnamedDefaultVoiceIsAFullScore() {
        let entry = extract("""
        X:1
        T:Single Voice
        M:4/4
        L:1/8
        V:1
        K:D
        V:1
        A2 d2 |]
        """)

        XCTAssertEqual(entry.parts, ["Full Score"])
    }

    /// Both spellings of the voice-name attribute are honoured. The old parser
    /// recognised only `name=`, so `nm=` used to fall through to the voice ID.
    func testVoiceNamesUseNameAndNmAttributes() {
        let entry = extract("""
        X:1
        T:Multi Voice
        M:4/4
        L:1/8
        V:1 name="Melody"
        V:2 nm="Harmony 1"
        K:D
        V:1
        A2 d2 |]
        V:2
        F2 A2 |]
        """)

        XCTAssertEqual(entry.parts, ["Melody", "Harmony 1"])
    }

    func testUnnamedVoiceFallsBackToItsVoiceID() {
        let entry = extract("""
        X:1
        T:Named And Unnamed
        M:4/4
        L:1/8
        V:1 name="Melody"
        V:Bass
        K:D
        V:1
        A2 d2 |]
        V:Bass
        D2 D2 |]
        """)

        XCTAssertEqual(entry.parts, ["Melody", "Bass"])
    }

    func testShortNameIsUsedWhenNoFullNameIsGiven() {
        let entry = extract("""
        X:1
        T:Short Names
        M:4/4
        L:1/8
        V:1 name="Melody"
        V:2 snm="Harm"
        K:D
        V:1
        A2 d2 |]
        V:2
        F2 A2 |]
        """)

        XCTAssertEqual(entry.parts, ["Melody", "Harm"])
    }

    /// Parts are collected across every tune in the file, deduplicated, in
    /// first-appearance order — the built PDF covers the whole file, so a part
    /// appearing in any tune is a part the musician can select.
    func testPartsAreUnionedAcrossTunesInFirstAppearanceOrder() {
        let entry = extract("""
        X:1
        T:First
        M:4/4
        L:1/8
        V:1 name="Melody"
        V:2 name="Harmony 1"
        K:D
        V:1
        A2 d2 |]
        V:2
        F2 A2 |]

        X:2
        T:Second
        M:6/8
        L:1/8
        V:1 name="Harmony 1"
        V:2 name="Bass"
        K:A
        V:1
        A2 B c2 d |]
        V:2
        A3 A3 |]
        """)

        XCTAssertEqual(entry.parts, ["Melody", "Harmony 1", "Bass"])
    }

    func testPartsAreNeverEmpty() {
        let entry = extract("X:1\nT:Empty\nK:D\n")

        XCTAssertFalse(entry.parts.isEmpty)
        XCTAssertEqual(entry.parts, ["Full Score"])
    }
}
