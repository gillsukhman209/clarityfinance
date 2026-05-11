const { ensureSchema, sql } = require("../_lib/db");
const { methodNotAllowed, readJson, sendJson } = require("../_lib/http");
const { sendBestCandidate } = require("../_lib/notificationDelivery");

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    const body = await readJson(req);
    const deviceID = String(body.device_id || "").trim();
    if (!deviceID) {
      return sendJson(res, 400, { ok: false, error: "device_id_required" });
    }

    await ensureSchema();
    const db = sql();
    const rows = await db`select * from devices where device_id = ${deviceID} limit 1`;
    if (rows.length === 0) {
      return sendJson(res, 404, { ok: false, error: "device_not_registered" });
    }

    const candidate = {
      type: "test",
      score: 100,
      merchantKey: "test",
      transactionId: null,
      title: "Clarity test",
      body: body.body || "Notifications are wired. Your spending will not be quiet."
    };
    const delivery = await sendBestCandidate({
      db,
      device: rows[0],
      candidates: [candidate],
      bypassDailyCap: true,
      bypassDedupe: true
    });
    return sendJson(res, 200, { ok: true, delivery });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error.message });
  }
};
