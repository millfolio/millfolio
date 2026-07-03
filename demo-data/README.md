# demo-data — synthetic personal-finance vault for millfolio's onboarding

A reproducible generator for a realistic **fake** finance vault: three
credit-card / bank CSV exports plus two PDF statements, packaged as
`demo-vault.zip` — the "Download demo data" option in first-run onboarding, so a
new user has something to query immediately.

Everything is synthetic (fixed seed). No real people, accounts, or card numbers.

```
demo-data/
  generate.py       # the deterministic generator (reportlab for the PDFs)
  verify_demo.mojo  # harness: runs millfolio's REAL extractor over the output
  manifest.json     # the 5 generated files, byte sizes, sha256, txn counts
  out/              # generated files (CSVs committed as samples; PDFs git-ignored)
```

## Regenerate

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install reportlab
python3 generate.py --out ./out                       # base date 2026-07-03, seed 42
python3 generate.py --out ./out --base-date 2026-07-03 --seed 42   # explicit
```

Output is deterministic — same `--base-date` + `--seed` ⇒ byte-identical files
(PDFs use reportlab `invariant=1`, so no embedded timestamps). Dates are
parameterised off `--base-date`: the most recent transaction lands on it and the
data runs ~183 days (≈6 months) back, so "last 3 months" always has data. Re-run
with a fresh date later as the data ages.

## Build the zip

```bash
cp out/*.csv out/*.pdf /tmp/demo-vault/ && (cd /tmp && zip -X -r demo-vault.zip demo-vault)
```

The zip holds the 5 files under a top-level `demo-vault/` folder; unzip and point
`mill index <dir>` at it. The zip itself is **not** committed — host it as the
release asset the onboarding flow downloads.

## The dataset

~444 transactions, ~2026-01-01 → 2026-07-03, across 25 merchants and 5 accounts:
groceries, dining/coffee, gas, shopping, subscriptions, utilities, transport,
travel, rent, a recurring paycheck (income), and a few refunds/credits. Recurring
bills recur monthly; discretionary spend varies. Built so
"spending by merchant, last 3 months" yields a clear top-merchants distribution
with a long tail, and "spending by month" / "how much on groceries" /
"biggest transaction" all answer richly.

| file | account | txns |
|------|---------|------|
| `apple_card_2026.csv` | Apple Card | 205 |
| `chase_credit_2026.csv` | Chase credit card | 146 |
| `citi_2026.csv` | Citi credit card | 64 |
| `chase_checking_2026-06.pdf` | Chase checking statement (June) | 12 |
| `bofa_visa_2026-06.pdf` | Bank of America Visa statement (June) | 17 |

## Formats — matched to millfolio's extractor

The generator targets the exact shapes
`vault/core/src/vault/extract/transactions.mojo` recognises (studied against
`csv_transactions` for CSVs and `extract_transactions` for PDFs). Each account
uses a mostly-disjoint merchant set so no `(date, desc, amount)` fingerprint
collides across files (the extractor's cross-file dedup keys on that).

### CSV exports (`csv_transactions`)

Column detection is by header-name substring; direction from a `Type` column, a
signed amount, or a debit/credit pair. The three header lines:

- **Apple Card** — `Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD)`
  Date `M/D/YYYY`; `Type` = `Purchase`/`Payment`; purchases positive, payments
  negative. (Direction resolved from `Type`.)
- **Chase** — `Transaction Date,Post Date,Description,Category,Type,Amount,Memo`
  Date `M/D/YYYY`; `Type` = `Sale`/`Payment`/`Return`; sales negative,
  payments/returns positive.
- **Citi** — `Status,Date,Description,Debit,Credit`
  Date `M/D/YYYY`; separate `Debit` / `Credit` columns (the other blank) — this
  exercises the debit/credit-pair path.

### PDF statements (`extract_transactions` over layout-preserved text)

PDFs are unstructured — the extractor persists a statement's rows **only when
they reconcile against the statement's own arithmetic**. Both PDFs are built to
close exactly, and both need column-aligned text (they set reportlab
`pageCompression=0` so `pdftotext.mojo`'s layout mode keeps each row on one line;
compressed streams extracted as empty text).

- **`chase_checking_*.pdf` → running-balance recurrence.** Every row is
  `M/D  description  amount  running-balance`, anchored by a printed
  `Beginning Balance`. `balance[i] == balance[i-1] ± amount[i]` closes across all
  rows, and the direction of each (deposit = credit, withdrawal = debit) falls
  out of the arithmetic — so amounts print as plain magnitudes (no parens/signs,
  which would leave residue in the description).
- **`bofa_visa_*.pdf` → sum-vs-printed-total.** Sectioned into
  `Payments and Other Credits` (credit) and `Purchases and Adjustments` (debit);
  each section's rows sum **exactly** to a printed control total
  (`Total Payments and Other Credits`, `Total Purchases`), which is how the
  extractor assigns direction and trusts the set.

The statement **year** (2026) lives only in the header/period line (`June 1,
2026 - June 30, 2026`), not on the `M/D` rows — `statement_year` recovers it.

## Verify (run the REAL extractor)

`verify_demo.mojo` drives `csv_transactions` / `extract_transactions` over the
generated files and prints per-file counts + sample rows. From the `vault/`
submodule dir (needs the sibling lib repos on the `-I` path, same as the indexer;
build the FFI shims first with `pixi run ffi` for the PDF zlib path):

```bash
cd vault
pixi run -- mojo run -I core/src -I ../flare -I ../json -I ../lancedb.mojo/src \
  -I ../pdftotext.mojo/src -I ../zlib.mojo/src -I ../csv.mojo/src -I ../docx.mojo/src \
  ../demo-data/verify_demo.mojo ../demo-data/out
```

Expected: 205 / 146 / 64 CSV transactions, and both PDFs `reconciled=True`
(`balance-recurrence` → 12, `sum-vs-total` → 17), `year=2026`. All 444 extract.
