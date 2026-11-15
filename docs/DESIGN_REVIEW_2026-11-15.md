# Design and content review — 15 November 2026

## Direction

Make Odds Edge feel current through clear hierarchy, confident typography,
responsive layouts and useful content. The owner's preference is a simple
feed with depth on tap. Personal bet logging, outcome entry and record-led
engagement remain outside the product direction.

The main task stays consistent: find a game or player, inspect the evidence,
understand the price and compare alternatives. Optimize for completing that
task and understanding the information, not time spent or number of bets.

## Implemented in this pass

- **Ink and iris visual system.** Deep ink surfaces, a restrained iris
  interaction accent and quieter borders. Mint, amber and coral retain
  labeled value meanings. Sans-serif type carries the interface; the serif
  wordmark remains a distinct brand element. Numerical figures stay aligned.
- **Responsive research layout.** Phone cards remain a readable single
  column. Wider layouts use two research columns when space and text size
  permit. Larger text returns to one column rather than compressing cards.
- **A browsable schedule.** Games are grouped by Eastern game date with
  date controls, clear kickoff information and consistent fixture cards.
  The schedule's heading and visible games derive from upcoming events.
- **A quieter source bar.** Actual schedule and sample research are explicit
  modes. A compact status uses “Checked” for a retrieval time, with source
  details behind a disclosure. Failed updates and outdated schedules remain
  visible. Repeated missing-price explanations are reduced.
- **Cleaner cards and copy.** Keep the earlier removal of explanatory
  matchup sentences from feed cards. Probability labels distinguish model
  estimates from the fee-free market. Deeper reasoning stays inside the
  prop detail, rather than becoming another feed paragraph.
- **Independent evidence provenance.** Prop details expose a compact Data
  sources control. The disclosure separates box-score coverage and
  retrieval, stored snaps, stored injury context and current availability
  checks. Unknown dates and future timestamps do not become freshness claims.

The visual references reviewed for this pass are
[Apple's Materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
and [Material's typography guidance](https://m3.material.io/styles/typography/applying-type).
They inform the design direction; this review does not claim a particular
palette scientifically increases engagement.

## Content-aging finding

At review time, the player box-score file records coverage through
**2026-11-09**. The bundled matchup file reports **2026 snaps through Week 9**
and **stored injuries through Week 10**, but records **no calendar cutoff or
retrieval timestamp**. A stored week is useful provenance; it does not
establish a calendar date or confirm current availability.

Schedule publication and historical evidence have different refresh paths.
A newly checked schedule must never imply that player, matchup, injury or
model evidence was also refreshed. This pass makes that distinction visible.
It does not add the missing historical/matchup exporters or claim those
pipelines are fixed.

## Content maintenance roadmap

1. **Build repeatable evidence exporters.** Refresh historical games and
   matchup/snap/injury context from approved sources. Write source identity,
   coverage cutoff, retrieval timestamp, season and revision/version
   metadata. Keep unavailable fields unknown; never substitute file time or
   the current schedule timestamp.
2. **Keep freshness independent.** Define source-specific age states and
   show the relevant coverage beside the evidence. Retrieval, coverage,
   publication and availability-check times have different meanings. Retain
   explicit failed-update states instead of silently replacing real data
   with examples.
3. **Add dated “what changed” insights.** Useful candidates are descriptive
   workload changes and recent-versus-prior production, with dates, sample
   counts and supporting observations. Publish only when refreshed evidence
   supports the statement, and expire or recompute it when its inputs
   change. No fabricated popularity, “hot picks” or AI confidence scores.
4. **Gate real prices on the provider connection.** The hosted release has
   actual schedule data and separate sample prices. A securely configured
   provider credential and a tested, quota-controlled quote integration are
   still required. Preserve exact-selection matching and separate price
   freshness from every historical evidence timestamp.
5. **Review the complete research journey.** Revisit phone and desktop
   layouts as real coverage arrives, especially empty states, large text,
   keyboard access and return-to-list continuity. Keep model validation and
   assumptions accessible in secondary disclosures. An experimental model
   or newer publication date does not establish a betting edge.

The proposed ensemble, a broader editorial feed and optional alerts remain
separate future decisions. Maintain this document when an exporter, source
contract or content policy changes; do not treat the observed week numbers
above as permanent expected values.
