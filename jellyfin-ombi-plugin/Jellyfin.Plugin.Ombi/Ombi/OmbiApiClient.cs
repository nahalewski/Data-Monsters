using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.Ombi.Configuration;
using Jellyfin.Plugin.Ombi.Ombi.Models;
using MediaBrowser.Common.Net;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.Ombi.Ombi;

/// <summary>
/// Default <see cref="IOmbiApiClient"/> implementation backed by <see cref="HttpClient"/>.
/// </summary>
public class OmbiApiClient : IOmbiApiClient
{
    private const string PosterBaseUrl = "https://image.tmdb.org/t/p/w300";

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<OmbiApiClient> _logger;

    private static readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Initializes a new instance of the <see cref="OmbiApiClient"/> class.
    /// </summary>
    /// <param name="httpClientFactory">The HTTP client factory.</param>
    /// <param name="logger">The logger.</param>
    public OmbiApiClient(IHttpClientFactory httpClientFactory, ILogger<OmbiApiClient> logger)
    {
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    private static PluginConfiguration Config =>
        Plugin.Instance?.Configuration
        ?? throw new InvalidOperationException("Ombi plugin is not initialized.");

    /// <inheritdoc />
    public async Task<OmbiOperationResult> TestConnectionAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var client = CreateClient(out var error);
            if (client is null)
            {
                return new OmbiOperationResult { Success = false, Message = error };
            }

            using var response = await client.GetAsync("api/v1/Status", cancellationToken).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                return new OmbiOperationResult { Success = true, Message = "Successfully connected to Ombi." };
            }

            return new OmbiOperationResult
            {
                Success = false,
                Message = string.Format(CultureInfo.InvariantCulture, "Ombi returned status {0}. Check the URL and API key.", (int)response.StatusCode)
            };
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            _logger.LogError(ex, "Failed to connect to Ombi");
            return new OmbiOperationResult { Success = false, Message = "Could not reach Ombi: " + ex.Message };
        }
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<OmbiSearchResult>> SearchMoviesAsync(string searchTerm, CancellationToken cancellationToken)
    {
        using var client = CreateClient(out _);
        if (client is null)
        {
            return Array.Empty<OmbiSearchResult>();
        }

        var path = "api/v1/Search/movie/" + Uri.EscapeDataString(searchTerm);
        var dtos = await GetJsonAsync<List<OmbiMovieSearchDto>>(client, path, cancellationToken).ConfigureAwait(false)
                   ?? new List<OmbiMovieSearchDto>();

        var results = new List<OmbiSearchResult>(dtos.Count);
        foreach (var dto in dtos)
        {
            results.Add(new OmbiSearchResult
            {
                MediaType = "movie",
                TheMovieDbId = dto.Id,
                Title = dto.Title,
                Overview = dto.Overview,
                ReleaseDate = dto.ReleaseDate,
                PosterPath = BuildPosterUrl(dto.PosterPath),
                Available = dto.Available,
                Requested = dto.Requested,
                Approved = dto.Approved
            });
        }

        return results;
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<OmbiSearchResult>> SearchTvAsync(string searchTerm, CancellationToken cancellationToken)
    {
        using var client = CreateClient(out _);
        if (client is null)
        {
            return Array.Empty<OmbiSearchResult>();
        }

        var path = "api/v1/Search/tv/" + Uri.EscapeDataString(searchTerm);
        var dtos = await GetJsonAsync<List<OmbiTvSearchDto>>(client, path, cancellationToken).ConfigureAwait(false)
                   ?? new List<OmbiTvSearchDto>();

        var results = new List<OmbiSearchResult>(dtos.Count);
        foreach (var dto in dtos)
        {
            int.TryParse(dto.TheMovieDbId, NumberStyles.Integer, CultureInfo.InvariantCulture, out var tmdbId);
            results.Add(new OmbiSearchResult
            {
                MediaType = "tv",
                TheTvDbId = dto.Id,
                TheMovieDbId = tmdbId,
                Title = dto.Title,
                Overview = dto.Overview,
                ReleaseDate = dto.FirstAired,
                PosterPath = dto.Banner,
                Available = dto.Available,
                Requested = dto.Requested,
                Approved = dto.Approved
            });
        }

        return results;
    }

    /// <inheritdoc />
    public async Task<OmbiOperationResult> RequestMovieAsync(int theMovieDbId, string? userName, CancellationToken cancellationToken)
    {
        using var client = CreateClient(out var error);
        if (client is null)
        {
            return new OmbiOperationResult { Success = false, Message = error };
        }

        AddUserName(client, userName);

        var body = new MovieRequestBody { TheMovieDbId = theMovieDbId };
        return await PostRequestAsync(client, "api/v1/Request/movie", body, cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task<OmbiOperationResult> RequestTvAsync(int tvDbId, bool requestAll, bool firstSeason, bool latestSeason, string? userName, CancellationToken cancellationToken)
    {
        using var client = CreateClient(out var error);
        if (client is null)
        {
            return new OmbiOperationResult { Success = false, Message = error };
        }

        AddUserName(client, userName);

        var body = new TvRequestBody
        {
            TvDbId = tvDbId,
            RequestAll = requestAll,
            FirstSeason = firstSeason,
            LatestSeason = latestSeason
        };
        return await PostRequestAsync(client, "api/v1/Request/tv", body, cancellationToken).ConfigureAwait(false);
    }

    private async Task<OmbiOperationResult> PostRequestAsync<TBody>(HttpClient client, string path, TBody body, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await client.PostAsJsonAsync(path, body, _jsonOptions, cancellationToken).ConfigureAwait(false);
            var payload = await response.Content
                .ReadFromJsonAsync<OmbiRequestResult>(_jsonOptions, cancellationToken)
                .ConfigureAwait(false);

            if (response.IsSuccessStatusCode && (payload?.Result ?? false))
            {
                return new OmbiOperationResult
                {
                    Success = true,
                    Message = payload?.Message ?? "Request submitted successfully."
                };
            }

            var message = payload?.ErrorMessage
                          ?? payload?.Message
                          ?? string.Format(CultureInfo.InvariantCulture, "Ombi returned status {0}.", (int)response.StatusCode);
            return new OmbiOperationResult { Success = false, Message = message };
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or TaskCanceledException)
        {
            _logger.LogError(ex, "Failed to submit request to Ombi at {Path}", path);
            return new OmbiOperationResult { Success = false, Message = "Request failed: " + ex.Message };
        }
    }

    private async Task<T?> GetJsonAsync<T>(HttpClient client, string path, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await client.GetAsync(path, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Ombi request to {Path} returned {StatusCode}", path, (int)response.StatusCode);
                return default;
            }

            return await response.Content.ReadFromJsonAsync<T>(_jsonOptions, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or TaskCanceledException)
        {
            _logger.LogError(ex, "Failed to query Ombi at {Path}", path);
            return default;
        }
    }

    private HttpClient? CreateClient(out string error)
    {
        error = string.Empty;
        var config = Config;

        if (string.IsNullOrWhiteSpace(config.OmbiUrl))
        {
            error = "Ombi URL is not configured.";
            return null;
        }

        if (string.IsNullOrWhiteSpace(config.ApiKey))
        {
            error = "Ombi API key is not configured.";
            return null;
        }

        if (!Uri.TryCreate(EnsureTrailingSlash(config.OmbiUrl), UriKind.Absolute, out var baseUri))
        {
            error = "Ombi URL is not a valid absolute URL.";
            return null;
        }

        var client = _httpClientFactory.CreateClient(NamedClient.Default);
        client.BaseAddress = baseUri;
        client.Timeout = TimeSpan.FromSeconds(30);
        client.DefaultRequestHeaders.Add("ApiKey", config.ApiKey);
        return client;
    }

    private static void AddUserName(HttpClient client, string? userName)
    {
        if (Config.RequestOnBehalfOfCurrentUser && !string.IsNullOrWhiteSpace(userName))
        {
            client.DefaultRequestHeaders.Remove("UserName");
            client.DefaultRequestHeaders.Add("UserName", userName);
        }
    }

    private static string? BuildPosterUrl(string? posterPath)
    {
        if (string.IsNullOrWhiteSpace(posterPath))
        {
            return null;
        }

        if (posterPath.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            return posterPath;
        }

        return PosterBaseUrl + (posterPath.StartsWith('/') ? posterPath : "/" + posterPath);
    }

    private static string EnsureTrailingSlash(string url) =>
        url.EndsWith('/') ? url : url + "/";
}
