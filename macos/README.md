# Zapdos for macOS (native)

Zapdos is a native SwiftUI rewrite of the Thunderbird desktop client for macOS 26, using Liquid Glass.
It is a standalone Swift package and does not use the Gecko build (`mach`).

## Building

Requires Xcode 26 (Swift 6.2) on macOS 26.

```sh
./build-app.sh          # release build -> build/Zapdos.app
./build-app.sh debug
swift test              # unit tests
```

`build-app.sh` wraps the SwiftPM executable in an app bundle that uses `Support/AppIcon.icns`.
After changing `Support/AppIcon.svg`, regenerate it with
`swift Support/make-icon.swift Support/AppIcon.svg Support/AppIcon.icns`. It also bundles
`librnp.dylib` (OpenPGP) from a local Thunderbird build (`obj-*/dist/bin`) or an installed
Thunderbird. The bundle identifier is
`net.thunderbird.mac`, so it does not clash with the Gecko build of Thunderbird. App data stays
in `~/Library/Application Support/Thunderbird for macOS`, as in builds from before the rename.

Ad-hoc signed builds look like a different app to Keychain after every rebuild, so macOS asks
before releasing saved passwords. To avoid that, sign with a development identity: add a free
Apple Development certificate in Xcode › Settings › Accounts, then build with
`CODESIGN_IDENTITY="Apple Development" ./build-app.sh`.

## Features

The app is organised into spaces, like Thunderbird's Spaces toolbar: Mail, Address Book,
Calendar, Tasks and Chat.

**Mail**
- IMAP (with IDLE push), POP3 (downloads into local storage, with an option to leave mail on the
  server), Local Folders, and NNTP newsgroups with subscription management.
- Password and OAuth2 sign-in (PKCE, loopback redirect, refresh tokens in the Keychain, XOAUTH2
  for IMAP, POP3 and SMTP).
- Account setup looks up server settings the way Thunderbird's account hub does. You can also
  import account settings from an existing Thunderbird profile (prefs.js).
- Multiple identities per account.
- A three-pane window with a Liquid Glass toolbar, quick filter bar (unread, starred,
  attachment, tag), threaded or flat lists, unified folders, and native window tabs for messages.
- Search on the server or locally across a folder, an account or everything, with Saved Search
  folders.
- Folder management: create, rename, delete, empty Trash/Junk, mark as read. Drag messages to
  folders to move them (hold Option to copy), including between accounts.
- Tags (Important, Work, Personal, To Do, Later), stars, archive.
- Message filters, run on new mail or on demand.
- An adaptive junk filter that learns from Junk / Not Junk.
- Notifications for new mail.
- Compose in plain text or rich text (HTML) with a glass format bar and address autocomplete
  from Contacts and Collected Addresses.
- Drafts (with autosave), templates, Send Later (Unsent Messages), and Thunderbird's
  "forgot an attachment?" reminder.
- The reader renders messages in a WKWebView with scripts disabled. Remote content is blocked
  by a Content-Security-Policy until you allow it.
- The reader also offers:
  - View Source, Print and Save As.
  - Convert to Event or Task.
  - Add the sender to the Address Book.
- End-to-end encryption:
  - OpenPGP through RNP (Thunderbird's own engine, loaded at runtime): key generation, import,
    export, and PGP/MIME or inline sign, encrypt, decrypt and verify.
  - S/MIME through the Security framework's CMS, using certificates in your Keychain.

**Address Book.** Uses the Contacts framework, so iCloud, Google, Exchange and CardDAV address
books all appear. It also keeps Thunderbird's Collected Addresses, lists (groups), and vCard
import and export.

**Calendar and Tasks.** Use EventKit, so every calendar and reminder list on the Mac is
available.
- Day, week, multiweek and month views, with drag to reschedule.
- An event editor with repeat rules and alerts.
- Task lists with due dates and priorities.
- A Today Pane in Mail.
- Email invitations get Accept, Maybe and Decline (sent as iMIP replies) and Add to Calendar.

**Chat.** IRC (with SASL), Matrix (login, sync, rooms, invitations) and XMPP (STARTTLS, roster,
group chats), with conversation logs and notifications for mentions and direct messages.

**Settings.** Settings mirrors Thunderbird's preferences and Account Settings.
- General: Start Page, check interval, alerts and sound, mark-as-read delay, opening messages in a
  new or existing window, closing the window on move or delete, display names for known
  contacts, and the downloads folder.
- Composition: default forward mode, autosave interval, a confirmation before sending with the
  keyboard shortcut, attachment reminder keywords, default HTML font, size and colours,
  collected addresses, and a spelling check before sending.
- Privacy & Security: remote content with per-sender and per-domain exceptions, junk handling,
  scam detection and saved passwords.
- Chat: notifications and the automatic Away status.
- Calendar: first day of the week, week numbers, working hours, default event length and
  default reminder.
- Each account has Server Settings (startup and interval checks, push, delete model, expunge
  and empty Trash on exit, how long POP keeps mail on the server), Copies & Folders (Sent, Bcc,
  Archives with yearly or monthly folders, Drafts, Templates), Composition & Addressing (quoting,
  signature placement and file, vCard, Organization, return receipts by default), Junk
  Settings (SpamAssassin headers, purging), Synchronization & Storage (offline copies,
  retention) and Return Receipts (never, always or ask).

## Layout

- `Sources/ThunderbirdCore`: no UI code.
  - Protocols: IMAP, SMTP, POP3, NNTP, IRC, Matrix and XMPP.
  - The `MailBackend` stores (IMAP, POP3, local and NNTP).
  - MIME parsing and composition, OAuth2 and autoconfig.
  - OpenPGP and S/MIME.
  - iCalendar parsing and iMIP replies.
  - Filters, the junk classifier and threading.
- `Sources/Thunderbird`: the SwiftUI app.
  - Stores: `MailStore`, `ContactsStore`, `CalendarStore` and `ChatStore`.
  - Views for each space, compose, settings and account setup.

## Trying it without a real account

```sh
python3 Support/fake-mail-server.py
```

This starts in-memory IMAP (127.0.0.1:2143), SMTP (2025), POP3 (2110) and NNTP (2119) servers
with sample mail and a sample newsgroup. In a debug build, launching with
`TB_DEMO_ACCOUNTS=1` adds IMAP, POP3 and News accounts that point at them;
`TB_DEMO_ACCOUNTS=remove` takes them away again:

```sh
open --env TB_DEMO_ACCOUNTS=1 build/Zapdos.app
```

To run the integration tests against the fake servers, and the OpenPGP tests against a
throwaway keyring:

```sh
TB_FAKE_SERVER=1 TB_OPENPGP_DIR=$(mktemp -d) TB_LIBRNP=../../obj-tb/dist/bin/librnp.dylib swift test
```

## Differences from Thunderbird

- **Add-ons** aren't supported. Thunderbird add-ons are WebExtensions (and, for older ones,
  experiments) that run inside Gecko, and a native app has no runtime to host them.
- **OAuth2** needs your own client registrations (Settings › OAuth). Thunderbird's registered
  client IDs belong to Mozilla, so this app doesn't reuse them.
- **Exchange (EWS/Graph)** and **Matrix end-to-end encryption** aren't implemented yet.
- **Contacts and calendars** come from macOS's own accounts (System Settings › Internet Accounts)
  rather than Thunderbird-specific CardDAV/CalDAV setup.
