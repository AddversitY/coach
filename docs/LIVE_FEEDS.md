# Live evidence through Coach

Ask Coach for "latest reporter news", "injury reports for [full player name]",
"weather for [team]", or "market movement for [player]". Evidence stays in the
one-page conversation. Each report includes a source and a date. Web source
links open the publisher; native clients offer copying the link.

## Connected coverage

| Source | Check cadence | What it means |
| --- | --- | --- |
| [ESPN NFL injury listings](https://www.espn.com/nfl/injuries) | Ten minutes, or two minutes when a kickoff is inside 90 minutes | Unofficial player status; only exact name/team matches to recorded QB/RB/WR/TE participants. Not complete roster coverage or confirmation for the next matchup. The answer names the check time, or says unavailable or stale. |
| [ESPN NFL RSS](https://www.espn.com/espn/rss/nfl/news) | Thirty minutes, respecting the feed's TTL | Published headlines, supplied author bylines, original publication dates and source links. No article bodies, private posts, or comprehensive social stream. |
| National Weather Service, then [Open-Meteo](https://open-meteo.com/) | Thirty minutes, or ten minutes inside the last 90 minutes before kickoff | Hourly forecast at the indexed venue, attached to that game and to a prop question about that game. Roof metadata is not live roof confirmation. A failed check says unavailable or stale. The forecast does not change the chance. |
| Published Odds API observations | Existing quota-controlled publication cadence | Saved pregame observations and changes between comparable snapshots. No extra provider requests or increased credit caps. |

The coordinator checks every two minutes, while each provider retains its own
cadence. A fresh coordinator timestamp does not refresh an older source report.
Injury observations expire after twelve minutes; reporter observations after
sixty-five; weather after thirty-five. Prices retain the existing eighteen-hour
and kickoff boundaries. Provider failures preserve original timestamps and use
backoff. Missing injury entries and Active labels never confirm participation.

Injury reports attach only to the next indexed game, and preserve the provider's
original update time. They may refer to a previous matchup. Coach explicitly
states that limitation rather than declaring a player out for the next game.
Report changes withdraw older interpretations and affected experimental analysis.
No automatic injury/news probability adjustment is invented.

Market movement requires the same event, book, provider, market, participant and
side, with an unambiguous line. Re-reading the same snapshot creates no change.
Comparisons preserve both original source timestamps. This is not a verified
opening line, steam, professional bettor identity or positive-EV signal. A page
with no current published quotes correctly waits for the next eligible snapshot.

## Provider adapter for betting shares

Verified sharp-money flow is **not connected**. Public odds do not identify
professional bettors. An authenticated adapter is ready for a provider that
permits this app to display its data. No paid service has been enabled.

Configure server-only `MARKET_INGEST_SECRET` and a comma-separated
`MARKET_ALLOWED_HOSTS` allowlist, then send a bounded request to `/v1/ingest`:

```json
{
  "kind": "market_splits",
  "provider": "Your permitted provider",
  "sourceUrl": "https://your-provider.example/public-source",
  "publishedAt": "an actual ISO-8601 source timestamp",
  "records": [
    {
      "eventId": "an exact current Coach event ID",
      "market": "spreads",
      "outcome": "Buffalo Bills",
      "line": -3.5,
      "betPercent": 40,
      "moneyPercent": 60
    }
  ]
}
```

Use `Authorization: Bearer <server-only secret>`. These example percentages are
contract examples, never deployed data. Up to 100 records are accepted. Timestamps
must be nonfuture and at most thirty minutes old; sources must be HTTPS URLs on
the configured allowlist, without embedded credentials or query strings. Unknown
or started games, invalid percentages and duplicate rows are rejected. No caller
can use the news-ingestion credential for this separate market adapter.

The output is labeled provider-reported betting shares, with sample size and
bettor identity unverified. Handle/ticket divergence still does not establish
sharp-money activity or a betting edge. The UI and AI retain that distinction.
