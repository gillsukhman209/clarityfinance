const { decrypt, encrypt } = require("../../_lib/crypto");
const { ensureSchema, sql } = require("../../_lib/db");
const { methodNotAllowed, readJson, sendJson } = require("../../_lib/http");
const { updateItemWebhook } = require("../../_lib/plaid");
const { webhookURLForRequest } = require("../../_lib/requestUrl");
const { requireSupabaseUser } = require("../../_lib/supabaseAuth");

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    const user = await requireSupabaseUser(req);
    const body = await readJson(req);
    const deviceID = String(body.device_id || "").trim();
    const itemID = String(body.item_id || "").trim();
    const accessToken = String(body.access_token || "").trim();
    const environment = body.environment === "production" ? "production" : "sandbox";

    if (!deviceID || !itemID) {
      return sendJson(res, 400, { ok: false, error: "device_id_and_item_id_required" });
    }

    await ensureSchema();
    const db = sql();
    const devices = await db`
      select device_id
      from devices
      where device_id = ${deviceID}
        and user_id = ${user.id}
      limit 1
    `;
    if (devices.length === 0) {
      return sendJson(res, 403, { ok: false, error: "device_not_registered_for_user" });
    }

    let storedAccessToken = accessToken;
    const existingItems = await db`
      select access_token_encrypted, environment
      from plaid_items
      where item_id = ${itemID}
        and user_id = ${user.id}
      limit 1
    `;
    if (!storedAccessToken && existingItems.length > 0) {
      storedAccessToken = decrypt(existingItems[0].access_token_encrypted);
    }
    if (!storedAccessToken) {
      return sendJson(res, 404, { ok: false, error: "plaid_item_not_found_for_user" });
    }

    if (accessToken) {
      const encryptedAccessToken = encrypt(accessToken);
      await db`
        insert into plaid_items (
          item_id,
          user_id,
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
          ${user.id},
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
          user_id = excluded.user_id,
          device_id = excluded.device_id,
          access_token_encrypted = excluded.access_token_encrypted,
          environment = excluded.environment,
          institution_id = excluded.institution_id,
          institution_name = excluded.institution_name,
          cursor = coalesce(excluded.cursor, plaid_items.cursor),
          updated_at = now()
      `;
    } else {
      await db`
        update plaid_items
        set device_id = ${deviceID}, updated_at = now()
        where item_id = ${itemID}
          and user_id = ${user.id}
      `;
    }

    const webhookURL = webhookURLForRequest(req);
    const webhook = await updateItemWebhook({ accessToken: storedAccessToken, environment, webhookURL });
    return sendJson(res, 200, { ok: true, user_id: user.id, webhook });
  } catch (error) {
    return sendJson(res, error.statusCode || 500, { ok: false, error: error.message, plaid: error.payload });
  }
};
