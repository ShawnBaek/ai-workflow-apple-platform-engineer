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
   guarantees. Their revenue claims, starting budgets, bid steps, thresholds, and
   country tiers are not rules, and a video that promotes a vendor does not
   justify adopting it.

## Official Apple video scope

Apple-authored videos explain workflows and product intent, but do not replace
current Apple Ads Help, Platform API documentation, or live account read-back.
Record each session's year, preserve older product names when quoting it, and
recheck every count, limit, field, and availability claim before acting.

| Session | Use it for | Not evidence for |
| --- | --- | --- |
| [Get started with app discovery and marketing](https://developer.apple.com/videos/play/tech-talks/110358/) | The closest official end-to-end campaign overview: placement, market, daily budget, max CPT, Search Match versus managed keywords, audience, ad variations, reporting | Current defaults; its numbers, labels, and limits are presentation-time context |
| [Enhance your presence on the App Store — WWDC26](https://developer.apple.com/videos/play/wwdc2026/205/) | Creative assets, Asset Library, custom product pages, Product Page Optimization, Apple Ads Platform API setup automation | Keyword selection, bid economics, structure, or budget control; confirm an announced capability is live for the placement |
| [What’s new in App Store Connect — WWDC25](https://developer.apple.com/videos/play/wwdc2025/328/) | Keywords associated with custom product pages for organic search | Paid Apple Ads keyword bids; the associations stay under App Store Connect authority |
| [What’s new in App Store Connect — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10063/) | Custom-product-page deep links in Search Results and Today tab ad variations | Authority to create, edit, submit, or publish the App Store Connect page |
| [Get ready to optimize your App Store product page — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10295/) | Historical custom product page and Product Page Optimization background | Current counts, metadata, review, or analytics behavior |
| [Meet AdAttributionKit — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10060/), [What’s new in AdAttributionKit — WWDC25](https://developer.apple.com/videos/play/wwdc2025/221/) | Privacy-preserving attribution implementation | Apple Ads campaign settings, keywords, bids, budgets, or account operations |

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

Recheck these rules immediately before a paid write. For promotional credit, feed
these exposure figures for the proposed campaign and every active campaign
sharing the account into the credit-only bound in the skill entry point.

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

Keyword write checks: before adding a keyword or recommendation, normalize and
deduplicate it against existing exact and broad keywords, check negative-keyword
conflicts, and respect the current 5,000-keyword limit per ad group. New keywords
default to broad match and inherit the ad group's default max CPT unless
explicitly overridden. Read that effective bid before the write, and verify that
the campaign daily budget satisfies the current API constraint relative to the
ad group's default bid. A saved keyword's match type cannot be edited; changing
it requires pausing the old keyword and adding a new one, each with fresh
approval under the mutation steps in the skill entry point.

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
promotional text, preview video, or deep link; its creation and metadata stay
under App Store Connect authority.

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

## Additional official references

The skill entry point lists the core sources; the videos are linked above.

- https://ads.apple.com/app-store/help/keywords/0014-add-and-manage-keywords
- https://ads.apple.com/app-store/help/reporting/0007-tips-for-solving-performance-issues
- https://ads.apple.com/app-store/help/attribution/0027-mobile-measurement-providers
- https://ads.apple.com/app-store/help/ad-groups/0021-modify-audience-settings

## Selected third-party ASO source

- https://www.kickstart.tools/mcp
- https://www.kickstart.tools/
