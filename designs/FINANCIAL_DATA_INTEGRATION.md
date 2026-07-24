# Financial data integration — automatic bank-transaction import

**Status:** research + recommendation (2026-07-19; **Akoya/pass-through added
2026-07-24**). No code yet.
**Question:** how does millfolio move past *manual CSV download* to *automatic*
bank-transaction import **without betraying the core promise — "your financial
data never leaves your Mac"?**

The starting fact: **most mainstream "connect your bank" products are cloud
aggregators.** The user's bank credentials and full transaction history flow
*through a third party's servers*, where they are retained, analyzed, and (for
some) monetized. That is the exact thing millfolio exists not to do. So the
options fall into **three** camps, not two:

1. **Store-everything aggregators** (Plaid, Teller, hosted SimpleFIN) — off-device;
   reject or heavily gate.
2. **Pass-through networks** (Akoya) — an FDX router that *does not store, copy, or
   analyze* the data; credential-free; a genuine third category discovered
   2026-07-24, and the best privacy fit that works *today* for banks already on it.
3. **Direct bank↔app** (OFX Direct Connect, CFPB-1033/FDX) — no intermediary at
   all; the purest shape, but coverage-limited (OFX) or timeline/legally-gated (1033).

---

## The six options at a glance

| Option | Intermediary stores data? | On-device? | Indie-accessible today | Coverage | Integration effort | Verdict |
|---|---|---|---|---|---|---|
| **Plaid** | Yes — collects + monetizes | ❌ | Yes (approval + paid) | ★★★ >12k institutions | High — webview Link + server token exchange | **Reject** |
| **Teller** | Yes — collects + analyzes | ❌ | Yes (indie-ish, mTLS) | ★★ US, narrower | Medium | **Reject** |
| **SimpleFIN Bridge** | Yes — hosted Bridge caches txns | ⚠️ partial (self-host possible) | **Yes — no contract, ~$1.50/mo, token** | ★★ decent, flaky | **Low — plain JSON GET** | **Least-bad aggregator**, opt-in only |
| **Akoya (pass-through network)** | **No — routes, keeps nothing** | ✅ (data isn't warehoused) | ⚠️ self-serve sandbox; **prod = usage-based contract** | ★★★ 4,300+ FIs (Wells Fargo, TD, Fidelity-network…) | Medium — FDX/OAuth via one network integration | **Best privacy fit that works TODAY** |
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

## The pass-through network — Akoya (the third category)

*Web research 2026-07-24 — re-verify pricing/terms/scopes before relying on this.*

**Akoya is not an aggregator — it's an FDX *router* that keeps nothing.** Its own
docs state it "does not open the package, does not make a copy of what is inside,
analyze it, or store it for future use" — a **pass-through** model. Data flows
**bank → (Akoya routes, retains nothing) → your app**, credential-free over
FDX/OAuth (the customer authorizes at their bank; no login is shared). That is a
categorically different privacy posture from Plaid/Teller, which are the
collector-of-record.

- **How you reach a bank through it:** one integration onto the Akoya Data Access
  Network reaches **4,300+ institutions** (7,000+ apps powered). **Wells Fargo is
  live on Akoya** (joined 2021, alongside TD and the Fidelity-founded network);
  Wells Fargo also keeps **direct** FDX data-exchange agreements for partners who
  sign one. So for a covered bank, Akoya is the aggregator-free way to get real FDX
  data **today**, years before 1033 forces universal coverage.
- **Access model:** Akoya offers a **self-service developer sandbox**, but
  **production is a usage-based commercial agreement** — not the zero-contract
  self-serve of SimpleFIN. There is an onboarding/sales step.
- **Why it's the strongest *available-now* fit for the promise:** no credentials
  in our app, no third party warehousing the user's finances, standardized FDX
  payloads that map straight into the vault's `transactions()` schema — and it
  doesn't wait on the 1033 timeline or its litigation risk. It's essentially
  "**1033-style access, but live today for the banks on the network**."

**Open unknowns (decision-critical, verify before betting):** (1) does Akoya's
*fintech* onboarding admit a native, **on-device consumer app** (vs. a hosted
service or a registered data recipient)? (2) production pricing at low/personal
volume; (3) which Wells Fargo **data scopes** are exposed via Akoya (transactions,
**≥24 months**, balances, account/routing) and whether they match what CSV import
gives today; (4) whether the token/consent flow can complete without our own
cloud component (an on-device OAuth redirect handler).

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
3. **Evaluate Akoya as the near-term automatic path** — it delivers FDX data
   **today** for banks already on the network (incl. **Wells Fargo**) through a
   *pass-through* router that stores nothing, so it can plausibly preserve the
   promise. It's the same FDX payload shape as 1033, just available now. Gate the
   evaluation on the four unknowns above — chiefly **whether a native on-device app
   can onboard without our own cloud** and the low-volume pricing. If those clear,
   Akoya + 1033 become one continuous plan (**Akoya now, 1033 as it goes live**);
   if the on-device-fit fails, it degrades to the same "off-device" verdict as the
   aggregators.
4. **Track CFPB 1033 / FDX as the strategic (universal) target** — the *only* path
   that is simultaneously **aggregator-free, broad, fee-free, and legally
   anti-monetization**, and the one that eventually covers banks Akoya doesn't.
   Prototype against an FDX sandbox; revisit once the 2026-04-01 tier is live *and*
   the regulatory picture stabilizes. Because Akoya *is* FDX, the same client work
   serves both.
4. **Optionally, a narrow OFX Direct Connect path** for the few banks that still
   offer it (Wells, PNC, Fifth Third, Fidelity) — same on-device shape as 1033,
   available today, but frame it as best-effort given the coverage collapse.
5. **If — and only if — user demand forces an aggregator before 1033 is usable,**
   ship **SimpleFIN Bridge** as a clearly-labeled opt-in ("this uses a third-party
   service; your data passes through their servers"), never on by default, with a
   one-click disconnect. It is the cheapest, simplest, read-only, most-minimal of
   the aggregators.

## Open questions / next steps

- **Akoya fit for an on-device app** — the decisive near-term question: does Akoya
  admit a native, per-user desktop app as a data recipient, can its consent/token
  flow complete without our own cloud redirect endpoint, what are the low-volume
  prod terms, and which Wells Fargo scopes (txns ≥24mo, balances) does it expose?
  Start with the **self-serve Akoya sandbox** (no contract) to answer these cheaply.
- Re-verify 1033's live legal status + revised compliance dates before roadmapping.
- Stand up an **FDX sandbox** prototype (Akoya's sandbox doubles for this, since
  Akoya *is* FDX): OAuth-style auth → pull 24-mo transactions → map into the vault's
  transaction schema (reuse the CSV extractor's reconcile-validated `transactions()`
  path). One client serves both Akoya-now and 1033-later.
- Scope an **OFX client** in the CLI/app for the holdout banks (SGML/XML
  request-response over HTTPS) — measure real reliability against Wells/PNC.
- Decide the **product framing** of any aggregator opt-in so it can never be
  mistaken for the on-device default.

*Sources (original 2026-07-19): Plaid consumer-data page, Teller End-User Privacy
Policy (2021-11-10), Firefly III "Import from SimpleFIN" docs, Quicken Direct
Connect forum threads, CFPB 12 CFR Part 1033 final rule text.*

*Akoya / Wells Fargo (web research 2026-07-24): [Wells Fargo joins the Akoya Data
Access Network](https://akoya.com/news/wells-fargo-joins-the-akoya-data-access-network-to-advance-api-based-financial-data-aggregation),
[Finextra — WF API-based third-party sharing via Akoya](https://www.finextra.com/newsarticle/38317/wells-fargo-introduces-api-based-third-party-data-sharing-with-akoya),
[Akoya — Data Access Network docs](https://docs.akoya.com/docs/data-access-network),
[Akoya — data sharing / privacy model](https://akoya.com/datasharing),
[Akoya — pricing](https://akoya.com/pricing),
[FDX — Wells Fargo member spotlight](https://financialdataexchange.org/fdx-feed/member-spotlight-wells-fargo-and-xero-on-the-evolution-of-data-sharing/).*

*Facts outside the primary files (pricing, coverage breadth, protocol mechanics,
on-device eligibility, current litigation status) should be **re-verified before
implementation** — the Akoya figures and access model above are from vendor/press
pages dated to 2026-07-24, not a signed data agreement.*
