import os

/// Atelier's log, by area, in Console under subsystem "Atelier" (AT-076 E3). Messages that name
/// a file, a model or an error are marked public so Console shows them; nothing in them is
/// private (no photo contents, no personal data).
public enum Log {
    /// AI models: Fine Edges, Depth Range, AI Denoise, the built-in models and their helpers.
    public static let models = Logger(subsystem: "Atelier", category: "Models")
    /// Match Look's fit: renders, stand-in tries, time.
    public static let matchLook = Logger(subsystem: "Atelier", category: "Match Look")
}
