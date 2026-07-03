#!/usr/bin/env python3
"""Generate a realistic *synthetic* personal-finance vault for millfolio's demo.

Deterministic (fixed seed) so re-running produces byte-identical output. Emits a
handful of bank/credit-card CSV exports plus a couple of PDF statements, in the
EXACT formats millfolio's extractor recognises (see README.md for the header
lines and the reconciliation each PDF is built to satisfy).

    python3 generate.py --out ./out            # default base date 2026-07-03
    python3 generate.py --out ./out --base-date 2026-07-03 --seed 42

Requires reportlab for the PDFs:  pip install reportlab

Everything is fake. No real people, accounts, or card numbers.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import random
from dataclasses import dataclass, field

# ─────────────────────────────────────────────────────────────────────────────
# Merchant catalogue.  Each account draws from a MOSTLY-DISJOINT merchant set so
# the same (date, description, amount) never appears in two files — millfolio's
# cross-file dedup keys on that fingerprint, and disjoint sets keep the demo's
# totals clean while still giving a rich spread for "spending by merchant".
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Merchant:
    name: str          # the descriptor written into the statement/export
    category: str
    lo: float          # amount range for a discretionary charge
    hi: float


# amount is drawn uniformly in [lo, hi] and rounded to cents.
APPLE_CARD_MERCHANTS = [
    Merchant("Whole Foods Market", "Groceries", 38, 145),
    Merchant("Trader Joes", "Groceries", 22, 95),
    Merchant("Starbucks", "Dining", 4.25, 8.75),
    Merchant("Blue Bottle Coffee", "Dining", 4.5, 12),
    Merchant("Chipotle", "Dining", 9, 24),
    Merchant("Sweetgreen", "Dining", 12, 19),
    Merchant("Amazon", "Shopping", 12, 128),
    Merchant("Apple Store", "Shopping", 19, 249),
]
# Fixed monthly subscriptions billed to the Apple Card (same amount each month).
APPLE_CARD_SUBS = [
    Merchant("Netflix", "Subscriptions", 15.49, 15.49),
    Merchant("Spotify", "Subscriptions", 11.99, 11.99),
    Merchant("iCloud", "Subscriptions", 2.99, 2.99),
]

CHASE_MERCHANTS = [
    Merchant("Shell", "Gas", 41, 78),
    Merchant("Chevron", "Gas", 38, 72),
    Merchant("Target", "Shopping", 24, 156),
    Merchant("Costco", "Groceries", 68, 244),
    Merchant("Safeway", "Groceries", 31, 121),
    Merchant("Uber Eats", "Dining", 18, 52),
    Merchant("Home Depot", "Shopping", 14, 189),
]

CITI_MERCHANTS = [
    Merchant("Uber", "Transport", 11, 44),
    Merchant("Lyft", "Transport", 9, 39),
    Merchant("United Airlines", "Travel", 118, 642),
    Merchant("Marriott Hotels", "Travel", 149, 389),
    Merchant("Delta Air Lines", "Travel", 96, 521),
    Merchant("Cheesecake Factory", "Dining", 42, 118),
    Merchant("Local Bistro", "Dining", 35, 96),
]

# Credit-card PDF (a Bank of America Visa) — its own merchant set.
BOFA_MERCHANTS = [
    Merchant("CVS Pharmacy", "Health", 8, 64),
    Merchant("Walgreens", "Health", 6, 48),
    Merchant("Petco", "Shopping", 22, 88),
    Merchant("REI", "Shopping", 45, 210),
    Merchant("Olive Garden", "Dining", 28, 74),
    Merchant("Shell", "Gas", 40, 70),  # gas can legitimately recur across cards
    Merchant("AMC Theatres", "Entertainment", 24, 62),
]


def money(x: float) -> float:
    return round(x + 1e-9, 2)


def rnd_amount(rng: random.Random, m: Merchant) -> float:
    if m.lo == m.hi:
        return money(m.lo)
    return money(rng.uniform(m.lo, m.hi))


@dataclass
class Txn:
    date: dt.date
    desc: str
    amount: float          # magnitude, always positive
    direction: str         # "debit" (spend) or "credit" (payment/refund/income)
    category: str = ""


# ─────────────────────────────────────────────────────────────────────────────
# Transaction streams
# ─────────────────────────────────────────────────────────────────────────────


def card_stream(
    rng: random.Random,
    start: dt.date,
    end: dt.date,
    merchants: list[Merchant],
    subs: list[Merchant],
    per_day_prob: float,
    max_per_day: int,
    refund_merchant: str | None,
) -> list[Txn]:
    """A discretionary-spend card stream: random purchases on most days plus fixed
    monthly subscriptions, an occasional refund, and a monthly statement payment."""
    txns: list[Txn] = []
    day = start
    billed_months: set[tuple[int, int]] = set()
    while day <= end:
        # Fixed monthly subscriptions on a stable day-of-month per sub.
        for i, s in enumerate(subs):
            dom = 3 + i * 5
            if day.day == dom:
                txns.append(Txn(day, s.name, rnd_amount(rng, s), "debit", s.category))
        # Discretionary purchases.
        if rng.random() < per_day_prob:
            for _ in range(rng.randint(1, max_per_day)):
                m = rng.choice(merchants)
                txns.append(Txn(day, m.name, rnd_amount(rng, m), "debit", m.category))
        # A monthly statement payment (credit) near the 12th.
        key = (day.year, day.month)
        if day.day == 12 and key not in billed_months:
            billed_months.add(key)
            pay = money(rng.uniform(400, 1400))
            txns.append(Txn(day, "Payment Thank You", pay, "credit", "Payment"))
        day += dt.timedelta(days=1)

    # A couple of refunds sprinkled in.
    if refund_merchant:
        for _ in range(2):
            d = start + dt.timedelta(days=rng.randint(10, (end - start).days - 5))
            txns.append(
                Txn(d, refund_merchant + " Refund", money(rng.uniform(12, 89)),
                    "credit", "Refund")
            )
    txns.sort(key=lambda t: t.date)
    return txns


# ─────────────────────────────────────────────────────────────────────────────
# CSV writers — one per issuer format the extractor detects.
# ─────────────────────────────────────────────────────────────────────────────


def write_apple_card_csv(path: str, txns: list[Txn]) -> int:
    """Apple Card export.
    Header: Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD)
    Date M/D/YYYY; Type Purchase/Payment; purchases positive, payments negative."""
    n = 0
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Transaction Date", "Clearing Date", "Description",
                    "Merchant", "Category", "Type", "Amount (USD)"])
        for t in txns:
            typ = "Payment" if t.direction == "credit" else "Purchase"
            amt = -t.amount if t.direction == "credit" else t.amount
            clr = t.date + dt.timedelta(days=1)
            w.writerow([
                f"{t.date.month}/{t.date.day}/{t.date.year}",
                f"{clr.month}/{clr.day}/{clr.year}",
                t.desc, t.desc, t.category, typ, f"{amt:.2f}",
            ])
            n += 1
    return n


def write_chase_csv(path: str, txns: list[Txn]) -> int:
    """Chase credit-card export.
    Header: Transaction Date,Post Date,Description,Category,Type,Amount,Memo
    Date M/D/YYYY; Type Sale/Payment/Return; sales negative, payments/returns positive."""
    n = 0
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Transaction Date", "Post Date", "Description",
                    "Category", "Type", "Amount", "Memo"])
        for t in txns:
            if t.direction == "credit":
                typ = "Return" if "Refund" in t.desc else "Payment"
                amt = t.amount
            else:
                typ = "Sale"
                amt = -t.amount
            post = t.date + dt.timedelta(days=1)
            w.writerow([
                f"{t.date.month}/{t.date.day}/{t.date.year}",
                f"{post.month}/{post.day}/{post.year}",
                t.desc, t.category, typ, f"{amt:.2f}", "",
            ])
            n += 1
    return n


def write_citi_csv(path: str, txns: list[Txn]) -> int:
    """Citi export.
    Header: Status,Date,Description,Debit,Credit
    Date M/D/YYYY; separate Debit / Credit columns (the other left blank)."""
    n = 0
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Status", "Date", "Description", "Debit", "Credit"])
        for t in txns:
            debit = f"{t.amount:.2f}" if t.direction == "debit" else ""
            credit = f"{t.amount:.2f}" if t.direction == "credit" else ""
            w.writerow(["Cleared", f"{t.date.month}/{t.date.day}/{t.date.year}",
                        t.desc, debit, credit])
            n += 1
    return n


# ─────────────────────────────────────────────────────────────────────────────
# PDF statements — reportlab, positioned text so pdftotext's layout mode keeps
# each row's columns on one line.
# ─────────────────────────────────────────────────────────────────────────────


def _fmt(x: float) -> str:
    return f"{x:,.2f}"


def write_checking_pdf(path: str, month_txns: list[Txn], begin_balance: float,
                       period_label: str, year: int) -> int:
    """A Chase checking statement built to satisfy the RUNNING-BALANCE recurrence:
    every row is `M/D  description  amount  running-balance`, anchored by a printed
    Beginning Balance, so balance[i] == balance[i-1] ± amount[i] closes exactly and
    yields each transaction's direction (deposit = credit, withdrawal = debit)."""
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(path, pagesize=letter, pageCompression=0, invariant=1)
    W, H = letter
    x_date, x_desc, x_amt, x_bal = 54, 96, 430, 545
    y = H - 60

    c.setFont("Helvetica-Bold", 15)
    c.drawString(x_date, y, "Chase Total Checking")
    y -= 20
    c.setFont("Helvetica", 9)
    c.drawString(x_date, y, "Account 000000000482    Statement Period: " + period_label)
    y -= 26
    c.setFont("Helvetica-Bold", 9)
    c.drawString(x_date, y, "TRANSACTION DETAIL")
    y -= 16
    c.setFont("Helvetica", 9)
    c.drawString(x_date, y, "DATE")
    c.drawString(x_desc, y, "DESCRIPTION")
    c.drawRightString(x_amt, y, "AMOUNT")
    c.drawRightString(x_bal, y, "BALANCE")
    y -= 4
    c.line(x_date, y, x_bal, y)
    y -= 14

    running = begin_balance
    c.drawString(x_date, y, "")
    c.drawString(x_desc, y, "Beginning Balance")
    c.drawRightString(x_bal, y, _fmt(running))
    y -= 14

    total_dep = 0.0
    total_wd = 0.0
    for t in month_txns:
        signed = t.amount if t.direction == "credit" else -t.amount
        running = money(running + signed)
        if t.direction == "credit":
            total_dep += t.amount
        else:
            total_wd += t.amount
        c.drawString(x_date, y, f"{t.date.month}/{t.date.day}")
        c.drawString(x_desc, y, t.desc)
        # Both deposits and withdrawals print as plain magnitudes; the running-
        # balance recurrence (balance goes up vs down) is what assigns the sign,
        # so we don't parenthesise (which would leave a "( )" residue in the desc).
        c.drawRightString(x_amt, y, _fmt(t.amount))
        c.drawRightString(x_bal, y, _fmt(running))
        y -= 14
        if y < 90:
            c.showPage()
            y = H - 60
            c.setFont("Helvetica", 9)

    y -= 4
    c.line(x_date, y, x_bal, y)
    y -= 16
    c.drawString(x_desc, y, "Total Deposits and Additions")
    c.drawRightString(x_bal, y, _fmt(total_dep))
    y -= 14
    c.drawString(x_desc, y, "Total Withdrawals and Subtractions")
    c.drawRightString(x_bal, y, _fmt(total_wd))
    y -= 14
    c.setFont("Helvetica-Bold", 9)
    c.drawString(x_desc, y, "Ending Balance")
    c.drawRightString(x_bal, y, _fmt(running))
    c.showPage()
    c.save()
    return len(month_txns)


def write_creditcard_pdf(path: str, purchases: list[Txn], payments: list[Txn],
                         period_label: str, prev_balance: float) -> int:
    """A Bank of America Visa statement built to satisfy the SUM-VS-PRINTED-TOTAL
    reconciliation: sectioned into "Payments and Other Credits" (credit) and
    "Purchases and Adjustments" (debit); each section's rows sum EXACTLY to a
    printed control total, which is how the extractor assigns direction + trusts it."""
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas

    c = canvas.Canvas(path, pagesize=letter, pageCompression=0, invariant=1)
    W, H = letter
    x_date, x_desc, x_amt = 54, 110, 545
    y = H - 60

    c.setFont("Helvetica-Bold", 15)
    c.drawString(x_date, y, "Bank of America  Customized Cash Rewards Visa")
    y -= 20
    c.setFont("Helvetica", 9)
    c.drawString(x_date, y, "Account ending 7043    Statement Period: " + period_label)
    y -= 16
    c.drawString(x_date, y, "Previous Balance: $" + _fmt(prev_balance))
    y -= 26

    def section(title: str, rows: list[Txn], sign: int) -> float:
        nonlocal y
        c.setFont("Helvetica-Bold", 10)
        c.drawString(x_date, y, title)
        y -= 4
        c.line(x_date, y, x_amt, y)
        y -= 14
        c.setFont("Helvetica", 9)
        total = 0.0
        for t in rows:
            total += t.amount
            c.drawString(x_date, y, f"{t.date.month}/{t.date.day}")
            c.drawString(x_desc, y, t.desc)
            # Plain magnitude per row (a leading "-" would leave a trailing "-" in
            # the desc); direction comes from the section header, and the printed
            # section TOTAL below carries the sign for realism.
            c.drawRightString(x_amt, y, f"{t.amount:,.2f}")
            y -= 14
            if y < 90:
                c.showPage()
                y = H - 60
                c.setFont("Helvetica", 9)
        return money(total)

    pay_total = section("Payments and Other Credits", payments, -1)
    y -= 6
    c.setFont("Helvetica-Bold", 9)
    c.drawString(x_desc, y, "Total Payments and Other Credits")
    c.drawRightString(x_amt, y, "-" + _fmt(pay_total))
    y -= 26

    buy_total = section("Purchases and Adjustments", purchases, +1)
    y -= 6
    c.setFont("Helvetica-Bold", 9)
    c.drawString(x_desc, y, "Total Purchases")
    c.drawRightString(x_amt, y, _fmt(buy_total))
    y -= 20
    new_bal = money(prev_balance - pay_total + buy_total)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(x_desc, y, "New Balance")
    c.drawRightString(x_amt, y, "$" + _fmt(new_bal))
    c.showPage()
    c.save()
    return len(purchases) + len(payments)


# ─────────────────────────────────────────────────────────────────────────────
# Checking / credit-card PDF transaction streams (single statement month).
# ─────────────────────────────────────────────────────────────────────────────


def checking_month(rng: random.Random, year: int, month: int) -> list[Txn]:
    """One month of checking activity: two paychecks, rent, utilities, a couple of
    transfers, insurance. Chronological — deposits and withdrawals interleaved."""
    def d(day: int) -> dt.date:
        return dt.date(year, month, day)

    txns = [
        Txn(d(1), "Acme Corp Payroll Direct Deposit", 3187.44, "credit", "Income"),
        Txn(d(3), "Greystar Apartment Homes Rent", 2450.00, "debit", "Rent"),
        Txn(d(5), "PG&E Utility Payment", money(rng.uniform(88, 162)), "debit", "Utilities"),
        Txn(d(7), "Comcast Xfinity Internet", 89.99, "debit", "Utilities"),
        Txn(d(9), "Geico Auto Insurance", 142.50, "debit", "Insurance"),
        Txn(d(11), "Transfer to Savings", 500.00, "debit", "Transfer"),
        Txn(d(14), "Zelle from Jordan Rent Share", 725.00, "credit", "Income"),
        Txn(d(16), "Acme Corp Payroll Direct Deposit", 3187.44, "credit", "Income"),
        Txn(d(18), "State Farm Renters Insurance", 18.00, "debit", "Insurance"),
        Txn(d(22), "ATM Cash Withdrawal", 120.00, "debit", "Cash"),
        Txn(d(25), "City Water and Sewer", money(rng.uniform(44, 78)), "debit", "Utilities"),
        Txn(d(28), "Transfer to Savings", 500.00, "debit", "Transfer"),
    ]
    txns.sort(key=lambda t: t.date)
    return txns


def creditcard_month(rng: random.Random, year: int, month: int) -> tuple[list[Txn], list[Txn]]:
    """One month of Bank of America Visa activity: a set of purchases + one payment."""
    import calendar
    ndays = calendar.monthrange(year, month)[1]
    purchases: list[Txn] = []
    for _ in range(rng.randint(16, 22)):
        m = rng.choice(BOFA_MERCHANTS)
        day = rng.randint(1, ndays)
        purchases.append(
            Txn(dt.date(year, month, day), m.name, rnd_amount(rng, m), "debit", m.category)
        )
    purchases.sort(key=lambda t: t.date)
    payments = [Txn(dt.date(year, month, 15), "Payment - Thank You",
                    money(rng.uniform(600, 1200)), "credit", "Payment")]
    return purchases, payments


# ─────────────────────────────────────────────────────────────────────────────


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="out", help="output directory")
    ap.add_argument("--base-date", default="2026-07-03",
                    help="most-recent transaction date (YYYY-MM-DD)")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    base = dt.date.fromisoformat(args.base_date)
    start = base - dt.timedelta(days=183)  # ~6 months back
    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    manifest: list[tuple[str, int]] = []

    # ── CSV card streams (Jan → base date) ──────────────────────────────────
    apple = card_stream(rng, start, base, APPLE_CARD_MERCHANTS, APPLE_CARD_SUBS,
                        per_day_prob=0.65, max_per_day=2, refund_merchant="Amazon")
    chase = card_stream(rng, start, base, CHASE_MERCHANTS, [],
                        per_day_prob=0.5, max_per_day=2, refund_merchant="Target")
    citi = card_stream(rng, start, base, CITI_MERCHANTS, [],
                       per_day_prob=0.35, max_per_day=1, refund_merchant=None)

    manifest.append(("apple_card_2026.csv",
                     write_apple_card_csv(os.path.join(args.out, "apple_card_2026.csv"), apple)))
    manifest.append(("chase_credit_2026.csv",
                     write_chase_csv(os.path.join(args.out, "chase_credit_2026.csv"), chase)))
    manifest.append(("citi_2026.csv",
                     write_citi_csv(os.path.join(args.out, "citi_2026.csv"), citi)))

    # ── PDF statements (the most-recent complete month before the base date) ─
    stmt_year, stmt_month = base.year, base.month - 1
    if stmt_month == 0:
        stmt_year, stmt_month = base.year - 1, 12
    import calendar
    period = (f"{calendar.month_name[stmt_month]} 1, {stmt_year} - "
              f"{calendar.month_name[stmt_month]} {calendar.monthrange(stmt_year, stmt_month)[1]}, {stmt_year}")

    chk = checking_month(rng, stmt_year, stmt_month)
    manifest.append((
        f"chase_checking_{stmt_year}-{stmt_month:02d}.pdf",
        write_checking_pdf(os.path.join(args.out, f"chase_checking_{stmt_year}-{stmt_month:02d}.pdf"),
                           chk, begin_balance=4210.66, period_label=period, year=stmt_year),
    ))

    buys, pays = creditcard_month(rng, stmt_year, stmt_month)
    manifest.append((
        f"bofa_visa_{stmt_year}-{stmt_month:02d}.pdf",
        write_creditcard_pdf(os.path.join(args.out, f"bofa_visa_{stmt_year}-{stmt_month:02d}.pdf"),
                             buys, pays, period_label=period, prev_balance=1834.20),
    ))

    total = sum(n for _, n in manifest)
    print(f"Generated into {args.out}/ (base date {base}, seed {args.seed}):")
    for name, n in manifest:
        print(f"  {name:36s} {n:4d} transactions")
    print(f"  {'TOTAL':36s} {total:4d} transactions")


if __name__ == "__main__":
    main()
