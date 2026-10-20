/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI

struct WelcomeView: View {
  let onSetUp: () -> Void

  var body: some View {
    ZStack {
      MeshGradient(
        width: 3, height: 3,
        points: [
          [0, 0], [0.5, 0], [1, 0],
          [0, 0.5], [0.6, 0.45], [1, 0.5],
          [0, 1], [0.5, 1], [1, 1],
        ],
        colors: [
          .indigo, .blue, .cyan,
          .blue, .purple, .teal,
          .cyan, .indigo, .blue,
        ]
      )
      .ignoresSafeArea()

      VStack(spacing: 20) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 112, height: 112)
          .shadow(radius: 12, y: 6)
        VStack(spacing: 6) {
          Text("Welcome to Thunderbird")
            .font(.largeTitle.weight(.bold))
          Text("Free, private email, now native on your Mac.")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        Button(action: onSetUp) {
          Label("Set Up an Email Account", systemImage: "envelope.badge.person.crop")
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
      }
      .padding(48)
      .glassEffect(.regular, in: .rect(cornerRadius: 36))
      .padding(40)
    }
    .frame(minWidth: 720, minHeight: 520)
  }
}
