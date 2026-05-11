const { ensureSchema, sql } = require("../_lib/db");
const { methodNotAllowed, readJson, requireSharedSecret, sendJson } = require("../_lib/http");
const { loadDeviceTransactions } = require("../_lib/notificationDelivery");
const { generateNotificationCandidates } = require("../_lib/notificationEngine");

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  if (!requireSharedSecret(req)) {
    return sendJson(res, 401, { ok: false, error: "unauthorized" });
  }

  try {
    const body = await readJson(req);
    let transactions = Array.isArray(body.transactions) ? body.transactions : [];
    const deviceID = String(body.device_id || "").trim();

    if (transactions.length === 0 && deviceID) {
      await ensureSchema();
      transactions = await loadDeviceTransactions(sql(), deviceID);
    }

    const candidates = generateNotificationCandidates({
      transactions,
      newTransactions: Array.isArray(body.new_transactions) ? body.new_transactions : [],
      settings: {
        tone: body.tone || "funny",
        privacy: body.privacy || "merchant_amount"
      }
    });

    return sendJson(res, 200, { ok: true, candidates });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error.message });
  }
};
