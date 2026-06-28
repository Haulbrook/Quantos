// Shared auth helpers for Netlify Functions (CommonJS).

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};

/** Pull the bearer token from an event and resolve the Supabase user, or null. */
async function getUser(supabase, event) {
  const authHeader = event.headers.authorization || event.headers.Authorization || '';
  const token = authHeader.replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user;
}

/** True if `userId` holds one of `roles` on `accountId`. */
async function hasAccountRole(supabase, accountId, userId, roles) {
  const { data } = await supabase
    .from('memberships')
    .select('role')
    .eq('account_id', accountId)
    .eq('user_id', userId)
    .maybeSingle();
  return !!data && roles.includes(data.role);
}

module.exports = { CORS, getUser, hasAccountRole };
