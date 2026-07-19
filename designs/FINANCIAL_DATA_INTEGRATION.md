# Financial data integration — automatic bank-transaction import

**Status:** research + recommendation (2026-07-19). No code yet.
**Question:** how does millfolio move past *manual CSV download* to *automatic*
bank-transaction import **without betraying the core promise — "your financial
data never leaves your Mac"?**

The whole decision turns on one fact: **every mainstream "connect your bank"
product is a cloud aggregator.** The user's bank credentials and full transaction
history flow *through a third party's servers*, where they are retained, analyzed,
and (for some) monetized. That is the exact thing millfolio exists not to do. So
the options split cleanly into **aggregator-mediated** (off-device, reject or
heavily gate) and **direct bank↔app** (on-device, the only true fits).

---

## The five options at a glance

| Option | Aggregator in path? | On-device? | Indie-accessible today | Coverage | Integration effort | Verdict |
|---|---|---|---|---|---|---|
| **Plaid** | Yes (mandatory) | ❌ | Yes (approval + paid) | ★★★ >12k institutions | High — webview Link + server token exchange | **Reject** |
| **Teller** | Yes (mandatory) | ❌ | Yes (indie-ish, mTLS) | ★★ US, narrower | Medium | **Reject** |
| **SimpleFIN Bridge** | Yes (hosted, read-only) | ⚠️ partial (self-host possible) | **Yes — no contract, ~$1.50/mo, token** | ★★ decent, flaky | **Low — plain JSON GET** | **Least-bad aggregator**, opt-in only |
| **OFX Direct Connect** | **No — bank↔app only** | ✅ | Partial (per-bank enroll, some fees) | ★ collapsing | Medium — OFX client | **Best privacy, dying coverage** |
| **CFPB-1033 / FDX API** | **No (aggregator optional)** | ✅ | **Yes** once live (fee-free, no-credential, revocable) | ★★★ eventually all large/mid banks | Medium-High + regulatory risk | **Strategic bet** |

---

## Why the aggregators are a non-starter (as the default)

- **Plaid** — flow is explicitly *your app → Plaid → your bank → your app*. Plaid
  is the collector-of-record: "**We collect the data**… and securely share it with
  the app," retains it (Plaid Portal / "delete my data"), and runs a suite of
  *derived* products on it (Enrich, Signal, Income, Underwriting, LendScore,
  Monitor, Identity). Requires a cloud backend (the `client_secret` can't ship in
  a native app) and Plaid-branded consent. **Directly contradicts the promise.**
- **Teller** — same mandatory-middleman shape. Collects username/password *or*
  security token, OTP, **security-question answers**, and the full transaction
  history (amount, date, payee, location, description) **from all accounts behind
  one login**. To its credit it says **"we do not sell"** — but it still shares
  with the developer, vendors, analytics (Google Analytics, tracking pixels, does
  **not** honor Do-Not-Track), and on **M&A/bankruptcy**, and it *analyzes* the
  data to build new products. Better than Plaid, still off-device.
- **SimpleFIN Bridge** — the least-bad aggregator: **read-only** (can't move
  money), **token-based** (no OAuth, no per-request bank creds in our app), **no
  approval / no contract**, ~**$1.50/mo paid by the user**, and integration is a
  **plain HTTPS GET returning JSON** — trivial for a native Mac app, no SDK, no
  webview, no backend. The catch: the hosted Bridge still logs into the bank and
  **caches transactions on its server** (uses MX-style back-ends), so it is *not*
  on-device unless self-hosted, and coverage is narrower/flakier than Plaid. If
  millfolio ever ships an aggregator path, this is the one — as an **explicitly
  disclosed opt-in, never the default.**

## The direct paths (the only true fits)

- **OFX Direct Connect** — the app talks **straight to the bank's OFX server**
  over HTTPS with **bank-issued credentials** (often a separate Direct Connect
  PIN). **Zero intermediary — the only parties are millfolio and the bank.** This
  is the ideal privacy shape. But the coverage is **collapsing**: forum evidence
  shows **Chase dropping it end of Sept 2026**, **TD already gone**; still-working
  holdouts include **Wells Fargo, PNC, Fifth Third, Fidelity** (Fidelity disables
  bill-pay). Banks must be enrolled per-user, some charge a monthly fee, and
  listing has historically been mediated through Quicken/Intuit's OFX
  certification. **Viable only as a "supported for the handful of banks that still
  offer it" feature**, not a universal solution.

- **CFPB Section 1033 / FDX direct API — the strategic bet.** Part 1033 legally
  forces banks, card issuers, and wallets to expose **covered data** (incl. **≥24
  months of transactions** — amount, date, payment type, pending/authorized
  status, payee/merchant, fees) through a **standardized, machine-readable
  developer API**, and it is engineered *against* the aggregator model:
  - **Aggregator is optional** (§1033.431) — an app may be its **own authorized
    third party** and hit the bank's developer interface directly.
  - **No fees** to the consumer or the third party (§1033.301(c)).
  - **No shared credentials** (§1033.311(e)) — kills screen-scraping; forces
    tokenized/OAuth-style auth.
  - **Use limited to "reasonably necessary"** (§1033.421(a)); **targeted ads,
    cross-selling, and sale are explicitly NOT reasonably necessary**
    (§1033.421(a)(2)) — the exact resale/analytics behavior that makes aggregators
    privacy-hostile is **banned** for 1033-authorized access.
  - **Revocable anytime, no fee** (§1033.421(h)); collection capped at one year
    then reauthorized (§1033.421(b)).
  - **≥99.5% monthly uptime** mandated and publicly reported (§1033.311(c)).
  - Formats conform to a CFPB-recognized standard-setting body (§1033.141) — in
    practice **FDX (Financial Data Exchange)**.

  This is the natural long-term home for a privacy-first, on-device importer: a
  fee-free, credential-free, revocable, **aggregator-optional** API whose terms of
  use *legally forbid* the data-monetization millfolio refuses to do.

  **Two catches, both decision-critical:**
  1. **Timeline** (compliance dates, §1033.121):

     | Date | Who must expose data |
     |---|---|
     | **2026-04-01** | Banks/CUs ≥ $250B assets; nondepository ≥ $10B receipts |
     | **2027-04-01** | Next tier of large banks |
     | **2028-04-01** | Depository institutions $3B–$10B |
     | **2029-04-01** | Depository institutions $1.5B–$3B |
     | **Never (exempt)** | Institutions ≤ SBA size standard (small banks/CUs) |

     So the largest banks (Chase, BofA, Wells…) owe a free standardized API by
     **2026-04-01**; mid-size by 2028–2029; the smallest are **permanently exempt**.
  2. **Regulatory risk** — the text researched is the Oct-2024 final rule, but the
     rule is under **active litigation and CFPB reconsideration**; its dates and
     even its survival are **unsettled**. Do **not** hard-commit a roadmap to the
     2026 date without re-checking the rule's live status.

---

## Recommendation

1. **Keep manual CSV as the always-available baseline** — it is the purest
   on-device path and depends on no one.
2. **Do not adopt Plaid or Teller.** They are architecturally incompatible with
   the promise; adopting one would force us to either lie about the promise or
   bolt on a cloud backend that sees the user's finances.
3. **Track CFPB 1033 / FDX as the strategic target** for real automatic import —
   it is the *only* path that is simultaneously **aggregator-free, broad, fee-free,
   and legally anti-monetization**. Prototype against an FDX sandbox; revisit once
   the 2026-04-01 tier is live *and* the regulatory picture stabilizes. This is the
   one that lets us say "automatic import, and your data still never leaves your
   Mac" truthfully.
4. **Optionally, a narrow OFX Direct Connect path** for the few banks that still
   offer it (Wells, PNC, Fifth Third, Fidelity) — same on-device shape as 1033,
   available today, but frame it as best-effort given the coverage collapse.
5. **If — and only if — user demand forces an aggregator before 1033 is usable,**
   ship **SimpleFIN Bridge** as a clearly-labeled opt-in ("this uses a third-party
   service; your data passes through their servers"), never on by default, with a
   one-click disconnect. It is the cheapest, simplest, read-only, most-minimal of
   the aggregators.

## Open questions / next steps

- Re-verify 1033's live legal status + revised compliance dates before roadmapping.
- Stand up an **FDX sandbox** prototype: OAuth-style auth → pull 24-mo
  transactions → map into the vault's transaction schema (reuse the CSV
  extractor's reconcile-validated `transactions()` path).
- Scope an **OFX client** in the CLI/app for the holdout banks (SGML/XML
  request-response over HTTPS) — measure real reliability against Wells/PNC.
- Decide the **product framing** of any aggregator opt-in so it can never be
  mistaken for the on-device default.

*Sources: Plaid consumer-data page, Teller End-User Privacy Policy (2021-11-10),
Firefly III "Import from SimpleFIN" docs, Quicken Direct Connect forum threads,
CFPB 12 CFR Part 1033 final rule text. Facts outside those files (pricing,
coverage breadth, protocol mechanics, current litigation status) are noted as
such in the working research and should be re-verified before implementation.*
