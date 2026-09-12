/// The destinations the home shell keeps alive as pages.
///
/// Search and setup are tasks the user finishes and leaves, so they stay
/// pushed routes with their own way back. These two are places the user
/// dwells in, so they are pages of one shell under a persistent navigation
/// bar — a pushed route would leave no way back to the one underneath it.
enum HomeDestination { home, matches }
