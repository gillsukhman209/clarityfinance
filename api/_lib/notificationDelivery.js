const { sendPush } = require("./apns");
const { generateExpensiveDayCandidate, generateNotificationCandidates, merchantKey } = require("./notificationEngine");

async function hasSentToday(db, deviceID) {
  const rows = await db`
    select id
    from notification_events
    where device_id = ${deviceID}
      and status = 'sent'
      and (created_at at time zone 'America/Los_Angeles')::date = (now() at time zone 'America/Los_Angeles')::date
    limit 1
  `;
  return rows.length > 0;
}

async function wasRecentlySent(db, deviceID, candidate) {
  const rows = await db`
    select id
    from notification_events
    where device_id = ${deviceID}
      and status = 'sent'
      and event_type = ${candidate.type}
      and coalesce(merchant_key, '') = coalesce(${candidate.merchantKey}, '')
      and created_at >= now() - interval '7 days'
    limit 1
  `;
  return rows.length > 0;
}

async function recordEvent(db, device, candidate, status, reason, itemID = null) {
  await db`
    insert into notification_events (
      user_id,
      device_id,
      item_id,
      event_type,
      merchant_key,
      transaction_id,
      title,
      body,
      status,
      reason
    )
    values (
      ${device.user_id || null},
      ${device.device_id},
      ${itemID},
      ${candidate.type},
      ${candidate.merchantKey},
      ${candidate.transactionId},
      ${candidate.title},
      ${candidate.body},
      ${status},
      ${reason || null}
    )
  `;
}

async function sendBestCandidate({ db, device, itemID, candidates, bypassDailyCap = false, bypassDedupe = false }) {
  if (!device.enabled) {
    if (candidates[0]) {
      await recordEvent(db, device, candidates[0], "suppressed", "notifications_disabled", itemID);
    }
    return { sent: false, reason: "notifications_disabled", candidates };
  }

  if (!bypassDailyCap && await hasSentToday(db, device.device_id)) {
    if (candidates[0]) {
      await recordEvent(db, device, candidates[0], "suppressed", "daily_cap", itemID);
    }
    return { sent: false, reason: "daily_cap", candidates };
  }

  for (const candidate of candidates) {
    if (!bypassDedupe && await wasRecentlySent(db, device.device_id, candidate)) {
      await recordEvent(db, device, candidate, "suppressed", "recent_duplicate", itemID);
      continue;
    }

    const result = await sendPush(device, candidate);
    await recordEvent(
      db,
      device,
      candidate,
      result.sent || result.dryRun ? "sent" : "failed",
      result.reason || null,
      itemID
    );
    return { ...result, candidate };
  }

  return { sent: false, reason: "no_sendable_candidate", candidates };
}

function settingsFromDevice(device) {
  return {
    tone: device.tone || "funny",
    privacy: device.privacy || "merchant_amount"
  };
}

async function loadDeviceTransactions(db, deviceID) {
  return db`
    select
      transaction_id as "transactionId",
      item_id as "itemId",
      account_id as "accountId",
      merchant_name as "merchantName",
      original_name as "originalName",
      amount::float as amount,
      date::text as date,
      category,
      pending,
      source
    from transactions
    where item_id in (
      select item_id
      from plaid_items
      where device_id = ${deviceID}
    )
    order by date desc
  `;
}

async function generateAndSendForDevice({ db, device, itemID = null, newTransactions = [], expensiveDayOnly = false }) {
  const transactions = await loadDeviceTransactions(db, device.device_id);
  const candidates = expensiveDayOnly
    ? [generateExpensiveDayCandidate({ transactions, settings: settingsFromDevice(device) })].filter(Boolean)
    : generateNotificationCandidates({
      transactions,
      newTransactions,
      settings: settingsFromDevice(device)
    });

  if (candidates.length === 0) {
    const placeholder = {
      type: expensiveDayOnly ? "expensive_day" : "none",
      merchantKey: merchantKey("none"),
      transactionId: null,
      title: null,
      body: null
    };
    await recordEvent(db, device, placeholder, "suppressed", "no_candidate", itemID);
    return { sent: false, reason: "no_candidate", candidates: [] };
  }

  return sendBestCandidate({ db, device, itemID, candidates });
}

module.exports = {
  generateAndSendForDevice,
  loadDeviceTransactions,
  sendBestCandidate
};
