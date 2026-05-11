const { ensureSchema, sql } = require("../_lib/db");
const { sendJson } = require("../_lib/http");
const { generateAndSendForDevice } = require("../_lib/notificationDelivery");

module.exports = async function handler(req, res) {
  if (req.method !== "GET" && req.method !== "POST") {
    return sendJson(res, 405, { ok: false, error: "method_not_allowed" });
  }

  if (process.env.CRON_SECRET) {
    const header = req.headers.authorization || "";
    if (header !== `Bearer ${process.env.CRON_SECRET}`) {
      return sendJson(res, 401, { ok: false, error: "unauthorized" });
    }
  }

  try {
    await ensureSchema();
    const db = sql();
    const devices = await db`select * from devices where enabled = true`;
    const results = [];

    for (const device of devices) {
      results.push(await generateAndSendForDevice({
        db,
        device,
        expensiveDayOnly: true
      }));
    }

    return sendJson(res, 200, { ok: true, checked: devices.length, results });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error.message });
  }
};
