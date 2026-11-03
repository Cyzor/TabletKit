# Security policy

## Reporting a vulnerability

Don't open a public issue for a security problem. Use GitHub's private vulnerability reporting instead: [Report a vulnerability](../../security/advisories/new).

Describe the problem, how to reproduce it, and the TabletKit version or commit you tested. Expect an acknowledgment within a few days.

## Scope

TabletKit parses HID reports and descriptors from devices plugged into the Mac. In scope: a crafted report or descriptor that crashes the host app, reads or writes out of bounds, or makes TabletKit send output reports the caller didn't ask for. Out of scope: anything that needs code already running on the Mac.
