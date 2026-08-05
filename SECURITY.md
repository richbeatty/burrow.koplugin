# Security Policy

## Supported versions

Burrow is currently pre-release software. Security and privacy fixes are applied to the latest published version only.

## Reporting a vulnerability

Do not post passwords, catalog tokens, authorization headers, private OPDS URLs, personal file paths, or unredacted logs in a public issue.

For ordinary bugs that do not expose private information, use the repository's bug-report form.

For a vulnerability involving credentials, private catalog access, arbitrary file access, or code execution, contact the repository owner privately through GitHub before publishing details. Include:

- Burrow and KOReader versions
- device and operating system
- reproduction steps
- expected impact
- the smallest safe log excerpt or proof of concept

## Credential handling

Authenticated OPDS catalog information is stored locally by KOReader and Burrow settings. Users should treat the KOReader data directory as sensitive and should review logs before sharing them.

Burrow release packages must not contain:

- user settings files
- OPDS credentials or tokens
- databases or reading history
- device identifiers
- local book or download paths
- private keys

## Scope

Security issues in KOReader itself or an upstream catalog server should be reported to the appropriate upstream project. Burrow's `NOTICE.md` identifies the main upstream components.
