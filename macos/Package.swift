// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
  name: "Thunderbird",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "Thunderbird", targets: ["Thunderbird"]),
    .library(name: "ThunderbirdCore", targets: ["ThunderbirdCore"]),
  ],
  targets: [
    .target(name: "ThunderbirdCore"),
    .executableTarget(
      name: "Thunderbird",
      dependencies: ["ThunderbirdCore"]
    ),
    .testTarget(
      name: "ThunderbirdCoreTests",
      dependencies: ["ThunderbirdCore"]
    ),
  ]
)
