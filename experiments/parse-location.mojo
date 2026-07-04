from vault import *

# parse-location — a human-written vault analysis program.
#
# Run it over your real, indexed vault WITHOUT a model call:
#
#     mill run https://millfolio.app/parse-location.mojo
#     mill run ./experiments/parse-location.mojo        # from a millfolio checkout
#
# It iterates every statement's reconciled transactions() and splits each Txn's
# `.desc` into a best-effort (merchant, state, country). Bank/card descriptors
# trail a location on the raw string, e.g.
#
#     AMAZON MKTPLACE AMZN.COM/BILL WA USA   -> [AMAZON MKTPLACE] | WA | USA
#     TESCO STORES 3421 LONDON GBR            -> [TESCO STORES]     | -  | GBR
#     UBER   *TRIP HELP.UBER.C AMSNLD         -> [UBER]             | -  | NLD
#
# The heuristic:
#   country — the TRAILING token, either a 3-letter ISO code (`USA`) or a 6-char
#             `<city3><ISO3>` pack (`LNDGBR` -> `GBR`, `ROMROM` -> `ROM`);
#   state   — the next trailing token if it's a US 2-letter state code (`WA`);
#   merchant— the LEADING brand tokens, stopping at the first address marker
#             (STREET/WAY/AVE/UNIT/OFFICE/STRADA/NR/ET/BLVD/RD/STE/…), a long
#             digit run, a `#store` token, or the state/country region.
#
# It prints one row per transaction plus hit-rate summary lines so you can eyeball
# how well the heuristic did on YOUR statements. Nothing leaves the sandbox.


@fieldwise_init
struct Parsed(Copyable, Movable):
    var merchant: String
    var state: String
    var country: String


def _pd_upper(s: String) -> String:
    """ASCII-uppercase a token so matching is case-insensitive."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 97 and c <= 122:  # 'a'..'z'
            c -= 32
        out += chr(c)
    return out^


def _pd_all_alpha(s: String) -> Bool:
    """True iff every byte is an ASCII letter (and the token is non-empty)."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
            return False
    return True


def _pd_all_digit(s: String) -> Bool:
    """True iff every byte is an ASCII digit (and the token is non-empty)."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return False
    return True


def _pd_last3(s: String) -> String:
    """The last 3 bytes of an all-ASCII token (the ISO3 tail of a 6-char pack)."""
    var b = s.as_bytes()
    var n = len(b)
    var out = String("")
    for i in range(n - 3, n):
        out += chr(Int(b[i]))
    return out^


def _pd_in(needle: String, hay: List[String]) -> Bool:
    for i in range(len(hay)):
        if hay[i] == needle:
            return True
    return False


def _pd_tokens(s: String) raises -> List[String]:
    """Whitespace-split a descriptor into non-empty tokens (spaces + tabs)."""
    var norm = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        # Fold tabs/newlines/CR to a plain space so a single split covers them.
        norm += " " if (c == 9 or c == 10 or c == 13) else chr(c)
    var raw = norm.split(" ")
    var out = List[String]()
    for i in range(len(raw)):
        var t = String(String(raw[i]).strip())
        if t.byte_length() > 0:
            out.append(t^)
    return out^


def _pd_iso3() -> List[String]:
    """Common ISO-3166 alpha-3 country codes (plus the legacy `ROM` for Romania,
    which real card descriptors still emit alongside `ROU`)."""
    return [
        String("USA"), String("CAN"), String("MEX"), String("GBR"),
        String("IRL"), String("FRA"), String("DEU"), String("ESP"),
        String("ITA"), String("PRT"), String("NLD"), String("BEL"),
        String("CHE"), String("AUT"), String("SWE"), String("NOR"),
        String("DNK"), String("FIN"), String("POL"), String("ROU"),
        String("ROM"), String("GRC"), String("TUR"), String("RUS"),
        String("UKR"), String("CZE"), String("HUN"), String("AUS"),
        String("NZL"), String("JPN"), String("CHN"), String("HKG"),
        String("SGP"), String("KOR"), String("IND"), String("IDN"),
        String("THA"), String("VNM"), String("PHL"), String("MYS"),
        String("ARE"), String("SAU"), String("ISR"), String("ZAF"),
        String("BRA"), String("ARG"), String("CHL"), String("COL"),
        String("PER"),
    ]


def _pd_states() -> List[String]:
    """US 2-letter state/territory codes (incl. DC)."""
    return [
        String("AL"), String("AK"), String("AZ"), String("AR"), String("CA"),
        String("CO"), String("CT"), String("DE"), String("FL"), String("GA"),
        String("HI"), String("ID"), String("IL"), String("IN"), String("IA"),
        String("KS"), String("KY"), String("LA"), String("ME"), String("MD"),
        String("MA"), String("MI"), String("MN"), String("MS"), String("MO"),
        String("MT"), String("NE"), String("NV"), String("NH"), String("NJ"),
        String("NM"), String("NY"), String("NC"), String("ND"), String("OH"),
        String("OK"), String("OR"), String("PA"), String("RI"), String("SC"),
        String("SD"), String("TN"), String("TX"), String("UT"), String("VT"),
        String("VA"), String("WA"), String("WV"), String("WI"), String("WY"),
        String("DC"),
    ]


def _pd_markers() -> List[String]:
    """Address-line marker words: once one appears the rest is an address, not the
    brand — so the merchant is everything BEFORE it."""
    return [
        String("STREET"), String("WAY"), String("AVE"), String("AVENUE"),
        String("UNIT"), String("OFFICE"), String("STRADA"), String("NR"),
        String("ET"), String("BLVD"), String("RD"), String("STE"),
        String("SUITE"),
    ]


def _pd_parse(
    desc: String,
    iso3: List[String],
    states: List[String],
    markers: List[String],
) raises -> Parsed:
    """Best-effort (merchant, state, country) split of one raw descriptor."""
    var toks = _pd_tokens(desc)
    if len(toks) == 0:
        return Parsed(String(String(desc).strip()), String(""), String(""))

    var country = String("")
    var state = String("")
    # `keep` is the count of leading tokens NOT yet consumed as state/country —
    # the merchant is drawn from tokens[0 .. keep).
    var keep = len(toks)

    # country from the trailing token: a 3-letter ISO, or a 6-char <city3><ISO3>.
    var last_up = _pd_upper(toks[keep - 1])
    if _pd_all_alpha(last_up):
        if last_up.byte_length() == 3 and _pd_in(last_up, iso3):
            country = last_up.copy()
            keep -= 1
        elif last_up.byte_length() == 6:
            var tail3 = _pd_last3(last_up)
            if _pd_in(tail3, iso3):
                country = tail3^
                keep -= 1

    # state from the new trailing token: a US 2-letter code.
    if keep > 0:
        var st_up = _pd_upper(toks[keep - 1])
        if st_up.byte_length() == 2 and _pd_in(st_up, states):
            state = st_up^
            keep -= 1

    # merchant = leading brand tokens, stopping at the first address-ish token or
    # the (already-consumed) geo region.
    var merch = String("")
    var mcount = 0
    for i in range(len(toks)):
        if i >= keep:
            break  # reached the state/country region
        ref t = toks[i]
        var tu = _pd_upper(t)
        var is_marker = _pd_in(tu, markers)
        var is_digrun = _pd_all_digit(t) and t.byte_length() >= 3
        var is_hash = Int(t.as_bytes()[0]) == 35  # leading '#'
        if is_marker or is_digrun or is_hash:
            break
        if mcount > 0:
            merch += " "
        merch += t
        mcount += 1
    if merch.byte_length() == 0:
        merch = toks[0].copy()  # nothing survived → fall back to the first token
    return Parsed(merch^, state^, country^)


def _bump(mut names: List[String], mut counts: List[Int], key: String):
    """Increment `key`'s tally in parallel name/count lists (insert at 1 if new)."""
    for i in range(len(names)):
        if names[i] == key:
            counts[i] += 1
            return
    names.append(key.copy())
    counts.append(1)


def _has_digit_run(s: String, n: Int) -> Bool:
    """True if `s` contains a run of >= n consecutive ASCII digits (a residual
    store/account number the merchant extraction failed to strip)."""
    var b = s.as_bytes()
    var run = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            run += 1
            if run >= n:
                return True
        else:
            run = 0
    return False


def _print_top(names: List[String], counts: List[Int], k: Int) raises:
    """Print the top-`k` (name, count) pairs by count, descending (selection sort)."""
    var used = List[Bool]()
    for _ in range(len(names)):
        used.append(False)
    var shown = 0
    while shown < k and shown < len(names):
        var best = -1
        var bestc = -1
        for i in range(len(names)):
            if not used[i] and counts[i] > bestc:
                bestc = counts[i]
                best = i
        if best < 0:
            break
        used[best] = True
        shown += 1
        print("  " + String(counts[best]) + "\t" + names[best])


def main() raises:
    var files = manifest()
    var iso3 = _pd_iso3()
    var states = _pd_states()
    var markers = _pd_markers()

    var total = 0
    var country_ok = 0
    var state_ok = 0
    var merch_dirty = 0  # merchants still holding a 3+ digit run (imperfect strip)
    var m_names = List[String]()
    var m_counts = List[Int]()
    var c_names = List[String]()
    var c_counts = List[Int]()
    var no_country = List[String]()  # sample of descriptors that parsed no region

    for i in range(len(files)):
        progress("parsing descriptors in " + files[i].alias)
        var txns = transactions(files[i].alias)  # [] when not a statement
        for t in range(len(txns)):
            ref x = txns[t]
            if x.desc.byte_length() == 0:
                continue
            var p = _pd_parse(x.desc, iso3, states, markers)
            total += 1
            _bump(m_names, m_counts, p.merchant)
            if _has_digit_run(p.merchant, 3):
                merch_dirty += 1
            if p.country.byte_length() > 0:
                country_ok += 1
                _bump(c_names, c_counts, p.country)
            elif len(no_country) < 25:
                no_country.append(x.desc.copy())
            if p.state.byte_length() > 0:
                state_ok += 1

    if total == 0:
        print_answer(
            "No transactions found in the vault — index some statements first"
            " (`mill index <folder>`), then re-run."
        )
        return

    print("=== top 30 merchants by transaction count (eyeball the brand quality) ===")
    _print_top(m_names, m_counts, 30)
    print("distinct merchants: " + String(len(m_names)) + " over " + String(total) + " transactions")
    print(
        "merchants still holding a 3+ digit run (imperfect strip): "
        + String(merch_dirty)
    )

    print("\n=== country histogram ===")
    _print_top(c_names, c_counts, 60)

    print("\n=== 25 sample descriptors with NO country parsed ===")
    print("(are these legitimately location-less — online / transfers / fees — or real misses?)")
    for i in range(len(no_country)):
        print("  " + no_country[i])

    print("\n=== hit rates ===")
    print("country parsed: " + String(country_ok) + "/" + String(total))
    print("state parsed:   " + String(state_ok) + "/" + String(total))
    print_answer(
        "Parsed "
        + String(total)
        + " descriptors — "
        + String(len(m_names))
        + " distinct merchants ("
        + String(merch_dirty)
        + " with residual digits), country on "
        + String(country_ok)
        + ", US state on "
        + String(state_ok)
        + "."
    )
