# Project context

## Deployment locale

The operator is based in **Europe**. Default to European regions, timezones and
examples in anything deployment-related — do not assume US.

For the Oracle Cloud deployment (`deploy/oracle-cloud/`) this means:

- The tenancy's **home region** is European. It is chosen once at signup and
  **cannot be changed afterwards**.
- Use an EU region in every example, default and fallback suggestion:
  `eu-frankfurt-1` (largest EU region, the safe default), `eu-amsterdam-1`,
  `eu-zurich-1`, `eu-paris-1`, `eu-milan-1`, `eu-madrid-1`, `eu-stockholm-1`,
  or `uk-london-1`.
- When suggesting an alternative region for Always Free ARM capacity, suggest
  another EU one — sending the run to a US region adds latency for no benefit,
  and the tenancy's identity still lives in the home region.

## Repository visibility

`granterogers/YT_Transcribe` is **public**. Nothing personal, and no credential,
cookie file, API token or database, may be committed. `.gitignore` already
excludes `*cookies*.txt`, `*.sqlite3`, the transcript output folders and
`deploy/**/*.env`; keep it that way.

## Platform

The operator drives this from **Windows**, via WSL (Ubuntu 24.04). Shell
instructions must say plainly which prompt they belong to — Windows `cmd` or
the WSL bash shell — because the two are easy to confuse and the deployment
scripts only run in the latter. Windows paths are reachable from WSL under
`/mnt/c`.
