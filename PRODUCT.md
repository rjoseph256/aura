# Product

## Register

product

## Users

Everyday and recreational cyclists in Pittsburgh: commuters and casual trail/path
explorers riding for pleasure or transport, not hardcore fitness training. Built
first for the author and a small friend group. In-ride context is a phone mounted
on handlebars in sunlight; out-of-ride context is quick planning at home or curbside.

## Product Purpose

Aura plans bike-aware routes (Most paths, Fastest, Flattest), gives turn-by-turn
voice navigation in a glanceable HUD, and records rides. The growth path is social:
led group rides with live peer presence, later in-ride voice. Success is a rider
trusting it for every ride without fiddling.

## Brand Personality

Instrument cluster, not fitness dashboard. Dark, calm, precise. One electric lime
accent (#C8FA4B) on near-black; pink reserved for ending a ride. Two voices: Saira
Condensed numerals for the cockpit, SF Pro Rounded for the chrome.

## Anti-references

- Strava-style fitness-metric density and leaderboard energy.
- Gradients of any kind (the aurora identity was retired deliberately).
- Generic SaaS card grids; light-mode map defaults.

## Design Principles

- Glanceable in sunlight: large numerals, high contrast, nothing precious mid-ride.
- The tool disappears into the ride; chrome is quiet, the map leads.
- One accent, spent only on action and state, never decoration.
- Consistency over surprise across screens; delight lives in moments (count-ups,
  the ring), not layouts.
- Every visual choice flows from AuraTheme tokens; no improvised values.

## Accessibility & Inclusion

Dynamic Type everywhere with @ScaledMetric on HUD numerals; composed VoiceOver
labels on cockpit elements; Reduce Motion and Reduce Transparency honored; WCAG
contrast asserted in CI via AuraPalette/WCAGContrast unit tests; scoped
Increase Contrast path on map-floating surfaces.
