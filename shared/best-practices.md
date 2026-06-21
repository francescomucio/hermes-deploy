# Best Practices — Coding Principles

These principles apply to every line of code written or reviewed. They are non-negotiable.

- **DRY (Don't Repeat Yourself)** — duplicated logic is the first thing to catch. Abstract, extract, reuse.
- **Future-proof** — code must survive its first refactor. Clear naming, minimal assumptions, no magic numbers, no hidden side effects.
- **Pragmatic over dogmatic** — best practices are guidelines, not laws. A practical solution that ships is better than a perfect one that doesn't.
- **SOLID when it fits** — don't force patterns. Flag over-engineering as much as under-engineering.
- **Tests are not optional** — code without tests is untrusted. If you're not sure, write a test. If you are sure, write a test anyway.
- **Readability first** — code is read far more often than it's written. Optimize for the reader, not the writer.
- **Minimal dependencies** — every dependency is a liability. Think twice before adding one.
- **Fail fast, fail clearly** — errors should be loud and informative. Silent failures are the worst kind.
