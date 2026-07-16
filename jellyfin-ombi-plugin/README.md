# Jellyfin Ombi Requests Plugin

A Jellyfin plugin that connects to an [Ombi](https://ombi.io/) server so your
users can **search for and request movies and TV shows** without leaving
Jellyfin.

> **Note on direction:** Ombi already integrates *with* Jellyfin for library
> and user sync. This plugin adds the reverse convenience — a request UI *inside*
> Jellyfin that submits to Ombi's request API. It does not replace Ombi; you
> still run Ombi as your request/approval backend.

## Features

- **Admin settings page** — configure the Ombi base URL and API key, with a
  one-click **Test connection** button.
- **User request page** — search movies and TV shows and submit requests.
- **Movie & TV requests** — movies request by TheMovieDb id; shows request by
  TheTvDb id, with a configurable "request all seasons" default.
- **Per-user attribution** — optionally submit requests under the current
  Jellyfin user's name so they appear against the matching Ombi account.

## Requirements

- Jellyfin **10.10+** (targets `net8.0`, ABI `10.10.0.0`).
- A reachable Ombi server and its API key
  (Ombi → *Settings → Configuration → General*).

## Build

```bash
cd jellyfin-ombi-plugin/Jellyfin.Plugin.Ombi
dotnet restore
dotnet build -c Release
```

The compiled plugin is `bin/Release/net8.0/Jellyfin.Plugin.Ombi.dll`.

## Install (manual)

1. Build as above (or download a release `.zip`).
2. Create a folder named `Ombi` under your Jellyfin `plugins` directory, e.g.
   - Linux: `/var/lib/jellyfin/plugins/Ombi/`
   - Docker: `/config/plugins/Ombi/`
   - Windows: `%ProgramData%\Jellyfin\Server\plugins\Ombi\`
3. Copy `Jellyfin.Plugin.Ombi.dll` into that folder.
4. Restart Jellyfin.

## Configure

1. **Dashboard → Plugins → Ombi Requests**.
2. Enter your **Ombi server URL** (e.g. `http://localhost:5000`) and **API key**.
3. Click **Test connection**, then **Save**.

## Use

Open **Dashboard → Plugins → Ombi Requests → Open Ombi Requests**, or navigate
to `/web/#!/configurationpage?name=OmbiRequests`. Search for a title and click
**Request**. Titles already available or already requested are labelled and
cannot be re-requested.

## API endpoints

The plugin exposes these authenticated Jellyfin endpoints (used by the UI, and
usable by your own clients with a Jellyfin token):

| Method | Route | Auth | Description |
| ------ | ----- | ---- | ----------- |
| `GET`  | `/Ombi/TestConnection` | Admin | Verify the Ombi connection. |
| `GET`  | `/Ombi/Search?query=…&type=all\|movie\|tv` | User | Search Ombi. |
| `POST` | `/Ombi/Request/Movie` `{ "TheMovieDbId": 123 }` | User | Request a movie. |
| `POST` | `/Ombi/Request/Tv` `{ "TvDbId": 456, "RequestAll": true }` | User | Request a show. |

## How it talks to Ombi

The plugin calls Ombi's REST API with the `ApiKey` header:

- `GET /api/v1/Status` — connection test
- `GET /api/v1/Search/movie/{term}` and `GET /api/v1/Search/tv/{term}`
- `POST /api/v1/Request/movie` and `POST /api/v1/Request/tv`

When per-user attribution is enabled, a `UserName` header carrying the Jellyfin
username is added so Ombi records the request against that account.

## License

MIT
