# Thunderbird for macOS (native)

A native SwiftUI rewrite of the Thunderbird desktop mail client for macOS 26, using Liquid Glass.
It is a standalone Swift package and does not use the Gecko build (`mach`).

## Building

Requires Xcode 26 (Swift 6.2) on macOS 26.

```sh
./build-app.sh          # release build -> build/Thunderbird.app
./build-app.sh debug
swift test              # unit tests
```

`build-app.sh` wraps the SwiftPM executable in an ad-hoc signed app bundle that uses the icon from
`mail/branding/thunderbird`. The bundle identifier is `net.thunderbird.mac`, so it does not clash
with the Gecko build of Thunderbird.

## Layout

- `Sources/ThunderbirdCore`: no UI code.
  - `IMAPClient`, `IMAPParser`: IMAP4rev1 with literals, LITERAL+, AUTHENTICATE PLAIN, LIST-STATUS,
    MOVE, UIDPLUS and APPEND.
  - `SMTPClient`: ESMTP with AUTH PLAIN/LOGIN and dot-stuffing.
  - `Connection`: TLS, STARTTLS (via `URLSessionStreamTask`) and plaintext.
  - `MIMEParser`, `MIMEDecoder`, `MessageBuilder`: parsing incoming messages and building outgoing
    ones (RFC 2045-2047, RFC 2231).
  - `Autoconfig`: looks up server settings the same way Thunderbird's account hub does (the
    provider's autoconfig, then `.well-known`, then the Thunderbird ISPDB, then a guess).
  - `AccountService`: runs one account's operations one at a time and keeps the on-disk cache current.
  - `MailCache`: the cache, under `~/Library/Application Support/Thunderbird for macOS/Cache`.
  - `Keychain`: passwords are stored in the macOS Keychain.
- `Sources/Thunderbird`: the SwiftUI app.
  - The three-pane window (`NavigationSplitView`) has a Liquid Glass toolbar, a quick filter bar,
    a glass message header card, and glass attachment chips and action buttons.
  - The compose window, account setup, and the Settings window (General and Accounts).
  - Messages render in a WKWebView with JavaScript disabled. Remote content is blocked by a
    Content-Security-Policy until the user allows it.

## Trying it without a real account

```sh
python3 Support/fake-mail-server.py
```

This starts an in-memory IMAP server on 127.0.0.1:2143 and an SMTP server on 2025, preloaded with
sample mail. In account setup, choose "Configure manually", set both servers to `127.0.0.1` with
security "None", and use any password. `TB_FAKE_SERVER=1 swift test` runs the integration tests
against it.

## Not yet ported

OAuth2 sign-in (Gmail and Microsoft need app passwords for now), POP3, NNTP, local folders,
filters, threading, full-text search, drafts and templates, HTML composition, OpenPGP/S-MIME,
the address book, calendar, chat and add-ons.
