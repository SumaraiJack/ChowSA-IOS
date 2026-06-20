-- Auto-creates a public.profiles row whenever an auth.users row is inserted.
-- Closes a gap in the sign-up flow: when Supabase email confirmation is
-- enabled, the client's _signUp() returns BEFORE calling _upsertProfile(),
-- so users who confirm via email link would otherwise have NO profiles
-- row at all — invisible to every find_user_by_handle() search.
--
-- The trigger pulls the chosen handle from raw_user_meta_data (set client-
-- side at auth.signUp(data: {handle})) and falls back to the email local
-- part if none was provided. Both `handle` and `username` are populated so
-- both lookup branches in find_user_by_handle() resolve.

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  meta_handle text;
BEGIN
  meta_handle := NULLIF(
    btrim(
      COALESCE(
        NEW.raw_user_meta_data->>'handle',
        NEW.raw_user_meta_data->>'username',
        split_part(COALESCE(NEW.email, ''), '@', 1)
      )
    ),
    ''
  );

  INSERT INTO public.profiles (id, email, handle, username)
  VALUES (NEW.id, NEW.email, meta_handle, meta_handle)
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- Backfill any existing auth.users rows that don't yet have a profile.
INSERT INTO public.profiles (id, email, handle, username)
SELECT
  u.id,
  u.email,
  NULLIF(
    btrim(
      COALESCE(
        u.raw_user_meta_data->>'handle',
        u.raw_user_meta_data->>'username',
        split_part(COALESCE(u.email, ''), '@', 1)
      )
    ),
    ''
  ) AS h,
  NULLIF(
    btrim(
      COALESCE(
        u.raw_user_meta_data->>'handle',
        u.raw_user_meta_data->>'username',
        split_part(COALESCE(u.email, ''), '@', 1)
      )
    ),
    ''
  ) AS uname
FROM auth.users u
LEFT JOIN public.profiles p ON p.id = u.id
WHERE p.id IS NULL;
