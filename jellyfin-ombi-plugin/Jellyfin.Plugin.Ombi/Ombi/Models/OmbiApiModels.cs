using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Jellyfin.Plugin.Ombi.Ombi.Models;

/// <summary>
/// Raw movie search result as returned by Ombi's <c>/api/v1/Search/movie</c> endpoint.
/// Only the fields the plugin consumes are mapped.
/// </summary>
public class OmbiMovieSearchDto
{
    /// <summary>Gets or sets the TheMovieDb id (serialized by Ombi as a string).</summary>
    [JsonPropertyName("id")]
    public int Id { get; set; }

    /// <summary>Gets or sets the title.</summary>
    [JsonPropertyName("title")]
    public string Title { get; set; } = string.Empty;

    /// <summary>Gets or sets the overview.</summary>
    [JsonPropertyName("overview")]
    public string Overview { get; set; } = string.Empty;

    /// <summary>Gets or sets the release date.</summary>
    [JsonPropertyName("releaseDate")]
    public string? ReleaseDate { get; set; }

    /// <summary>Gets or sets the poster path.</summary>
    [JsonPropertyName("posterPath")]
    public string? PosterPath { get; set; }

    /// <summary>Gets or sets a value indicating whether the movie is available.</summary>
    [JsonPropertyName("available")]
    public bool Available { get; set; }

    /// <summary>Gets or sets a value indicating whether the movie was requested.</summary>
    [JsonPropertyName("requested")]
    public bool Requested { get; set; }

    /// <summary>Gets or sets a value indicating whether the movie was approved.</summary>
    [JsonPropertyName("approved")]
    public bool Approved { get; set; }
}

/// <summary>
/// Raw TV search result as returned by Ombi's <c>/api/v1/Search/tv</c> endpoint.
/// </summary>
public class OmbiTvSearchDto
{
    /// <summary>Gets or sets the TheTvDb id.</summary>
    [JsonPropertyName("id")]
    public int Id { get; set; }

    /// <summary>Gets or sets the TheMovieDb id.</summary>
    [JsonPropertyName("theMovieDbId")]
    public string? TheMovieDbId { get; set; }

    /// <summary>Gets or sets the title.</summary>
    [JsonPropertyName("title")]
    public string Title { get; set; } = string.Empty;

    /// <summary>Gets or sets the overview.</summary>
    [JsonPropertyName("overview")]
    public string Overview { get; set; } = string.Empty;

    /// <summary>Gets or sets the first air date.</summary>
    [JsonPropertyName("firstAired")]
    public string? FirstAired { get; set; }

    /// <summary>Gets or sets the banner/poster path.</summary>
    [JsonPropertyName("banner")]
    public string? Banner { get; set; }

    /// <summary>Gets or sets a value indicating whether the show is available.</summary>
    [JsonPropertyName("available")]
    public bool Available { get; set; }

    /// <summary>Gets or sets a value indicating whether the show was requested.</summary>
    [JsonPropertyName("requested")]
    public bool Requested { get; set; }

    /// <summary>Gets or sets a value indicating whether the show was approved.</summary>
    [JsonPropertyName("approved")]
    public bool Approved { get; set; }
}

/// <summary>
/// Request body for <c>POST /api/v1/Request/movie</c>.
/// </summary>
public class MovieRequestBody
{
    /// <summary>Gets or sets the TheMovieDb id of the movie to request.</summary>
    [JsonPropertyName("theMovieDbId")]
    public int TheMovieDbId { get; set; }
}

/// <summary>
/// Request body for <c>POST /api/v1/Request/tv</c>.
/// </summary>
public class TvRequestBody
{
    /// <summary>Gets or sets the TheTvDb id of the show to request.</summary>
    [JsonPropertyName("tvDbId")]
    public int TvDbId { get; set; }

    /// <summary>Gets or sets a value indicating whether every season should be requested.</summary>
    [JsonPropertyName("requestAll")]
    public bool RequestAll { get; set; }

    /// <summary>Gets or sets a value indicating whether only the first season should be requested.</summary>
    [JsonPropertyName("firstSeason")]
    public bool FirstSeason { get; set; }

    /// <summary>Gets or sets a value indicating whether only the latest season should be requested.</summary>
    [JsonPropertyName("latestSeason")]
    public bool LatestSeason { get; set; }
}

/// <summary>
/// Standard response envelope returned by Ombi request endpoints.
/// </summary>
public class OmbiRequestResult
{
    /// <summary>Gets or sets a value indicating whether the request succeeded.</summary>
    [JsonPropertyName("result")]
    public bool Result { get; set; }

    /// <summary>Gets or sets the error message, if any.</summary>
    [JsonPropertyName("errorMessage")]
    public string? ErrorMessage { get; set; }

    /// <summary>Gets or sets the informational message, if any.</summary>
    [JsonPropertyName("message")]
    public string? Message { get; set; }

    /// <summary>Gets or sets the identifier of the created request, if any.</summary>
    [JsonPropertyName("requestId")]
    public int? RequestId { get; set; }
}

/// <summary>
/// Aggregate result returned to callers describing the outcome of an operation.
/// </summary>
public class OmbiOperationResult
{
    /// <summary>Gets or sets a value indicating whether the operation succeeded.</summary>
    public bool Success { get; set; }

    /// <summary>Gets or sets a human-readable message describing the outcome.</summary>
    public string Message { get; set; } = string.Empty;

    /// <summary>Gets or sets the search results, when applicable.</summary>
    public IReadOnlyList<OmbiSearchResult>? Results { get; set; }
}
