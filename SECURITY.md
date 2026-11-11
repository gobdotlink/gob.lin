# Security

Do not post API keys, dictation audio, private transcripts, or exploitable vulnerabilities in public issues. Use the repository's GitHub private vulnerability reporting feature when available. If it is unavailable, contact the repository owner privately through their GitHub profile to arrange a secure report.

Reports should include affected versions, reproducible steps using synthetic data, expected impact, and suggested mitigations. Never include a live credential to demonstrate a finding.

Development builds use a local signing identity. Releases are signed with Developer ID and notarized, and the updater installs only a release that matches the installed app's signing identity.
