# Incident: file-parser Print returned 500 — pdfium's U+FFFE line-break hyphen

## Date
2026-10-19

## Time lost
~1h from report to fix deployed. Latent since 2026-07-20 (`sha-ef055b2`).

## Status
Resolved

## Context
- **System / component:** `file-parser` Deployment, `file-parser` namespace,
  `/print` endpoint.
- **Scope:** printing only. `/parse` kept returning workbooks, the pod stayed
  Running/Ready with 0 restarts, and nothing alerted.
- **State before:** pdfium had been the default extraction engine since
  ADR 013's second step (`sha-ef055b2`), three months earlier.

## Symptoms
- Parse a report → the xlsx downloads fine → Print → 500.
- Every Print of the same report failed (3 in the pod log), each with the same
  error at the same column. Other reports printed fine.
  ```text
  File "/app/web/app.py", line 214, in _incidents_only
    wb = load_workbook(src)
  xml.etree.ElementTree.ParseError: not well-formed (invalid token): line 1, column 91070
  ```

## Investigation
- The workbook failing to load had passed the `/print` HMAC check, so it was
  byte-for-byte what `/parse` produced. Something in `write_xlsx` was writing
  XML that openpyxl itself couldn't read back.
- openpyxl rejects illegal characters on cell assignment
  (`IllegalCharacterError`), which would have failed `/parse`, not `/print`.
  But its regex only covers C0 controls. A scratch test confirmed that
  `U+FFFE` / `U+FFFF` get through on write and break on read with exactly this
  error.
- `template.pdf` has no such characters on either engine, so the bundled
  self-test couldn't catch it.
- A generated PDF with a hyphenated line break ("Mem-" / "ber") reproduced it.
  pdfplumber returns `-`; pypdfium2 returns `'￾'` for that hyphen.
  PDFium uses U+FFFE internally to mark a hyphen that splits a word across lines.
- Side finding: the deployed tag `sha-ef055b2` wasn't in Gitea or local
  history. It was the pre-rebase hash of "make pdfium the default extraction
  engine" (now `8c72142`); GitHub built it before the history was rewritten.

## Root cause
A report with a word hyphenated across a line break inside a cell. The pdfium
engine extracted that hyphen as U+FFFE. openpyxl wrote it into the sheet XML
unchecked (it isn't in openpyxl's illegal-character set), producing an xlsx
that isn't well-formed XML. `/parse` never re-reads its output, so it looked
fine. `/print` re-opens the workbook to keep only the Incidents sheet, and
failed. Data-dependent, which is why it stayed hidden for three months.

## Fix
file-parser `a60408b`, deployed as `sha-a60408b` (homelab `d565dd3`):
- `_pdfium_page_view`: map `'￾'` back to `-`, so the output matches pdfplumber.
- `write_xlsx`: run every row/skipped value through `_xml_safe()` first, which
  strips everything XML 1.0 forbids (C0 controls except tab/LF/CR, lone
  surrogates, U+FFFE/U+FFFF). One choke point covers cells, divider labels
  and hover comments.

Quick mitigation if this kind of thing recurs: set `PARSER_ENGINE: pdfplumber`
in `file-parser-config` and restart.

## Verification
```bash
# self-test, both engines
./parse_incidents.py --self-test            # RESULT: PASS
# U+FFFE/U+FFFF injected into every field + comments: write_xlsx -> load_workbook OK
# hyphenated test PDF: pdfium now yields ['Mem-', 'ber'], same as pdfplumber
ssh control-node 'kubectl -n file-parser exec deploy/file-parser -- python -c \
  "import sys; sys.path.insert(0,\"/app\"); import parse_incidents as p; print(repr(p._xml_safe(\"Mem￾ber\")))"'
# 'Member'
```
Real-world check: Print on the report that failed now works (confirmed by Henry).

## Prevention
- The writer no longer trusts extracted text. Any engine, any odd character:
  the workbook stays loadable.
- `--compare-engines` (ADR 013) compares fields between engines. It only helps
  if it's run on a report that has the divergence; it wasn't, and the template
  doesn't have one. Run it on a few real reports before changing engines.
- Gap, not closed: a 500 on `/print` raised no alert. The user found it.
  Alerting on file-parser 5xx (Traefik metrics) would have caught it.

## Related
- ADR: docs/adr/013-file-parser-pdfium-engine.md
- Other lessons: docs/lessons/k8s/file-parser-oom-large-pdf.md
