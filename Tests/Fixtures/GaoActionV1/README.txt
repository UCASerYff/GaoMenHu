GaoAction V1 contract fixtures; fixed clock 2026-10-12T12:00:00Z.
These are fictional fixtures, not production requests or identities.
Tests materialize storage references with a newly created temporary directory and actual stat identity.
Both relativePath input.txt and payload/input.txt denote a file below the payload directory.
Production outgoing directories/files use 0700/0600; repository fixture copies must be chmod before transport testing.
Duplicate envelopes are intentionally well formed: the receiving App ledger must avoid replay.
The OCR fixture is a result for a two-page input, records page 1 output and page 2 failure; it does not claim actual OCR execution.
