# MacDPI development handoff

Updated November 5, 2026. The base 0.1.0 source, tests and uncommitted project files were preserved in local checkpoint `192f7c4` on `codex/system-integration`.

The next revision integrates two embedded system extensions and the approval-aware app model. The primary mode is Mac-wide traffic handling. Local CONNECT remains available for diagnostics and is protected by a per-launch credential. The current scope and exact verification evidence are in the engineering report and test results. [Engineering report](FINAL_REPORT.md), [test results](../TEST_RESULTS.md).

The next external milestone is an authorized Developer ID build and installation on a test Mac. The active keychains had no valid code-signing identities at inspection time, and matching profiles were unavailable. Once the owner supplies the signing setup, follow the recorded approval, rollback and native acceptance sequence. [Installed acceptance plan](NETWORK_SETUP_PLAN.md).
