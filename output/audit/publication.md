# Publication assessment

Reviewed October 4, 2026, with publication preparation, the [follow-up audit](follow-up-audit.md), and [bundled-data removal](real-data-only.md) checked October 7. Main has one `green flag` root commit with an empty body. Commit IDs and history counts in earlier reports describe the former private history or earlier publication snapshots.

The code and privacy review found no reason by itself to keep the source private. Publishing the original MIT code as a noncommercial hobby project is a reasonable choice if the maintainer accepts the unresolved provider-data risk. This is a practical recommendation, not legal clearance or a promise that a complaint can only lead to a repository takedown.

## What the audit establishes

The final commit check covered every tracked file, commit metadata, the research PDF, and the icon. It found no exposed credentials, private owner-home paths, unintended files, submodules, symlinks, or private binary metadata. The only credential-like URLs were dummy values in rejection tests. Pattern scanning cannot prove that every string is harmless. The original code has an MIT license; downloaded provider data keeps its separate terms in [third-party notices](../../THIRD_PARTY_NOTICES.md). No provider dataset is included in the current source tree or app. The [current validation record](real-data-validation.json) identifies the bundled-data removal checks. The [follow-up record](follow-up-validation.json) and [preceding record](fresh-validation.json) preserve earlier source and publication snapshots.

The app has no direct live timing connection, paid-feed bypass, race video, team radio, bundled official logo, or race-data proxy. Completed recordings download to each user's Mac. The native archive reader is independently implemented; no FastF1 runtime or provider client is vendored. Original icon generation is in the repository.

Squashing the five private commits removed the older live implementations from main's reachable history. This does not promise erasure of old Git objects from backups, reflogs, or server retention. The 12 provider JSON files that earlier audits checked were subsequently removed from the source tree and app. Synthetic inputs remain confined to tests and the separate benchmark. The original icon is unchanged. Research text, PDF text and metadata, and icon metadata passed the privacy checks; provenance review cannot establish the origin of every authored line or grant upstream rights.

## Remaining rights questions

In the United States, copyright does not protect facts, although it can protect their expression. That distinction supports using numerical race facts, but does not establish permission for every archive, compilation, asset, or service-access method. [U.S. Copyright Office](https://www.copyright.gov/help/faq/faq-protect.html)

[OpenF1](https://openf1.org/) describes free historical access and noncommercial fan use, and disclaims ownership of Formula 1 data. [Jolpica's terms](https://github.com/jolpica/jolpica-f1/blob/main/TERMS.md) license its API data under CC BY-NC-SA 4.0 and require respecting rate limits. Those provider statements do not settle every upstream right.

[Formula 1's guidelines](https://www.formula1.com/en/information/guidelines.4EOKE9RRqevL4niTK9kWyt) assert rights over timing data and restrict its use in apps. Paddock still reads completed files under `livetiming.formula1.com/static/`. Replay-only access reduces exposure from direct live feeds; it does not resolve those stated restrictions. A public endpoint returning HTTP success is not a license.

No criminal activity was identified by this code audit. That finding is narrower than a legal opinion. Noncommercial use is not a blanket exemption: copyright infringement can have civil remedies, and criminal infringement has additional statutory requirements. The audit does not determine whether any particular claim would succeed. [17 U.S.C. §§ 504–506](https://www.copyright.gov/title17/92chap5.html)

[GitHub's DMCA policy](https://docs.github.com/en/site-policy/content-removal-policies/dmca-takedown-policy) provides a notice and removal process and retains discretion to terminate accounts for infringement. Responding promptly to a complaint is sensible, but neither removal nor making the repository private guarantees that a claim disappears. The policy supplies no assurance of zero account or legal consequences.

The MIT license covers the owned code. Provider notices describe the separately downloaded data. Keep those notices with redistribution, avoid implying official affiliation, and address any concrete complaint rather than treating this audit as permission from a rights holder.
