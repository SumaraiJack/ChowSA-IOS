# ChowSA — Play Console listing copy (draft)

Drop straight into the Google Play Console listing form. Edit as needed
before publishing.

---

## App name (max 30 chars)
ChowSA

## Short description (max 80 chars)
Recipes, shopping, load-shedding and braai — the SA kitchen, in one app.

## Full description (max 4000 chars)

ChowSA is the kitchen sidekick built for South Africa.

Scan or paste any recipe link and our AI pulls the ingredients,
instructions, and serving size into a clean card you can save, share,
or shop from. Plan the week's meals, build a smart shopping list with
live SA price estimates, and check whether load-shedding is about to
hit your suburb before you start a slow braise.

What's inside:

🔥 Local Braai Hub — daily braai recipe of the day, live banter with
   braai masters in your area, and load-shedding-aware cook times so
   you always know if the coals or the oven is the better bet tonight.

🛒 Smart Shopping Lists — auto-grouped by aisle, R-priced against South
   African shelves, and shareable with the household in one tap. PDF
   export for the gogo who still likes a printed list.

📦 My Pantry — track what you've actually got so the planner stops
   suggesting recipes that need three things you don't.

🗓️ Meal Planner — drag recipes into the week, see the full grocery
   roll-up, and let the planner handle "what's for dinner" forever.

👥 Community Hub — your local What's Cooking, Spotted (food trucks &
   pop-ups), The Pantry (grocery deals), Gatherings (markets & potjies),
   and the Braai Banter feed. All filtered to your suburb.

⚽ FIFA World Cup 2026 Stadium — live scores, live banter, and a daily
   Bafana watch list.

🤖 AI Recipe Scraper — paste any recipe URL, get a clean card. Camera
   scan for handwritten or printed recipes too.

ChowSA Pro unlocks unlimited AI scrapes, premium recipe packs, the
priority Local Hub experience, and an ad-free interface.

Built in Cape Town for South African kitchens. Load-shedding, hek-en-
muur prices, and a proper boerie roll — all baked in.

## Promo text (max 170 chars, optional but recommended)
Scan a recipe, build your week's shopping, and never get caught by
load-shedding mid-bake. ChowSA — the South African kitchen, all in
one app.

## Category
Food & Drink (primary)

## Tags
recipes, meal planning, shopping list, South Africa, braai,
load-shedding, AI, community

## Contact email
TODO — fill in support address before submission.

## Privacy policy URL
TODO — fill in after deploying `marketing/site/privacy.html` to public host.

## Account deletion URL
TODO — fill in after deploying `marketing/site/delete-account.html`.

## Screenshot picks (from marketing/screenshots/)

Recommend selecting these 6 in this order for the phone listing carousel:
1. Home dashboard — "What's cooking this morning" + Seasonal in SA.
2. Local Braai Hub — recipe of the day + chat.
3. Recipe detail with ingredients/instructions.
4. Smart Shopping List with prices.
5. Meal Planner week view.
6. Community Hub — Table View categories.

(Curate the final shortlist from the 15 captures already in
 marketing/screenshots/.)

## Feature graphic (1024 × 500)
TODO — design at `marketing/play-store/feature-graphic.png`.
Suggested concept: forest green background, gold protea accent, the
"ChowSA" wordmark, and three phone mockups fanned out showing recipe,
shopping list, and the Braai Hub.

## Data Safety form — what to declare

| Data type | Collected? | Shared? | Required? | Purpose |
|---|---|---|---|---|
| Email | Yes | No | Yes | Account management |
| Approx. location | Yes | No | No | Local Hub + load-shedding |
| Precise location | Yes | No | No | Spotted pin (optional) |
| Photos | Yes | No | No | Recipe scan + chat photo |
| App activity (interactions) | Yes | Yes (AdMob) | No | Ads |
| Device IDs | Yes | Yes (AdMob) | No | Ads |
| Crash logs | Yes | Yes (Crashlytics) | No | Stability |

Encryption in transit: Yes (HTTPS to Supabase, Gemini, AdMob).
Users can request deletion: Yes — see in-app Settings → Delete Account,
and the hosted `delete-account.html`.

## Generative AI disclosure
Yes — ChowSA uses Google Gemini to parse recipe URLs and price
estimates. AI output is clearly labelled in-app and never used to
generate disallowed content (no minors, no medical/financial advice).
