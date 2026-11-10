import SwiftUI

struct ThirdPartyLicensesView: View {
    private let notices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "无法读取第三方许可，请查看项目 docs/dependencies 中的许可清单。"
        }
        let nativeURL = Bundle.main.url(forResource: "LocationDDI", withExtension: nil)?.appendingPathComponent("ThirdPartyNotices.txt")
        let native = nativeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return text + (native.isEmpty ? "" : "\n\n" + native)
    }()

    var body: some View {
        ScrollView {
            Text(notices).font(.footnote).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("第三方许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}
