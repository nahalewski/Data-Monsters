using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.Ombi.Ombi.Models;

namespace Jellyfin.Plugin.Ombi.Ombi;

/// <summary>
/// Client for talking to an Ombi server.
/// </summary>
public interface IOmbiApiClient
{
    /// <summary>
    /// Verifies connectivity and authentication against the configured Ombi server.
    /// </summary>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>An operation result describing whether the connection succeeded.</returns>
    Task<OmbiOperationResult> TestConnectionAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Searches Ombi for movies matching the supplied term.
    /// </summary>
    /// <param name="searchTerm">The search term.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The list of matching movies.</returns>
    Task<IReadOnlyList<OmbiSearchResult>> SearchMoviesAsync(string searchTerm, CancellationToken cancellationToken);

    /// <summary>
    /// Searches Ombi for TV shows matching the supplied term.
    /// </summary>
    /// <param name="searchTerm">The search term.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The list of matching shows.</returns>
    Task<IReadOnlyList<OmbiSearchResult>> SearchTvAsync(string searchTerm, CancellationToken cancellationToken);

    /// <summary>
    /// Requests a movie from Ombi.
    /// </summary>
    /// <param name="theMovieDbId">The TheMovieDb id of the movie.</param>
    /// <param name="userName">Optional Ombi username to attribute the request to.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The outcome of the request.</returns>
    Task<OmbiOperationResult> RequestMovieAsync(int theMovieDbId, string? userName, CancellationToken cancellationToken);

    /// <summary>
    /// Requests a TV show from Ombi.
    /// </summary>
    /// <param name="tvDbId">The TheTvDb id of the show.</param>
    /// <param name="requestAll">Whether to request every season.</param>
    /// <param name="firstSeason">Whether to request only the first season.</param>
    /// <param name="latestSeason">Whether to request only the latest season.</param>
    /// <param name="userName">Optional Ombi username to attribute the request to.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The outcome of the request.</returns>
    Task<OmbiOperationResult> RequestTvAsync(int tvDbId, bool requestAll, bool firstSeason, bool latestSeason, string? userName, CancellationToken cancellationToken);
}
