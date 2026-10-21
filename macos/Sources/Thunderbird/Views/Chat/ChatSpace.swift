/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import SwiftUI
import ThunderbirdCore

struct ChatSpace: View {
  @Environment(ChatStore.self) private var chat
  @State private var addingAccount = false
  @State private var joiningAccount: UUID?
  @State private var showParticipants = true

  var body: some View {
    @Bindable var chat = chat
    Group {
      if chat.accounts.isEmpty {
        VStack(spacing: 16) {
          Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 48))
            .foregroundStyle(.tint)
          Text("Chat")
            .font(.title2.weight(.semibold))
          Text("Connect to IRC, Matrix or XMPP to chat right inside Thunderbird.")
            .foregroundStyle(.secondary)
          Button("Add Chat Account") { addingAccount = true }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        NavigationSplitView {
          List(selection: $chat.selection) {
            ForEach(chat.accounts) { account in
              Section {
                ForEach(chat.conversations[account.id] ?? []) { conversation in
                  let key = ConversationKey(accountID: account.id, conversationID: conversation.id)
                  Label {
                    Text(conversation.title)
                      .lineLimit(1)
                  } icon: {
                    Image(systemName: conversation.isInvitation ? "envelope.open" : conversation.isGroup ? "number" : "person")
                  }
                  .badge(chat.unread[key] ?? 0)
                  .tag(key)
                  .contextMenu {
                    Button("Leave", role: .destructive) { Task { await chat.leave(key) } }
                  }
                }
              } header: {
                ChatAccountHeader(account: account, onJoin: { joiningAccount = account.id })
              }
            }
          }
          .listStyle(.sidebar)
          .safeAreaInset(edge: .bottom) {
            HStack {
              Button {
                addingAccount = true
              } label: {
                Label("Add Account", systemImage: "plus")
              }
              .buttonStyle(.glass)
              Spacer()
            }
            .controlSize(.small)
            .padding(12)
          }
          .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
          if let key = chat.selection, let conversation = chat.conversation(key) {
            ConversationView(key: key, conversation: conversation)
              .inspector(isPresented: $showParticipants) {
                ParticipantsView(conversation: conversation)
                  .inspectorColumnWidth(min: 160, ideal: 200, max: 280)
              }
          } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              joiningAccount = chat.selection?.accountID ?? chat.accounts.first?.id
            } label: {
              Label("Join Chat", systemImage: "plus.bubble")
            }
            .help("Join a channel or room")
          }
          ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showParticipants) {
              Label("Participants", systemImage: "person.2")
            }
            .help("Show participants")
          }
        }
      }
    }
    .navigationTitle("Chat")
    .sheet(isPresented: $addingAccount) {
      ChatAccountSetup()
    }
    .sheet(isPresented: Binding(get: { chat.pendingAddContact }, set: { chat.pendingAddContact = $0 })) {
      AddChatContactSheet()
    }
    .onChange(of: chat.pendingAccountSetup, initial: true) {
      if chat.pendingAccountSetup {
        addingAccount = true
        chat.pendingAccountSetup = false
      }
    }
    .onChange(of: chat.pendingJoin, initial: true) {
      if chat.pendingJoin {
        joiningAccount = chat.selection?.accountID ?? chat.accounts.first?.id
        chat.pendingJoin = false
      }
    }
    .sheet(item: $joiningAccount) { accountID in
      JoinChatSheet(accountID: accountID)
    }
  }
}

private struct ChatAccountHeader: View {
  @Environment(ChatStore.self) private var chat
  let account: ChatAccount
  let onJoin: () -> Void

  var body: some View {
    let status = chat.status[account.id] ?? .offline
    HStack(spacing: 6) {
      Circle()
        .fill(status == .online ? Color.green : status == .connecting ? Color.yellow : Color.secondary)
        .frame(width: 7, height: 7)
        .accessibilityLabel(status.label)
      Text("\(account.chatProtocol.label) · \(account.title)")
        .lineLimit(1)
      Spacer()
      if case .failed(let message) = status {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(message)
      }
    }
    .contextMenu {
      if status == .online || status == .connecting {
        Button("Disconnect") { Task { await chat.disconnect(account.id) } }
        Button("Join Chat…", action: onJoin)
      } else {
        Button("Connect") { Task { await chat.connect(account.id) } }
      }
      Divider()
      Button("Remove Account", role: .destructive) { chat.remove(account.id) }
    }
  }
}

private struct ConversationView: View {
  @Environment(ChatStore.self) private var chat
  let key: ConversationKey
  let conversation: ChatConversation
  @State private var draft = ""
  @FocusState private var composerFocused: Bool

  var body: some View {
    let messages = chat.messages[key] ?? []
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            let showSender = index == 0 || messages[index - 1].sender != message.sender
              || message.date.timeIntervalSince(messages[index - 1].date) > 300
            ChatBubble(message: message, showSender: showSender && conversation.isGroup)
              .id(message.id)
          }
        }
        .padding(16)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: messages.count) {
        if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
      }
    }
    .safeAreaBar(edge: .top) {
      if conversation.isInvitation || conversation.topic?.isEmpty == false {
        HStack {
          if conversation.isInvitation {
            Text("You've been invited to this room.")
            Spacer()
            Button("Join") { Task { await chat.acceptInvitation(key) } }
              .buttonStyle(.glassProminent)
          } else if let topic = conversation.topic {
            Image(systemName: "text.bubble")
            Text(topic)
              .lineLimit(2)
              .textSelection(.enabled)
            Spacer()
          }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.top, 6)
      }
    }
    .safeAreaBar(edge: .bottom) {
      HStack(spacing: 8) {
        TextField("Message \(conversation.title)", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .focused($composerFocused)
          .onSubmit(send)
        Button(action: send) {
          Image(systemName: "arrow.up")
            .fontWeight(.semibold)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Send")
      }
      .padding(.leading, 16)
      .padding(.trailing, 6)
      .padding(.vertical, 6)
      .glassEffect(.regular.interactive(), in: .capsule)
      .padding(12)
    }
    .navigationTitle(conversation.title)
    .navigationSubtitle(chat.account(key.accountID)?.chatProtocol.label ?? "")
    .onAppear { composerFocused = true }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draft = ""
    Task { await chat.send(text, to: key) }
  }
}

private struct ChatBubble: View {
  let message: ChatMessage
  let showSender: Bool

  var body: some View {
    switch message.kind {
    case .system:
      Text(message.text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    default:
      VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
        if showSender && !message.isOutgoing {
          Text(message.sender)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        HStack(alignment: .bottom, spacing: 6) {
          if message.isOutgoing { Spacer(minLength: 60) }
          Text(message.kind == .action ? "\(message.sender) \(message.text)" : message.text)
            .italic(message.kind == .action)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
            .glassEffect(
              message.isOutgoing ? .regular.tint(.accentColor) : message.kind == .notice ? .regular.tint(.orange.opacity(0.3)) : .regular,
              in: .rect(cornerRadius: 16))
          if !message.isOutgoing { Spacer(minLength: 60) }
        }
        Text(message.date.formatted(date: .omitted, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 12)
      }
      .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }
  }
}

private struct ParticipantsView: View {
  let conversation: ChatConversation

  var body: some View {
    List {
      Section("\(conversation.participants.count) participants") {
        ForEach(conversation.participants, id: \.self) { name in
          Label(name, systemImage: "person.crop.circle")
        }
      }
    }
  }
}

private struct JoinChatSheet: View {
  @Environment(ChatStore.self) private var chat
  @Environment(\.dismiss) private var dismiss
  let accountID: UUID
  @State private var name = ""

  var body: some View {
    let account = chat.account(accountID)
    VStack(alignment: .leading, spacing: 14) {
      Text("Join Chat")
        .font(.title3.weight(.semibold))
      TextField(
        account?.chatProtocol == .irc ? "#channel" : account?.chatProtocol == .matrix ? "#room:matrix.org" : "room@conference.example.org",
        text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(join)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Join", action: join)
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(name.isEmpty)
      }
    }
    .padding(22)
    .frame(width: 380)
  }

  private func join() {
    let target = name
    Task { await chat.join(target, accountID: accountID) }
    dismiss()
  }
}

struct ChatAccountSetup: View {
  @Environment(ChatStore.self) private var chat
  @Environment(\.dismiss) private var dismiss
  @State private var chatProtocol = ChatProtocol.matrix
  @State private var username = ""
  @State private var server = ""
  @State private var port = 0
  @State private var useTLS = true
  @State private var password = ""
  @State private var autoJoin = ""
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Picker("Network", selection: $chatProtocol) {
          ForEach(ChatProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        switch chatProtocol {
        case .irc:
          TextField("Nickname", text: $username)
          TextField("Server", text: $server, prompt: Text("irc.libera.chat"))
          TextField("Password (optional, for SASL)", text: $password)
        case .matrix:
          TextField("Matrix ID", text: $username, prompt: Text("@you:matrix.org"))
          SecureField("Password", text: $password)
          TextField("Homeserver (optional)", text: $server, prompt: Text("Discovered automatically"))
        case .xmpp:
          TextField("Jabber ID", text: $username, prompt: Text("you@example.org"))
          SecureField("Password", text: $password)
          TextField("Server (optional)", text: $server)
        }
        Toggle("Use an encrypted connection", isOn: $useTLS)
        TextField("Port (0 for default)", value: $port, format: .number.grouping(.never))
        TextField("Join automatically (comma separated)", text: $autoJoin)
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add Account", action: add)
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(username.isEmpty || (chatProtocol == .irc && server.isEmpty))
      }
      .padding(16)
    }
    .frame(width: 480)
  }

  private func add() {
    var account = ChatAccount(
      chatProtocol: chatProtocol, username: username.trimmingCharacters(in: .whitespaces),
      server: server.trimmingCharacters(in: .whitespaces), port: port, useTLS: useTLS)
    account.autoJoin = autoJoin.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    do {
      try chat.add(account, password: password)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// File › New › Chat Contact…
private struct AddChatContactSheet: View {
  @Environment(ChatStore.self) private var chat
  @Environment(\.dismiss) private var dismiss
  @State private var accountID: UUID?
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add Contact")
        .font(.title3.weight(.semibold))
      Picker("Account", selection: $accountID) {
        ForEach(chat.accounts) { Text("\($0.chatProtocol.label) · \($0.title)").tag(Optional($0.id)) }
      }
      TextField("Username, @user:server or user@server", text: $name)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Add Contact") {
          if let accountID { Task { await chat.addContact(name, accountID: accountID) } }
          dismiss()
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(name.isEmpty || accountID == nil)
      }
    }
    .padding(22)
    .frame(width: 420)
    .onAppear { accountID = accountID ?? chat.accounts.first?.id }
  }
}
