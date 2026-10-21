/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/// The HTML editing surface for the composer: a contenteditable document driven through
/// execCommand, the same model Thunderbird's editor uses, plus helpers for the Insert, Format
/// and Table menus that execCommand doesn't cover.
enum EditorScript {
  static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <style>
    html { background: #fff; }
    body { font: 14px -apple-system, Helvetica, Arial, sans-serif; color: #1d1d1f; margin: 14px 18px;
           min-height: calc(100vh - 28px); outline: none; word-wrap: break-word; }
    blockquote[type=cite] { margin: 0 0 0 4px; padding-left: 10px; border-left: 2px solid #3a7bd5; color: #3a7bd5; }
    img { max-width: 100%; }
    table { border-collapse: collapse; }
    td, th { border: 1px solid #a0a0a0; padding: 4px 6px; min-width: 2em; }
    a[name]:not([href])::before { content: "#"; font-size: 0.8em; color: #888; }
    pre { white-space: pre-wrap; }
    .moz-signature { color: #6e6e73; }
    </style></head>
    <body contenteditable="true" spellcheck="true"></body></html>
    """

  static let script = #"""
    (() => {
      const post = (type, payload) => window.webkit.messageHandlers.tb.postMessage(Object.assign({type}, payload || {}));
      document.execCommand('styleWithCSS', false, false);
      document.execCommand('defaultParagraphSeparator', false, 'p');

      const selectionNode = () => {
        const sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return null;
        let node = sel.getRangeAt(0).startContainer;
        return node.nodeType === 3 ? node.parentNode : node;
      };
      const closest = (tag) => { const n = selectionNode(); return n ? n.closest(tag) : null; };

      const state = () => {
        let block = document.queryCommandValue('formatBlock') || 'p';
        post('state', {
          bold: document.queryCommandState('bold'), italic: document.queryCommandState('italic'),
          underline: document.queryCommandState('underline'), strike: document.queryCommandState('strikeThrough'),
          ul: document.queryCommandState('insertUnorderedList'), ol: document.queryCommandState('insertOrderedList'),
          block: block.toLowerCase(), font: (document.queryCommandValue('fontName') || '').replace(/['"]/g, ''),
          inTable: !!closest('td,th'), align: document.queryCommandState('justifyCenter') ? 'center'
            : document.queryCommandState('justifyRight') ? 'right' : document.queryCommandState('justifyFull') ? 'justify' : 'left'
        });
      };
      document.addEventListener('selectionchange', state);
      document.addEventListener('input', () => post('dirty'));

      const wrap = (tag, attrs) => {
        const sel = window.getSelection();
        if (!sel.rangeCount || sel.isCollapsed) return;
        const range = sel.getRangeAt(0);
        const el = document.createElement(tag);
        Object.entries(attrs || {}).forEach(([k, v]) => el.setAttribute(k, v));
        el.appendChild(range.extractContents());
        range.insertNode(el);
        sel.removeAllRanges();
        const r = document.createRange(); r.selectNodeContents(el); sel.addRange(r);
        post('dirty');
      };

      const cellPosition = (cell) => {
        const row = cell.parentElement;
        return { row, table: cell.closest('table'), rowIndex: row.rowIndex, cellIndex: cell.cellIndex };
      };

      window.tb = {
        exec: (cmd, value) => { document.body.focus(); document.execCommand(cmd, false, value ?? null); state(); post('dirty'); },
        html: () => document.body.innerHTML,
        text: () => document.body.innerText,
        setHTML: (html) => { document.body.innerHTML = html; },
        focusStart: () => { document.body.focus(); const r = document.createRange(); r.setStart(document.body, 0);
          r.collapse(true); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); },
        insertHTML: (html) => { document.body.focus(); document.execCommand('insertHTML', false, html); post('dirty'); },
        wrap,
        nonbreaking: () => { const sel = window.getSelection(); if (!sel.rangeCount) return;
          const text = sel.toString().replace(/ /g, ' '); document.execCommand('insertText', false, text); },
        selectedText: () => window.getSelection().toString(),
        removeLinks: () => { document.querySelectorAll('a[href]').forEach(a => {
            const sel = window.getSelection();
            if (sel.isCollapsed || sel.containsNode(a, true)) a.replaceWith(...a.childNodes); }); post('dirty'); },
        removeAnchors: () => { document.querySelectorAll('a[name]:not([href])').forEach(a => a.replaceWith(...a.childNodes)); post('dirty'); },
        pageColors: (text, background, link) => { document.body.style.color = text; document.body.style.backgroundColor = background;
          document.querySelectorAll('a').forEach(a => a.style.color = link); document.body.setAttribute('data-link', link); post('dirty'); },
        listStyle: (type) => { const list = closest('ul,ol'); if (list) { list.style.listStyleType = type; post('dirty'); } },
        definitionList: (tag) => { document.execCommand('insertHTML', false, `<dl><${tag}>${window.getSelection().toString() || '&nbsp;'}</${tag}></dl>`); },
        imageProperties: (alt, width) => { const img = document.querySelector('img.tb-selected') || closest('img');
          if (img) { img.alt = alt; if (width) img.style.width = width; post('dirty'); } },
        breakBelowImages: () => { document.querySelectorAll('img').forEach(img => {
            if (!(img.nextSibling && img.nextSibling.nodeName === 'BR')) img.after(document.createElement('br')); }); post('dirty'); },
        insertTable: (rows, cols, border, width) => {
          let html = `<table border="${border}" style="width:${width}">`;
          for (let r = 0; r < rows; r++) { html += '<tr>'; for (let c = 0; c < cols; c++) html += '<td>&nbsp;</td>'; html += '</tr>'; }
          document.execCommand('insertHTML', false, html + '</table><p><br></p>'); post('dirty');
        },
        tableFromSelection: () => {
          const text = window.getSelection().toString(); if (!text) return;
          const rows = text.split(/\n/).filter(l => l.length).map(l => l.split(/\t|,/));
          const html = '<table border="1">' + rows.map(r => '<tr>' + r.map(c => `<td>${c.trim()}</td>`).join('') + '</tr>').join('') + '</table>';
          document.execCommand('insertHTML', false, html); post('dirty');
        },
        tableOp: (op, arg) => {
          const cell = closest('td,th'); if (!cell) return;
          const { row, table, rowIndex, cellIndex } = cellPosition(cell);
          const cols = row.cells.length;
          switch (op) {
            case 'rowAbove': case 'rowBelow': {
              const r = table.insertRow(op === 'rowAbove' ? rowIndex : rowIndex + 1);
              for (let i = 0; i < cols; i++) r.insertCell().innerHTML = '&nbsp;'; break; }
            case 'colBefore': case 'colAfter':
              [...table.rows].forEach(r => r.insertCell(Math.min(op === 'colBefore' ? cellIndex : cellIndex + 1, r.cells.length)).innerHTML = '&nbsp;'); break;
            case 'cellBefore': case 'cellAfter': row.insertCell(op === 'cellBefore' ? cellIndex : cellIndex + 1).innerHTML = '&nbsp;'; break;
            case 'deleteTable': table.remove(); break;
            case 'deleteRow': table.deleteRow(rowIndex); if (!table.rows.length) table.remove(); break;
            case 'deleteColumn': [...table.rows].forEach(r => { if (r.cells[cellIndex]) r.deleteCell(cellIndex); }); break;
            case 'deleteCell': row.deleteCell(cellIndex); break;
            case 'deleteContents': cell.innerHTML = '&nbsp;'; break;
            case 'join': { const next = row.cells[cellIndex + 1]; if (next) { cell.innerHTML += ' ' + next.innerHTML;
              cell.colSpan = (cell.colSpan || 1) + (next.colSpan || 1); next.remove(); } break; }
            case 'split': if (cell.colSpan > 1) { cell.colSpan -= 1; row.insertCell(cellIndex + 1).innerHTML = '&nbsp;'; } break;
            case 'color': (arg.target === 'table' ? table : cell).style.backgroundColor = arg.color; break;
            case 'properties': table.setAttribute('border', arg.border); table.style.width = arg.width;
              table.setAttribute('cellpadding', arg.padding); break;
            case 'select': { const sel = window.getSelection(); const r = document.createRange();
              const target = arg === 'table' ? table : arg === 'row' ? row : cell;
              if (arg === 'column') { r.setStartBefore(table.rows[0].cells[cellIndex]); r.setEndAfter(table.rows[table.rows.length - 1].cells[cellIndex] || cell); }
              else if (arg === 'all') { r.selectNodeContents(table); } else { r.selectNodeContents(target); }
              sel.removeAllRanges(); sel.addRange(r); break; }
          }
          post('dirty'); state();
        },
        toc: (op) => {
          document.querySelectorAll('.moz-toc').forEach(n => n.remove());
          if (op === 'remove') { post('dirty'); return; }
          const headings = [...document.body.querySelectorAll('h1,h2,h3,h4,h5,h6')];
          if (!headings.length) return;
          let html = '<div class="moz-toc"><p><b>Table of Contents</b></p><ul>';
          headings.forEach((h, i) => { const id = h.id || `tb-toc-${i}`; h.id = id;
            html += `<li style="margin-left:${(parseInt(h.tagName[1]) - 1) * 1.2}em"><a href="#${id}">${h.textContent}</a></li>`; });
          html += '</ul></div>';
          document.body.insertAdjacentHTML('afterbegin', html); post('dirty');
        },
        find: (text, backwards, caseSensitive) => window.find(text, !!caseSensitive, !!backwards, true, false, false, false),
        replace: (text, replacement, caseSensitive) => {
          const sel = window.getSelection();
          const matches = caseSensitive ? sel.toString() === text : sel.toString().toLowerCase() === text.toLowerCase();
          if (matches) document.execCommand('insertText', false, replacement);
          return window.find(text, !!caseSensitive, false, true, false, false, false);
        },
        replaceAll: (text, replacement, caseSensitive) => {
          let count = 0; tb.focusStart();
          while (window.find(text, !!caseSensitive, false, false, false, false, false) && count < 10000) {
            document.execCommand('insertText', false, replacement); count++; }
          post('dirty'); return count;
        }
      };
      state();
      post('ready');
    })();
    """#
}
