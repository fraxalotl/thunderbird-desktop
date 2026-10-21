/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

const { MailServices } = ChromeUtils.importESModule(
  "resource:///modules/MailServices.sys.mjs"
);

// Template placeholders look like {{Name}}. Inside the braces, case and
// whitespace (including line breaks from the template's source) are ignored.
const PLACEHOLDER = /\{\{([^{}]+)\}\}/g;
// The hidden preview text, filled in from the reply when sending.
const PREVIEW_KEY = "first line of your reply";
// How much of the first paragraph to use as preview text.
const PREVIEW_LENGTH = 90;

/**
 * Reply with Template: a template opened as a reply to another message, with
 * placeholders in the template filled in. Loaded once per compose window.
 */
export const ReplyWithTemplate = {
  /**
   * First name of the person being replied to, for {{Name}}.
   *
   * @type {string}
   */
  recipientName: "",

  /**
   * Subject of the message being replied to, without "Re:", for {{Subject}}.
   *
   * @type {string}
   */
  originalSubject: "",

  /**
   * Text nodes holding the hidden preview placeholder, with their original
   * text, so the preview can be filled again on every send attempt.
   *
   * @type {{node: Text, text: string}[]}
   */
  previewNodes: [],

  /**
   * Check whether the compose window was opened with "Reply with Template".
   * Templates are always opened through the template code path, which passes
   * along the header given to OpenComposeWindow() as origMsgHdr. For a plain
   * template that is the template itself, for a reply it is the message being
   * replied to.
   *
   * @param {nsIMsgComposeParams} params
   * @returns {boolean}
   */
  isReplyWithTemplate(params) {
    const hdr = params.type == Ci.nsIMsgCompType.Template && params.origMsgHdr;
    return (
      !!hdr?.folder &&
      !(hdr.flags & Ci.nsMsgMessageFlags.Template) &&
      !hdr.folder.isSpecialFolder(Ci.nsMsgFolderFlags.Templates, true)
    );
  },

  /**
   * Turn a template compose into a reply to params.origMsgHdr, keeping the
   * template's body and attachments.
   *
   * @param {nsIMsgComposeParams} params
   */
  setup(params) {
    const hdr = params.origMsgHdr;
    const fields = params.composeFields;

    params.type = Ci.nsIMsgCompType.ReplyWithTemplate;
    // Used for the References header, the Replied flag and Fcc.
    params.originalMsgURI = hdr.folder.getUriForMsg(hdr);

    const recipients = MailServices.headerParser.parseEncodedHeader(
      hdr.getStringProperty("replyTo") || hdr.author
    );
    fields.to = recipients.map(r => r.toString()).join(", ");
    fields.subject = "Re: " + hdr.mime2DecodedSubject;
    // Reply from the identity picked for the original message, not the one
    // that saved the template.
    fields.from = "";

    this.recipientName = getFirstName(recipients[0]?.name ?? "");
    // Templates add their own "Re: " where they want it.
    this.originalSubject = hdr.mime2DecodedSubject;
  },

  /**
   * Fill in {{Name}}, {{Your name}} and {{Subject}}, and remember where the
   * hidden preview placeholder is.
   *
   * @param {Document} doc - The message document.
   * @param {string} yourName - Name of the sending identity.
   */
  fillPlaceholders(doc, yourName) {
    const values = new Map([
      ["name", this.recipientName],
      ["your name", yourName],
      ["subject", this.originalSubject],
    ]);
    this.previewNodes = [];
    for (const node of getTextNodes(doc)) {
      const text = replacePlaceholders(node.data, values);
      if (text != node.data) {
        node.data = text;
      }
      const keys = [...text.matchAll(PLACEHOLDER)].map(([, key]) =>
        normalizeKey(key)
      );
      if (keys.includes(PREVIEW_KEY)) {
        this.previewNodes.push({ node, text });
      }
    }
  },

  /**
   * Fill the hidden preview placeholder with the start of the reply. This is
   * redone on every send attempt, so edits made after a cancelled send are
   * picked up. If no paragraph was written yet, the placeholder is put back.
   *
   * @param {Document} doc - The message document.
   */
  fillPreview(doc) {
    const values = new Map([[PREVIEW_KEY, getFirstLine(doc)]]);
    for (const { node, text } of this.previewNodes) {
      if (node.isConnected) {
        node.data = replacePlaceholders(text, values);
      }
    }
  },

  /**
   * Get the placeholders left in the subject and message body.
   *
   * @param {Document} doc - The message document.
   * @param {string} subject - Subject of the reply.
   * @returns {string[]} The unique placeholders, as shown in the message.
   */
  getUnfilledPlaceholders(doc, subject) {
    const found = new Set();
    for (const text of [subject, ...getTextNodes(doc).map(n => n.data)]) {
      for (const [match] of text.matchAll(PLACEHOLDER)) {
        found.add(match.replace(/\s+/g, " "));
      }
    }
    return [...found];
  },
};

/**
 * Get the first name from a display name, e.g. "Ben" from "Ben Hoenes" or
 * "Hoenes, Ben".
 *
 * @param {string} displayName
 * @returns {string} The first name, or an empty string if there is none.
 */
function getFirstName(displayName) {
  if (displayName.includes("@")) {
    // Some senders use their address as the display name.
    return "";
  }
  if (displayName.includes(",")) {
    displayName = displayName.slice(displayName.indexOf(",") + 1);
  }
  return displayName
    .trim()
    .split(/\s+/)[0]
    .replace(/^["']+|["']+$/g, "");
}

/**
 * @param {string} key - The text between the braces of a placeholder.
 * @returns {string} The key, normalized for lookups.
 */
function normalizeKey(key) {
  return key.trim().replace(/\s+/g, " ").toLowerCase();
}

/**
 * Replace the placeholders we have a value for. Others are left as they are.
 *
 * @param {string} text
 * @param {Map<string, string>} values - Values keyed by normalized key.
 * @returns {string}
 */
function replacePlaceholders(text, values) {
  return text.replace(
    PLACEHOLDER,
    (match, key) => values.get(normalizeKey(key)) || match
  );
}

/**
 * Get all text nodes of the message document that may hold placeholders,
 * including the <title>.
 *
 * @param {Document} doc
 * @returns {Text[]}
 */
function getTextNodes(doc) {
  const walker = doc.createTreeWalker(
    doc.documentElement,
    doc.defaultView.NodeFilter.SHOW_TEXT
  );
  const nodes = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!["STYLE", "SCRIPT"].includes(node.parentNode.nodeName)) {
      nodes.push(node);
    }
  }
  return nodes;
}

/**
 * Find the first paragraph written in the reply, to use as preview text.
 * Short lines ending in a comma, like "Hi Ben,", are skipped as greetings,
 * as are hidden paragraphs and those still holding a placeholder.
 *
 * @param {Document} doc
 * @returns {string} The preview text, or an empty string if none was found.
 */
function getFirstLine(doc) {
  for (const p of doc.body.querySelectorAll("p")) {
    const text = p.textContent.replace(/\s+/g, " ").trim();
    if (
      !text ||
      /\{\{[^{}]+\}\}/.test(text) ||
      (text.length <= 40 && text.endsWith(",")) ||
      !p.checkVisibility()
    ) {
      continue;
    }
    if (text.length <= PREVIEW_LENGTH) {
      return text;
    }
    const cut = text.slice(0, PREVIEW_LENGTH);
    const lastSpace = cut.lastIndexOf(" ");
    return (lastSpace > 0 ? cut.slice(0, lastSpace) : cut).trimEnd() + "…";
  }
  return "";
}
