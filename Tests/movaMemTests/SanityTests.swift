import Testing

@Test func testingFrameworkLoadsCorrectly() {
    // Proves the Makefile's flags work. If this fails to *compile*, the
    // framework search path is wrong; if it fails to *load*, an rpath is wrong.
    #expect(1 + 1 == 2)
}
