# Changelog

## 1.0.0 - 2026-08-28

- First release: watch a list of sites from the Omarchy bar, with an optional
  health check path per site and its own check interval per site.
- Edit mode per site behind the pencil button (or `e`): name, address, path,
  interval, expected status, failure threshold, and paused state, with Save and
  Cancel and nothing written until you save.
- Desktop notification when a site goes down and when it comes back; clicking
  either opens the site. A site is only down after a configurable number of
  consecutive failures, so one flaky check never alerts.
- Outage history per site, hidden until the row is clicked: when it started,
  how long it lasted, and what the failure was.
- Bar icon (a pulse) stays quiet while everything answers and turns urgent when
  it does not; it can be hidden entirely until something breaks.
- The header leads with how many sites are up, and every row says when its
  reading was taken.
- Checks run in one background service rather than once per monitor.
