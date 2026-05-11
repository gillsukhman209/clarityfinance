const { encrypt } = require("../../_lib/crypto");
const { ensureSchema, sql } = require("../../_lib/db");
const { methodNotAllowed, readJson, sendJson } = require("../../_lib/http");
const { updateItemWebhook } = require("../../_lib/plaid");

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    const body = await readJson(req);
    const deviceID = String(body.device_id || "").trim();
    const itemID = String(body.item_id || "").trim();
    const accessToken = String(body.access_token || "").trim();
    const environment = body.environment === "production" ? "production" : "sandbox";

    if (!deviceID || !itemID || !accessToken) {
      return sendJson(res, 400, { ok: false, error: "device_id_item_id_access_token_required" });
    }

    await ensureSchema();
    const db = sql();
    const encryptedAccessToken = encrypt(accessToken);
    await db`
      insert into plaid_items (
        item_id,
        device_id,
        access_token_encrypted,
        environment,
        institution_id,
        institution_name,
        cursor,
        updated_at
      )
      values (
        ${itemID},
        ${deviceID},
        ${encryptedAccessToken},
        ${environment},
        ${body.institution_id || null},
        ${body.institution_name || null},
        ${body.cursor || null},
        now()
      )
      on conflict (item_id)
      do update set
        device_id = excluded.device_id,
        access_token_encrypted = excluded.access_token_encrypted,
        environment = excluded.environment,
        institution_id = excluded.institution_id,
        institution_name = excluded.institution_name,
        cursor = coalesce(excluded.cursor, plaid_items.cursor),
        updated_at = now()
    `;

    const webhookURL = process.env.PLAID_WEBHOOK_URL;
    const webhook = await updateItemWebhook({ accessToken, environment, webhookURL });
    return sendJson(res, 200, { ok: true, webhook });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error.message, plaid: error.payload });
  }
};
