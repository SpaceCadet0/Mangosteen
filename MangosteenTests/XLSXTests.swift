import XCTest

final class XLSXTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testZipRoundTripKeepsStoredAndDeflatedEntries() throws {
        let big = Data(String(repeating: "mangosteen ", count: 500).utf8)
        let archive = ZipArchive.write([("a.txt", Data("hi".utf8)), ("dir/b.xml", big), ("empty", Data())])
        let entries = try ZipArchive.read(archive)
        XCTAssertEqual(entries["a.txt"], Data("hi".utf8))
        XCTAssertEqual(entries["dir/b.xml"], big)
        XCTAssertEqual(entries["empty"], Data())
        XCTAssertLessThan(archive.count, big.count)
    }

    func testZipMatchesSystemUnzip() throws {
        let archive = directory.appendingPathComponent("test.zip")
        try ZipArchive.write([("folder/hello.txt", Data(String(repeating: "привет ", count: 100).utf8))]).write(to: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", archive.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testWriteThenReadRoundTrip() throws {
        let rows = [
            ["Name", "Price", "Code", "Note"],
            ["Mangosteen", "3.5", "007", "a, \"quoted\" <tag> & more"],
            ["", "-12", "1234567890123456", " padded "],
            ["Мангостин", "0", "", "line\nbreak"],
        ]
        let data = XLSX.write(rows: rows, sheetName: "Fruit: list")
        let sheets = try XLSX.read(parts: ZipArchive.read(data))
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].name, "Fruit list")
        XCTAssertEqual(sheets[0].rows, rows)
    }

    func testWriterKeepsIdentifiersAsText() throws {
        let data = XLSX.write(rows: [["007", "3.5", "1234567890123456", "1e5"]], sheetName: "S")
        let sheet = try XCTUnwrap(String(data: ZipArchive.read(data)["xl/worksheets/sheet1.xml"]!, encoding: .utf8))
        XCTAssertTrue(sheet.contains(#"<c r="B1"><v>3.5</v></c>"#))
        XCTAssertTrue(sheet.contains(#"<c r="A1" t="inlineStr"><is><t>007</t></is></c>"#))
        XCTAssertTrue(sheet.contains(#"<c r="C1" t="inlineStr">"#))
        XCTAssertTrue(sheet.contains(#"<c r="D1" t="inlineStr">"#))
    }

    func testReadsSharedStringsDatesGapsAndSeveralSheets() throws {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parts: [String: Data] = [
            "_rels/.rels": Data("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="r1" Type="\(rel)/officeDocument" Target="/xl/workbook.xml"/></Relationships>
            """.utf8),
            "xl/workbook.xml": Data("""
            <x:workbook xmlns:x="\(main)" xmlns:r="\(rel)"><x:sheets>
            <x:sheet name="Data" sheetId="1" r:id="rIdA"/><x:sheet name="Other" sheetId="2" r:id="rIdB"/>
            </x:sheets></x:workbook>
            """.utf8),
            "xl/_rels/workbook.xml.rels": Data("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdA" Type="\(rel)/worksheet" Target="worksheets/data.xml"/>
            <Relationship Id="rIdB" Type="\(rel)/worksheet" Target="worksheets/../worksheets/other.xml"/>
            <Relationship Id="rIdS" Type="\(rel)/sharedStrings" Target="sharedStrings.xml"/>
            <Relationship Id="rIdT" Type="\(rel)/styles" Target="styles.xml"/></Relationships>
            """.utf8),
            "xl/sharedStrings.xml": Data("""
            <sst xmlns="\(main)"><si><t>Plain</t></si><si><r><t>Rich </t></r><r><t>text</t></r><rPh><t>ignored</t></rPh></si></sst>
            """.utf8),
            "xl/styles.xml": Data("""
            <styleSheet xmlns="\(main)"><numFmts><numFmt numFmtId="164" formatCode="&quot;Day&quot; dd.mm.yyyy"/>
            <numFmt numFmtId="165" formatCode="0.00&quot;h&quot;"/></numFmts>
            <cellStyleXfs><xf numFmtId="14"/></cellStyleXfs>
            <cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="20"/></cellXfs></styleSheet>
            """.utf8),
            "xl/worksheets/data.xml": Data("""
            <worksheet xmlns="\(main)"><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
            <row r="3"><c r="A3" s="1"><v>45000</v></c><c r="B3" s="2"><v>45000.5</v></c><c r="C3" s="3"><v>2.5</v></c></row>
            <row r="4"><c r="A4" t="b"><v>1</v></c><c r="B4" t="str"><f>A1</f><v>Plain</v></c><c r="C4" s="4"><v>0.75</v></c></row>
            <row r="5"><c r="B5" t="inlineStr"><is><t>inline</t></is></c><c r="AA5"><v>7</v></c></row>
            </sheetData></worksheet>
            """.utf8),
            "xl/worksheets/other.xml": Data("""
            <worksheet xmlns="\(main)"><sheetData><row><c><v>1</v></c><c><v>2</v></c></row></sheetData></worksheet>
            """.utf8),
        ]
        let sheets = try XLSX.read(parts: parts)
        XCTAssertEqual(sheets.map(\.name), ["Data", "Other"])
        let rows = sheets[0].rows
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0][0], "Plain")
        XCTAssertEqual(rows[0][2], "Rich text")
        XCTAssertEqual(rows[1].allSatisfy(\.isEmpty), true)
        XCTAssertEqual(rows[2][0], "2023-03-15")
        XCTAssertEqual(rows[2][1], "2023-03-15 12:00:00")
        XCTAssertEqual(rows[2][2], "2.5")
        XCTAssertEqual(rows[3], ["TRUE", "Plain", "18:00:00"] + Array(repeating: "", count: 24))
        XCTAssertEqual(rows[4][1], "inline")
        XCTAssertEqual(rows[4][26], "7")
        XCTAssertEqual(sheets[1].rows, [["1", "2"]])
    }

    func testDateHelpers() {
        XCTAssertTrue(XLSX.isDateFormat("yyyy-mm-dd"))
        XCTAssertTrue(XLSX.isDateFormat("[$-409]h:mm AM/PM"))
        XCTAssertFalse(XLSX.isDateFormat("0.00"))
        XCTAssertFalse(XLSX.isDateFormat("#,##0 \"days\""))
        XCTAssertFalse(XLSX.isDateFormat("[Red]0.0"))
        XCTAssertEqual(XLSX.dateText(serial: 0, date1904: true), "00:00:00")
        XCTAssertEqual(XLSX.dateText(serial: 1, date1904: true), "1904-01-02")
        XCTAssertEqual(XLSX.columnName(0), "A")
        XCTAssertEqual(XLSX.columnName(27), "AB")
        XCTAssertEqual(XLSX.columnIndex(ofReference: "AB12"), 27)
    }

    func testConvertsCSVToXLSXAndBack() throws {
        let csv = directory.appendingPathComponent("prices.csv")
        try "Item,Price\nMangosteen,3.5\n\"Lychee, red\",2\n".write(to: csv, atomically: true, encoding: .utf8)
        let xlsx = try XCTUnwrap(Converter.convert(csv, to: .xlsx, options: ConversionOptions()))
        XCTAssertEqual(xlsx.lastPathComponent, "prices.xlsx")
        let tsv = try XCTUnwrap(Converter.convert(xlsx, to: .tsv, options: ConversionOptions()))
        XCTAssertEqual(try String(contentsOf: tsv, encoding: .utf8), "Item\tPrice\nMangosteen\t3.5\nLychee, red\t2\n")
    }

    func testWorkbookWithSeveralSheetsBecomesFolder() throws {
        var parts = try ZipArchive.read(XLSX.write(rows: [["a"]], sheetName: "First"))
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        parts["xl/workbook.xml"] = Data("""
        <workbook xmlns="\(main)" xmlns:r="\(rel)"><sheets><sheet name="First" sheetId="1" r:id="rId1"/>\
        <sheet name="Q1/Q2" sheetId="2" r:id="rId3"/><sheet name="Empty" sheetId="3" r:id="rId4"/></sheets></workbook>
        """.utf8)
        parts["xl/_rels/workbook.xml.rels"] = Data("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId3" Type="\(rel)/worksheet" Target="worksheets/sheet2.xml"/>\
        <Relationship Id="rId4" Type="\(rel)/worksheet" Target="worksheets/sheet3.xml"/></Relationships>
        """.utf8)
        parts["xl/worksheets/sheet2.xml"] = Data("<worksheet xmlns=\"\(main)\"><sheetData><row r=\"1\"><c r=\"A1\"><v>2</v></c></row></sheetData></worksheet>".utf8)
        parts["xl/worksheets/sheet3.xml"] = Data("<worksheet xmlns=\"\(main)\"><sheetData/></worksheet>".utf8)
        let workbook = directory.appendingPathComponent("book.xlsx")
        try ZipArchive.write(parts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }).write(to: workbook)

        let folder = try XCTUnwrap(Converter.convert(workbook, to: .csv, options: ConversionOptions()))
        XCTAssertEqual(folder.lastPathComponent, "book (CSV)")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["First.csv", "Q1-Q2.csv"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Q1-Q2.csv"), encoding: .utf8), "2\n")
    }

    func testOffersXLSXForTables() {
        XCTAssertEqual(FormatCatalog.targets(for: .csv), [.tsv, .xlsx])
        XCTAssertEqual(FormatCatalog.targets(for: .xlsx), [.csv, .tsv])
    }
}
