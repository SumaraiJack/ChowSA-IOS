-- SECURITY DEFINER lookup functions so authenticated users can find each
-- other by handle/username (Kitchen Circle invite, chat author hydration)
-- WITHOUT relaxing the row-level read policy on `profiles`. Each function
-- returns only the safe public fields — no email, no cooking_preferences.

CREATE OR REPLACE FUNCTION public.find_user_by_handle(
  q text
)
RETURNS TABLE (
  id          uuid,
  username    text,
  handle      text,
  avatar_url  text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.username, p.handle, p.avatar_url
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
    AND (
      lower(p.username) = lower(trim(q)) OR
      lower(p.handle)   = lower(trim(q))
    )
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.find_user_by_handle(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.find_user_by_handle(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_public_profile(
  uid uuid
)
RETURNS TABLE (
  id          uuid,
  username    text,
  handle      text,
  avatar_url  text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id, p.username, p.handle, p.avatar_url
  FROM public.profiles p
  WHERE auth.uid() IS NOT NULL
    AND p.id = uid
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_public_profile(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_public_profile(uuid) TO authenticated;
