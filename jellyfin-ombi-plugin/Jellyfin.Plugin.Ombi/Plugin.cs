using System;
using System.Collections.Generic;
using System.Globalization;
using Jellyfin.Plugin.Ombi.Configuration;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;

namespace Jellyfin.Plugin.Ombi;

/// <summary>
/// The main plugin class. Registers configuration pages and exposes the
/// shared <see cref="PluginConfiguration"/> holding the Ombi connection details.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    /// <summary>
    /// Initializes a new instance of the <see cref="Plugin"/> class.
    /// </summary>
    /// <param name="applicationPaths">Instance of the <see cref="IApplicationPaths"/> interface.</param>
    /// <param name="xmlSerializer">Instance of the <see cref="IXmlSerializer"/> interface.</param>
    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
    }

    /// <inheritdoc />
    public override string Name => "Ombi Requests";

    /// <inheritdoc />
    public override string Description => "Search and request movies and TV shows through an Ombi server, directly from Jellyfin.";

    /// <inheritdoc />
    public override Guid Id => Guid.Parse("7b222f6f-30f2-4709-9170-3c46087c81c3");

    /// <summary>
    /// Gets the current plugin instance.
    /// </summary>
    public static Plugin? Instance { get; private set; }

    /// <inheritdoc />
    public IEnumerable<PluginPageInfo> GetPages()
    {
        var prefix = GetType().Namespace;
        return new[]
        {
            new PluginPageInfo
            {
                Name = "OmbiConfig",
                EmbeddedResourcePath = string.Format(CultureInfo.InvariantCulture, "{0}.Configuration.configPage.html", prefix)
            },
            new PluginPageInfo
            {
                Name = "OmbiRequests",
                EmbeddedResourcePath = string.Format(CultureInfo.InvariantCulture, "{0}.Configuration.requestPage.html", prefix)
            }
        };
    }
}
