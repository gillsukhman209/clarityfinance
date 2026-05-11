function supabaseConfig() {
  const url = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required.");
  }

  return {
    url: url.replace(/\/+$/, ""),
    anonKey
  };
}

function bearerToken(req) {
  const header = req.headers.authorization || req.headers.Authorization;
  if (!header || typeof header !== "string") {
    return null;
  }

  const match = header.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

async function requireSupabaseUser(req) {
  const token = bearerToken(req);
  if (!token) {
    const error = new Error("missing_bearer_token");
    error.statusCode = 401;
    throw error;
  }

  const { url, anonKey } = supabaseConfig();
  const response = await fetch(`${url}/auth/v1/user`, {
    method: "GET",
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${token}`
    }
  });

  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { message: text };
  }

  if (!response.ok) {
    const error = new Error(body.msg || body.message || body.error || "invalid_supabase_token");
    error.statusCode = response.status;
    throw error;
  }

  return body;
}

module.exports = {
  requireSupabaseUser
};
