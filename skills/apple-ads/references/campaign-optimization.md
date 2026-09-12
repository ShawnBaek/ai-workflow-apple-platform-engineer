# Apple Ads campaign optimization

Read this reference before recommending or changing campaign structure, paid
keywords, Search Match, audience, bids, budgets, or performance status.

## Evidence order

Use evidence in this order:

1. current Apple Ads Help, policies, Platform API documentation, and live client
   help for the requested surface;
2. the approved account's current object read-back, reports, billing state, and
   app economics;
3. Apple-authored Developer videos for the exact topic, constrained by their
   session date and current feature availability;
4. product source, App Store product pages, localization, and attribution code;
5. the connected Kickstart MCP for scoped, read-only ASO rankings and competitor
   evidence, with the exact project, market, platform, date, and returned fields;
6. other third-party keyword tools and measurement providers, with methodology;
7. third-party case studies and videos as hypotheses, never as current platform
   guarantees.

## Official Apple video scope

Apple-authored videos explain workflows and product intent, but do not replace
current Apple Ads Help, Platform API documentation, or live account read-back.
Record each session's year, preserve older product names when quoting it, and
recheck every count, limit, field, and availability claim before acting.

- [Get started with app discovery and marketing](https://developer.apple.com/videos/play/tech-talks/110358/)
  is the closest official end-to-end campaign overview. It covers app,
  placement, market, daily budget, max-CPT, Search Match versus managed keywords,
  audience, custom-product-page ad variations, and reporting. Treat its numbers,
  labels, and feature limits as presentation-time context, not current defaults.
- [Enhance your presence on the App Store](https://developer.apple.com/videos/play/wwdc2026/205/)
  explains creative assets, Asset Library, custom product pages, Product Page
  Optimization, and Apple Ads Platform API setup automation. It is not a guide
  to keyword selection, bid economics, campaign structure, or budget control.
  Verify that any announced creative-asset capability is live for the requested
  placement before depending on it, and preserve separate App Store Connect and
  Apple Ads review gates.
- [What’s new in App Store Connect — WWDC25](https://developer.apple.com/videos/play/wwdc2025/328/)
  shows keywords associated with custom product pages for organic App Store
  search discovery. These language-specific page associations are not paid Apple
  Ads keyword bids and remain under App Store Connect authority.
- [What’s new in App Store Connect — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10063/)
  shows custom-product-page deep links used with Search Results and Today tab ad
  variations. It does not grant Apple Ads authority to create, edit, submit, or
  publish the underlying App Store Connect page.
- [Get ready to optimize your App Store product page — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10295/)
  is historical guidance for custom product pages and Product Page Optimization.
  Use current App Store Connect documentation for supported counts, metadata,
  review, and analytics behavior.
- [Meet AdAttributionKit — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10060/)
  and [What’s new in AdAttributionKit — WWDC25](https://developer.apple.com/videos/play/wwdc2025/221/)
  explain privacy-preserving attribution implementation. They are not evidence
  for Apple Ads campaign settings, keyword strategy, bids, budgets, or account
  operations; use Apple Ads reporting and AdServices sources for those claims.

## Third-party case-study scope

The 2026 video [I Built a $10K/Month App With Only Apple Ads](https://www.youtube.com/watch?v=dbt2Mt1VpLo)
is a useful case study, not normative documentation. Its full automatic captions
and 1,131 one-second samples were reviewed for this guide. The video shows a form
being configured but not the final create action, server read-back, or operating
results. It also contains promotional segments for third-party tooling, SDKs,
dashboards, and an advertising-credit offer, so it is not neutral comparative
evidence and does not justify adopting any promoted vendor. Do not claim that its
example campaign was created or activated.

## Third-party video lessons and corrections

| Time | Observed lesson | Reusable decision |
| --- | --- | --- |
| 00:00–03:02 | A self-reported revenue case and suggested test budgets of 200–500 for competitive markets and 100–300 for lower-competition markets, in the presenter's currency. | Search intent can be valuable, but revenue and starting amounts are unverified heuristics. Size tests from the app's economics and authorized loss. |
| 03:02–05:12 | Align the query, product page, install, onboarding, paywall, price, and purchase. | Preserve this funnel alignment and test keyword-themed ad variations when appropriate. |
| 05:12–06:53 | Markets are placed into three fixed cost or purchasing-power tiers. | Treat tiers as time- and app-specific hypotheses. Validate current country eligibility, localization, bids, conversion, and value. |
| 06:53–10:11 | Compare keyword spend with attributed subscriptions or revenue; lower losers and scale winners. A slide calls conversion under 80 percent "free money," while the narration is more qualified. | Preserve unit-economics analysis, but reject a universal 80-percent threshold. Require a stated attribution window, conversion delay, funnel baseline, and sufficient sample. |
| 10:11–11:31 | Localize first, then test short and long queries; a slide says 91 countries are supported. | Validate natural local intent and demand. Length alone does not make a keyword cheaper or better, and the video-era country count must be rechecked. |
| 11:32–13:37 | The form uses Search Results, Germany, Manage Bids, daily budget `20`, `$1.00` default max CPT, and `$1.46` suggested max CPT. | The daily-budget field does not visibly show its currency. Search Results is an intent-first example, not a rule excluding Apple's other placements. Starting about 30 percent below a suggestion is one example, not a rule. |
| 13:37–15:23 | Search Match is shown on at 13:37, toggled off by 13:46, and three bracketed terms are then added as exact match at `$1.00`. | Brackets are web-UI notation. APIs use keyword text plus match type. Exact includes close variants; Search Match remains useful in a separately controlled discovery test. |
| 13:55–15:23 | The recommendation list visibly contains many unrelated social and game terms and offers bulk add. | Review every recommendation; never bulk-add an unvalidated list. |
| 15:25–16:43 | The final example narrows to iPhone and new users, leaves age, gender, and location at All, and uses the default ad. The UI conditionally warns that applying age or gender disables custom-product-page deep links. | Reach All Eligible Users is the safer baseline unless the hypothesis needs narrowing. Age or gender refinement can suppress AdServices attribution and disable those deep links; the warning does not apply to the final All setting shown. |
| 17:10–18:03 | Slides suggest fixed 0.50 bid steps, an approximate 3.00 ceiling, and treating under-90-percent impression share as being outbid. | Do not encode fixed amounts or a universal share threshold. Diagnose relevance, popularity, eligibility, budget, and economics too. |
| 18:03–18:38 | The presenter usually waits three or four days, sometimes seeing movement sooner. | Apple suggests allowing 24–48 hours for initial data, but decide with elapsed time plus sample and attribution delay. |

The video's third-party SDK/dashboard promotion, free-credit marketing, revenue
graphic, and closing tool promotion are not Apple platform evidence. Automatic
caption values that conflict with visible UI, such as an apparent 50-dollar bid
where the slide shows an approximately 3-dollar ceiling, must not become rules.

## Kickstart MCP ASO checks

Use Paul Hudson's Kickstart MCP as the preferred third-party ASO checker when it
is available. Its current general MCP is bundled with the Kickstart app and its
live `tools/list` response is authoritative for exact schemas.

For a paid-keyword hypothesis:

1. Resolve the exact approved Kickstart project and App Store app ID without
   browsing unrelated projects when the project name is already known.
2. Use read-only calls such as `get_project`, `list_localizations`,
   `check_keyword_rankings`, `get_search_rankings`, and
   `get_competitor_analysis` as the current schema permits.
3. Record country, platform, locale, query, retrieval date, returned app rank and
   competitors, result count, trend, and any difficulty or entry-barrier fields.
4. Separate observed values from inference. Rank is not search volume; result
   count is not demand; difficulty is not a bid; localization is not proof of
   natural local-language intent.
5. Cross-check candidates against the app's real features and live Apple Ads
   popularity, impressions, search terms, conversion, and value evidence.

Do not use `refresh_project_data`, App Store Connect update tools, tracked-keyword
mutations, or Search Ads create/update tools under a read-only ASO request. A
Kickstart Apple Ads report or mutation is an Apple Ads operation: explicitly pass
the approved ad-account ID, reapply the private organization guard, and stop if
the tool would fall back to Kickstart's selected account. If Kickstart is missing
or rate-limited, preserve the gap instead of silently replacing it with a vendor
promoted by a case-study video.

## Budget and bid math

Calculate and show the assumptions instead of selecting a round number:

- `TTR = taps / impressions`
- `tap-through CR = tap-through installs / taps`
- `average CPT = spend / taps`
- `tap-through CPA = spend / tap-through installs`
- `ROAS = attributed net revenue / spend`
- `economic max CPT = target CPA x expected tap-through CR`

Use net value appropriate to the product: account for proceeds after platform
fees and taxes when known, trial-to-paid conversion, refunds, churn, and the time
horizon used for customer value. Never use gross lifetime value without naming
its uncertainty.

For current daily-budget campaigns:

- monthly exposure is bounded by `daily budget x 30.4` under Apple's current
  rule, although spend on an individual opportunity day may exceed the average;
- an end-dated campaign will not spend more than `campaign days x daily budget`
  under the current rule;
- changing a daily budget mid-month changes the remaining monthly calculation;
- campaigns that used lifetime budget were paused in June 2026, so do not design
  a new safety plan around that retired setting.

Recheck these rules immediately before a paid write. To use promotional credit,
verify top-level eligibility and expiry on the scoped Billing page and calculate
remaining balance from applied invoices. Record the latest invoice cutoff because
that balance is not real-time. Confirm that the requested amount is denominated
in, or explicitly converted to, the account currency.

For a credit-only test, calculate a conservative exposure bound:

- add spend posted after the invoice cutoff and all known unbilled or later spend;
- add the maximum remaining exposure through the end date of every active
  campaign sharing the account, including the proposed campaign;
- add a declared reserve for reporting latency and the longest monitoring gap;
- require the result to remain strictly below eligible, unexpired credit.

An active campaign without an end date makes that future exposure unbounded for
this purpose. Pause or end it and verify the state, or do not promise credit-only
operation. Credit can expire or change under its terms and can require a valid
payment method. Neither an invoice-derived balance nor monitoring is a hard stop.

## Campaign and keyword structure

For Manage Bids search-results work, use the smallest structure that keeps
economics interpretable:

| Theme | Starting control | Purpose |
| --- | --- | --- |
| Brand | Exact keywords, Search Match off | Measure and defend direct app or company intent. |
| Category | Relevant exact keywords, Search Match off | Test nonbrand feature and need intent. |
| Competitor | Relevant exact keywords, Search Match off | Isolate similar-app intent and policy risk. |
| Discovery broad | Relevant prompts in broad match, Search Match off | Find related search terms without mixing automated matches. |
| Discovery automatic | No explicit keywords, Search Match on | Mine searches from app metadata and related App Store signals. |

Use exact negatives from the controlled campaigns in discovery when needed to
reduce overlap. Review search terms and promote a relevant, economically proven
term into the controlled exact group. Negative exact blocks only the precise term;
negative broad requires all included words and does not necessarily block every
variant, so verify the actual behavior in current documentation.

Before adding recommendations, normalize and deduplicate them against existing
exact and broad keywords, check negative-keyword conflicts, and respect the
current 5,000-keyword limit per ad group. New keywords default to broad match and
inherit the ad group's default max CPT unless explicitly overridden. Read that
effective bid before the write. A saved keyword's match type cannot be edited;
changing it requires pausing the old keyword and adding a new one, each under the
approved mutation scope. Create new paid objects paused when supported, verify
their keyword text, match type, bid, parent, and status, then gate activation as a
separate write.

A single-country campaign improves budget isolation and simplifies country-level
analysis. A multi-country campaign still exposes country dimensions and reduces
management when language and customer value are similar. Neither structure is
universally required. When countries differ in currency value, localization,
regulation, seasonality, or target CPA, isolate them rather than averaging away
the signal.

## Audience and creative

Start with compatible devices and Reach All Eligible Users unless the product
contract requires narrower targeting. Age, gender, customer type, device, and
location refinements can reduce reach. Age or gender refinement also excludes
people with Personalized Ads turned off. Under Apple's current rules, an ad group
using age or gender refinement receives only an `attribution: false` response
rather than campaign detail from AdServices, and custom-product-page deep links
are disabled for that ad group. Treat a narrow audience as a separately measured
hypothesis and recheck this behavior before use.

When the New Users customer type is first applied, Apple's current guidance says
it can take up to seven days to exclude previous downloaders, so redownloads may
appear temporarily. An ad group can also go on hold when the eligible audience
falls below the current minimum. Record that warm-up and threshold risk instead
of interpreting the first days as a clean new-user cohort.

Map each keyword theme to what the customer sees first. Use the default ad when
the default App Store page already matches the intent. Use an approved custom
product page and ad variation when a meaningful theme needs different screenshots,
promotional text, preview video, or deep link. Product-page creation, localization,
review submission, and metadata keywords belong to App Store Connect authority,
not Apple Ads authority.

## Performance decisions

Record a baseline before changing anything. Use the same time zone, countries,
attribution type, and report window in comparisons.

| Signal | Diagnose first | Possible bounded test |
| --- | --- | --- |
| No impressions | Object status, app/placement eligibility, keyword relevance, popularity, audience reach, bid, and budget. | Correct the blocking layer or test one justified bid/reach change. |
| Impressions, low TTR | Search intent, broad or automatic query quality, visible creative, and localization. | Add negatives, narrow the term, or test a better-aligned page. |
| Taps, low install CR | Product-page promise, screenshots, compatibility, reviews, locale, and loading. | Test one page or targeting hypothesis before buying more taps. |
| Installs, weak activation/revenue | Attribution, onboarding, paywall, pricing, trial and retention. | Fix or test the product funnel; a larger ad budget does not repair it. |
| CPA above cap after delay/sample | Search term, match source, value event, and statistical noise. | Lower the bid, pause the loser, or move a useful term to exact. |
| CPA/ROAS inside target with constrained reach | Impression share, popularity, budget utilization, and bid insights. | Increase one bid or budget gradually and remeasure economics. |

Suggested bids are reference points based on current auction signals. Dynamic
pricing also considers relevance, competing bids, user experience, reserve
price, and other factors; it is not a simple second-price rule. Low impression
share can indicate opportunity but does not by itself prove that another bidder
is the only cause.

Wait at least the platform's initial data delay and the app's conversion delay,
then require a sample appropriate to the decision. A rare subscription purchase
needs more evidence than a tap. Define a stop-loss in the same unit as the target,
for example authorized spend per zero-value keyword, rather than using “no sale”
after an arbitrary number of days.

## Attribution and reporting record

Apple Ads reporting currently counts tap-through installs within 30 days and
view-through installs within one day. Measurement providers can use first-open
events, different windows, and different redownload rules. State which source
supports every number.

AdServices can provide campaign, placement, ad-group, and keyword-level context
for eligible attribution. Search Match attribution omits `keywordId`; evaluate
its post-install value at campaign or ad-group level and use Apple's Search Terms
report for discovery. Do not claim a deterministic user-revenue-to-search-term
join that the payload cannot support. Join only available context to privacy-safe
product events and revenue using stable campaign, ad-group, and keyword
identifiers. Do not store tokens or device-identifying data in reports, PRs, or
skill artifacts.

For each decision, record:

- retrieval timestamp, reporting time zone, currency, date range, and attribution
  source/window;
- scoped organization, account, app, campaign, ad group, keyword/search term, and
  ad IDs without credentials or unrelated account inventory;
- impressions, taps, TTR, installs by type, CR, spend, average CPT/CPA, impression
  share when available, and the product value event;
- hypothesis, approved before/after values, total exposure and stop condition;
- server read-back state and the next review condition.

## Current official references

- https://developer.apple.com/documentation/apple-ads-platform-api
- https://developer.apple.com/documentation/adservices/
- https://developer.apple.com/videos/play/tech-talks/110358/
- https://developer.apple.com/videos/play/wwdc2026/205/
- https://developer.apple.com/videos/play/wwdc2025/328/
- https://developer.apple.com/videos/play/wwdc2024/10063/
- https://developer.apple.com/videos/play/wwdc2021/10295/
- https://developer.apple.com/videos/play/wwdc2024/10060/
- https://developer.apple.com/videos/play/wwdc2025/221/
- https://ads.apple.com/app-store/certification
- https://ads.apple.com/app-store/help/campaigns/0056-structure-campaigns
- https://ads.apple.com/app-store/help/campaigns/0006-understand-search-match
- https://ads.apple.com/app-store/help/keywords/0014-add-and-manage-keywords
- https://ads.apple.com/app-store/help/keywords/0059-understand-keyword-match-types
- https://ads.apple.com/app-store/help/bids-and-budget/0062-set-and-adjust-bids
- https://ads.apple.com/app-store/help/bids-and-budget/0016-manage-budgets
- https://ads.apple.com/app-store/help/reporting/0023-reporting-options-and-definitions
- https://ads.apple.com/app-store/help/reporting/0007-tips-for-solving-performance-issues
- https://ads.apple.com/app-store/help/attribution/0028-measuring-ad-performance
- https://ads.apple.com/app-store/help/attribution/0027-mobile-measurement-providers
- https://ads.apple.com/app-store/help/ad-groups/0021-modify-audience-settings
- https://ads.apple.com/app-store/help/ads/0077-create-ad-variations
- https://ads.apple.com/app-store/help/billing/0032-apple-ads-promo-credit
- https://ads.apple.com/app-store/help/apple-ads-basic/0001-compare-apple-ads-solutions

## Selected third-party ASO source

- https://www.kickstart.tools/mcp
- https://www.kickstart.tools/
