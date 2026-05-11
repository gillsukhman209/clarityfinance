const { methodNotAllowed, sendJson } = require("../_lib/http");
const { requireSupabaseUser } = require("../_lib/supabaseAuth");

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    return methodNotAllowed(res, "GET");
  }

  try {
    const user = await requireSupabaseUser(req);
    return sendJson(res, 200, {
      ok: true,
      user: {
        id: user.id,
        email: user.email || null
      }
    });
  } catch (error) {
    return sendJson(res, error.statusCode || 500, {
      ok: false,
      error: error.message || "auth_check_failed"
    });
  }
};
