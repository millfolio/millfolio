"""Ad-hoc verification harness for the demo-data vault (NOT shipped).

Runs millfolio's REAL extractor over the generated CSV/PDF files and prints,
per file, how many transactions came out (and, for PDFs, whether they
reconciled + the detected statement year) plus a few sample rows.

Build+run from the vault dir with the same -I set the indexer uses:
    pixi run -- mojo run core/verify_demo.mojo <demo-out-dir> \
        -I core/src -I ../flare -I ../json -I ../lancedb.mojo/src \
        -I ../pdftotext.mojo/src -I ../zlib.mojo/src -I ../csv.mojo/src -I ../docx.mojo/src
"""

from std.sys import argv
from vault.extract import extract_transactions
from vault.extract.transactions import csv_transactions, statement_year
from vault.index.readers import csv_rows, pdf_text_layout


def _ends_with(s: String, suf: String) -> Bool:
    return s.byte_length() >= suf.byte_length() and s.endswith(suf)


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: verify_demo <demo-out-dir>")
        return
    var d = String(args[1])

    # The generated file names (kept in sync with generate.py).
    var csvs = List[String]()
    csvs.append(String("apple_card_2026.csv"))
    csvs.append(String("chase_credit_2026.csv"))
    csvs.append(String("citi_2026.csv"))

    var pdfs = List[String]()
    pdfs.append(String("chase_checking_2026-06.pdf"))
    pdfs.append(String("bofa_visa_2026-06.pdf"))

    var grand = 0

    for i in range(len(csvs)):
        var path = d + "/" + csvs[i]
        var rows = csv_rows(path)
        var txns = csv_transactions(rows)
        print("")
        print(
            "CSV  "
            + csvs[i]
            + "  ("
            + String(len(rows))
            + " rows) -> "
            + String(len(txns))
            + " transactions"
        )
        grand += len(txns)
        var lim = 3 if len(txns) >= 3 else len(txns)
        for k in range(lim):
            ref t = txns[k]
            print(
                "    "
                + t.date
                + "/"
                + String(t.year)
                + "  "
                + t.direction
                + "  "
                + String(t.amount)
                + "  "
                + t.desc
            )

    for i in range(len(pdfs)):
        var path = d + "/" + pdfs[i]
        var text = pdf_text_layout(path)
        var ext = extract_transactions(text)
        var yr = statement_year(text)
        print("")
        print(
            "PDF  "
            + pdfs[i]
            + "  reconciled="
            + String(ext.reconciled)
            + "  method="
            + ext.method
            + "  year="
            + String(yr)
            + "  -> "
            + String(len(ext.txns))
            + " transactions"
        )
        print("     note: " + ext.note)
        if ext.reconciled:
            grand += len(ext.txns)
        var lim2 = 4 if len(ext.txns) >= 4 else len(ext.txns)
        for k in range(lim2):
            ref t = ext.txns[k]
            print(
                "    "
                + t.date
                + "  "
                + t.direction
                + "  "
                + String(t.amount)
                + "  "
                + t.desc
            )

    print("")
    print("GRAND TOTAL reconciled/extracted transactions: " + String(grand))
