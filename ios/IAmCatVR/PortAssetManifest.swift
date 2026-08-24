import Foundation

struct PortAssetEntry: Codable {
    let fileName: String
    let size: Int64
    let sha256: String
    let availableInSourceSet: Bool
}

enum PortAssetManifest {
    static let unityVersion = "2022.3.19f1"
    static let campaignScenes = ["level0", "level1", "level2", "level3", "level4", "level5", "level6", "level7"]

    static let assets: [PortAssetEntry] = [
        .init(fileName: "resources.assets", size: 3_732_344, sha256: "ff2394e891ea8198877d2013581a2af54547b300ccab21c67ffabb796f99188c", availableInSourceSet: true),
        .init(fileName: "sharedassets0.assets", size: 16_374_364, sha256: "c9515caf25d4a6efc571122d30b0002189adfcdfb0cedcb8008af5fd5c57832a", availableInSourceSet: true),
        .init(fileName: "sharedassets1.assets", size: 3_235_460, sha256: "e8e83bf01e29301717a2ceabd2f7ff60ed7a8f200ab23dfa75e429857b6d808a", availableInSourceSet: true),
        .init(fileName: "sharedassets2.assets", size: 28_314_204, sha256: "168fa27b49819bac77ae99f9b7511b217cdb581e5d50bc1a6628422f6c14795b", availableInSourceSet: true),
        .init(fileName: "sharedassets3.assets", size: 4_579_832, sha256: "38df11e8de0abd0a8a2c3ec30e01a65a6b2acea686fba28485f61033916702b7", availableInSourceSet: true),
        .init(fileName: "sharedassets4.assets", size: 35_443_880, sha256: "fe3d4314b7cb778a7e995f148424e22f252c552fd654c1927145b531e615e27c", availableInSourceSet: true),
        .init(fileName: "sharedassets5.assets", size: 40_325_632, sha256: "488e719724dc839cf8eb1b18ec8c884160536b96d3882c0bc686bf856a0d2277", availableInSourceSet: true),
        .init(fileName: "sharedassets5.assets.resS", size: 263_330_624, sha256: "09c257cede3b73c708bb226e0e2247783bdada6e430d33849078e48a5af8e841", availableInSourceSet: true),
        .init(fileName: "sharedassets6.assets", size: 424_912_728, sha256: "7ecb59861184a84bd034bbf4f202fa5d7db3099f1714d4d3bcd02daa847d146e", availableInSourceSet: true),
        .init(fileName: "sharedassets7.assets", size: 36_401_376, sha256: "d5b3f6d7592068603f57fb143259daa067ad1474ad79ae8d822d150cebf2c709", availableInSourceSet: true),
        .init(fileName: "level7", size: 21_308_552, sha256: "66374426294e6865f5932f556313fd755fafb119552447c2b1ae51a4db8fec3e", availableInSourceSet: true),
        .init(fileName: "sharedassets4.assets.resS", size: 0, sha256: "", availableInSourceSet: false),
        .init(fileName: "sharedassets6.assets.resS", size: 0, sha256: "", availableInSourceSet: false),
        .init(fileName: "sharedassets7.assets.resS", size: 0, sha256: "", availableInSourceSet: false)
    ]

    static var sourceCoverageText: String {
        let present = assets.filter(\.availableInSourceSet).count
        return "Port source: \(present)/\(assets.count) tracked files"
    }
}
