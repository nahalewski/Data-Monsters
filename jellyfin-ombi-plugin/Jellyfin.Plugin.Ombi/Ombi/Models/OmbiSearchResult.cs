using System.Text.Json.Serialization;

namespace Jellyfin.Plugin.Ombi.Ombi.Models;

/// <summary>
/// A normalized search result returned to the Jellyfin UI, covering both
/// movie and TV results from Ombi's search endpoints.
/// </summary>
public class OmbiSearchResult
{
    /// <summary>
    /// Gets or sets the media type, either "movie" or "tv".
    /// </summary>
    [JsonPropertyName("mediaType")]
    public string MediaType { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the TheMovieDb identifier for the title.
    /// </summary>
    [JsonPropertyName("theMovieDbId")]
    public int TheMovieDbId { get; set; }

    /// <summary>
    /// Gets or sets the TheTvDb identifier for the title (TV only, may be 0).
    /// </summary>
    [JsonPropertyName("theTvDbId")]
    public int TheTvDbId { get; set; }

    /// <summary>
    /// Gets or sets the display title.
    /// </summary>
    [JsonPropertyName("title")]
    public string Title { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the plot overview.
    /// </summary>
    [JsonPropertyName("overview")]
    public string Overview { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the release/first-air date string.
    /// </summary>
    [JsonPropertyName("releaseDate")]
    public string? ReleaseDate { get; set; }

    /// <summary>
    /// Gets or sets the poster image path (fully-qualified URL).
    /// </summary>
    [JsonPropertyName("posterPath")]
    public string? PosterPath { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the title is already available in the library.
    /// </summary>
    [JsonPropertyName("available")]
    public bool Available { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the title has already been requested.
    /// </summary>
    [JsonPropertyName("requested")]
    public bool Requested { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the title has been approved.
    /// </summary>
    [JsonPropertyName("approved")]
    public bool Approved { get; set; }
}
