# Bookshelf

A compact personal library browser for iPhone 6-class devices on iOS 12 and later.

## Screenshot

<p>
  <img src="screenshots/IMG_0400.PNG" alt="Bookshelf personal library browser" width="220">
</p>

## Screens

- Bookshelf: browse, filter, add, edit, and delete owned books.
- Book Details: view metadata, personal notes, shelf location, condition, loan/return books to friends, and links to Goodreads/reviews.
- Scanner: scan an ISBN barcode or type an ISBN manually, then add the matched book.

The first launch seeds the app with the seven Harry Potter books plus `Project Hail Mary`, which is included as a resale-pricing smoke test because ThriftBooks has recently returned a non-zero quote for that ISBN.

## Covers and Ratings

Bookshelf enriches books with a best-effort Goodreads autocomplete lookup by ISBN. When Goodreads returns metadata, the app stores the cover URL, Goodreads book URL, average rating, and rating count locally; cover images are cached on disk so the app can keep showing them later. If the lookup fails or the endpoint changes, the app falls back to its local metadata and drawn cover cards.

## Resale Pricing

The bookshelf has a `VALUE` toggle that enables daily resale-price refreshes. The app is currently configured to call ThriftBooks directly at `https://www.thriftbooks.com/tb-api/buyback/get-quotes/` using a bundled local cookie jar. The request first fetches a CSRF token from `https://www.thriftbooks.com/tb-api/csrf/GetToken`, then posts `{"identifiers":["{isbn}"],"addedFrom":3}` with `X-XSRF-TOKEN`.

BookScouter also advertises Cached Prices, Current Prices, Book Info, and Historic Pricing APIs for buyback pricing, but API access requires signup. The app keeps pricing provider details configurable in `Info.plist`:

- `BKPricingEndpointURLTemplate`: endpoint URL with `{isbn}` where the ISBN should be inserted.
- `BKPricingAPIKey`: optional API key.
- `BKPricingAPIKeyHeader`: request header for the key, defaulting to `Authorization`.
- `BKPricingSourceName`: display name for the provider, currently `ThriftBooks`.
- `BKPricingCookieResource`: local bundled JSON cookie resource, currently `ThriftBooksCookies`.

The client accepts common JSON offer shapes and chooses the highest sell/buyback price it finds, including `$0.00` quotes when a vendor recognizes the book but is not buying it. Pricing refreshes are queued and sent sequentially so the phone does not burst multiple ThriftBooks quote requests at once.

`Bookshelf/ThriftBooksCookies.json` is a local secret generated from `../thrift/api/cookies.json` and is ignored by git. Refresh it when ThriftBooks returns `ThriftBooks login expired`.

## iPhone 6 Launch Sizing

This app includes `Bookshelf/Default-667h@2x.png` plus `UILaunchImageFile` and `UILaunchImages` in `Info.plist`. Keep those in place: without a 667h launch asset, iOS 12 can run the app in legacy letterboxed mode on the iPhone 6.

## Build and Install

From the workspace root:

```sh
scripts/install_usb_unsigned_ios12.sh apps/Bookshelf
```
