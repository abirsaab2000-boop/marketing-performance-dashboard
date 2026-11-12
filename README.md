# Marketing Performance Dashboard

A static web dashboard of an agency's GoHighLevel leads, pipeline, conversion and closed revenue, split by lead source.

- `site/` is the page. It reads four JSON files from `site/data/`.
- `scripts/pull.ps1` pulls contacts and opportunities from the GoHighLevel API.
- `scripts/build.ps1` turns that pull into the four data files. They hold only dates, sources, stages, statuses and deal values: no names, contact details or record ids.
- `.github/workflows/refresh.yml` runs both scripts every Monday at 04:00 UTC and publishes `site/` to GitHub Pages. It also runs on every push and from the Actions tab ("Run workflow").

## Settings

Repository secrets (Settings > Secrets and variables > Actions):

- `GHL_TOKEN`: GoHighLevel Private Integration Token (read-only contacts, opportunities, locations)
- `GHL_LOCATION_ID`: GoHighLevel sub-account (location) id

Optional repository variables:

- `PAID_START_DATE`: `YYYY-MM-DD` the paid campaigns started (otherwise the last 13 weeks)
- `GHL_PIPELINE_NAME`: pipeline to report on (default `Sales Pipeline`)

Paid sources are listed in `PAID_SOURCES` at the top of the script in `site/index.html`.

## Run locally

Put `GHL_TOKEN` and `GHL_LOCATION_ID` in a `.env` file at the repo root (it is git-ignored), then:

```powershell
./scripts/pull.ps1; ./scripts/build.ps1
```

and serve `site/` with any static file server.
