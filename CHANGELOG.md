# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## v0.4.1 (2026-08-21)




### Bug Fixes:

* respond on the `conn` returned by `read_body/2` (#1) by Benjamin Milde

## v0.4.0 (2026-08-12)
### Breaking Changes:

* allow lock stores to report service unavailability (#34) by James Harton



### Bug Fixes:

* support all RFC 9110 byte range forms and return 416 (#36) by James Harton

## v0.3.1 (2026-05-09)




### Bug Fixes:

* avoid compile warning when bandit is not available by James Harton

## v0.3.0 (2026-04-21)




### Features:

* emit :telemetry events for requests, backend calls, and lock store calls (#1) by James Harton

## v0.2.1 (2026-04-21)




### Bug Fixes:

* ci: add `runs-on` and fully-qualified URL to reusable workflow caller by James Harton

## v0.2.0 (2026-04-20)




### Features:

* add `mix davy.serve` task and promote in-memory backend to public API by James Harton

## v0.1.0 (2026-04-20)




### Features:

* extract webdav_server from neonfs as davy by James Harton
