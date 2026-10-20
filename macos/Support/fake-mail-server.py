#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""A tiny in-memory IMAP (port 2143), SMTP (2025), POP3 (2110) and NNTP (2119) server with
sample mail, for trying the app without a real account. Log in with any username and
password, with connection security set to "None"."""

import asyncio
import email.utils
import re
import time
from email.message import EmailMessage
from email.policy import SMTP

HOST = "127.0.0.1"
IMAP_PORT = 2143
SMTP_PORT = 2025
POP3_PORT = 2110
NNTP_PORT = 2119


def sample(sender, subject, body, *, hours_ago, html=None, seen=False, flagged=False, attachment=None, cc=None):
    msg = EmailMessage(policy=SMTP)
    msg["From"] = sender
    msg["To"] = "Fraser <fraser@example.com>"
    if cc:
        msg["Cc"] = cc
    msg["Subject"] = subject
    msg["Date"] = email.utils.formatdate(time.time() - hours_ago * 3600, localtime=True)
    msg["Message-ID"] = email.utils.make_msgid(domain="example.org")
    msg.set_content(body)
    if html:
        msg.add_alternative(html, subtype="html")
    if attachment:
        name, data, maintype, subtype = attachment
        msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
    flags = set()
    if seen:
        flags.add("\\Seen")
    if flagged:
        flags.add("\\Flagged")
    return {"data": msg.as_bytes(), "flags": flags, "time": time.time() - hours_ago * 3600}


def build_mailboxes():
    inbox = [
        sample(
            "Thunderbird Team <team@thunderbird.example>",
            "Welcome to Thunderbird for macOS",
            "Hi Fraser,\n\nThis build is native SwiftUI with Liquid Glass.\n\nEnjoy!\n\n-- \nThe Thunderbird Team",
            hours_ago=0.2,
            html="<h2 style='color:#0a84ff'>Welcome!</h2><p>This build is native <b>SwiftUI</b> with Liquid Glass.</p>"
            "<p><img src='https://www.thunderbird.net/media/img/thunderbird/logos/logo.png' width=120></p>",
        ),
        sample(
            "Ada Lovelace <ada@analytical.example>",
            "Re: Notes on the engine",
            "That works for me.\n\nOn Monday, you wrote:\n> Can we review the notes on Thursday?\n>> I've attached the latest draft.\n",
            hours_ago=2,
            cc="Charles Babbage <charles@analytical.example>",
        ),
        sample(
            "=?utf-8?q?J=C3=B6rg_M=C3=BCller?= <joerg@example.de>",
            "Quarterly report 📊",
            "Hallo,\n\nanbei der Bericht.\n\nGrüße\nJörg",
            hours_ago=5,
            flagged=True,
            attachment=("Q3 report.pdf", b"%PDF-1.4\n%sample\n", "application", "pdf"),
        ),
        sample(
            "Margate Café <hello@margatecafe.example>",
            "Your table is booked for Saturday",
            "Thanks for booking! We've reserved a table for two at 7pm.",
            hours_ago=26,
            seen=True,
        ),
        sample(
            "GitHub <noreply@github.example>",
            "[fraxalotl/thunderbird-desktop] New branch: liquid-glass",
            "A new branch was pushed.",
            hours_ago=50,
            seen=True,
        ),
        sample(
            "Grace Hopper <grace@navy.example>",
            "Compiler meetup",
            "Shall we meet next week to talk about compilers?",
            hours_ago=24 * 9,
            seen=True,
        ),
    ]
    sent = [
        sample(
            "Fraser <fraser@example.com>",
            "Notes on the engine",
            "Can we review the notes on Thursday?",
            hours_ago=30,
            seen=True,
        )
    ]
    mailboxes = {
        "INBOX": {"attrs": "", "messages": inbox},
        "Drafts": {"attrs": "\\Drafts", "messages": []},
        "Sent": {"attrs": "\\Sent", "messages": sent},
        "Archive": {"attrs": "\\Archive", "messages": []},
        "Junk": {"attrs": "\\Junk", "messages": []},
        "Trash": {"attrs": "\\Trash", "messages": []},
        "Projects": {"attrs": "", "messages": []},
        "Projects/Website": {"attrs": "", "messages": []},
    }
    for box in mailboxes.values():
        box["next_uid"] = 1
        for message in box["messages"]:
            message["uid"] = box["next_uid"]
            box["next_uid"] += 1
    return mailboxes


MAILBOXES = build_mailboxes()
IDLERS = []


def notify_idlers():
    for event in IDLERS:
        event.set()


NEWS = {
    "local.thunderbird.test": [
        sample("Ada <ada@analytical.example>", "Welcome to the newsgroup", "First post!", hours_ago=10, seen=True),
        sample("Grace <grace@navy.example>", "Re: Welcome to the newsgroup", "Glad to be here.", hours_ago=5, seen=True),
    ]
}
for _number, _article in enumerate(NEWS["local.thunderbird.test"], start=1):
    _article["uid"] = _number


def quote(value):
    if value is None:
        return "NIL"
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def address_list(value):
    if not value:
        return "NIL"
    parts = []
    for name, addr in email.utils.getaddresses([value]):
        mailbox, _, host = addr.partition("@")
        parts.append(f"({quote(name or None)} NIL {quote(mailbox)} {quote(host)})")
    return "(" + "".join(parts) + ")"


def envelope(data):
    headers = data.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")
    unfolded = re.sub(r"\r\n[ \t]+", " ", headers)
    fields = {}
    for line in unfolded.split("\r\n"):
        key, _, value = line.partition(":")
        fields.setdefault(key.strip().lower(), value.strip())
    return "({} {} {} {} {} {} {} NIL {} {})".format(
        quote(fields.get("date")),
        quote(fields.get("subject")),
        address_list(fields.get("from")),
        address_list(fields.get("from")),
        address_list(fields.get("from")),
        address_list(fields.get("to")),
        address_list(fields.get("cc")),
        quote(fields.get("in-reply-to")),
        quote(fields.get("message-id")),
    )


def parse_set(text, values):
    result = set()
    top = max(values) if values else 0
    for part in text.split(","):
        if ":" in part:
            a, b = part.split(":")
            a = top if a == "*" else int(a)
            b = top if b == "*" else int(b)
            result.update(v for v in values if min(a, b) <= v <= max(a, b))
        else:
            result.add(top if part == "*" else int(part))
    return result


async def handle_imap(reader, writer):
    selected = None

    def send(text):
        writer.write(text.encode() if isinstance(text, str) else text)

    send("* OK [CAPABILITY IMAP4rev1 MOVE UIDPLUS] Fake IMAP ready\r\n")
    while True:
        raw = await reader.readline()
        if not raw:
            break
        line = raw.rstrip(b"\r\n")
        tag, _, rest = line.decode("utf-8", "replace").partition(" ")
        command, _, args = rest.partition(" ")
        command = command.upper()
        if command == "UID":
            sub, _, args = args.partition(" ")
            command = "UID " + sub.upper()
        box = MAILBOXES.get(selected) if selected else None

        if command == "CAPABILITY":
            send("* CAPABILITY IMAP4rev1 MOVE UIDPLUS IDLE\r\n")
        elif command == "IDLE":
            event = asyncio.Event()
            IDLERS.append(event)
            send("+ idling\r\n")
            await writer.drain()
            done = asyncio.ensure_future(reader.readline())
            waiter = asyncio.ensure_future(event.wait())
            finished, _ = await asyncio.wait({done, waiter}, return_when=asyncio.FIRST_COMPLETED)
            IDLERS.remove(event)
            if waiter in finished:
                send(f"* {len(MAILBOXES['INBOX']['messages'])} EXISTS\r\n")
                await writer.drain()
                await done
            else:
                waiter.cancel()
        elif command in ("CREATE", "SUBSCRIBE", "DELETE", "RENAME", "CLOSE"):
            names = re.findall(r'"((?:[^"\\]|\\.)*)"', args)
            if command == "CREATE" and names[0] not in MAILBOXES:
                MAILBOXES[names[0]] = {"attrs": "", "messages": [], "next_uid": 1}
            elif command == "DELETE":
                MAILBOXES.pop(names[0], None)
            elif command == "RENAME":
                MAILBOXES[names[1]] = MAILBOXES.pop(names[0])
            if command == "CLOSE":
                selected = None
        elif command in ("UID SEARCH", "SEARCH"):
            needles = [n.lower() for n in re.findall(r'"((?:[^"\\]|\\.)*)"', args)]
            literal = re.search(r"\{(\d+)\+?\}$", args)
            if literal:
                send("+ go\r\n")
                await writer.drain()
                needles.append((await reader.readexactly(int(literal.group(1)))).decode().lower())
                await reader.readline()
            text = args
            hits = []
            for message in box["messages"]:
                raw = message["data"].decode("utf-8", "replace").lower()
                if "unseen" in text.lower() and "\\Seen" in message["flags"]:
                    continue
                if all(n in raw for n in needles if n not in ("message-id",)):
                    hits.append(str(message["uid"]))
            send(f"* SEARCH {' '.join(hits)}\r\n")
        elif command == "LOGIN":
            pass
        elif command == "LIST":
            for name, info in MAILBOXES.items():
                send(f'* LIST ({info["attrs"]}) "/" {quote(name)}\r\n')
        elif command == "STATUS":
            name = re.match(r'"((?:[^"\\]|\\.)*)"', args).group(1)
            msgs = MAILBOXES[name]["messages"]
            unseen = sum(1 for m in msgs if "\\Seen" not in m["flags"])
            send(f"* STATUS {quote(name)} (MESSAGES {len(msgs)} UNSEEN {unseen})\r\n")
        elif command in ("SELECT", "EXAMINE"):
            selected = re.match(r'"((?:[^"\\]|\\.)*)"', args).group(1)
            box = MAILBOXES[selected]
            box["messages"].sort(key=lambda m: m["uid"])
            send(f"* {len(box['messages'])} EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n* OK [UIDNEXT {box['next_uid']}] ok\r\n")
        elif command in ("FETCH", "UID FETCH"):
            set_text, _, items = args.partition(" ")
            messages = box["messages"]
            if command == "FETCH":
                wanted = parse_set(set_text, list(range(1, len(messages) + 1)))
                targets = [(i + 1, m) for i, m in enumerate(messages) if i + 1 in wanted]
            else:
                wanted = parse_set(set_text, [m["uid"] for m in messages])
                targets = [(i + 1, m) for i, m in enumerate(messages) if m["uid"] in wanted]
            items = items.upper()
            for seq, message in targets:
                parts = [f"UID {message['uid']}", f"FLAGS ({' '.join(sorted(message['flags']))})"]
                payload = b""
                if "ENVELOPE" in items:
                    stamp = time.strftime("%d-%b-%Y %H:%M:%S +0000", time.gmtime(message["time"]))
                    parts.append(f'INTERNALDATE "{stamp}"')
                    parts.append(f"RFC822.SIZE {len(message['data'])}")
                    parts.append("ENVELOPE " + envelope(message["data"]))
                if "HEADER.FIELDS" in items:
                    match = re.search(rb"(?im)^content-type:.*(?:\r\n[ \t].*)*", message["data"])
                    header = (match.group(0) if match else b"") + b"\r\n\r\n"
                    send(f"* {seq} FETCH ({' '.join(parts)} BODY[HEADER.FIELDS (CONTENT-TYPE)] {{{len(header)}}}\r\n")
                    send(header + b")\r\n")
                    continue
                if "BODY.PEEK[]" in items or "BODY[]" in items:
                    payload = message["data"]
                    send(f"* {seq} FETCH ({' '.join(parts)} BODY[] {{{len(payload)}}}\r\n")
                    send(payload + b")\r\n")
                    continue
                send(f"* {seq} FETCH ({' '.join(parts)})\r\n")
        elif command == "UID STORE":
            set_text, op, flags = args.split(" ", 2)
            wanted = parse_set(set_text, [m["uid"] for m in box["messages"]])
            flag_set = set(flags.strip("()").split())
            for message in box["messages"]:
                if message["uid"] in wanted:
                    if op.startswith("+"):
                        message["flags"] |= flag_set
                    else:
                        message["flags"] -= flag_set
        elif command in ("UID MOVE", "UID COPY"):
            set_text, _, dest = args.partition(" ")
            dest = dest.strip('"')
            wanted = parse_set(set_text, [m["uid"] for m in box["messages"]])
            target = MAILBOXES[dest]
            for message in [m for m in box["messages"] if m["uid"] in wanted]:
                copy = dict(message, flags=set(message["flags"]), uid=target["next_uid"])
                target["next_uid"] += 1
                target["messages"].append(copy)
            if command == "UID MOVE":
                box["messages"] = [m for m in box["messages"] if m["uid"] not in wanted]
        elif command == "STORE":
            _, op, flags = args.split(" ", 2)
            for message in box["messages"]:
                if op.startswith("+"):
                    message["flags"] |= set(flags.strip("()").split())
        elif command in ("UID EXPUNGE", "EXPUNGE"):
            box["messages"] = [m for m in box["messages"] if "\\Deleted" not in m["flags"]]
        elif command == "APPEND":
            match = re.match(r'(?:"((?:[^"\\]|\\.)*)"|(\S+))(?: \(([^)]*)\))?(?: "[^"]*")? \{(\d+)(\+?)\}', args)
            quoted, atom, flags, size, plus = match.groups()
            name, flags = quoted or atom, flags or ""
            if not plus:
                send("+ go ahead\r\n")
                await writer.drain()
            data = await reader.readexactly(int(size))
            await reader.readline()
            target = MAILBOXES[name]
            target["messages"].append(
                {"data": data, "flags": set(flags.split()), "time": time.time(), "uid": target["next_uid"]}
            )
            target["next_uid"] += 1
            if name == "INBOX":
                notify_idlers()
        elif command == "LOGOUT":
            send("* BYE\r\n")
            send(f"{tag} OK done\r\n")
            await writer.drain()
            break
        send(f"{tag} OK {command} completed\r\n")
        await writer.drain()
    writer.close()


async def handle_smtp(reader, writer):
    def send(text):
        writer.write((text + "\r\n").encode())

    send("220 fake.smtp ESMTP")
    await writer.drain()
    while True:
        line = await reader.readline()
        if not line:
            break
        text = line.decode().strip()
        upper = text.upper()
        if upper.startswith("EHLO"):
            send("250-fake.smtp")
            send("250 AUTH PLAIN LOGIN")
        elif upper.startswith("AUTH"):
            send("235 ok")
        elif upper.startswith("MAIL") or upper.startswith("RCPT"):
            send("250 ok")
        elif upper == "DATA":
            send("354 go")
            await writer.drain()
            lines = []
            while True:
                data_line = await reader.readline()
                if data_line in (b".\r\n", b".\n"):
                    break
                lines.append(data_line)
            print(f"SMTP received {sum(len(l) for l in lines)} bytes")
            send("250 queued")
        elif upper == "QUIT":
            send("221 bye")
            await writer.drain()
            break
        else:
            send("250 ok")
        await writer.drain()
    writer.close()


async def handle_pop3(reader, writer):
    def send(text):
        writer.write(text.encode() if isinstance(text, str) else text)

    messages = list(MAILBOXES["INBOX"]["messages"])
    deleted = set()
    send("+OK fake POP3 ready\r\n")
    await writer.drain()
    while True:
        line = await reader.readline()
        if not line:
            break
        parts = line.decode().strip().split(" ")
        command = parts[0].upper()
        if command in ("USER", "PASS", "NOOP", "AUTH"):
            send("+OK\r\n")
        elif command == "UIDL":
            send("+OK\r\n")
            for index, message in enumerate(messages, start=1):
                if index not in deleted:
                    send(f"{index} uid-{message['uid']}\r\n")
            send(".\r\n")
        elif command == "RETR":
            data = messages[int(parts[1]) - 1]["data"].replace(b"\r\n.", b"\r\n..")
            send(f"+OK {len(data)} octets\r\n")
            send(data + (b"" if data.endswith(b"\r\n") else b"\r\n") + b".\r\n")
        elif command == "DELE":
            deleted.add(int(parts[1]))
            send("+OK\r\n")
        elif command == "QUIT":
            send("+OK bye\r\n")
            await writer.drain()
            break
        else:
            send("-ERR unknown\r\n")
        await writer.drain()
    writer.close()


async def handle_nntp(reader, writer):
    def send(text):
        writer.write(text.encode() if isinstance(text, str) else text)

    group = None
    send("200 fake NNTP ready\r\n")
    await writer.drain()
    while True:
        line = await reader.readline()
        if not line:
            break
        parts = line.decode().strip().split(" ")
        command = parts[0].upper()
        if command == "MODE":
            send("200 reader\r\n")
        elif command == "LIST":
            send("215 list follows\r\n")
            for name, articles in NEWS.items():
                send(f"{name} {len(articles)} 1 y\r\n")
            send(".\r\n")
        elif command == "GROUP":
            group = parts[1]
            articles = NEWS.get(group, [])
            send(f"211 {len(articles)} 1 {len(articles)} {group}\r\n")
        elif command in ("OVER", "XOVER"):
            low, _, high = parts[1].partition("-")
            send("224 overview\r\n")
            for article in NEWS[group]:
                if int(low) <= article["uid"] <= int(high or low):
                    headers = article["data"].split(b"\r\n\r\n", 1)[0].decode()
                    fields = dict(
                        (k.strip().lower(), v.strip())
                        for k, _, v in (h.partition(":") for h in re.sub(r"\r\n[ \t]+", " ", headers).split("\r\n"))
                    )
                    send(
                        f"{article['uid']}\t{fields.get('subject', '')}\t{fields.get('from', '')}\t{fields.get('date', '')}\t"
                        f"{fields.get('message-id', '')}\t{fields.get('references', '')}\t{len(article['data'])}\t1\r\n"
                    )
            send(".\r\n")
        elif command == "ARTICLE":
            article = NEWS[group][int(parts[1]) - 1]
            send(f"220 {parts[1]} article\r\n")
            send(article["data"] + b".\r\n")
        elif command == "POST":
            send("340 send article\r\n")
            await writer.drain()
            lines = []
            while True:
                data_line = await reader.readline()
                if data_line in (b".\r\n", b".\n"):
                    break
                lines.append(data_line[1:] if data_line.startswith(b"..") else data_line)
            data = b"".join(lines)
            target = re.search(rb"(?im)^newsgroups:\s*([^\r\n,]+)", data)
            name = target.group(1).decode().strip() if target else "local.thunderbird.test"
            NEWS.setdefault(name, []).append({"data": data, "flags": set(), "time": time.time(), "uid": len(NEWS.get(name, [])) + 1})
            send("240 posted\r\n")
        elif command == "QUIT":
            send("205 bye\r\n")
            await writer.drain()
            break
        else:
            send("500 unknown\r\n")
        await writer.drain()
    writer.close()


async def main():
    imap = await asyncio.start_server(handle_imap, HOST, IMAP_PORT)
    smtp = await asyncio.start_server(handle_smtp, HOST, SMTP_PORT)
    pop3 = await asyncio.start_server(handle_pop3, HOST, POP3_PORT)
    nntp = await asyncio.start_server(handle_nntp, HOST, NNTP_PORT)
    print(f"IMAP {IMAP_PORT}, SMTP {SMTP_PORT}, POP3 {POP3_PORT}, NNTP {NNTP_PORT} on {HOST}")
    async with imap, smtp, pop3, nntp:
        await asyncio.gather(imap.serve_forever(), smtp.serve_forever(), pop3.serve_forever(), nntp.serve_forever())


if __name__ == "__main__":
    asyncio.run(main())
