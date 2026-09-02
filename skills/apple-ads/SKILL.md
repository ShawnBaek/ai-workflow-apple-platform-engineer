---
name: apple-ads
description: >-
  Safely inspects, plans, creates, and optimizes Apple Ads Advanced campaigns, ad groups, search-result keywords, bids, budgets, audiences, Search Match, ad variations, attribution, and reporting. Use for Apple Ads, Apple Search Ads, asc ads, CPT, CPA, TTR, impression share, paid keyword work, or attributed ad revenue. Do not use for App Store metadata keywords or organic ASO; route those to app-store-connect.
---

# Apple Ads

Improve paid App Store acquisition without crossing the wrong account, treating
promotional credit as a hard spend stop, or optimizing downloads without the
economics and attribution needed to judge them.

## Resolve the account before reading

1. Load the expected Apple Ads profile, organization, ad account, and permitted
   apps from the project's private policy. Reusable public skills must not
   contain personal identifiers.
2. Inspect only the local authentication metadata needed to compare the active
   identity. Redact credentials, key material, client secrets, and unrelated
   account names.
3. Constrain every website, API, or CLI request to the approved organization and
   ad account. Pass the profile, organization, and ad-account identifiers
   explicitly wherever the client supports them; never rely only on defaults.
4. Stop before listing campaigns, apps, billing, or reports if the identity
   differs, the account cannot be constrained, or a command would enumerate
   other organizations.
5. After the account matches, resolve the exact app ID, campaign group, account
   currency and time zone, placement, countries or regions, and requested
   action. Read current client help and version before depending on third-party
   command syntax.
6. Confirm that the scoped account and requested capability are Apple Ads
   Advanced. Apple Ads Basic is a separate surface with a simplified dashboard
   and AdServices measurement, but without Advanced keyword and audience controls
   or Apple Ads Platform API campaign-management access. Never cross into a Basic
   account to work around an Advanced account problem.

If a request spans "all results" or multiple apps, require the user or private
policy to name the permitted app IDs before comparing them. Keep each app's
outcome, value definition, currency, attribution window, and conversion delay
separate. Never select a cross-app "winner" from incomparable CPA or ROAS data.

Do not switch to another cached profile after an authentication or permission
failure. Never ask the user to paste a private key, password, verification code,
or recovery information into chat.

## Keep authority granular

A request to inspect or analyze is read-only. Do not infer permission to:

- create a campaign, ad group, keyword, negative keyword, or ad variation;
- activate a draft or resume a paused object;
- change Search Match, match type, audience, bid, budget, dates, or placement;
- pause, archive, delete, or replace an existing object;
- change App Store metadata or a custom product page;
- install or upgrade a client, authenticate, or create credentials.

Treat creation and activation as separate actions when the client permits a
paused draft. Immediately before any paid activation or spend-increasing edit,
restate the exact app, object IDs, countries, daily budget, dates, bids or target
CPA, current spend, remaining authorized exposure, and intended stop condition.
Obtain approval for that exact mutation. A prior campaign approval does not
authorize later budget or bid increases.

## Bind the spend and outcome

Before proposing a paid experiment, record:

- the business event to optimize: new download, activated user, trial, purchase,
  subscription, retained subscriber, or attributed revenue;
- target CPA or ROAS and the value assumptions behind it;
- authorized total exposure, daily budget, start and end dates, countries,
  currency, and all other active campaigns sharing that exposure;
- reporting time zone, attribution source and window, and conversion delay;
- promotional-credit balance and expiry when the user intends credit-only spend.

Confirm every user-stated amount in the account currency before calculating or
writing it. Do not assume that a `$` amount and the account's currency are the
same unit.

Apple Ads daily budget is an average daily amount, not a promise that each day
will spend exactly that amount. Recheck the current budget rules, calculate both
`daily budget x campaign days` and the applicable monthly exposure, and set an
explicit end date for a bounded test. Do not assume lifetime budget is available.

Treat promotional credit as a billing offset, not as authorization for paid
overage or as a guaranteed campaign stop. Verify its eligibility, expiry, and
invoice-derived balance on the scoped Billing page, and record the invoice cutoff
time. That balance is not a real-time spend meter. For credit-only authorization,
calculate a conservative upper bound that includes spend since the invoice
cutoff, current unbilled or later spend, the maximum remaining exposure of every
other active campaign sharing the account before its end date, and an explicit
reserve for reporting latency and the longest monitoring gap. If an active
campaign has no end date, or the upper bound cannot be proved strictly below the
eligible credit in the account currency, pause or end the exposure and verify it,
or do not activate unless the user explicitly accepts paid overage. Monitoring
alone is not a hard cap.

For Manage Bids, max CPT is a ceiling for a tap and the actual price may be lower.
Derive a starting ceiling from unit economics, not from a universal dollar amount.
Suggested bids and impression share are evidence, not commands. Read
[campaign optimization](references/campaign-optimization.md) before choosing a
budget, bid, keyword structure, or performance action.

## Design a test around search intent

- Use paid keywords only for search-results campaigns and confirm the selected
  bidding mode. Manage Bids supports explicit keyword and max-CPT control;
  Maximize Conversions uses automated bidding and requires Search Match for its
  automatic ad group.
- Separate brand, category, competitor, and discovery intent when doing so makes
  budget, search-term, and revenue evidence clearer. One country per campaign is
  optional: isolate markets with distinct value or budgets, and group countries
  only when language, customer value, and reporting goals genuinely align.
- Exact match still includes close variants such as spelling, word order, and
  translations. In the web UI brackets can select exact match; in APIs and CLIs,
  pass the keyword text and `EXACT` match type separately unless current help says
  otherwise.
- Broad match and Search Match are valid discovery tools, not settings that must
  always be disabled. Isolate discovery in its own ad groups, use relevant
  negatives to reduce overlap, and review actual search terms before promoting a
  winner to exact match. Daily budgets are campaign-level; an isolated ad group
  does not hard-cap spend, so use a separately budgeted campaign when the
  discovery test needs its own hard exposure boundary.
- Review recommendations individually. Never bulk-add a recommendation list or
  competitor names without checking product relevance, current policy, language,
  search popularity, and the resulting query intent.
- Before adding a keyword, normalize and deduplicate it against existing exact
  and broad keywords, check conflicts with negative keywords, verify the current
  per-ad-group keyword limit, and read the effective or inherited max CPT. Verify
  that the campaign daily budget satisfies the current API constraint relative
  to the ad group's default bid before submission. New keywords can default to
  broad match and the match type cannot be changed after save; pass the intended
  match type explicitly and pause/re-add only with fresh approval when a saved
  type is wrong.
- Treat third-party ASO difficulty or entry-barrier scores as candidate evidence,
  not search demand, Apple relevance, expected volume, or a bid recommendation.
  Validate candidates with current Apple popularity, impressions, search terms,
  conversion evidence, and the app's real feature set.

Match the search intent through the product page, first screenshots, onboarding,
paywall, and purchase. A default ad uses default App Store product-page assets.
For materially different keyword themes, consider an ad variation backed by an
approved custom product page. Route creation or mutation of that page and all App
Store metadata through `app-store-connect`; Apple Ads permission does not grant
that separate mutation.

Validate every selected country's app availability, product-page localization,
language, pricing, legal eligibility, and supported placement before creation.
Do not translate keywords literally or assume that a supported app localization
proves local search demand.

## Diagnose before changing bids

Use one consistent date range, time zone, attribution definition, and report
granularity. Inspect campaign, ad group, keyword, search-term, and ad-variation
levels with pagination and stable IDs.

- No impressions: check status, eligibility, relevance, search popularity,
  placement, audience reach, budget, and bid competitiveness.
- Impressions without taps: check query intent, keyword breadth, and visible ad
  or product-page promise.
- Taps without downloads: check localization, screenshots, page performance,
  device compatibility, and expectation mismatch.
- Downloads without the intended value event: check onboarding, activation,
  paywall, price, product fit, and attribution plumbing before buying more taps.
- Attributed value below target: wait for the stated conversion delay and a
  sufficient sample, then lower or pause the bounded loser.
- Value above target with constrained reach: consider a gradual bid or budget
  test while preserving the target CPA or ROAS.

Do not use a universal conversion rate, impression-share threshold, country tier,
fixed bid increment, fixed max-CPT cutoff, or number of elapsed days as an
automatic decision. Apple notes that initial data can take 24–48 hours and major
changes need time, but low-volume terms may require longer. Change one material
variable at a time and define the next review by both time and sample.

Connect post-install value through AdServices, AdAttributionKit, or an approved
measurement provider when the objective extends beyond a download. Apple and
third-party reports can differ in install source, redownload treatment, and
attribution windows. Never merge them as if they were identical measurements.

## Execute the smallest verified mutation

1. Snapshot the exact scoped objects and current metrics with a retrieval time.
2. Present the proposed before/after diff, spend exposure, hypothesis, success
   threshold, stop condition, and next observation time.
3. Revalidate the account guard and exact approval immediately before the write.
4. Mutate only the approved fields on the approved IDs. Prefer structured input
   and output; never interpolate unreviewed keyword suggestions into a command.
   Create new spend-bearing campaigns, ad groups, and keywords paused wherever
   the surface supports it. If it does not, do not write into an active parent
   unless the exact approval also authorizes pausing that parent first.
5. Read the changed object back from Apple and compare every approved field.
6. Treat activation as a separate gate: re-present the read-back state and spend
   exposure, obtain activation approval, activate only the named objects, and
   read their status back again.
7. Re-read the relevant report after its data delay. Report `pending`, `on hold`,
   or another observed state instead of calling a successful request active.

Prefer pause over deletion while preserving learning and rollback value. Delete
only when the user explicitly names the test objects to remove and the current
account-scoped read confirms those exact targets.

## Evidence and completion

Report the sanitized account guard result, client/API version, app and object IDs,
currency and time zone, report window and filters, attribution definition,
pre/post values, authorized exposure, stable response state, and next review or
stop condition. Record omitted checks and remaining risk.

A 2xx response, a populated form, a recommendation badge, a high daily budget,
or a few elapsed days is not proof that a campaign is active or effective. Do not
claim completion until the requested state is read back on the approved account.

## Official sources

- [Structure campaigns](https://ads.apple.com/app-store/help/campaigns/0056-structure-campaigns)
- [Understand Search Match](https://ads.apple.com/app-store/help/campaigns/0006-understand-search-match)
- [Understand keyword match types](https://ads.apple.com/app-store/help/keywords/0059-understand-keyword-match-types)
- [Set and adjust bids](https://ads.apple.com/app-store/help/bids-and-budget/0062-set-and-adjust-bids)
- [Manage budgets](https://ads.apple.com/app-store/help/bids-and-budget/0016-manage-budgets)
- [Reporting definitions](https://ads.apple.com/app-store/help/reporting/0023-reporting-options-and-definitions)
- [Measure ad performance](https://ads.apple.com/app-store/help/attribution/0028-measuring-ad-performance)
- [Create ad variations](https://ads.apple.com/app-store/help/ads/0077-create-ad-variations)
- [Apple Ads promo credit](https://ads.apple.com/app-store/help/billing/0032-apple-ads-promo-credit)
- [Compare Apple Ads solutions](https://ads.apple.com/app-store/help/apple-ads-basic/0001-compare-apple-ads-solutions)
