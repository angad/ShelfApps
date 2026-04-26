# Attributions

This repository's source code is released under the MIT License in `LICENSE`.
Third-party data, services, trademarks, and media referenced by the apps remain
subject to their own terms.

Last reviewed: 2026-04-26.

## General Notes

- The MIT License applies to this repository's original code and documentation only.
- App Store, Apple, iOS, iPhone, UIKit, AVKit, CoreLocation, CoreMotion, and other Apple names or SDKs are trademarks or software from Apple and are not licensed by this repository.
- External APIs and camera feeds may change availability, rate limits, licensing, attribution requirements, and commercial-use rules without notice.
- Do not commit API keys, cookies, device identifiers, generated app bundles, generated IPAs, or local diagnostics.

## OverheadFlight

- ADSB.lol live aircraft API and globe links: https://www.adsb.lol/ and https://api.adsb.lol/
  - ADSB.lol describes itself as open data and says data is freely available via API and historical archive.
  - ADSB.lol historical datasets are published under ODbL/CC0 terms; the API source repository is BSD-3-Clause.
  - Keep visible attribution to ADSB.lol when displaying live flight data.
- ADSBdb aircraft and route metadata: https://api.adsbdb.com/ and https://github.com/mrjackwills/adsbdb
  - ADSBdb source is MIT licensed, but its README credits third-party sources including PlaneBase, airport-data, and route data by David J. Taylor and Jim Mason.
  - Do not treat ADSBdb's underlying aircraft, photo, or route data as MIT-licensed repository content.
- Planespotters.net aircraft photos: https://www.planespotters.net/ and https://www.planespotters.net/legal/termsofuse
  - Aircraft photos are third-party content uploaded by photographers under Planespotters.net terms.
  - Show photo/source attribution when displaying these images, and avoid bundling or redistributing downloaded photos.

## Bookshelf

- Goodreads metadata, ratings, cover URLs, and links: https://www.goodreads.com/ and https://www.goodreads.com/about/terms
  - Goodreads grants only limited access under its terms and reserves rights in Goodreads content.
  - Goodreads terms restrict collection/use of book listings and similar data and restrict data mining, robots, and similar extraction tools.
  - The current app uses a public autocomplete endpoint; this should be treated as a personal/local integration, not a broadly redistributable data source.
- BookScouter API reference in documentation: https://bookscouter.com/
  - Mentioned as a possible pricing provider only; API access requires separate signup and terms.

## CityCams

CityCams fetches public traffic camera metadata, still images, and HLS streams from transportation-agency and 511 traveler-information systems. The app should identify the source provider in the UI when camera feeds are shown.

Provider sources currently wired in code:

- Virginia 511 / VDOT: https://511.vdot.virginia.gov/
- California Caltrans CWWP2: https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm
- Delaware DelDOT Traffic Cameras: https://deldot.gov/Traffic/travel_advisory/
- FL511 Cameras: https://fl511.com/
- Iowa DOT / 511 Iowa Cameras: https://www.511ia.org/
- Travel Midwest / Illinois traffic cameras: https://www.travelmidwest.com/
- Kentucky GoKY traffic cameras: https://goky.ky.gov/
- Michigan MDOT Mi Drive: https://mdotjboss.state.mi.us/MiDrive/map
- Missouri MoDOT Traveler Information: https://traveler.modot.org/map/
- Montana 511 Cameras: https://www.511mt.net/
- DriveNC / NCDOT cameras: https://drivenc.gov/
- North Dakota Travel Information: https://travel.dot.nd.gov/
- New Mexico Roads: https://nmroads.com/
- OHGO cameras: https://www.ohgo.com/
- Oregon TripCheck cameras: https://www.tripcheck.com/
- South Carolina 511 cameras: https://www.511sc.org/
- South Dakota 511 cameras: https://sd511.org/

State flag thumbnails:

- Generated from Flagcdn/Flagpedia U.S. state flag PNGs: https://flagcdn.com/ and https://flagpedia.net/
- Flagcdn says its flags are based on Wikimedia Commons vector files and appreciates a backlink to Flagpedia.
- Flagpedia's terms say flag images are public domain and free for commercial and non-commercial use.

State DOT and 511 feeds are public-facing feeds, but each provider may have its own terms for automated access, attribution, caching, embedding, commercial use, and redistribution. Review the current provider terms before publishing a public binary or operating a hosted derivative service.

## ParkCams

- National Park Service Data API: https://www.nps.gov/subjects/digital/nps-data-api.htm
- NPS developer guides and rate limits: https://www.nps.gov/subjects/developer/guides.htm
- NPS disclaimer and ownership guidance: https://www.nps.gov/aboutus/disclaimer.htm
- NPS public webcam pages: https://www.nps.gov/

NPS states that the Data API is open to developers. NPS developer guidance requires an API key, says API keys should be kept private, and documents default rate limits. NPS disclaimer guidance says NPS-created website materials are generally public domain unless otherwise indicated, but some materials may have third-party rights; acknowledgement of NPS as source is appreciated.

When ParkCams displays NPS-derived park metadata, images, webcam links, or direct feeds, credit the National Park Service as the source. Do not use the NPS Arrowhead or other NPS marks without permission.

Some direct streams are parsed from NPS pages and may be hosted by third-party services such as Pixelcaster. Those feeds remain subject to their respective source and host terms.

## NetworkWall and DriveDash

These apps primarily use local-device APIs and local network data. No external data provider attribution is currently required beyond Apple platform APIs and local network/device permissions.
