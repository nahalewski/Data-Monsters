using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.Ombi.Configuration;

/// <summary>
/// Plugin configuration holding the Ombi connection details.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Initializes a new instance of the <see cref="PluginConfiguration"/> class.
    /// </summary>
    public PluginConfiguration()
    {
        OmbiUrl = string.Empty;
        ApiKey = string.Empty;
        RequestOnBehalfOfCurrentUser = true;
        DefaultRequestAllSeasons = true;
    }

    /// <summary>
    /// Gets or sets the base URL of the Ombi server (e.g. http://localhost:5000).
    /// </summary>
    public string OmbiUrl { get; set; }

    /// <summary>
    /// Gets or sets the Ombi API key. Found in Ombi under Settings &gt; Configuration &gt; General.
    /// </summary>
    public string ApiKey { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether requests should be submitted on behalf of the
    /// current Jellyfin user (using their username as the Ombi <c>UserName</c> header) when a
    /// matching Ombi account exists. When false, requests are attributed to the API key owner.
    /// </summary>
    public bool RequestOnBehalfOfCurrentUser { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether TV requests default to requesting all seasons.
    /// </summary>
    public bool DefaultRequestAllSeasons { get; set; }
}
