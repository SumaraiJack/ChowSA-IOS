// lib/config/supabase_config.dart
//
// Central home for all Supabase connection constants.
// Import this wherever you need direct client access — or let main.dart
// initialise the singleton once and use Supabase.instance.client everywhere.
//
// ⚠️  The anon key is safe to ship in a client app — it is intentionally
//     public and is restricted by Supabase Row-Level Security policies.
//     Never store your service-role key here.

abstract final class SupabaseConfig {
  /// Base project URL (no trailing slash, no /rest/v1 path).
  /// Full REST endpoint: $url/rest/v1/
  static const String url = 'https://arxwrwzhzyzckveijexl.supabase.co';

  /// Publishable anon key — scoped to RLS-enforced public access.
  static const String anonKey =
      'sb_publishable_PjZk5Jwg4Po3ONVzhVhQoQ_M-6HIsaV';
}
