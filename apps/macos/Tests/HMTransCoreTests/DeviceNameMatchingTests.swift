import Testing
@testable import HMTransCore

@Test("同一设备的型号名和系统完整名称可作为历史展示别名")
func deviceDisplayNameAliases() {
    #expect(deviceDisplayNamesAreAliases("MatePad Pro", "Linksc的MatePad Pro"))
    #expect(deviceDisplayNamesAreAliases("  MATEPAD   PRO ", "MatePad Pro"))
    #expect(!deviceDisplayNamesAreAliases("Alice的MatePad Pro", "Bob的MatePad Pro"))
    #expect(!deviceDisplayNamesAreAliases("MatePad Pro", "MatePad 11"))
}
