const { ensureSchema, sql } = require("../_lib/db");
const { methodNotAllowed, readJson, sendJson } = require("../_lib/http");

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    const body = await readJson(req);
    const deviceID = String(body.device_id || "").trim();
    const apnsToken = String(body.apns_token || "").trim();
    const platform = String(body.platform || "ios").trim();
    const tone = String(body.tone || "funny").trim();
    const privacy = String(body.privacy || "merchant_amount").trim();
    const enabled = body.enabled !== false;

    if (!deviceID || !apnsToken) {
      return sendJson(res, 400, { ok: false, error: "device_id_and_apns_token_required" });
    }

    await ensureSchema();
    const db = sql();
    await db`
      insert into devices (device_id, apns_token, platform, enabled, tone, privacy, updated_at)
      values (${deviceID}, ${apnsToken}, ${platform}, ${enabled}, ${tone}, ${privacy}, now())
      on conflict (device_id)
      do update set
        apns_token = excluded.apns_token,
        platform = excluded.platform,
        enabled = excluded.enabled,
        tone = excluded.tone,
        privacy = excluded.privacy,
        updated_at = now()
    `;

    return sendJson(res, 200, { ok: true });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error.message });
  }
};
