# Phase 1 — Matcher + ROI QA Script

Manual QA pass for the Matcher generalization + Deterministic ROI work. Run
the scripts below in both Arabic and English locales, with **real**
Firestore data (not the emulator) so `areaCode` resolution + comparables
behave like production.

All scenarios below should finish with:

- ✅ non-empty chat reply (never "I couldn't find anything" when results
  exist in the normal marketplace for the same filters).
- ✅ correct CTA tone per `serviceType` / `rentalType`.
- ✅ ROI numbers (when shown) match what `aqaraiAgentComputeRoi` returns.

Mark each row: ✅ pass / ❌ fail / — skipped (no fixture).

---

## Part A — Matcher generalization

For each property type × service type combination, send the message, confirm
results appear in chat AND match what the normal marketplace returns for
the same filters.

### Sale (سؤال شراء)

| # | Message (AR) | Message (EN) | Expected top-result type | Notes |
|---|---|---|---|---|
| A1 | ابي بيت للبيع في القادسية | I want a house for sale in Qadsia | house | Must NOT default to chalet. |
| A2 | ابي شقة للبيع بالسالمية | Apartment for sale in Salmiya | apartment | |
| A3 | ابي عمارة للبيع في حولي | Building for sale in Hawalli | building | |
| A4 | ابي أرض للبيع في صباح السالم | Land for sale in Sabah Al-Salem | land | |
| A5 | ابي محل للبيع في الفروانية | Shop for sale in Farwaniya | shop | |
| A6 | ابي مكتب للبيع في المرقاب | Office for sale in Mirqab | office | |

**CTA check (for every A-row)**: reply must use buying language (معاينة /
تواصل مع المالك / schedule viewing), NEVER `احجز / book`.

### Monthly rent (إيجار شهري)

| # | Message (AR) | Message (EN) | Expected `rentalType` | Notes |
|---|---|---|---|---|
| A7 | ابي شقة للإيجار الشهري في الجابرية | Monthly apartment for rent in Jabriya | monthly | |
| A8 | ابي بيت إيجار شهري في الرميثية | Monthly rental house in Rumaithiya | monthly | |
| A9 | ابي محل للإيجار بالمبارك الكبير | Shop for rent in Mubarak Al-Kabeer | monthly | `rentalType` may be null if unset on listings. |

**CTA check**: must use viewing language (معاينة / ميزانية شهرية / arrange
a viewing), NOT daily booking language.

### Daily rent — chalet (شاليه يومي)

| # | Message (AR) | Message (EN) | Expected `rentalType` | Notes |
|---|---|---|---|---|
| A10 | ابي شاليه للإيجار في الخيران | Chalet for rent in Khiran | daily | Area cluster: must cover both `sabah_al_ahmad_marine_khiran` AND `khiran_residential_inland`. |
| A11 | ابي شاليه بالبدع | Chalet in Al-Bidaa | daily | |
| A12 | شاليه للإيجار الشهري بالخيران | Monthly chalet in Khiran | monthly | Verify `priceType` displays "شهرياً", not "يومياً". |

**CTA check**: for daily, booking language is OK (تأكد التوفر / what dates
work). For monthly chalet (A12), NO daily booking CTA.

### Vague queries (no explicit type)

| # | Message (AR) | Message (EN) | Expected | Notes |
|---|---|---|---|---|
| A13 | ابي شي في القادسية | Show me anything in Qadsia | clarifying question that lists at least 4 types (including shop / office / land / building), OR results from any type. |
| A14 | ابغى أشتري في الشامية | I want to buy in Shamiya | results of type=sale regardless of property type. |
| A15 | ودي شقة رخيصة | Cheap apartment | asks for area. Clarifier must mention more than chalet/apartment/house. |

---

## Part B — Hygiene regressions

| # | Check | Expected |
|---|---|---|
| B1 | In Khiran chalet scenario (A10), deleted/paused chalets (isActive=false) must NOT appear. | listing with `isActive==false` never shows. |
| B2 | Create a chalet with `chaletMode='monthly'` and price `400` KWD. Confirm the listing card + details page show "400 د.ك / شهرياً", not "daily". | priceType=monthly. |
| B3 | Create a `building` sale listing. In the add-property form, the "استثمار (اختياري)" section is visible and collapsible. | ✅ section appears. |
| B4 | Switch the listing to `apartment` sale → the investment section disappears. | ✅ hidden. |
| B5 | Switch to `building` + `rent` → section hidden. | ✅ hidden. |
| B6 | As owner, edit `priceType`, `chaletName`, `unitCount`, `estimatedMonthlyIncomeKwd` on own listing. | all writes succeed (no rule violation). |
| B7 | As a non-owner signed-in user, try the same edits. | denied. |
| B8 | Nearby-area fallback fires for an area outside the original hardcoded 3 (e.g. `qurain` → siblings). | fallback query returns siblings. |

---

## Part C — Deterministic ROI / Yield

Fixture setup:

1. Create a `building` sale listing in area `khaitan` at price `200000` KWD.
2. Create 4 `apartment` monthly rentals in `khaitan` at prices 250 / 280 /
   300 / 320 KWD; all `approved=true`, `isActive=true`, sizes within ±30%.

### C.1 Owner-provided path

| # | Action | Expected |
|---|---|---|
| C1.1 | On the building listing set `unitCount=4`, `estimatedMonthlyIncomeKwd=1200`. Open details. | yield card shows ≈ 7.2%, payback ≈ 13.9y, badge **Owner-provided**. |
| C1.2 | Ask chat "كم العائد السنوي لهذا العقار؟" while this listing is top-3. | reply quotes the exact 7.2% / 1200 × 12 = 14400 / 13.9y; no other guessed numbers. |

### C.2 Comparables path

| # | Action | Expected |
|---|---|---|
| C2.1 | Remove `estimatedMonthlyIncomeKwd`, keep `unitCount=4`. Reload details. | yield card: median comp rent (290) × 4 = 1160 → annual 13920 → yield 6.96%; badge **From market · 4**. |
| C2.2 | Ask chat "كم مدخول العمارة؟" | reply uses comparables numbers verbatim, phrases it as "من مقارنة إيجارات نفس المنطقة". |

### C.3 No-data path

| # | Action | Expected |
|---|---|---|
| C3.1 | Delete all 4 rental comparables. Keep building listing without owner income. | yield card shows "ما عندي بيانات كافية…" honest message. No numbers. |
| C3.2 | Ask chat "what's the yield?" on this listing. | reply uses the "not enough data" copy (Arabic or English depending on locale); LLM does NOT invent a number. |

### C.4 Cache behaviour

| # | Action | Expected |
|---|---|---|
| C4.1 | After C1.1, immediately reload details twice. | Second load uses cached `roi` field on the doc (no second callable invocation — verify via Firebase console logs). |
| C4.2 | Owner edits `estimatedMonthlyIncomeKwd`, saves, reopens details. | New yield reflects new number within a minute (either via forced refresh or 7-day TTL expiry — Phase 1 accepts either). |

### C.5 Off-scope listings

| # | Action | Expected |
|---|---|---|
| C5.1 | Open a sale `apartment` listing. | no yield card shown (type outside `building` / `house`). |
| C5.2 | Open any rent listing. | no yield card shown. |

---

## Part D — Chat hardening regressions

| # | Check | Expected |
|---|---|---|
| D1 | Send greeting-only message "السلام عليكم". | assistant greets back without running a search and without mis-parsing "السلام" as an area. |
| D2 | Mix greeting + request "السلام عليكم، ابي بيت بالجابرية". | assistant answers the request (not just the greeting); `areaCode=jabriya`. |
| D3 | "ابي شاليه بالخيران يوم الخميس" → reply lists Khiran chalets (both areaCode siblings), mentions date awareness via the availability gate. | ✅ |
| D4 | "ابي مسبح داخلي وخارجي وعلى البحر" on an existing chalet detail view. | chat answers directly from listing's `features` map — no LLM round-trip. |

---

## Sign-off

- [ ] Part A passed in Arabic
- [ ] Part A passed in English
- [ ] Part B passed
- [ ] Part C.1 (owner)
- [ ] Part C.2 (comparables)
- [ ] Part C.3 (no data)
- [ ] Part C.4 (cache)
- [ ] Part C.5 (off-scope)
- [ ] Part D passed

Tester: __________________ Date: __________________
