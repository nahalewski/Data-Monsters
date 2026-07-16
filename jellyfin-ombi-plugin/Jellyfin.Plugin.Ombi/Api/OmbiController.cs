using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Security.Claims;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.Ombi.Ombi;
using Jellyfin.Plugin.Ombi.Ombi.Models;
using MediaBrowser.Controller.Library;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.Ombi.Api;

/// <summary>
/// API endpoints backing the Ombi request UI. All endpoints require an authenticated Jellyfin user.
/// </summary>
[ApiController]
[Authorize]
[Route("Ombi")]
[Produces("application/json")]
public class OmbiController : ControllerBase
{
    private readonly IOmbiApiClient _ombiClient;
    private readonly IUserManager _userManager;

    /// <summary>
    /// Initializes a new instance of the <see cref="OmbiController"/> class.
    /// </summary>
    /// <param name="ombiClient">The Ombi API client.</param>
    /// <param name="userManager">The Jellyfin user manager.</param>
    public OmbiController(IOmbiApiClient ombiClient, IUserManager userManager)
    {
        _ombiClient = ombiClient;
        _userManager = userManager;
    }

    /// <summary>
    /// Tests the connection to the configured Ombi server. Administrators only.
    /// </summary>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The connection test result.</returns>
    [HttpGet("TestConnection")]
    [Authorize(Policy = "RequiresElevation")]
    public async Task<ActionResult<OmbiOperationResult>> TestConnection(CancellationToken cancellationToken)
    {
        return await _ombiClient.TestConnectionAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Searches Ombi for movies and/or TV shows.
    /// </summary>
    /// <param name="query">The search term.</param>
    /// <param name="type">The media type to search: "movie", "tv", or "all" (default).</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The matching results.</returns>
    [HttpGet("Search")]
    public async Task<ActionResult<IReadOnlyList<OmbiSearchResult>>> Search(
        [FromQuery, Required] string query,
        [FromQuery] string type,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return new List<OmbiSearchResult>();
        }

        type = string.IsNullOrWhiteSpace(type) ? "all" : type.ToLowerInvariant();
        var results = new List<OmbiSearchResult>();

        if (type is "all" or "movie")
        {
            results.AddRange(await _ombiClient.SearchMoviesAsync(query, cancellationToken).ConfigureAwait(false));
        }

        if (type is "all" or "tv")
        {
            results.AddRange(await _ombiClient.SearchTvAsync(query, cancellationToken).ConfigureAwait(false));
        }

        return results;
    }

    /// <summary>
    /// Requests a movie from Ombi.
    /// </summary>
    /// <param name="body">The movie request payload.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The request outcome.</returns>
    [HttpPost("Request/Movie")]
    public async Task<ActionResult<OmbiOperationResult>> RequestMovie(
        [FromBody] MovieRequestBody body,
        CancellationToken cancellationToken)
    {
        var result = await _ombiClient
            .RequestMovieAsync(body.TheMovieDbId, GetCurrentUserName(), cancellationToken)
            .ConfigureAwait(false);
        return result;
    }

    /// <summary>
    /// Requests a TV show from Ombi.
    /// </summary>
    /// <param name="body">The TV request payload.</param>
    /// <param name="cancellationToken">The cancellation token.</param>
    /// <returns>The request outcome.</returns>
    [HttpPost("Request/Tv")]
    public async Task<ActionResult<OmbiOperationResult>> RequestTv(
        [FromBody] TvRequestPayload body,
        CancellationToken cancellationToken)
    {
        var config = Plugin.Instance?.Configuration;
        var requestAll = body.RequestAll ?? config?.DefaultRequestAllSeasons ?? true;

        var result = await _ombiClient
            .RequestTvAsync(body.TvDbId, requestAll, body.FirstSeason, body.LatestSeason, GetCurrentUserName(), cancellationToken)
            .ConfigureAwait(false);
        return result;
    }

    private string? GetCurrentUserName()
    {
        // The Jellyfin authentication middleware stashes the user id in this claim.
        var raw = User.FindFirstValue("Jellyfin-UserId");
        if (!Guid.TryParse(raw, out var userId) || userId.Equals(default))
        {
            return null;
        }

        return _userManager.GetUserById(userId)?.Username;
    }
}

/// <summary>
/// Incoming payload for a TV request from the web UI.
/// </summary>
public class TvRequestPayload
{
    /// <summary>Gets or sets the TheTvDb id of the show.</summary>
    public int TvDbId { get; set; }

    /// <summary>Gets or sets a value indicating whether every season should be requested. Falls back to the configured default when null.</summary>
    public bool? RequestAll { get; set; }

    /// <summary>Gets or sets a value indicating whether only the first season should be requested.</summary>
    public bool FirstSeason { get; set; }

    /// <summary>Gets or sets a value indicating whether only the latest season should be requested.</summary>
    public bool LatestSeason { get; set; }
}
